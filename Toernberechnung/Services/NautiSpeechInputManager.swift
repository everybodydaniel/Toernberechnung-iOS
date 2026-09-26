import AVFAudio
import Foundation
import Observation
import OSLog
import Speech

struct NautiSpeechTranscript: Equatable, Sendable {
    /// Enthält den gesamten bisher erkannten Text der Aufnahme.
    let text: String
    /// Bezieht sich auf den letzten Textabschnitt, nicht auf das Aufnahmeende.
    let isFinal: Bool
}

enum NautiSpeechPermission: Equatable, Sendable {
    case authorized, denied, restricted
}

enum NautiSpeechPreparation: Equatable, Sendable {
    case permission, checkingModel, downloading(Double?), preparingAudio

    var message: String {
        switch self {
        case .permission: return "Mikrofonzugriff wird geprüft …"
        case .checkingModel: return "Deutsches Sprachmodell wird geprüft …"
        case .downloading: return "Deutsches Sprachmodell wird geladen …"
        case .preparingAudio: return "Spracheingabe wird vorbereitet …"
        }
    }
}

enum NautiSpeechInputError: LocalizedError, Equatable, Sendable {
    case permissionDenied, permissionRestricted, onDeviceRecognitionUnavailable, unsupportedGerman
    case assetsUnavailable, downloadFailed, audioFormatUnavailable, modelPreparationFailed
    case audioSessionUnavailable, recognitionFailed, finalizationTimedOut, audioInterrupted

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Mikrofon oder Spracherkennung wurde nicht erlaubt. Du kannst den Zugriff in den Einstellungen aktivieren."
        case .permissionRestricted:
            return "Spracherkennung ist auf diesem Gerät eingeschränkt."
        case .onDeviceRecognitionUnavailable:
            return "Die lokale Spracherkennung ist auf diesem Gerät gerade nicht verfügbar."
        case .unsupportedGerman:
            return "Für Deutsch ist auf diesem Gerät kein unterstütztes lokales Sprachmodell verfügbar."
        case .assetsUnavailable:
            #if targetEnvironment(simulator)
            return "Eine echte Sprachaufnahme ist im Simulator nicht verfügbar. Bitte teste sie auf einem iPhone oder iPad."
            #else
            return "Das deutsche Sprachmodell ist noch nicht bereit. Bitte versuche es erneut."
            #endif
        case .downloadFailed:
            return "Das deutsche Sprachmodell konnte nicht geladen werden. Verbinde das Gerät mit dem Internet und versuche es erneut."
        case .audioFormatUnavailable:
            return "Für den Audioeingang ist kein passendes Sprachformat verfügbar. Bitte versuche es ohne angeschlossenes Headset erneut."
        case .modelPreparationFailed:
            return "Das lokale Sprachmodell konnte nicht gestartet werden. Bitte versuche es erneut."
        case .audioSessionUnavailable:
            return "Das Mikrofon konnte gerade nicht gestartet werden."
        case .recognitionFailed:
            return "Die Spracheingabe konnte nicht verarbeitet werden. Der bisher erkannte Text bleibt erhalten."
        case .finalizationTimedOut:
            return "Die letzten Wörter konnten nicht fertig verarbeitet werden. Bitte prüfe den erkannten Text."
        case .audioInterrupted:
            return "Die Sprachaufnahme wurde unterbrochen. Der bisher erkannte Text bleibt erhalten."
        }
    }

    static func reason(for error: Error) -> Self? {
        (error as? Self) ?? (error as? NautiSpeechFailure)?.reason
    }
}

struct NautiSpeechFailure: LocalizedError {
    let reason: NautiSpeechInputError
    let underlying: Error
    var errorDescription: String? { reason.errorDescription }
}

enum NautiSpeechDiagnostics {
    private static let logger = Logger(subsystem: "Toernberechnung", category: "NautiSpeech")

    static func record(backend: String, phase: String, error: Error? = nil) {
        let cause = ((error as? NautiSpeechFailure)?.underlying ?? error) as NSError?
        let domain = cause?.domain ?? "kein Fehler"
        let code = cause?.code ?? 0
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        logger.notice("Backend=\(backend, privacy: .public) Phase=\(phase, privacy: .public) Sprache=de_DE iOS=\(os, privacy: .public) Fehler=\(domain, privacy: .public)/\(code)")
    }
}

@MainActor
protocol NautiSpeechInputClient: AnyObject {
    var onPreparation: (@MainActor (NautiSpeechPreparation) -> Void)? { get set }
    func requestPermission() async -> NautiSpeechPermission
    func startTranscription() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error>
    func stopTranscription() async
    func cancelTranscription() async
}

