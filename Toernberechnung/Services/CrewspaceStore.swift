// swiftlint:disable file_length type_body_length
import Foundation
import Observation

enum CrewspaceConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
}

struct CrewspacePendingMessage: Codable, Identifiable, Hashable, Sendable {
    let clientMessageID: String
    let accountID: String
    let conversationID: String
    let text: String
    let mediaType: String?
    let mediaContentType: String?
    let mediaFileExtension: String?
    let mediaDurationSeconds: Double?
    let localMediaPath: String?
    var remoteMediaURL: String?
    let createdAt: Date
    var state: CrewspaceMessageDeliveryState
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastError: String?

    var id: String { clientMessageID }
}

struct CrewspaceMessageCursorState: Codable, Equatable, Sendable {
    var before: String?
    var after: String?
    var hasMoreBefore: Bool

    init(before: String?, after: String?, hasMoreBefore: Bool) {
        self.before = before
        self.after = after
        self.hasMoreBefore = hasMoreBefore
    }

    init(latestPage page: CrewspaceMessagePageDTO) {
        before = page.nextBeforeCursor
        after = page.nextAfterCursor
        hasMoreBefore = page.hasMore
    }

    mutating func applyOlderPage(_ page: CrewspaceMessagePageDTO) {
        before = page.nextBeforeCursor
        hasMoreBefore = page.hasMore
    }

    mutating func applyDeltaPage(
        _ page: CrewspaceMessagePageDTO,
        currentCursor: String
    ) -> String? {
        let nextCursor = page.nextAfterCursor ?? currentCursor
        after = nextCursor
        guard page.hasMore, nextCursor != currentCursor else { return nil }
        return nextCursor
    }
}

enum CrewspaceCanonicalSyncMode: Equatable {
    case latest
    case delta(after: String)
}

enum CrewspaceCanonicalSyncPolicy {
    static func mode(isLoadedInMemory: Bool, afterCursor: String?) -> CrewspaceCanonicalSyncMode {
        guard isLoadedInMemory, let afterCursor, !afterCursor.isEmpty else {
            return .latest
        }
        return .delta(after: afterCursor)
    }
}

