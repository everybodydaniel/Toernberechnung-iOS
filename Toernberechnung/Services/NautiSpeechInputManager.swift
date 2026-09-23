import AVFAudio
import CoreMedia
import Foundation
import Observation
import OSLog
import Speech

struct NautiSpeechTranscript: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

enum NautiSpeechPermission: Equatable, Sendable {
    case authorized
    case denied
    case restricted
}

enum NautiSpeechInputError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case permissionRestricted
    case onDeviceRecognitionUnavailable
    case unsupportedGerman
    case assetsUnavailable
    case audioSessionUnavailable
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Mikrofon oder Spracherkennung wurde nicht erlaubt. Du kannst den Zugriff in den Einstellungen aktivieren."
        case .permissionRestricted:
            return "Spracherkennung ist auf diesem Gerät eingeschränkt."
        case .onDeviceRecognitionUnavailable:
            return "Die lokale deutsche Spracherkennung ist auf diesem Gerät nicht verfügbar."
        case .unsupportedGerman:
            return "Für Deutsch ist auf diesem Gerät kein lokales Sprachmodell verfügbar."
        case .assetsUnavailable:
            #if targetEnvironment(simulator)
            return "Die lokalen Sprachressourcen sind im Simulator nicht verfügbar. Bitte teste die Spracheingabe auf einem echten iPhone oder iPad."
            #else
            return "Die lokalen Sprachressourcen sind noch nicht verfügbar. Verbinde das Gerät mit dem Internet, prüfe unter Einstellungen › Allgemein › Tastatur, ob Diktierfunktion und Deutsch aktiviert sind, und versuche es erneut."
            #endif
        case .audioSessionUnavailable:
            return "Das Mikrofon konnte gerade nicht gestartet werden."
        case .recognitionFailed:
            return "Die Spracheingabe konnte nicht verarbeitet werden."
        }
    }
}

@MainActor
protocol NautiSpeechInputClient: AnyObject {
    func requestPermission() async -> NautiSpeechPermission
    func startTranscription() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error>
    func stopTranscription() async
    func cancelTranscription() async
}

@MainActor
@Observable
final class NautiSpeechInputController {
    enum State: Equatable {
        case idle
        case preparing
        case recording
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    var errorMessage: String?

    @ObservationIgnored
    private let client: any NautiSpeechInputClient
    @ObservationIgnored
    private var transcriptionTask: Task<Void, Never>?
    private var startGeneration = 0
    @ObservationIgnored
    private var cleanupTask: Task<Void, Never>?

    init(client: (any NautiSpeechInputClient)? = nil) {
        self.client = client ?? AppleNautiSpeechInputClient()
    }

    var isRecording: Bool {
        state == .recording
    }

    var isActive: Bool {
        state != .idle
    }

    func start() async {
        guard state == .idle else { return }
        startGeneration += 1
        let attempt = startGeneration
        errorMessage = nil
        transcript = ""
        state = .preparing

        await cleanupTask?.value
        guard startGeneration == attempt else { return }
        guard !Task.isCancelled else { state = .idle; return }
        let permission = await client.requestPermission()
        guard startGeneration == attempt else { return }
        guard !Task.isCancelled else { state = .idle; return }
        switch permission {
        case .denied:
            state = .idle
            errorMessage = NautiSpeechInputError.permissionDenied.localizedDescription
            return
        case .restricted:
            state = .idle
            errorMessage = NautiSpeechInputError.permissionRestricted.localizedDescription
            return
        case .authorized:
            break
        }

        do {
            let stream = try await client.startTranscription()
            guard startGeneration == attempt else { return }
            if Task.isCancelled {
                await client.cancelTranscription()
                state = .idle
                return
            }
            state = .recording
            transcriptionTask = Task { [weak self] in
                do {
                    for try await result in stream {
                        guard !Task.isCancelled, self?.startGeneration == attempt else { return }
                        self?.transcript = result.text
                        if result.isFinal {
                            self?.state = .idle
                        }
                    }
                    guard self?.startGeneration == attempt else { return }
                    if self?.state == .recording {
                        self?.state = .idle
                    }
                } catch is CancellationError {
                    guard self?.startGeneration == attempt else { return }
                    self?.state = .idle
                } catch {
                    guard self?.startGeneration == attempt else { return }
                    self?.state = .idle
                    self?.errorMessage = Self.message(for: error)
                }
            }
        } catch is CancellationError {
            guard startGeneration == attempt else { return }
            state = .idle
        } catch {
            guard startGeneration == attempt else { return }
            state = .idle
            errorMessage = Self.message(for: error)
        }
    }

