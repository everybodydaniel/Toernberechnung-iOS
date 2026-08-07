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
