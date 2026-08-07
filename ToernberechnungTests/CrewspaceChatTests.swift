import Foundation
import XCTest
@testable import Toernberechnung

final class CrewspaceChatTests: XCTestCase {
    func testRealtimeMessageEventDecodesProtocolV1() throws {
        let payload = Data(
            #"""
            {
              "version": 1,
              "type": "message.created",
              "event_id": "evt-17",
              "occurred_at": "2026-07-25T14:15:16.125Z",
              "message": {
                "id": "message-42",
                "client_message_id": "client-42",
                "conversation_id": "conversation-7",
                "sender_id": "firebase-user-a",
                "sender_name": "Anna",
                "text": "Moin",
                "media_url": null,
                "media_type": null,
                "media_duration_seconds": null,
                "poll": null,
                "event": null,
                "created_at": "2026-07-25T14:15:16.125Z"
              }
            }
            """#.utf8
        )

        let event = try CrewspaceAPI.decoder.decode(CrewspaceRealtimeEventDTO.self, from: payload)

        XCTAssertEqual(event.version, 1)
        XCTAssertEqual(event.type, "message.created")
        XCTAssertEqual(event.eventID, "evt-17")
        XCTAssertNotNil(event.occurredAt)
        XCTAssertEqual(event.message?.id, "message-42")
        XCTAssertEqual(event.message?.clientMessageID, "client-42")
        XCTAssertEqual(event.message?.senderID, "firebase-user-a")
        XCTAssertEqual(event.message?.text, "Moin")
    }

    func testCompatibilityDecodersUseSafeDefaults() throws {
        let conversation = try CrewspaceAPI.decoder.decode(
            CrewspaceConversationDTO.self,
            from: Data(
                #"""
                {
                  "id": "conversation-1",
                  "title": "Direktchat",
                  "kind": "direct",
                  "member_ids": ["self", "peer"],
                  "member_names": ["Ich", "Peer"],
                  "last_message": null,
                  "last_message_at": null,
                  "unread_count": 0,
                  "updated_at": "2026-07-25T14:15:16Z"
                }
                """#.utf8
            )
        )
        let canonicalBlocks = try CrewspaceAPI.decoder.decode(
            CrewspaceBlockListDTO.self,
            from: Data(#"{"blocked_uids":["peer-a","peer-b"]}"#.utf8)
        )
        let legacyBlocks = try CrewspaceAPI.decoder.decode(
            CrewspaceBlockListDTO.self,
            from: Data(#"["peer-c"]"#.utf8)
        )

        XCTAssertTrue(conversation.chatAvailable)
        XCTAssertEqual(canonicalBlocks.blockedUIDs, ["peer-a", "peer-b"])
        XCTAssertEqual(legacyBlocks.blockedUIDs, ["peer-c"])
    }

    @MainActor
    func testStoreDeduplicatesCanonicalMessagesByServerAndClientID() {
        let store = CrewspaceStore(
            authTokenProvider: { "unused" },
            baseURL: URL(string: "https://crewspace.invalid")!
        )
        let createdAt = Date(timeIntervalSince1970: 1_774_400_000)
        let optimistic = makeMessage(
            id: "local:client-1",
            clientMessageID: "client-1",
            text: "ausstehend",
            createdAt: createdAt,
            deliveryState: .pending
        )
        let canonical = makeMessage(
            id: "server-1",
            clientMessageID: "client-1",
            text: "kanonisch",
            createdAt: createdAt
        )
        let repeatedServerEvent = makeMessage(
            id: "server-1",
            clientMessageID: "client-1",
            text: "kanonisch",
            createdAt: createdAt
        )
        let idempotentRetryResponse = makeMessage(
            id: "server-1",
            clientMessageID: "client-1",
            text: "kanonisch",
            createdAt: createdAt
        )

        store.merge(optimistic)
        store.merge(canonical)
        store.merge(repeatedServerEvent)
        store.merge(idempotentRetryResponse)

        let messages = store.messages(for: "conversation-1")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, "server-1")
        XCTAssertEqual(messages.first?.clientMessageID, "client-1")
        XCTAssertEqual(messages.first?.deliveryState, .sent)
        XCTAssertNil(messages.first?.deliveryError)
    }

    func testCursorPolicyKeepsDeltaCursorWhileLoadingOlderPages() {
        var cursor = CrewspaceMessageCursorState(
            latestPage: page(before: "before-1", after: "after-1", hasMore: true)
        )

        cursor.applyOlderPage(page(before: "before-2", after: "rewind", hasMore: false))

        XCTAssertEqual(cursor.before, "before-2")
        XCTAssertEqual(cursor.after, "after-1")
        XCTAssertFalse(cursor.hasMoreBefore)

        let next = cursor.applyDeltaPage(
            page(before: nil, after: "after-2", hasMore: true),
            currentCursor: "after-1"
        )
        XCTAssertEqual(next, "after-2")
        XCTAssertEqual(cursor.after, "after-2")
        XCTAssertEqual(cursor.before, "before-2")

        let finished = cursor.applyDeltaPage(
            page(before: nil, after: "after-3", hasMore: false),
            currentCursor: "after-2"
        )
        XCTAssertNil(finished)
        XCTAssertEqual(cursor.after, "after-3")
    }

    func testPersistedCursorDoesNotSkipLatestPageWhenMemoryIsEmpty() {
        XCTAssertEqual(
            CrewspaceCanonicalSyncPolicy.mode(
                isLoadedInMemory: false,
                afterCursor: "persisted-after"
            ),
            .latest
        )
        XCTAssertEqual(
            CrewspaceCanonicalSyncPolicy.mode(
                isLoadedInMemory: true,
                afterCursor: "persisted-after"
            ),
            .delta(after: "persisted-after")
        )
        XCTAssertEqual(
            CrewspaceCanonicalSyncPolicy.mode(
                isLoadedInMemory: true,
                afterCursor: nil
            ),
            .latest
        )
    }

    func testOutboxAndCursorsPersistAtomicallyPerAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crewspace-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CrewspaceOutboxRepository(rootDirectory: root)
        let timestamp = Date(timeIntervalSince1970: 1_774_400_000)
        let pending = CrewspacePendingMessage(
            clientMessageID: "client-persisted",
            accountID: "account-a",
            conversationID: "conversation-1",
            text: "offline",
            mediaType: nil,
            mediaContentType: nil,
            mediaFileExtension: nil,
            mediaDurationSeconds: nil,
            localMediaPath: nil,
            remoteMediaURL: nil,
            createdAt: timestamp,
            state: .failed,
            attemptCount: 2,
            nextAttemptAt: timestamp.addingTimeInterval(4),
            lastError: "timeout"
        )
        let cursors = [
            "conversation-1": CrewspaceMessageCursorState(
                before: "before-cursor",
                after: "after-cursor",
                hasMoreBefore: true
            ),
        ]

        try await repository.save([pending], accountID: "account-a")
        try await repository.saveCursorState(cursors, accountID: "account-a")

        let accountAOutbox = try await repository.load(accountID: "account-a")
        let accountBOutbox = try await repository.load(accountID: "account-b")
        let accountACursors = try await repository.loadCursorState(accountID: "account-a")
        let accountBCursors = try await repository.loadCursorState(accountID: "account-b")

        XCTAssertEqual(accountAOutbox, [pending])
        XCTAssertEqual(accountBOutbox, [])
        XCTAssertEqual(accountACursors, cursors)
        XCTAssertEqual(accountBCursors, [:])
    }

    func testOutboxRetriesOnlyTransportAndRetryableServerFailures() {
        XCTAssertNil(
            CrewspaceOutboxRetryPolicy.delay(
                for: SocialFeedAPIError.server(statusCode: 403, message: "chat_unavailable"),
                attemptCount: 1
            )
        )
        XCTAssertNil(
            CrewspaceOutboxRetryPolicy.delay(
                for: SocialFeedAPIError.server(statusCode: 422, message: "invalid_media"),
                attemptCount: 4
            )
        )
        XCTAssertEqual(
            CrewspaceOutboxRetryPolicy.delay(
                for: SocialFeedAPIError.server(statusCode: 503, message: nil),
                attemptCount: 3
            ),
            8
        )
        XCTAssertEqual(
            CrewspaceOutboxRetryPolicy.delay(
                for: URLError(.timedOut),
                attemptCount: 2
            ),
            4
        )
    }

    @MainActor
    func testColdStartPushRouteRemainsBufferedUntilStoreConsumesIt() {
        let center = CrewspacePushRouteCenter()
        let store = CrewspaceStore(
            authTokenProvider: { "unused" },
            baseURL: URL(string: "https://crewspace.invalid")!
        )

        center.pendingConversationID = "conversation-push"
        XCTAssertEqual(
            AppDelegate.conversationID(from: ["conversation_id": "conversation-push"]),
            "conversation-push"
        )
        XCTAssertNil(AppDelegate.conversationID(from: ["conversation_id": ""]))

        if let pending = center.pendingConversationID {
            store.requestConversationRoute(pending)
        }

        XCTAssertEqual(center.pendingConversationID, "conversation-push")
        XCTAssertEqual(store.pendingConversationID, "conversation-push")

        center.pendingConversationID = nil
        store.consumeConversationRoute("conversation-push")
        XCTAssertNil(center.pendingConversationID)
        XCTAssertNil(store.pendingConversationID)
    }

    private func makeMessage(
        id: String,
        clientMessageID: String?,
        text: String,
        createdAt: Date,
        deliveryState: CrewspaceMessageDeliveryState? = nil
    ) -> CrewspaceMessageDTO {
        CrewspaceMessageDTO(
            id: id,
            clientMessageID: clientMessageID,
            conversationID: "conversation-1",
            senderID: "account-a",
            senderName: "Anna",
            text: text,
            createdAt: createdAt,
            deliveryState: deliveryState
        )
    }

    private func page(
        before: String?,
        after: String?,
        hasMore: Bool
    ) -> CrewspaceMessagePageDTO {
        CrewspaceMessagePageDTO(
            messages: [],
            nextBeforeCursor: before,
            nextAfterCursor: after,
            hasMore: hasMore
        )
    }
}
