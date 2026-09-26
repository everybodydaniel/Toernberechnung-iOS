import XCTest
@testable import Toernberechnung

final class NautiSpeechInputTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor
    func testSystemSpeechInSimulatorFailsWithoutStartingAudio() async {
        let client = AppleNautiSpeechInputClient()
        do {
            _ = try await client.startTranscription()
            XCTFail("Simulator must not enter the unsupported on-device capture path")
        } catch {
            XCTAssertEqual(error as? NautiSpeechInputError, .assetsUnavailable)
        }
        await client.cancelTranscription()
    }
    #endif
    @MainActor
    func testDeniedPermissionNeverStartsRecognition() async {
        let client = FakeNautiSpeechInputClient(permission: .denied)
        let controller = NautiSpeechInputController(client: client)

        await controller.start()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(client.startCount, 0)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testPartialAndFinalTranscriptUpdateDraftSource() async {
        let client = FakeNautiSpeechInputClient()
        let controller = NautiSpeechInputController(client: client)

        await controller.start()
        client.yield(NautiSpeechTranscript(text: "Plane einen Törn", isFinal: false))
        await waitUntil { controller.transcript == "Plane einen Törn" }

        XCTAssertEqual(controller.state, .recording)
        client.yield(NautiSpeechTranscript(text: "Plane einen Törn nach Juist", isFinal: true))
        await waitUntil { controller.transcript == "Plane einen Törn nach Juist" }
        XCTAssertEqual(controller.state, .recording)
        client.finish()
        await waitUntil { controller.state == .idle }

        XCTAssertEqual(controller.transcript, "Plane einen Törn nach Juist")
    }

    @MainActor
    func testRecognitionErrorReturnsToIdleWithInlineMessage() async {
        let client = FakeNautiSpeechInputClient()
        let controller = NautiSpeechInputController(client: client)

        await controller.start()
        client.finish(throwing: NautiSpeechInputError.assetsUnavailable)
        await waitUntil { controller.errorMessage != nil }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.errorMessage, NautiSpeechInputError.assetsUnavailable.localizedDescription)
    }

    @MainActor
    func testCancelReleasesSpeechClient() async {
        let client = FakeNautiSpeechInputClient()
        let controller = NautiSpeechInputController(client: client)

        await controller.start()
        controller.cancel()
        await waitUntil { client.cancelCount == 1 }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(client.cancelCount, 1)
    }

    @MainActor
    func testUnavailableAssetsStartFallbackAfterPrimaryCleanup() async throws {
        let primary = FakeNautiSpeechBackend(error: NautiSpeechInputError.assetsUnavailable)
        let fallback = FakeNautiSpeechBackend()
        let client = AppleNautiSpeechInputClient(primary: { primary }, fallback: {
            XCTAssertEqual(primary.cancelCount, 1)
            return fallback
        })
        let stream = try await client.startTranscription()
        fallback.continuation?.yield(.init(text: "Einen Termin planen", isFinal: true))
        var iterator = stream.makeAsyncIterator()
        let result = try await iterator.next()
        XCTAssertEqual(result?.text, "Einen Termin planen")
        XCTAssertEqual(fallback.startCount, 1)
        await client.cancelTranscription()
        XCTAssertEqual(fallback.cancelCount, 1)
    }

    @MainActor
    func testSuccessfulPrimaryDoesNotStartFallback() async throws {
        let primary = FakeNautiSpeechBackend()
        let fallback = FakeNautiSpeechBackend()
        let client = AppleNautiSpeechInputClient(primary: { primary }, fallback: { fallback })
        _ = try await client.startTranscription()
        XCTAssertEqual(fallback.startCount, 0)
        await client.cancelTranscription()
        XCTAssertEqual(primary.cancelCount, 1)
    }

    @MainActor
    func testCancellationAndMicrophoneErrorsDoNotStartFallback() async {
        for error: Error in [CancellationError(), NautiSpeechInputError.audioSessionUnavailable] {
            let primary = FakeNautiSpeechBackend(error: error)
            let fallback = FakeNautiSpeechBackend()
            let client = AppleNautiSpeechInputClient(primary: { primary }, fallback: { fallback })
            do {
                _ = try await client.startTranscription()
                XCTFail("Expected startup failure")
            } catch { }
            XCTAssertEqual(primary.cancelCount, 1)
            XCTAssertEqual(fallback.startCount, 0)
        }
    }

    @MainActor
    func testBothRecognizersUnavailableReleaseResourcesAndReportRecovery() async {
        let primary = FakeNautiSpeechBackend(error: NautiSpeechInputError.assetsUnavailable)
        let fallback = FakeNautiSpeechBackend(error: NautiSpeechInputError.onDeviceRecognitionUnavailable)
        let client = AppleNautiSpeechInputClient(primary: { primary }, fallback: { fallback })
        do {
            _ = try await client.startTranscription()
            XCTFail("Expected unavailable resources")
        } catch {
            XCTAssertEqual(error as? NautiSpeechInputError, .assetsUnavailable)
        }
        XCTAssertEqual(primary.cancelCount, 1)
        XCTAssertEqual(fallback.cancelCount, 1)
    }

    @MainActor
    func testCancelDuringPreparationDoesNotRestartMicrophone() async {
        let primary = FakeNautiSpeechBackend()
        primary.suspendStart = true
        let fallback = FakeNautiSpeechBackend()
        let client = AppleNautiSpeechInputClient(primary: { primary }, fallback: { fallback })
        let start = Task { try await client.startTranscription() }
        await waitUntil { primary.pendingStart != nil }
        await client.cancelTranscription()
        primary.pendingStart?.resume()
        primary.pendingStart = nil
        do {
            _ = try await start.value
            XCTFail("Cancelled startup must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(fallback.startCount, 0)
    }

    @MainActor
    func testStopWaitsForFinalWords() async {
        let client = FakeNautiSpeechInputClient()
        client.stopResult = "Plane einen Törn nach Juist"
        let controller = NautiSpeechInputController(client: client)
        await controller.start()
        client.yield(.init(text: "Plane einen Törn", isFinal: false))
        await waitUntil { controller.transcript == "Plane einen Törn" }
        await controller.stop()
        XCTAssertEqual(controller.transcript, "Plane einen Törn nach Juist")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(client.stopCount, 1)
    }

    @MainActor
    func testStopTimeoutReturnsAndPreservesRecognizedText() async {
        let client = FakeNautiSpeechInputClient()
        client.finishWhenStopped = false
        let controller = NautiSpeechInputController(client: client, finalizationTimeout: .milliseconds(30))
        await controller.start()
        client.yield(.init(text: "Nach Juist", isFinal: false))
        await waitUntil { controller.transcript == "Nach Juist" }
        await controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.transcript, "Nach Juist")
        XCTAssertEqual(controller.errorMessage, NautiSpeechInputError.finalizationTimedOut.localizedDescription)
        await waitUntil { client.cancelCount > 0 }
    }

    @MainActor
    func testThirdBackendStartsOnlyAfterBothFailedBackendsAreReleased() async throws {
        let primary = FakeNautiSpeechBackend(error: NautiSpeechInputError.onDeviceRecognitionUnavailable)
        let fallback = FakeNautiSpeechBackend(error: NautiSpeechInputError.downloadFailed)
        let last = FakeNautiSpeechBackend()
        let client = AppleNautiSpeechInputClient(primary: { primary }, fallback: { fallback }, additionalFallback: {
            XCTAssertEqual(primary.cancelCount, 1)
            XCTAssertEqual(fallback.cancelCount, 1)
            return last
        })
        _ = try await client.startTranscription()
        XCTAssertEqual(last.startCount, 1)
        await client.cancelTranscription()
    }

    @MainActor
    func testDownloadFailureKeepsOriginalCauseInsteadOfGenericAssetsError() async {
        let original = NSError(domain: "SpeechDownloadTest", code: 42)
        let primary = FakeNautiSpeechBackend(error: NautiSpeechFailure(reason: .downloadFailed, underlying: original))
        let fallback = FakeNautiSpeechBackend(error: NautiSpeechInputError.onDeviceRecognitionUnavailable)
        let client = AppleNautiSpeechInputClient(primary: { primary }, fallback: { fallback })
        do {
            _ = try await client.startTranscription()
            XCTFail("Der Downloadfehler muss erhalten bleiben.")
        } catch {
            XCTAssertEqual(NautiSpeechInputError.reason(for: error), .downloadFailed)
            XCTAssertEqual(((error as? NautiSpeechFailure)?.underlying as? NSError)?.code, 42)
        }
    }

    @MainActor
    func testSpeechDraftStaysInOriginatingConversationAndIsNotSent() async {
        let client = FakeNautiSpeechInputClient()
        let model = NautiChatViewModel(repository: MemoryNautiConversationRepository(), speechClient: client)
        model.draft = "Bitte:"
        let original = model.activeConversationID
        await model.startSpeechInput()
        client.yield(.init(text: "Plane einen Törn", isFinal: false))
        await waitUntil { model.draft == "Bitte: Plane einen Törn" }
        XCTAssertFalse(model.canSend)
        let other = model.createConversation()
        client.yield(.init(text: "Späterer Text", isFinal: true))
        await Task.yield()
        XCTAssertEqual(model.activeConversationID, other)
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.messages.contains { $0.role == .user })
        model.selectConversation(original)
        XCTAssertEqual(model.draft, "Bitte: Plane einen Törn")
    }

    @MainActor
    func testSecondRecordingAppendsWithoutDuplicatingTheFirst() async {
        let client = FakeNautiSpeechInputClient()
        let model = NautiChatViewModel(repository: MemoryNautiConversationRepository(), speechClient: client)
        model.draft = "Bitte"
        await model.startSpeechInput()
        client.stopResult = "Plane einen Törn"
        await model.speechInput.stop()
        XCTAssertEqual(model.draft, "Bitte Plane einen Törn")
        await model.startSpeechInput()
        client.stopResult = "nach Juist"
        await model.speechInput.stop()
        XCTAssertEqual(model.draft, "Bitte Plane einen Törn nach Juist")
        XCTAssertTrue(model.canSend)
        XCTAssertFalse(model.messages.contains { $0.role == .user })
    }

    @MainActor
    func testSpeechCorrectsNauticalWordWithoutChangingExistingDraft() async {
        let client = FakeNautiSpeechInputClient()
        let model = NautiChatViewModel(repository: MemoryNautiConversationRepository(), speechClient: client)
        model.draft = "Turn als Beispiel:"
        await model.startSpeechInput()
        client.yield(.init(text: "Plane einen Turn nach Juist", isFinal: false))
        await waitUntil { model.draft == "Turn als Beispiel: Plane einen Törn nach Juist" }
        XCTAssertEqual(model.speechInput.transcript, "Plane einen Törn nach Juist")
        model.speechInput.cancel()
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class FakeNautiSpeechInputClient: NautiSpeechInputClient {
    let permission: NautiSpeechPermission
    private var continuation: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?
    var stopResult: String?
    var finishWhenStopped = true

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    init(permission: NautiSpeechPermission = .authorized) {
        self.permission = permission
    }

    func requestPermission() async -> NautiSpeechPermission {
        permission
    }

    func startTranscription() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        startCount += 1
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func stopTranscription() async {
        stopCount += 1
        if let stopResult { continuation?.yield(.init(text: stopResult, isFinal: true)) }
        if finishWhenStopped { continuation?.finish() }
        continuation = nil
    }

    func cancelTranscription() async {
        cancelCount += 1
        continuation?.finish(throwing: CancellationError())
        continuation = nil
    }

    func yield(_ transcript: NautiSpeechTranscript) {
        continuation?.yield(transcript)
    }

    func finish() { continuation?.finish() }

    func finish(throwing error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class FakeNautiSpeechBackend: NautiSpeechBackend {
    let error: Error?
    var startCount = 0
    var cancelCount = 0
    var suspendStart = false
    var pendingStart: CheckedContinuation<Void, Never>?
    var continuation: AsyncThrowingStream<NautiSpeechTranscript, Error>.Continuation?

    init(error: Error? = nil) { self.error = error }

    func start() async throws -> AsyncThrowingStream<NautiSpeechTranscript, Error> {
        startCount += 1
        if suspendStart {
            await withCheckedContinuation { pendingStart = $0 }
        }
        if let error { throw error }
        return AsyncThrowingStream { continuation = $0 }
    }

    func stop() async { continuation?.finish() }
    func cancel() async {
        cancelCount += 1
        continuation?.finish()
    }
}
