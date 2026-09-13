import XCTest
@testable import Toernberechnung

final class NautiSpeechInputTests: XCTestCase {
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
        XCTAssertTrue(controller.errorMessage?.contains("Sprachressourcen") == true)
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
        continuation?.finish()
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
