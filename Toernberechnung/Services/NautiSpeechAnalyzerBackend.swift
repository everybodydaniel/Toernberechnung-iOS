import AVFAudio
import CoreMedia
import Foundation
import Speech

/// Ersetzt überarbeitete Abschnitte, ohne bereits bestätigte Sätze zu verlieren.
struct NautiSpeechTranscriptAccumulator {
    private struct Segment {
        let start: Double
        let end: Double
        let text: String
        let isFinal: Bool
    }
    private var segments: [Segment] = []

    mutating func update(start: Double, end: Double, text: String, isFinal: Bool) -> String {
        guard start.isFinite, end.isFinite, end >= start else { return self.text }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return self.text }
        segments.removeAll { $0.start == start || (!$0.isFinal && $0.start < end && start < $0.end) }
        segments.append(.init(start: start, end: end, text: value, isFinal: isFinal))
        segments.sort { $0.start < $1.start }
        return self.text
    }

    var text: String {
        segments.reduce("") { NautiSpeechDraft.appending($1.text, to: $0) }
    }
}

enum NautiSpeechDraft {
    static func appending(_ transcript: String, to draft: String) -> String {
        guard !transcript.isEmpty else { return draft }
        guard !draft.isEmpty else { return transcript }
        let separator = draft.last?.isWhitespace == true || ",.!?;:".contains(transcript.first ?? " ") ? "" : " "
        return draft + separator + transcript
    }
}

enum NautiSpeechAssetStatus: String { case unsupported, supported, downloading, installed }

@MainActor
protocol NautiSpeechAssetClient {
    func status() async -> NautiSpeechAssetStatus
    func install(onProgress: @escaping @MainActor (Double?) -> Void) async throws
}

enum NautiSpeechAssetPreparation {
    @MainActor
    static func prepare(using assets: any NautiSpeechAssetClient, backend: String,
                        report: @escaping @MainActor (NautiSpeechPreparation) -> Void) async throws {
        report(.checkingModel)
        let status = await assets.status()
        NautiSpeechDiagnostics.record(backend: backend, phase: "Sprachmodell: \(status.rawValue)")
        try Task.checkCancellation()
        if status == .unsupported { throw NautiSpeechInputError.onDeviceRecognitionUnavailable }
        if status != .installed {
            report(.downloading(nil))
            do {
                try await assets.install { report(.downloading($0)) }
                try Task.checkCancellation()
            } catch is CancellationError { throw CancellationError() } catch {
                NautiSpeechDiagnostics.record(backend: backend, phase: "Modell-Download", error: error)
                if error is NautiSpeechFailure { throw error }
                throw NautiSpeechFailure(reason: .downloadFailed, underlying: error)
            }
            let installedStatus = await assets.status()
            NautiSpeechDiagnostics.record(backend: backend, phase: "Nach Download: \(installedStatus.rawValue)")
            guard installedStatus == .installed else { throw NautiSpeechInputError.assetsUnavailable }
            try Task.checkCancellation()
        }
    }
}

@available(iOS 26.0, *)
@MainActor
private final class AppleNautiSpeechAssetClient: NautiSpeechAssetClient {
    let module: any SpeechModule
    init(module: any SpeechModule) { self.module = module }

    func status() async -> NautiSpeechAssetStatus {
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    func install(onProgress: @escaping @MainActor (Double?) -> Void) async throws {
        // Das System reserviert die benötigte Sprache und übernimmt bestehende Downloads.
        let installation: AssetInstallationRequest?
        do {
            installation = try await AssetInventory.assetInstallationRequest(supporting: [module])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NautiSpeechFailure(reason: .modelPreparationFailed, underlying: error)
        }
        guard let request = installation else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in onProgress(value.isFinite ? min(max(value, 0), 1) : nil) }
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }
}

