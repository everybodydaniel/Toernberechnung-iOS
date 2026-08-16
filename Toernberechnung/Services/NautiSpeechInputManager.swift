import AVFAudio
import CoreMedia
import Foundation
import Observation
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
            return "Die lokalen Sprachressourcen konnten nicht vorbereitet werden."
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
        errorMessage = nil
        transcript = ""
        state = .preparing

        switch await client.requestPermission() {
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
            state = .recording
            transcriptionTask = Task { [weak self] in
                do {
                    for try await result in stream {
                        guard !Task.isCancelled else { return }
                        self?.transcript = result.text
                        if result.isFinal {
                            self?.state = .idle
                        }
                    }
                    if self?.state == .recording {
                        self?.state = .idle
                    }
                } catch is CancellationError {
                    self?.state = .idle
                } catch {
                    self?.state = .idle
                    self?.errorMessage = Self.message(for: error)
                }
            }
        } catch {
            state = .idle
            errorMessage = Self.message(for: error)
        }
    }

    func stop() async {
        guard state != .idle else { return }
        await client.stopTranscription()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .idle
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .idle
        Task { await client.cancelTranscription() }
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
private protocol NautiSpeechBackend: AnyObject {
    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error>
    func stop() async
    func cancel() async
}

@MainActor
final class AppleNautiSpeechInputClient: NautiSpeechInputClient {
    private var activeBackend: (any NautiSpeechBackend)?

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
        await activeBackend?.cancel()

        let backend: any NautiSpeechBackend
        if #available(iOS 26.0, *) {
            backend = SpeechAnalyzerNautiBackend()
        } else {
            backend = LegacyNautiSpeechBackend()
        }
        activeBackend = backend
        do {
            return try await backend.start()
        } catch {
            // Without this the failed backend stays installed and its audio
            // session is never torn down, so the next attempt starts dirty.
            activeBackend = nil
            throw error
        }
    }

    func stopTranscription() async {
        await activeBackend?.stop()
        activeBackend = nil
    }

    func cancelTranscription() async {
        await activeBackend?.cancel()
        activeBackend = nil
    }
}

@available(iOS 26.0, *)
@MainActor
private final class SpeechAnalyzerNautiBackend: NautiSpeechBackend {
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var outputContinuation: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var tapInstalled = false

    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        let transcriber = try await makeTranscriber()

        let context = AnalysisContext()
        context.contextualStrings[.general] = SpeechAnalyzerNautiVocabulary.values
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
        try await analyzer.setContext(context)

        try activateAudioSession()

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (outputStream, outputContinuation) = AsyncThrowingStream<NautiSpeechTranscript, Error>.makeStream()
        self.analyzer = analyzer
        self.inputContinuation = inputContinuation
        self.outputContinuation = outputContinuation

        do {
            try await startCapture(for: transcriber, yielding: inputContinuation)
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
        if let installation = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            do {
                try await installation.downloadAndInstall()
            } catch {
                throw NautiSpeechInputError.assetsUnavailable
            }
        }
        return transcriber
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.duckOthers` is only valid for playback-capable categories; on
            // `.record` it makes setCategory throw.
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            throw NautiSpeechInputError.audioSessionUnavailable
        }
    }

    private func startCapture(
        for transcriber: DictationTranscriber,
        yielding inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    ) async throws {
        let inputNode = audioEngine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        // A zero-rate/zero-channel format means the input route is not ready.
        // Installing a tap on it would abort the process, so bail out with a
        // recoverable error instead.
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
            throw NautiSpeechInputError.audioSessionUnavailable
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: naturalFormat
        ) else {
            throw NautiSpeechInputError.assetsUnavailable
        }

        // The tap MUST run at the hardware format — AVAudioEngine raises an
        // uncatchable exception otherwise. Resampling to the analyzer format
        // happens per buffer.
        guard let converter = SpeechAudioFormatConverter(from: naturalFormat, to: analyzerFormat) else {
            throw NautiSpeechInputError.audioSessionUnavailable
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: naturalFormat
        ) { buffer, time in
            guard let converted = converter.convert(buffer) else { return }
            inputContinuation.yield(
                AnalyzerInput(buffer: converted, bufferStartTime: Self.startTime(for: time))
            )
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw NautiSpeechInputError.audioSessionUnavailable
        }
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
        stopAudioCapture()
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
        stopAudioCapture()
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
    private static func startTime(for time: AVAudioTime) -> CMTime? {
        guard time.isSampleTimeValid,
              time.sampleRate.isFinite,
              time.sampleRate > 0,
              time.sampleRate <= Double(Int32.max) else {
            return nil
        }
        return CMTime(value: time.sampleTime, timescale: CMTimeScale(time.sampleRate))
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
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
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de_DE"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var outputContinuation: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?
    private var tapInstalled = false

    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        guard let recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw NautiSpeechInputError.onDeviceRecognitionUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.duckOthers` is only valid for playback-capable categories.
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            throw NautiSpeechInputError.audioSessionUnavailable
        }

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
                        self?.cleanup()
                    }
                } else if let error {
                    continuation.finish(throwing: error)
                    self?.cleanup()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            await cancel()
            throw NautiSpeechInputError.audioSessionUnavailable
        }
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            await cancel()
            throw NautiSpeechInputError.audioSessionUnavailable
        }
        return stream
    }

    func stop() async {
        stopAudioCapture()
        request?.endAudio()
    }

    func cancel() async {
        stopAudioCapture()
        task?.cancel()
        outputContinuation?.finish()
        cleanup()
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func cleanup() {
        stopAudioCapture()
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