actor CrewspaceOutboxRepository {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootDirectory = support.appendingPathComponent("CrewspaceOutbox", isDirectory: true)
        }
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(accountID: String) throws -> [CrewspacePendingMessage] {
        try ensureAccountDirectory(accountID)
        let url = outboxURL(accountID)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([CrewspacePendingMessage].self, from: Data(contentsOf: url))
    }

    func save(_ messages: [CrewspacePendingMessage], accountID: String) throws {
        try ensureAccountDirectory(accountID)
        let data = try encoder.encode(messages)
        try data.write(to: outboxURL(accountID), options: .atomic)
    }

    func loadCursorState(accountID: String) throws -> [String: CrewspaceMessageCursorState] {
        try ensureAccountDirectory(accountID)
        let url = cursorURL(accountID)
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        return try decoder.decode([String: CrewspaceMessageCursorState].self, from: Data(contentsOf: url))
    }

    func saveCursorState(
        _ cursors: [String: CrewspaceMessageCursorState],
        accountID: String
    ) throws {
        try ensureAccountDirectory(accountID)
        try encoder.encode(cursors).write(to: cursorURL(accountID), options: .atomic)
    }

    func persistMedia(
        _ data: Data,
        accountID: String,
        clientMessageID: String,
        fileExtension: String
    ) throws -> URL {
        try ensureAccountDirectory(accountID)
        let safeExtension = fileExtension
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
        let url = accountDirectory(accountID)
            .appendingPathComponent("\(clientMessageID).\(safeExtension.isEmpty ? "bin" : safeExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    func removeMedia(at path: String?) {
        guard let path, !path.isEmpty else { return }
        try? fileManager.removeItem(at: URL(fileURLWithPath: path))
    }

    private func ensureAccountDirectory(_ accountID: String) throws {
        try fileManager.createDirectory(
            at: accountDirectory(accountID),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    private func accountDirectory(_ accountID: String) -> URL {
        let encoded = Data(accountID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return rootDirectory.appendingPathComponent(encoded, isDirectory: true)
    }

    private func outboxURL(_ accountID: String) -> URL {
        accountDirectory(accountID).appendingPathComponent("pending-messages.json")
    }

    private func cursorURL(_ accountID: String) -> URL {
        accountDirectory(accountID).appendingPathComponent("message-cursors.json")
    }
}

enum CrewspaceOutboxRetryPolicy {
    static func delay(for error: Error, attemptCount: Int) -> TimeInterval? {
        let shouldRetry: Bool
        if let apiError = error as? SocialFeedAPIError {
            switch apiError {
            case let .server(statusCode, _):
                shouldRetry = statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
            case .invalidResponse, .uploadFailed:
                shouldRetry = true
            case .invalidURL, .authenticationRequired:
                shouldRetry = false
            }
        } else {
            shouldRetry = (error as NSError).domain == NSURLErrorDomain
        }
        guard shouldRetry else { return nil }
        return min(300.0, pow(2.0, Double(min(attemptCount, 8))))
    }
}

private actor CrewspaceRealtimeClient {
    typealias EventHandler = @Sendable (CrewspaceRealtimeEventDTO) async -> Void
    typealias StateHandler = @Sendable (CrewspaceConnectionState) async -> Void

    private let baseURL: URL
    private let session: URLSession
    private let authTokenProvider: @Sendable () async throws -> String
    private var runTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var eventIDs = Set<String>()
    private var eventIDOrder: [String] = []

    init(
        baseURL: URL,
        session: URLSession,
        authTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.baseURL = baseURL
        self.session = session
        self.authTokenProvider = authTokenProvider
    }

    func start(onEvent: @escaping EventHandler, onState: @escaping StateHandler) {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run(onEvent: onEvent, onState: onState)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func run(onEvent: @escaping EventHandler, onState: @escaping StateHandler) async {
        var reconnectAttempt = 0
        while !Task.isCancelled {
            await onState(.connecting)
            do {
                let task = try await makeSocket()
                socket = task
                task.resume()
                let pingTask = Task { [weak self] in
                    await self?.pingLoop(task)
                }
                let readyTimeoutTask = Task {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    task.cancel(with: .policyViolation, reason: Data("ready timeout".utf8))
                }
                defer {
                    pingTask.cancel()
                    readyTimeoutTask.cancel()
                    task.cancel(with: .goingAway, reason: nil)
                    if socket === task { socket = nil }
                }

                var receivedReady = false
                while !Task.isCancelled {
                    let frame = try await task.receive()
                    let data: Data
                    switch frame {
                    case let .data(value):
                        data = value
                    case let .string(value):
                        guard let value = value.data(using: .utf8) else { continue }
                        data = value
                    @unknown default:
                        continue
                    }
                    let event = try CrewspaceAPI.decoder.decode(CrewspaceRealtimeEventDTO.self, from: data)
                    guard event.version == 1, shouldDeliver(event) else { continue }
                    if event.type == "ready" {
                        receivedReady = true
                        reconnectAttempt = 0
                        readyTimeoutTask.cancel()
                        await onState(.connected)
                    }
                    await onEvent(event)
                }
                if !receivedReady { reconnectAttempt += 1 }
            } catch is CancellationError {
                break
            } catch {
                reconnectAttempt += 1
            }

            guard !Task.isCancelled else { break }
            await onState(.disconnected)
            let exponent = min(reconnectAttempt, 6)
            let delay = min(30.0, pow(2.0, Double(exponent))) + Double.random(in: 0...0.75)
            try? await Task.sleep(for: .seconds(delay))
        }
        await onState(.disconnected)
    }

    private func makeSocket() async throws -> URLSessionWebSocketTask {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("crewspace/realtime"),
            resolvingAgainstBaseURL: false
        )
        components?.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        guard let url = components?.url else { throw SocialFeedAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Crewspace-Protocol-Version")
        return session.webSocketTask(with: request)
    }

    private func pingLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    socket.sendPing { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func shouldDeliver(_ event: CrewspaceRealtimeEventDTO) -> Bool {
        guard let eventID = event.eventID, !eventID.isEmpty else { return true }
        guard eventIDs.insert(eventID).inserted else { return false }
        eventIDOrder.append(eventID)
        if eventIDOrder.count > 1_000 {
            eventIDs.remove(eventIDOrder.removeFirst())
        }
        return true
    }
}

@MainActor
@Observable
final class CrewspaceStore {
    private(set) var conversations: [CrewspaceConversationDTO] = []
    private(set) var events: [CrewspaceEventDTO] = []
    private(set) var groupInfoByID: [String: CrewspaceGroupInfoDTO] = [:]
    private(set) var messagesByConversation: [String: [CrewspaceMessageDTO]] = [:]
    private(set) var blockedUIDs = Set<String>()
    private(set) var connectionState = CrewspaceConnectionState.disconnected
    private(set) var pendingConversationID: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let api: CrewspaceAPI
    @ObservationIgnored private let realtime: CrewspaceRealtimeClient
    @ObservationIgnored private let outbox: CrewspaceOutboxRepository
    @ObservationIgnored private var cursorByConversation: [String: CrewspaceMessageCursorState] = [:]
    @ObservationIgnored private var loadedConversationIDs = Set<String>()
    @ObservationIgnored private var pendingMessages: [CrewspacePendingMessage] = []
    @ObservationIgnored private var activeAccountID: String?
    @ObservationIgnored private var accountGeneration = UUID()
    @ObservationIgnored private var activeDisplayName = "Skipper"
    @ObservationIgnored private var isFlushingOutbox = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init(
        authTokenProvider: @escaping @Sendable () async throws -> String,
        baseURL: URL = SocialFeedAPI.defaultBaseURL,
        session: URLSession = .shared,
        outboxDirectory: URL? = nil
    ) {
        api = CrewspaceAPI(baseURL: baseURL, session: session, authTokenProvider: authTokenProvider)
        realtime = CrewspaceRealtimeClient(
            baseURL: baseURL,
            session: session,
            authTokenProvider: authTokenProvider
        )
        outbox = CrewspaceOutboxRepository(rootDirectory: outboxDirectory)
    }

    func activateAccount(accountID: String, displayName: String?) async {
        let normalizedName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Skipper"
        if activeAccountID == accountID {
            activeDisplayName = normalizedName
            await ensureRealtimeStarted()
            await flushOutbox()
            return
        }

        let generation = UUID()
        accountGeneration = generation
        await realtime.stop()
        guard accountGeneration == generation else { return }
        retryTask?.cancel()
        clearInMemoryState()
        activeAccountID = accountID
        activeDisplayName = normalizedName

        do {
            let loadedPendingMessages = try await outbox.load(accountID: accountID)
            let loadedCursors = try await outbox.loadCursorState(accountID: accountID)
            guard isCurrentAccount(accountID, generation: generation) else { return }
            pendingMessages = loadedPendingMessages
            cursorByConversation = loadedCursors
            hydratePendingMessages()
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = "Ausstehende Nachrichten konnten nicht geladen werden: \(error.localizedDescription)"
        }

        do {
            _ = try await api.upsertMe(name: normalizedName)
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = error.localizedDescription
        }
        guard isCurrentAccount(accountID, generation: generation) else { return }
        await refresh()
        guard isCurrentAccount(accountID, generation: generation) else { return }
        await refreshBlocks()
        guard isCurrentAccount(accountID, generation: generation) else { return }
        await ensureRealtimeStarted()
        await flushOutbox()
    }

    func reset() {
        accountGeneration = UUID()
        retryTask?.cancel()
        retryTask = nil
        activeAccountID = nil
        clearInMemoryState()
        Task { await realtime.stop() }
    }

    func deactivateAccount(installationID: String?) async {
        let accountID = activeAccountID
        let generation = UUID()
        accountGeneration = generation
        if let installationID, !installationID.isEmpty {
            try? await api.unregisterDevice(installationID: installationID)
        }
        guard accountGeneration == generation, activeAccountID == accountID else { return }
        await realtime.stop()
        guard accountGeneration == generation, activeAccountID == accountID else { return }
        retryTask?.cancel()
        retryTask = nil
        activeAccountID = nil
        clearInMemoryState()
    }

    func messages(for conversationID: String) -> [CrewspaceMessageDTO] {
        messagesByConversation[conversationID] ?? []
    }

    func isActiveAccount(_ accountID: String) -> Bool {
        activeAccountID == accountID
    }

    func canLoadOlderMessages(conversationID: String) -> Bool {
        loadedConversationIDs.contains(conversationID)
            && cursorByConversation[conversationID]?.hasMoreBefore == true
    }

    func refresh() async {
        guard let accountID = activeAccountID else { return }
        let generation = accountGeneration
        isLoading = true
        defer {
            if isCurrentAccount(accountID, generation: generation) {
                isLoading = false
            }
        }

        do {
            let chats = try await api.conversations()
            guard isCurrentAccount(accountID, generation: generation) else { return }
            let appointments = try await api.events()
            guard isCurrentAccount(accountID, generation: generation) else { return }
            conversations = chats.sorted(by: Self.conversationSort)
            events = appointments.sorted { $0.startsAt < $1.startsAt }
            errorMessage = nil
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadLatestMessages(conversationID: String, force: Bool = false) async {
        guard let accountID = activeAccountID else { return }
        let generation = accountGeneration
        if !force, loadedConversationIDs.contains(conversationID) {
            try? await api.markRead(conversationID: conversationID)
            return
        }
        do {
            let page = try await api.messagePage(conversationID: conversationID)
            guard isCurrentAccount(accountID, generation: generation) else { return }
            mergeMessages(page.messages, conversationID: conversationID)
            cursorByConversation[conversationID] = CrewspaceMessageCursorState(latestPage: page)
            loadedConversationIDs.insert(conversationID)
            try? await persistCursorState()
            try? await api.markRead(conversationID: conversationID)
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = nil
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadOlderMessages(conversationID: String) async {
        guard let accountID = activeAccountID else { return }
        let generation = accountGeneration
        guard let cursor = cursorByConversation[conversationID],
              cursor.hasMoreBefore,
              let before = cursor.before else { return }
        do {
            let page = try await api.messagePage(conversationID: conversationID, before: before)
            guard isCurrentAccount(accountID, generation: generation) else { return }
            mergeMessages(page.messages, conversationID: conversationID)
            cursorByConversation[conversationID]?.applyOlderPage(page)
            try? await persistCursorState()
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func resolveConversations(
        matching query: String,
        isGroup: Bool?,
        currentSkipperID: String?
    ) -> [CrewspaceConversationDTO] {
        let needle = Self.normalized(query)
        guard !needle.isEmpty else { return [] }

        return conversations.filter { conversation in
            guard isGroup == nil || conversation.isGroup == isGroup else { return false }
            var candidates = [conversation.title]
            candidates.append(contentsOf: conversation.memberNames)
            candidates.append(contentsOf: conversation.memberIDs.filter { $0 != currentSkipperID })
            return candidates.contains { candidate in
                let normalized = Self.normalized(candidate)
                return normalized == needle
                    || normalized.contains(needle)
                    || needle.contains(normalized)
            }
        }
    }

    @discardableResult
    func sendMessage(conversationID: String, text: String) async throws -> CrewspaceMessageDTO {
        try await enqueueText(conversationID: conversationID, text: text)
    }

    @discardableResult
    func enqueueText(conversationID: String, text: String) async throws -> CrewspaceMessageDTO {
        try ensureChatAvailable(conversationID: conversationID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CrewspaceStoreError.emptyMessage }
        let pending = try await makePendingMessage(conversationID: conversationID, text: trimmed)
        let local = optimisticMessage(from: pending)
        mergeMessages([local], conversationID: conversationID)
        Task { await flushOutbox() }
        return local
    }

    @discardableResult
    func enqueueMedia(
        conversationID: String,
        text: String,
        data: Data,
        mediaType: String,
        contentType: String,
        fileExtension: String,
        duration: Double? = nil
    ) async throws -> CrewspaceMessageDTO {
        try ensureChatAvailable(conversationID: conversationID)
        guard !data.isEmpty else { throw CrewspaceStoreError.emptyMedia }
        guard let accountID = activeAccountID else { throw SocialFeedAPIError.authenticationRequired }
        let clientMessageID = UUID().uuidString.lowercased()
        let localURL = try await outbox.persistMedia(
            data,
            accountID: accountID,
            clientMessageID: clientMessageID,
            fileExtension: fileExtension
        )
        let pending = CrewspacePendingMessage(
            clientMessageID: clientMessageID,
            accountID: accountID,
            conversationID: conversationID,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            mediaType: mediaType,
            mediaContentType: contentType,
            mediaFileExtension: fileExtension,
            mediaDurationSeconds: duration,
            localMediaPath: localURL.path,
            remoteMediaURL: nil,
            createdAt: .now,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: .now,
            lastError: nil
        )
        pendingMessages.append(pending)
        try await persistOutbox()
        let local = optimisticMessage(from: pending)
        mergeMessages([local], conversationID: conversationID)
        Task { await flushOutbox() }
        return local
    }

    func retry(clientMessageID: String) async {
        guard let index = pendingMessages.firstIndex(where: { $0.clientMessageID == clientMessageID }) else {
            return
        }
        pendingMessages[index].state = .pending
        pendingMessages[index].nextAttemptAt = .now
        pendingMessages[index].lastError = nil
        try? await persistOutbox()
        replaceOptimisticMessage(from: pendingMessages[index])
        await flushOutbox()
    }

    func registerDevice(installationID: String) async {
        guard let accountID = activeAccountID, !installationID.isEmpty else { return }
        let generation = accountGeneration
        do {
            try await api.registerDevice(installationID: installationID)
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func unregisterDevice(installationID: String) async {
        guard activeAccountID != nil, !installationID.isEmpty else { return }
        try? await api.unregisterDevice(installationID: installationID)
    }

    func refreshBlocks() async {
        guard let accountID = activeAccountID else { return }
        let generation = accountGeneration
        do {
            let blocks = try await api.blocks()
            guard isCurrentAccount(accountID, generation: generation) else { return }
            blockedUIDs = Set(blocks.blockedUIDs)
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func setBlocked(_ blocked: Bool, skipperID: String) async throws {
        guard let accountID = activeAccountID else {
            throw SocialFeedAPIError.authenticationRequired
        }
        let generation = accountGeneration
        if blocked {
            try await api.block(skipperID: skipperID)
            guard isCurrentAccount(accountID, generation: generation) else {
                throw CancellationError()
            }
            blockedUIDs.insert(skipperID)
        } else {
            try await api.unblock(skipperID: skipperID)
            guard isCurrentAccount(accountID, generation: generation) else {
                throw CancellationError()
            }
            blockedUIDs.remove(skipperID)
        }
        let updatedConversations = try await api.conversations()
        guard isCurrentAccount(accountID, generation: generation) else {
            throw CancellationError()
        }
        conversations = updatedConversations.sorted(by: Self.conversationSort)
    }

    func isChatAvailable(_ conversation: CrewspaceConversationDTO) -> Bool {
        guard !conversation.isGroup else { return true }
        guard conversation.chatAvailable else { return false }
        guard let accountID = activeAccountID else { return false }
        let peerIDs = conversation.memberIDs.filter { $0 != accountID }
        return !peerIDs.contains(where: blockedUIDs.contains)
    }

    func peerID(for conversation: CrewspaceConversationDTO) -> String? {
        guard !conversation.isGroup, let accountID = activeAccountID else { return nil }
        return conversation.memberIDs.first { $0 != accountID }
    }

    func requestConversationRoute(_ conversationID: String) {
        pendingConversationID = conversationID
    }

    @discardableResult
    func prepareConversationRouteAfterPush(conversationID: String) async -> Bool {
        guard let accountID = activeAccountID else { return false }
        let generation = accountGeneration
        if !conversations.contains(where: { $0.id == conversationID }) {
            await refresh()
        }
        guard isCurrentAccount(accountID, generation: generation),
              conversations.contains(where: { $0.id == conversationID }) else {
            errorMessage = "Die Unterhaltung aus der Mitteilung ist nicht verfügbar."
            return false
        }

        do {
            try await synchronizeCanonicalMessages(
                conversationID: conversationID,
                accountID: accountID,
                generation: generation,
                markRead: true
            )
            guard isCurrentAccount(accountID, generation: generation) else { return false }
            requestConversationRoute(conversationID)
            errorMessage = nil
            return true
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func consumeConversationRoute(_ conversationID: String) {
        if pendingConversationID == conversationID {
            pendingConversationID = nil
        }
    }

    @discardableResult
    func createEvent(_ draft: CrewspaceEventDraft) async throws -> CrewspaceEventDTO {
        let event = try await api.createEvent(draft)
        replace(event)
        errorMessage = nil
        return event
    }

    func groupInfo(conversationID: String, force: Bool = false) async throws -> CrewspaceGroupInfoDTO {
        if !force, let cached = groupInfoByID[conversationID] {
            return cached
        }
        let info = try await api.groupInfo(conversationID: conversationID)
        groupInfoByID[conversationID] = info
        errorMessage = nil
        return info
    }

    @discardableResult
    func addCrewMember(
        conversationID: String,
        skipperID: String,
        crewRole: String
    ) async throws -> CrewspaceGroupInfoDTO {
        let info = try await api.addGroupMember(
            conversationID: conversationID,
            skipperID: skipperID,
            crewRole: crewRole,
            isOnBoard: false
        )
        groupInfoByID[conversationID] = info
        errorMessage = nil
        return info
    }

    func removeCrewMember(conversationID: String, skipperID: String) async throws {
        try await api.removeGroupMember(conversationID: conversationID, skipperID: skipperID)
        groupInfoByID[conversationID] = try await api.groupInfo(conversationID: conversationID)
        errorMessage = nil
    }

    func merge(_ conversation: CrewspaceConversationDTO) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.append(conversation)
        conversations.sort(by: Self.conversationSort)
    }

    func merge(_ message: CrewspaceMessageDTO) {
        mergeMessages([message], conversationID: message.conversationID)
    }

    func replace(_ event: CrewspaceEventDTO) {
        events.removeAll { $0.id == event.id }
        events.append(event)
        events.sort { $0.startsAt < $1.startsAt }
    }

    func deleteEvent(_ event: CrewspaceEventDTO) async throws {
        try await api.deleteEvent(eventID: event.id)
        events.removeAll { $0.id == event.id }
        errorMessage = nil
    }

    func removeConversation(_ conversation: CrewspaceConversationDTO) async throws {
        try await api.removeConversation(conversationID: conversation.id)
        conversations.removeAll { $0.id == conversation.id }
        messagesByConversation[conversation.id] = nil
        cursorByConversation[conversation.id] = nil
        loadedConversationIDs.remove(conversation.id)
        groupInfoByID[conversation.id] = nil
        errorMessage = nil
    }

    func record(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func ensureRealtimeStarted() async {
        guard let accountID = activeAccountID else { return }
        let generation = accountGeneration
        await realtime.start(
            onEvent: { [weak self] event in
                await self?.receive(event, accountID: accountID, generation: generation)
            },
            onState: { [weak self] state in
                await self?.setConnectionState(
                    state,
                    accountID: accountID,
                    generation: generation
                )
            }
        )
    }

    private func setConnectionState(
        _ state: CrewspaceConnectionState,
        accountID: String,
        generation: UUID
    ) {
        guard isCurrentAccount(accountID, generation: generation) else { return }
        connectionState = state
    }

    private func receive(
        _ event: CrewspaceRealtimeEventDTO,
        accountID: String,
        generation: UUID
    ) async {
        guard isCurrentAccount(accountID, generation: generation) else { return }
        switch event.type {
        case "ready":
            await recoverAfterReconnect(accountID: accountID, generation: generation)
            guard isCurrentAccount(accountID, generation: generation) else { return }
            await flushOutbox()
        case "message.created":
            if let message = event.message {
                mergeMessages([message], conversationID: message.conversationID)
            }
        case "conversation.updated":
            if let conversation = event.conversation {
                merge(conversation)
            }
        default:
            break
        }
    }

    private func recoverAfterReconnect(accountID: String, generation: UUID) async {
        guard isCurrentAccount(accountID, generation: generation) else { return }
        let conversationIDs = Set(messagesByConversation.keys)
            .union(cursorByConversation.keys)
            .union(conversations.map(\.id))
            .sorted()
        for conversationID in conversationIDs {
            do {
                try await synchronizeCanonicalMessages(
                    conversationID: conversationID,
                    accountID: accountID,
                    generation: generation,
                    markRead: false
                )
            } catch {
                guard isCurrentAccount(accountID, generation: generation) else { return }
                errorMessage = error.localizedDescription
            }
        }
        guard isCurrentAccount(accountID, generation: generation) else { return }
        try? await persistCursorState()
        do {
            let updatedConversations = try await api.conversations()
            guard isCurrentAccount(accountID, generation: generation) else { return }
            conversations = updatedConversations.sorted(by: Self.conversationSort)
        } catch {
            guard isCurrentAccount(accountID, generation: generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func synchronizeCanonicalMessages(
        conversationID: String,
        accountID: String,
        generation: UUID,
        markRead: Bool
    ) async throws {
        guard isCurrentAccount(accountID, generation: generation) else {
            throw CancellationError()
        }
        let syncMode = CrewspaceCanonicalSyncPolicy.mode(
            isLoadedInMemory: loadedConversationIDs.contains(conversationID),
            afterCursor: cursorByConversation[conversationID]?.after
        )
        if syncMode == .latest {
            let page = try await api.messagePage(conversationID: conversationID, limit: 200)
            guard isCurrentAccount(accountID, generation: generation) else {
                throw CancellationError()
            }
            mergeMessages(page.messages, conversationID: conversationID)
            cursorByConversation[conversationID] = CrewspaceMessageCursorState(latestPage: page)
            loadedConversationIDs.insert(conversationID)
            try await persistCursorState()
            if markRead {
                try? await api.markRead(conversationID: conversationID)
            }
            return
        }
        guard case let .delta(after: initialCursor) = syncMode else { return }
        var cursor = initialCursor

        repeat {
            let page = try await api.messagePage(
                conversationID: conversationID,
                after: cursor,
                limit: 200
            )
            guard isCurrentAccount(accountID, generation: generation) else {
                throw CancellationError()
            }
            mergeMessages(page.messages, conversationID: conversationID)
            guard let next = cursorByConversation[conversationID]?.applyDeltaPage(
                page,
                currentCursor: cursor
            ) else {
                try await persistCursorState()
                if markRead {
                    try? await api.markRead(conversationID: conversationID)
                }
                return
            }
            cursor = next
            try await persistCursorState()
        } while !Task.isCancelled
        try Task.checkCancellation()
    }

    private func makePendingMessage(
        conversationID: String,
        text: String
    ) async throws -> CrewspacePendingMessage {
        guard let accountID = activeAccountID else { throw SocialFeedAPIError.authenticationRequired }
        let pending = CrewspacePendingMessage(
            clientMessageID: UUID().uuidString.lowercased(),
            accountID: accountID,
            conversationID: conversationID,
            text: text,
            mediaType: nil,
            mediaContentType: nil,
            mediaFileExtension: nil,
            mediaDurationSeconds: nil,
            localMediaPath: nil,
            remoteMediaURL: nil,
            createdAt: .now,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: .now,
            lastError: nil
        )
        pendingMessages.append(pending)
        try await persistOutbox()
        return pending
    }

    private func flushOutbox() async {
        guard !isFlushingOutbox, let accountID = activeAccountID else { return }
        let generation = accountGeneration
        isFlushingOutbox = true
        retryTask?.cancel()
        retryTask = nil
        defer {
            isFlushingOutbox = false
            scheduleOutboxRetry()
        }

        let dueIDs = pendingMessages
            .filter { $0.accountID == accountID && $0.nextAttemptAt <= .now }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.clientMessageID)

        for clientMessageID in dueIDs {
            guard !Task.isCancelled,
                  isCurrentAccount(accountID, generation: generation),
                  let initialIndex = pendingMessages.firstIndex(where: {
                      $0.clientMessageID == clientMessageID && $0.accountID == accountID
                  }) else { continue }
            var pending = pendingMessages[initialIndex]
            do {
                if let localPath = pending.localMediaPath,
                   pending.remoteMediaURL == nil,
                   let contentType = pending.mediaContentType,
                   let fileExtension = pending.mediaFileExtension {
                    pending.state = .uploading
                    updatePending(pending)
                    let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
                    let upload = try await api.createMediaUpload(
                        contentType: contentType,
                        fileExtension: fileExtension
                    )
                    guard isCurrentAccount(accountID, generation: generation) else { return }
                    try await api.uploadMedia(data, to: upload, contentType: contentType)
                    guard isCurrentAccount(accountID, generation: generation) else { return }
                    pending.remoteMediaURL = upload.publicURL
                    updatePending(pending)
                    try await persistOutbox()
                    guard isCurrentAccount(accountID, generation: generation) else { return }
                }

                let canonical = try await api.sendMessage(
                    conversationID: pending.conversationID,
                    clientMessageID: pending.clientMessageID,
                    text: pending.text,
                    mediaURL: pending.remoteMediaURL,
                    mediaType: pending.mediaType,
                    mediaDurationSeconds: pending.mediaDurationSeconds
                )
                guard isCurrentAccount(accountID, generation: generation) else { return }
                pendingMessages.removeAll { $0.clientMessageID == pending.clientMessageID }
                try await persistOutbox()
                guard isCurrentAccount(accountID, generation: generation) else { return }
                await outbox.removeMedia(at: pending.localMediaPath)
                guard isCurrentAccount(accountID, generation: generation) else { return }
                mergeMessages([canonical], conversationID: canonical.conversationID)
            } catch {
                guard isCurrentAccount(accountID, generation: generation) else { return }
                pending.attemptCount += 1
                pending.state = .failed
                pending.lastError = error.localizedDescription
                if let delay = CrewspaceOutboxRetryPolicy.delay(
                    for: error,
                    attemptCount: pending.attemptCount
                ) {
                    pending.nextAttemptAt = .now.addingTimeInterval(delay)
                } else {
                    pending.nextAttemptAt = .distantFuture
                }
                updatePending(pending)
                try? await persistOutbox()
                guard isCurrentAccount(accountID, generation: generation) else { return }
                if let apiError = error as? SocialFeedAPIError,
                   case let .server(statusCode, _) = apiError,
                   statusCode == 403 {
                    await refresh()
                }
            }
        }
    }

    private func updatePending(_ pending: CrewspacePendingMessage) {
        guard let index = pendingMessages.firstIndex(where: { $0.clientMessageID == pending.clientMessageID }) else {
            return
        }
        pendingMessages[index] = pending
        replaceOptimisticMessage(from: pending)
    }

    private func scheduleOutboxRetry() {
        retryTask?.cancel()
        let retryDates = pendingMessages
            .map(\.nextAttemptAt)
            .filter { $0 != .distantFuture }
        guard let next = retryDates.min() else { return }
        let delay = max(0.25, next.timeIntervalSinceNow)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushOutbox()
        }
    }

    private func persistOutbox() async throws {
        guard let accountID = activeAccountID else { throw SocialFeedAPIError.authenticationRequired }
        try await outbox.save(pendingMessages.filter { $0.accountID == accountID }, accountID: accountID)
    }

    private func persistCursorState() async throws {
        guard let accountID = activeAccountID else { throw SocialFeedAPIError.authenticationRequired }
        try await outbox.saveCursorState(cursorByConversation, accountID: accountID)
    }

    private func hydratePendingMessages() {
        for pending in pendingMessages {
            mergeMessages([optimisticMessage(from: pending)], conversationID: pending.conversationID)
        }
    }

    private func optimisticMessage(from pending: CrewspacePendingMessage) -> CrewspaceMessageDTO {
        CrewspaceMessageDTO(
            id: "local:\(pending.clientMessageID)",
            clientMessageID: pending.clientMessageID,
            conversationID: pending.conversationID,
            senderID: pending.accountID,
            senderName: activeDisplayName,
            text: pending.text,
            mediaURL: pending.remoteMediaURL
                ?? pending.localMediaPath.map { URL(fileURLWithPath: $0).absoluteString },
            mediaType: pending.mediaType,
            mediaDurationSeconds: pending.mediaDurationSeconds,
            createdAt: pending.createdAt,
            deliveryState: pending.state,
            deliveryError: pending.lastError
        )
    }

    private func replaceOptimisticMessage(from pending: CrewspacePendingMessage) {
        var messages = messagesByConversation[pending.conversationID] ?? []
        messages.removeAll { $0.clientMessageID == pending.clientMessageID }
        messages.append(optimisticMessage(from: pending))
        messages.sort(by: Self.messageSort)
        messagesByConversation[pending.conversationID] = messages
    }

    private func mergeMessages(_ incoming: [CrewspaceMessageDTO], conversationID: String) {
        var merged = messagesByConversation[conversationID] ?? []
        for var message in incoming {
            if !message.id.hasPrefix("local:") {
                message.deliveryState = .sent
                message.deliveryError = nil
            }
            merged.removeAll { existing in
                existing.id == message.id
                    || (
                        message.clientMessageID != nil
                            && existing.clientMessageID == message.clientMessageID
                    )
            }
            merged.append(message)
        }
        merged.sort(by: Self.messageSort)
        messagesByConversation[conversationID] = merged
    }

    private func ensureChatAvailable(conversationID: String) throws {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        guard isChatAvailable(conversation) else { throw CrewspaceStoreError.chatUnavailable }
    }

    private func clearInMemoryState() {
        conversations = []
        events = []
        groupInfoByID = [:]
        messagesByConversation = [:]
        cursorByConversation = [:]
        loadedConversationIDs = []
        pendingMessages = []
        blockedUIDs = []
        connectionState = .disconnected
        pendingConversationID = nil
        isLoading = false
        isFlushingOutbox = false
        errorMessage = nil
    }

    private func isCurrentAccount(_ accountID: String, generation: UUID) -> Bool {
        activeAccountID == accountID && accountGeneration == generation
    }

    private static func messageSort(_ lhs: CrewspaceMessageDTO, _ rhs: CrewspaceMessageDTO) -> Bool {
        if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
        return lhs.createdAt < rhs.createdAt
    }

    private static func conversationSort(
        _ lhs: CrewspaceConversationDTO,
        _ rhs: CrewspaceConversationDTO
    ) -> Bool {
        let left = lhs.lastMessageAt ?? lhs.updatedAt
        let right = rhs.lastMessageAt ?? rhs.updatedAt
        if left == right { return lhs.id < rhs.id }
        return left > right
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CrewspaceStoreError: LocalizedError {
    case emptyMessage
    case emptyMedia
    case chatUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyMessage:
            return "Die Nachricht ist leer."
        case .emptyMedia:
            return "Das Medium ist leer."
        case .chatUnavailable:
            return "Dieser Direktchat ist derzeit nicht verfügbar."
        }
    }
}