extension NautiSpeechInputClient {
    var onPreparation: (@MainActor (NautiSpeechPreparation) -> Void)? {
        get { nil }
        set { _ = newValue }
    }
}

@MainActor
@Observable
final class NautiSpeechInputController {
    enum State: Equatable { case idle, preparing, recording, finalizing }
    private(set) var state: State = .idle
    private(set) var transcript = ""
    private(set) var preparation: NautiSpeechPreparation = .permission
    var errorMessage: String?
    @ObservationIgnored var onTranscript: (@MainActor (String) -> Void)?
    @ObservationIgnored private let client: any NautiSpeechInputClient
    @ObservationIgnored private let finalizationTimeout: Duration
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<AsyncThrowingStream<NautiSpeechTranscript, Error>, Error>?
    @ObservationIgnored private var finishingTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var completion: AsyncStream<Void>.Continuation?
    private var generation = 0

    init(client: (any NautiSpeechInputClient)? = nil, finalizationTimeout: Duration = .seconds(5)) {
        self.client = client ?? Self.systemClient()
        self.finalizationTimeout = finalizationTimeout
    }

    private static func systemClient() -> any NautiSpeechInputClient {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["UITEST_NAUTI_SPEECH"] {
            return NautiSpeechUITestClient(mode: mode)
        }
        #endif
        return AppleNautiSpeechInputClient()
    }

    var isRecording: Bool { state == .recording }
    var isActive: Bool { state != .idle }

    func start() async {
        guard state == .idle else { return }
        generation += 1
        let attempt = generation
        transcript = ""
        errorMessage = nil
        preparation = .permission
        state = .preparing
        await cleanupTask?.value
        guard generation == attempt else { return }
        if Task.isCancelled { cancel(); return }
        client.onPreparation = { [weak self] step in
            guard self?.generation == attempt, self?.state == .preparing else { return }
            self?.preparation = step
        }
        let permission = await client.requestPermission()
        guard generation == attempt else { return }
        if Task.isCancelled { cancel(); return }
        guard permission == .authorized else {
            errorMessage = (permission == .denied ? NautiSpeechInputError.permissionDenied : .permissionRestricted).localizedDescription
            state = .idle
            return
        }
        let task = Task { try await client.startTranscription() }
        startupTask = task
        do {
            let stream = try await task.value
            guard generation == attempt else { return }
            try Task.checkCancellation()
            startupTask = nil
            state = .recording
            transcriptionTask = Task { [weak self] in
                do {
                    for try await result in stream {
                        guard let self, self.generation == attempt, !Task.isCancelled else { return }
                        let text = NautiSpeechVocabulary.correctedTranscript(result.text)
                        self.transcript = text
                        self.onTranscript?(text)
                    }
                    await self?.finish(attempt: attempt)
                } catch is CancellationError {
                    await self?.finish(attempt: attempt)
                } catch {
                    await self?.finish(attempt: attempt, error: error)
                }
            }
        } catch {
            guard generation == attempt else { return }
            startupTask = nil
            await finish(attempt: attempt, error: error is CancellationError ? nil : error)
        }
    }

    func stop() async {
        if state == .preparing { cancel(); return }
        guard state == .recording else { return }
        state = .finalizing
        let attempt = generation
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        completion = continuation
        finishingTask = Task { await client.stopTranscription() }
        timeoutTask = Task { [weak self, finalizationTimeout] in
            do { try await Task.sleep(for: finalizationTimeout) } catch { return }
            guard let self, self.generation == attempt, self.state == .finalizing else { return }
            self.errorMessage = NautiSpeechInputError.finalizationTimedOut.localizedDescription
            self.cancel()
        }
        // Das Signal beendet das Warten auch dann, wenn das System die Abschlussaufgabe nicht beendet.
        for await _ in signal { }
    }

    func cancel() {
        generation += 1
        startupTask?.cancel()
        transcriptionTask?.cancel()
        finishingTask?.cancel()
        timeoutTask?.cancel()
        startupTask = nil
        transcriptionTask = nil
        finishingTask = nil
        timeoutTask = nil
        completion?.finish()
        completion = nil
        state = .idle
        let previous = cleanupTask
        cleanupTask = Task {
            await previous?.value
            await client.cancelTranscription()
        }
    }

    private func finish(attempt: Int, error: Error? = nil) async {
        guard generation == attempt else { return }
        if let error {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? NautiSpeechInputError.recognitionFailed.localizedDescription
        }
        await client.cancelTranscription()
        guard generation == attempt else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        state = .idle
        completion?.finish()
        completion = nil
    }