    func stop() async {
        guard state != .idle else { return }
        if state == .preparing {
            cancel()
            return
        }
        await client.stopTranscription()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .idle
    }

    func cancel() {
        startGeneration += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .idle
        let pendingCleanup = cleanupTask
        cleanupTask = Task {
            await pendingCleanup?.value
            await client.cancelTranscription()
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private static func message(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return description
        }
        return NautiSpeechInputError.recognitionFailed.localizedDescription
    }
}

@MainActor
protocol NautiSpeechBackend: AnyObject {
    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error>
    func stop() async
    func cancel() async
}

@MainActor
final class AppleNautiSpeechInputClient: NautiSpeechInputClient {
    private let usesSystemBackend: Bool
    private var activeBackend: (any NautiSpeechBackend)?
    private var generation = 0
    private let makePrimary: @MainActor () -> any NautiSpeechBackend
    private let makeFallback: (@MainActor () -> any NautiSpeechBackend)?
    private static let logger = Logger(subsystem: "Toernberechnung", category: "NautiSpeech")

    init(
        primary: (@MainActor () -> any NautiSpeechBackend)? = nil,
        fallback: (@MainActor () -> any NautiSpeechBackend)? = nil
    ) {
        usesSystemBackend = primary == nil
        if let primary {
            makePrimary = primary
            makeFallback = fallback
        } else if #available(iOS 26.0, *) {
            makePrimary = { SpeechAnalyzerNautiBackend() }
            makeFallback = { LegacyNautiSpeechBackend() }
        } else {
            makePrimary = { LegacyNautiSpeechBackend() }
            makeFallback = nil
        }
    }

    func requestPermission() async -> NautiSpeechPermission {
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard microphoneAllowed else { return .denied }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        switch speechStatus {
        case .authorized: return .authorized
        case .restricted: return .restricted
        case .denied, .notDetermined: return .denied
        @unknown default: return .restricted
        }
    }

    func startTranscription() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        #if targetEnvironment(simulator)
        // Local dictation assets/capture are not supported by this simulator
        // path. Do not enter framework code that can abort rather than throw.
        if usesSystemBackend { throw NautiSpeechInputError.assetsUnavailable }
        #endif
        generation += 1
        let attempt = generation
        let previous = activeBackend
        activeBackend = nil
        await previous?.cancel()
        try checkAttempt(attempt)

        do {
            return try await start(makePrimary(), attempt: attempt)
        } catch {
            try checkAttempt(attempt)
            guard !(error is CancellationError),
                  let makeFallback,
                  Self.canFallback(after: error) else { throw error }
            let failure = error as NSError
            Self.logger.error("SpeechAnalyzer preparation failed: \(failure.domain, privacy: .public) / \(failure.code). Trying on-device dictation.")
            do {
                return try await start(makeFallback(), attempt: attempt)
            } catch {
                try checkAttempt(attempt)
                guard !(error is CancellationError) else { throw error }
                if Self.canFallback(after: error) {
                    throw NautiSpeechInputError.assetsUnavailable
                }
                throw error
            }
        }
    }

    private func start(
        _ backend: any NautiSpeechBackend,
        attempt: Int
    ) async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        activeBackend = backend
        do {
            let stream = try await backend.start()
            try checkAttempt(attempt)
            return stream
        } catch {
            // A failure can happen after the audio session has been activated.
            // Fully release it before trying another recognizer.
            await backend.cancel()
            if generation == attempt { activeBackend = nil }
            throw error
        }
    }

    private func checkAttempt(_ attempt: Int) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
    }

    private static func canFallback(after error: Error) -> Bool {
        guard let error = error as? NautiSpeechInputError else { return true }
        switch error {
        case .assetsUnavailable, .unsupportedGerman, .onDeviceRecognitionUnavailable, .recognitionFailed:
            return true
        case .permissionDenied, .permissionRestricted, .audioSessionUnavailable:
            return false
        }
    }

    func stopTranscription() async {
        generation += 1
        let backend = activeBackend
        activeBackend = nil
        await backend?.stop()
    }

    func cancelTranscription() async {
        generation += 1
        let backend = activeBackend
        activeBackend = nil
        await backend?.cancel()
    }

}