@available(iOS 26.0, *)
@MainActor
final class SpeechAnalyzerNautiBackend: NautiSpeechBackend {
    enum Kind: String { case transcription = "SpeechTranscriber", dictation = "DictationTranscriber" }
    var onPreparation: (@MainActor (NautiSpeechPreparation) -> Void)?
    private let kind: Kind
    private let capture = NautiAudioCapture()
    private var cancelled = false
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var output: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    init(kind: Kind) { self.kind = kind }

    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        onPreparation?(.checkingModel)
        let module: any SpeechModule
        let beginResults: @MainActor () -> Void
        switch kind {
        case .transcription:
            guard SpeechTranscriber.isAvailable else { throw NautiSpeechInputError.onDeviceRecognitionUnavailable }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "de_DE")) else {
                throw NautiSpeechInputError.unsupportedGerman
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            module = transcriber
            beginResults = { self.consume(transcriber.results.map {
                SpeechSegment(start: $0.range.start.seconds, end: CMTimeRangeGetEnd($0.range).seconds,
                              text: String($0.text.characters), isFinal: $0.isFinal)
            }) }
        case .dictation:
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "de_DE")) else {
                throw NautiSpeechInputError.unsupportedGerman
            }
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            module = transcriber
            beginResults = { self.consume(transcriber.results.map {
                SpeechSegment(start: $0.range.start.seconds, end: CMTimeRangeGetEnd($0.range).seconds,
                              text: String($0.text.characters), isFinal: $0.isFinal)
            }) }
        }
        try checkAttempt()
        try await NautiSpeechAssetPreparation.prepare(using: AppleNautiSpeechAssetClient(module: module),
                                                      backend: kind.rawValue) { [weak self] in self?.onPreparation?($0) }
        try checkAttempt()
        onPreparation?(.preparingAudio)
        let context = AnalysisContext()
        context.contextualStrings[.general] = NautiSpeechVocabulary.values
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        try await analyzer.setContext(context)
        let naturalFormat = try await capture.prepare()
        try checkAttempt()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: naturalFormat) else {
            throw NautiSpeechInputError.audioFormatUnavailable
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            NautiSpeechDiagnostics.record(backend: kind.rawValue, phase: "Analyzer vorbereiten", error: error)
            if error is CancellationError { throw error }
            throw NautiSpeechFailure(reason: .modelPreparationFailed, underlying: error)
        }
        try checkAttempt()
        let (input, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (stream, output) = AsyncThrowingStream<NautiSpeechTranscript, Error>.makeStream()
        self.inputContinuation = inputContinuation
        self.output = output
        beginResults()
        analysisTask = Task {
            do { _ = try await analyzer.analyzeSequence(input) } catch is CancellationError { } catch {
                NautiSpeechDiagnostics.record(backend: kind.rawValue, phase: "Analyse", error: error)
                output.finish(throwing: NautiSpeechFailure(reason: .recognitionFailed, underlying: error))
            }
        }
        try await capture.start(outputFormat: format) { buffer, _ in
            // Nach der Umrechnung bestimmt der Analyzer die Zeit aus den tatsächlichen
            // Ausgabeframes. Hardware-Zeitstempel können durch den Konverter überlappen.
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }
        try checkAttempt()
        NautiSpeechDiagnostics.record(backend: kind.rawValue, phase: "Aufnahme gestartet")
        return stream
    }

    private struct SpeechSegment: Sendable {
        let start: Double
        let end: Double
        let text: String
        let isFinal: Bool
    }

    private func consume<Sequence: AsyncSequence>(_ results: Sequence) where Sequence.Element == SpeechSegment {
        resultTask = Task {
            var transcript = NautiSpeechTranscriptAccumulator()
            do {
                for try await result in results {
                    guard !cancelled, !Task.isCancelled else { break }
                    let text = transcript.update(start: result.start, end: result.end, text: result.text, isFinal: result.isFinal)
                    output?.yield(.init(text: text, isFinal: result.isFinal))
                }
                output?.finish()
            } catch is CancellationError {
                output?.finish()
            } catch {
                NautiSpeechDiagnostics.record(backend: kind.rawValue, phase: "Textergebnis", error: error)
                output?.finish(throwing: NautiSpeechFailure(reason: .recognitionFailed, underlying: error))
            }
        }
    }

    func stop() async {
        await capture.stop()
        inputContinuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch is CancellationError { } catch {
            NautiSpeechDiagnostics.record(backend: kind.rawValue, phase: "Aufnahme abschließen", error: error)
            output?.finish(throwing: NautiSpeechFailure(reason: .recognitionFailed, underlying: error))
        }
        await resultTask?.value
        cleanup()
    }

    func cancel() async {
        cancelled = true
        await capture.stop()
        inputContinuation?.finish()
        analysisTask?.cancel()
        resultTask?.cancel()
        output?.finish()
        await analyzer?.cancelAndFinishNow()
        cleanup()
    }

    private func cleanup() {
        analyzer = nil
        inputContinuation = nil
        output = nil
        analysisTask = nil
        resultTask = nil
    }

    private func checkAttempt() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
    }

}

@MainActor
final class LegacyNautiSpeechBackend: NautiSpeechBackend {
    var onPreparation: (@MainActor (NautiSpeechPreparation) -> Void)?
    private let capture = NautiAudioCapture()
    private var cancelled = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de_DE"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var output: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?

    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        onPreparation?(.permission)
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try checkAttempt()
        if permission == .restricted { throw NautiSpeechInputError.permissionRestricted }
        guard permission == .authorized else { throw NautiSpeechInputError.permissionDenied }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw NautiSpeechInputError.onDeviceRecognitionUnavailable
        }
        onPreparation?(.preparingAudio)
        _ = try await capture.prepare()
        try checkAttempt()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = NautiSpeechVocabulary.values
        self.request = request
        let (stream, output) = AsyncThrowingStream<NautiSpeechTranscript, Error>.makeStream()
        self.output = output
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                if let result {
                    output.yield(.init(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
                    if result.isFinal { output.finish(); await self.cleanup(); return }
                }
                if let error {
                    NautiSpeechDiagnostics.record(backend: "SFSpeechRecognizer", phase: "Textergebnis", error: error)
                    output.finish(throwing: NautiSpeechFailure(reason: .recognitionFailed, underlying: error))
                    await self.cleanup()
                }
            }
        }
        try await capture.start { buffer, _ in request.append(buffer) }
        try checkAttempt()
        return stream
    }

    func stop() async {
        await capture.stop()
        request?.endAudio()
    }

    func cancel() async {
        cancelled = true
        task?.cancel()
        output?.finish()
        await cleanup()
    }

    private func cleanup() async {
        await capture.stop()
        request = nil
        task = nil
        output = nil
    }

    private func checkAttempt() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
    }
}

enum NautiSpeechVocabulary {
    static func correctedTranscript(_ text: String) -> String {
        // Die lokale Erkennung verwechselt diesen nautischen Begriff häufig.
        // Nur das ganze Wort ersetzen; Wörter wie „Turnhalle“ bleiben erhalten.
        text.replacingOccurrences(of: "(?i)\\bturn\\b", with: "Törn", options: .regularExpression)
    }

    static let values = [
        "TideNode", "Nauti", "Borkum", "Fischerbalje", "Emden", "Juist", "Norderney",
        "Baltrum", "Langeoog", "Spiekeroog", "Wangerooge", "Törn", "Gezeiten", "Wasserstand",
        "Passagefenster", "Backbord", "Steuerbord", "Knoten", "Böen", "BSH", "Crewspace",
        "Skipper-ID", "Co-Skipper", "Wachführung", "Sicherheit Medizin", "Termin", "Nachricht", "Gruppe"
    ]
}