    func clearError() { errorMessage = nil }
}

@MainActor
protocol NautiSpeechBackend: AnyObject {
    var onPreparation: (@MainActor (NautiSpeechPreparation) -> Void)? { get set }
    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error>
    func stop() async
    func cancel() async
}

extension NautiSpeechBackend {
    var onPreparation: (@MainActor (NautiSpeechPreparation) -> Void)? {
        get { nil }
        set { _ = newValue }
    }
}

@MainActor
final class AppleNautiSpeechInputClient: NautiSpeechInputClient {
    var onPreparation: (@MainActor (NautiSpeechPreparation) -> Void)?
    private let usesSystemBackend: Bool
    private let factories: [@MainActor () -> any NautiSpeechBackend]
    private var activeBackend: (any NautiSpeechBackend)?
    private var generation = 0

    init(primary: (@MainActor () -> any NautiSpeechBackend)? = nil,
         fallback: (@MainActor () -> any NautiSpeechBackend)? = nil,
         additionalFallback: (@MainActor () -> any NautiSpeechBackend)? = nil) {
        usesSystemBackend = primary == nil
        if let primary {
            factories = [primary] + [fallback, additionalFallback].compactMap { $0 }
        } else if #available(iOS 26.0, *) {
            factories = [{ SpeechAnalyzerNautiBackend(kind: .transcription) },
                         { SpeechAnalyzerNautiBackend(kind: .dictation) }, { LegacyNautiSpeechBackend() }]
        } else {
            factories = [{ LegacyNautiSpeechBackend() }]
        }
    }

    func requestPermission() async -> NautiSpeechPermission {
        let allowed = await AVAudioApplication.requestRecordPermission()
        return allowed ? .authorized : .denied
    }

    func startTranscription() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        #if targetEnvironment(simulator)
        // Echte Aufnahme bleibt im Simulator gesperrt. Tests können einen eigenen Client einsetzen.
        if usesSystemBackend { throw NautiSpeechInputError.assetsUnavailable }
        #endif
        generation += 1
        let attempt = generation
        let previous = activeBackend
        activeBackend = nil
        await previous?.cancel()
        var failures: [Error] = []
        for factory in factories {
            try checkAttempt(attempt)
            let backend = factory()
            backend.onPreparation = onPreparation
            activeBackend = backend
            do {
                let stream = try await backend.start()
                try checkAttempt(attempt)
                return stream
            } catch {
                NautiSpeechDiagnostics.record(backend: String(describing: type(of: backend)), phase: "Start", error: error)
                await backend.cancel()
                if generation == attempt { activeBackend = nil }
                try checkAttempt(attempt)
                guard !(error is CancellationError), Self.canFallback(after: error) else { throw error }
                failures.append(error)
            }
        }
        // Ein konkreter Download- oder Vorbereitungsfehler ist hilfreicher als die letzte allgemeine Nichtverfügbarkeit.
        throw failures.first(where: { [.downloadFailed, .audioFormatUnavailable, .modelPreparationFailed]
            .contains(NautiSpeechInputError.reason(for: $0) ?? .recognitionFailed) })
            ?? failures.first ?? NautiSpeechInputError.onDeviceRecognitionUnavailable
    }

    private func checkAttempt(_ attempt: Int) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
    }

    private static func canFallback(after error: Error) -> Bool {
        switch NautiSpeechInputError.reason(for: error) {
        case .permissionDenied, .permissionRestricted, .audioSessionUnavailable, .audioInterrupted: return false
        default: return true
        }
    }

    func stopTranscription() async {
        let backend = activeBackend
        await backend?.stop()
    }

    func cancelTranscription() async {
        generation += 1
        let backend = activeBackend
        activeBackend = nil
        await backend?.cancel()
    }
}

#if DEBUG
@MainActor
private final class NautiSpeechUITestClient: NautiSpeechInputClient {
    let mode: String
    private var continuation: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?
    init(mode: String) { self.mode = mode }
    func requestPermission() async -> NautiSpeechPermission { .authorized }
    func startTranscription() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        if mode == "download-error" { throw NautiSpeechInputError.downloadFailed }
        let (stream, continuation) = AsyncThrowingStream<NautiSpeechTranscript, Error>.makeStream()
        self.continuation = continuation
        continuation.yield(.init(text: "Plane einen Törn", isFinal: false))
        return stream
    }
    func stopTranscription() async {
        continuation?.yield(.init(text: "Plane einen Törn nach Juist", isFinal: true))
        continuation?.finish()
    }
    func cancelTranscription() async { continuation?.finish(); continuation = nil }
}
#endif
