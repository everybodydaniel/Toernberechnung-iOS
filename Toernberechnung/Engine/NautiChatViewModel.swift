import Foundation
import Observation

@MainActor
@Observable
final class NautiChatViewModel {
    private static let maximumVisibleMessages = 100
    private static let maximumGeneratedTitleLength = 48

    private(set) var conversations: [NautiConversation]
    private(set) var activeConversationID: UUID
    private(set) var generatingConversationID: UUID?
    private(set) var didLoadHistory = false

    var isSending = false
    var errorMessage: String?
    var persistenceWarning: String?

    @ObservationIgnored
    private let inferenceClient: any LocalAIInferenceClient
    @ObservationIgnored
    private let repository: any NautiConversationRepository
    @ObservationIgnored
    private var persistenceTask: Task<Void, Never>?

    init(
        inferenceClient: any LocalAIInferenceClient = LocalAIInferenceManager.shared,
        repository: any NautiConversationRepository = FileNautiConversationRepository.shared
    ) {
        let initialConversation = NautiConversation()
        self.conversations = [initialConversation]
        self.activeConversationID = initialConversation.id
        self.inferenceClient = inferenceClient
        self.repository = repository
    }

    var sortedConversations: [NautiConversation] {
        conversations.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var activeConversation: NautiConversation {
        conversations.first(where: { $0.id == activeConversationID })
            ?? conversations.first
            ?? NautiConversation()
    }

    var messages: [NautiChatMessage] {
        activeConversation.messages
    }

    var draft: String {
        get { activeConversation.draft }
        set {
            updateConversation(activeConversationID) { conversation in
                conversation.draft = newValue
            }
            schedulePersistence()
        }
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var isGeneratingActiveConversation: Bool {
        generatingConversationID == activeConversationID
    }

    func loadHistory() async {
        guard !didLoadHistory else { return }
        didLoadHistory = true

        do {
            let stored = try await repository.load()
            guard !stored.isEmpty else {
                await persistImmediately()
                return
            }

            conversations = stored.map(Self.sanitizedConversation)
            activeConversationID = sortedConversations.first?.id ?? conversations[0].id
        } catch {
            persistenceWarning = error.localizedDescription
            await persistImmediately()
        }
    }

    @discardableResult
    func createConversation() -> UUID {
        let conversation = NautiConversation()
        conversations.append(conversation)
        activeConversationID = conversation.id
        errorMessage = nil
        schedulePersistence()
        return conversation.id
    }

    func selectConversation(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        activeConversationID = id
        errorMessage = nil
    }

    func togglePin(_ id: UUID) {
        updateConversation(id) { conversation in
            conversation.isPinned.toggle()
            conversation.updatedAt = .now
        }
        schedulePersistence()
    }

    @discardableResult
    func renameConversation(_ id: UUID, title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        updateConversation(id) { conversation in
            conversation.title = String(normalized.prefix(80))
            conversation.hasCustomTitle = true
            conversation.updatedAt = .now
        }
        schedulePersistence()
        return true
    }

    func deleteConversation(_ id: UUID) {
        if generatingConversationID == id {
            cancelCurrentInference()
        }

        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            let replacement = NautiConversation()
            conversations = [replacement]
            activeConversationID = replacement.id
        } else if activeConversationID == id {
            activeConversationID = sortedConversations[0].id
        }
        schedulePersistence()
    }

    func sendCurrentDraft(when accessState: AIAccessState = .available) async -> NautiActionDispatch? {
        let conversationID = activeConversationID

        guard accessState.canUseAssistant else {
            let message = accessState.noticeMessage
                ?? "Nauti ist auf diesem Gerät nicht verfügbar. Die manuelle Planung bleibt vollständig nutzbar."
            errorMessage = message
            appendMessage(
                NautiChatMessage(role: .assistant, text: message),
                conversationID: conversationID
            )
            return nil
        }

        let userText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty, !isSending else { return nil }

        errorMessage = nil
        updateConversation(conversationID) { conversation in
            conversation.draft = ""
        }
        appendMessage(
            NautiChatMessage(role: .user, text: userText),
            conversationID: conversationID
        )
        isSending = true
        generatingConversationID = conversationID
        defer {
            isSending = false
            generatingConversationID = nil
        }

        let request = NautiInferenceRequest(
            messages: messages(in: conversationID).map {
                NautiConversationMessage(
                    role: $0.role == .user ? .user : .assistant,
                    text: $0.text
                )
            }
        )

        do {
            let result = try await inferenceClient.infer(request)
            appendMessage(
                NautiChatMessage(role: .assistant, text: result.text),
                conversationID: conversationID
            )
            guard let action = result.action else { return nil }
            return NautiActionDispatch(conversationID: conversationID, action: action)
        } catch LocalAIInferenceError.cancelled {
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            let message = Self.userFacingErrorMessage(for: error)
            errorMessage = message
            appendMessage(
                NautiChatMessage(role: .assistant, text: message),
                conversationID: conversationID
            )
            return nil
        }
    }

    func cancelCurrentInference() {
        isSending = false
        generatingConversationID = nil
        Task { await inferenceClient.cancelCurrentInference() }
    }

    func releaseResources() {
        isSending = false
        generatingConversationID = nil
        persistenceTask?.cancel()
        Task {
            await inferenceClient.releaseResources()
            await persistImmediately()
        }
    }

    func appendAssistantMessage(
        _ text: String,
        payload: NautiChatPayload? = nil,
        conversationID: UUID? = nil
    ) {
        appendMessage(
            NautiChatMessage(role: .assistant, text: text, payload: payload),
            conversationID: conversationID ?? activeConversationID
        )
    }

    func replaceLastAssistantMessage(
        matching oldText: String,
        with newText: String,
        payload: NautiChatPayload? = nil,
        conversationID: UUID? = nil
    ) {
        let conversationID = conversationID ?? activeConversationID
        guard let conversationIndex = index(of: conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: {
                  $0.role == .assistant && $0.text == oldText
              }) else {
            appendAssistantMessage(newText, payload: payload, conversationID: conversationID)
            return
        }

        conversations[conversationIndex].messages[messageIndex] = NautiChatMessage(
            role: .assistant,
            text: newText,
            payload: payload
        )
        conversations[conversationIndex].updatedAt = .now
        schedulePersistence()
    }

    func clearPersistenceWarning() {
        persistenceWarning = nil
    }

    func persistImmediately() async {
        persistenceTask?.cancel()
        let snapshot = conversations
        do {
            try await repository.save(snapshot)
        } catch {
            persistenceWarning = "Die Chat-Historie konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func appendMessage(_ message: NautiChatMessage, conversationID: UUID) {
        guard let conversationIndex = index(of: conversationID) else { return }
        let hadUserMessage = conversations[conversationIndex].messages.contains { $0.role == .user }

        conversations[conversationIndex].messages.append(message)
        if message.role == .user,
           !hadUserMessage,
           !conversations[conversationIndex].hasCustomTitle {
            conversations[conversationIndex].title = Self.generatedTitle(from: message.text)
        }

        if conversations[conversationIndex].messages.count > Self.maximumVisibleMessages {
            let welcome = conversations[conversationIndex].messages.first
            let latest = Array(
                conversations[conversationIndex].messages.suffix(Self.maximumVisibleMessages - 1)
            )
            conversations[conversationIndex].messages = welcome.map { [$0] + latest } ?? latest
        }
        conversations[conversationIndex].updatedAt = .now
        schedulePersistence()
    }

    private func messages(in conversationID: UUID) -> [NautiChatMessage] {
        conversations.first(where: { $0.id == conversationID })?.messages ?? []
    }

    private func updateConversation(
        _ id: UUID,
        mutation: (inout NautiConversation) -> Void
    ) {
        guard let conversationIndex = index(of: id) else { return }
        mutation(&conversations[conversationIndex])
    }

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex(where: { $0.id == id })
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        let snapshot = conversations
        let repository = self.repository

        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                try await repository.save(snapshot)
            } catch is CancellationError {
                return
            } catch {
                self?.persistenceWarning = "Die Chat-Historie konnte nicht gespeichert werden: \(error.localizedDescription)"
            }
        }
    }

    private static func generatedTitle(from text: String) -> String {
        let singleLine = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return NautiConversation.defaultTitle }

        guard singleLine.count > maximumGeneratedTitleLength else { return singleLine }
        let prefix = String(singleLine.prefix(maximumGeneratedTitleLength - 1))
        return "\(prefix)…"
    }

    private static func sanitizedConversation(_ conversation: NautiConversation) -> NautiConversation {
        var conversation = conversation
        if conversation.messages.isEmpty {
            conversation.messages = [.welcome]
        } else if conversation.messages.count > maximumVisibleMessages {
            let first = conversation.messages.first
            conversation.messages = first.map {
                [$0] + Array(conversation.messages.suffix(maximumVisibleMessages - 1))
            } ?? Array(conversation.messages.suffix(maximumVisibleMessages))
        }
        if conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversation.title = NautiConversation.defaultTitle
        }
        return conversation
    }

    private static func userFacingErrorMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "Nauti konnte lokal keine Antwort erzeugen. Versuche es erneut."
    }
}