@available(iOS 26.0, *)
@MainActor
private final class SpeechAnalyzerNautiBackend: NautiSpeechBackend {
    private let capture = NautiAudioCapture()
    private var cancelled = false
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var outputContinuation: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        let transcriber = try await makeTranscriber()
        try checkCaptureAttempt()

        let context = AnalysisContext()
        context.contextualStrings[.general] = SpeechAnalyzerNautiVocabulary.values
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
        try await analyzer.setContext(context)

        try checkCaptureAttempt()
        let naturalFormat = try await capture.prepare()
        try checkCaptureAttempt()

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (outputStream, outputContinuation) = AsyncThrowingStream<NautiSpeechTranscript, Error>.makeStream()
        self.analyzer = analyzer
        self.inputContinuation = inputContinuation
        self.outputContinuation = outputContinuation

        do {
            try await startCapture(for: transcriber, naturalFormat: naturalFormat, yielding: inputContinuation)
        } catch {
            await cancel()
            throw error
        }

        startResultPump(transcriber: transcriber, output: outputContinuation)
        startAnalysis(analyzer: analyzer, inputStream: inputStream, output: outputContinuation)
        return outputStream
    }

    private func makeTranscriber() async throws -> DictationTranscriber {
        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "de_DE")
        ) else {
            throw NautiSpeechInputError.unsupportedGerman
        }

        let transcriber = DictationTranscriber(
            locale: locale,
            preset: .progressiveShortDictation
        )
        do {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = error as NSError
            Logger(subsystem: "Toernberechnung", category: "NautiSpeech")
                .error("Speech asset installation failed: \(failure.domain, privacy: .public) / \(failure.code)")
            throw NautiSpeechInputError.assetsUnavailable
        }
        return transcriber
    }

    private func checkCaptureAttempt() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
    }

    private func startCapture(
        for transcriber: DictationTranscriber,
        naturalFormat: AVAudioFormat,
        yielding inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    ) async throws {
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: naturalFormat
        ) else {
            throw NautiSpeechInputError.assetsUnavailable
        }
        try checkCaptureAttempt()
        try await capture.start(outputFormat: analyzerFormat) { buffer, time in
            inputContinuation.yield(
                AnalyzerInput(buffer: buffer, bufferStartTime: Self.startTime(for: time))
            )
        }
        try checkCaptureAttempt()
    }

    private func startResultPump(
        transcriber: DictationTranscriber,
        output: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation
    ) {
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    output.yield(NautiSpeechTranscript(text: text, isFinal: result.isFinal))
                }
                output.finish()
            } catch is CancellationError {
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }
    }

    private func startAnalysis(
        analyzer: SpeechAnalyzer,
        inputStream: AsyncStream<AnalyzerInput>,
        output: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation
    ) {
        analysisTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(inputStream)
            } catch is CancellationError {
                return
            } catch {
                output.finish(throwing: error)
            }
        }
    }

    func stop() async {
        cancelled = true
        await capture.stop()
        inputContinuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            outputContinuation?.finish(throwing: error)
        }
        analysisTask?.cancel()
        _ = await resultTask?.result
        cleanup()
    }

    func cancel() async {
        cancelled = true
        await capture.stop()
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        analysisTask?.cancel()
        resultTask?.cancel()
        outputContinuation?.finish()
        cleanup()
    }

    /// `AVAudioTime.sampleRate` is a `Double` straight from CoreAudio; feeding
    /// it to `CMTimeScale` unchecked traps on NaN or an out-of-range value —
    /// and this runs on the realtime audio thread.
    nonisolated private static func startTime(for time: AVAudioTime) -> CMTime? {
        guard time.isSampleTimeValid,
              time.sampleRate.isFinite,
              time.sampleRate > 0,
              time.sampleRate <= Double(Int32.max) else {
            return nil
        }
        return CMTime(value: time.sampleTime, timescale: CMTimeScale(time.sampleRate))
    }

    private func cleanup() {
        analyzer = nil
        inputContinuation = nil
        outputContinuation = nil
        analysisTask = nil
        resultTask = nil
    }
}

@MainActor
private final class LegacyNautiSpeechBackend: NautiSpeechBackend {
    private let capture = NautiAudioCapture()
    private var cancelled = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de_DE"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var outputContinuation: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?

    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        guard let recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw NautiSpeechInputError.onDeviceRecognitionUnavailable
        }

        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        _ = try await capture.prepare()
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = SpeechAnalyzerNautiVocabulary.values
        self.request = request

        let (stream, continuation) = AsyncThrowingStream<NautiSpeechTranscript, Error>.makeStream()
        outputContinuation = continuation

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    continuation.yield(
                        NautiSpeechTranscript(text: text, isFinal: result.isFinal)
                    )
                    if result.isFinal {
                        continuation.finish()
                        await self?.cleanup()
                    }
                } else if let error {
                    continuation.finish(throwing: error)
                    await self?.cleanup()
                }
            }
        }

        do {
            try await capture.start { buffer, _ in request.append(buffer) }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
        } catch {
            await cancel()
            throw error
        }
        return stream
    }

    func stop() async {
        cancelled = true
        await capture.stop()
        request?.endAudio()
    }

    func cancel() async {
        cancelled = true
        await capture.stop()
        task?.cancel()
        outputContinuation?.finish()
        await cleanup()
    }

    private func cleanup() async {
        await capture.stop()
        request = nil
        task = nil
        outputContinuation = nil
    }
}

private enum SpeechAnalyzerNautiVocabulary {
    static let values = [
        "TideNode", "Nauti", "Borkum", "Fischerbalje", "Emden", "Juist",
        "Norderney", "Baltrum", "Langeoog", "Spiekeroog", "Wangerooge",
        "Törn", "Gezeiten", "Wasserstand", "Passagefenster", "Backbord",
        "Steuerbord", "Knoten", "Böen", "BSH", "Crewspace", "Skipper-ID",
        "Co-Skipper", "Wachführung", "Sicherheit Medizin", "Termin", "Nachricht", "Gruppe"
    ]
}

/// Owns all blocking session/engine operations on its own executor. No engine
/// or AVAudioSession lifecycle call runs on MainActor, and stop cannot race start.
private actor NautiAudioCapture {
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var sessionActive = false

    func prepare() throws -> AVAudioFormat {
        try Task.checkCancellation()
        guard engine == nil else { throw NautiSpeechInputError.audioSessionUnavailable }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            sessionActive = true
            let engine = AVAudioEngine()
            self.engine = engine
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                throw NautiSpeechInputError.audioSessionUnavailable
            }
            return format
        } catch {
            stop()
            throw NautiSpeechInputError.audioSessionUnavailable
        }
    }

    func start(
        outputFormat: AVAudioFormat? = nil,
        receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        try Task.checkCancellation()
        guard let engine, sessionActive, !tapInstalled else {
            throw NautiSpeechInputError.audioSessionUnavailable
        }
        // Re-read after asynchronous asset/format preparation: the input route
        // may have changed. A nil tap format lets the engine choose its current
        // hardware format, avoiding the uncatchable sample-rate assertion.
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let converter = SpeechAudioFormatConverter(from: format, to: outputFormat ?? format) else {
            throw NautiSpeechInputError.audioSessionUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil,
                         block: Self.makeTap(converter: converter, receive: receive))
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw NautiSpeechInputError.audioSessionUnavailable
        }
    }

    // Explicitly nonisolated: audio callbacks must not inherit an actor executor.
    nonisolated private static func makeTap(
        converter: SpeechAudioFormatConverter,
        receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, time in
            guard let ownedBuffer = converter.convert(buffer) else { return }
            receive(ownedBuffer, time)
        }
    }

    func stop() {
        if let engine {
            if engine.isRunning { engine.stop() }
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        engine = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}
