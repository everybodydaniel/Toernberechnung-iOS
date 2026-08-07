import SwiftUI
import UIKit

struct NautiPremiumChatOverlay: View {
    @Binding var mode: NautiDashboardMode
    @Bindable var viewModel: NautiChatViewModel
    @Bindable var speechController: NautiSpeechInputController

    let focusDismissTrigger: Int
    let onCollapse: () -> Void
    let onAction: (NautiActionDispatch) -> Void
    let onPayloadAction: (NautiChatPayload) -> Void
    let accessState: AIAccessState
    let onRetryAvailability: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText = ""
    @State private var renamingConversation: NautiConversation?
    @State private var renameDraft = ""
    @State private var deletingConversation: NautiConversation?

    var body: some View {
        Group {
            switch mode {
            case .dashboard:
                Color.clear
            case .chat:
                chatArea
                    .transition(panelTransition)
            case .history:
                historyArea
                    .transition(panelTransition)
            }
        }
        .animation(NautiDashboardGeometry.animation(reduceMotion: reduceMotion), value: mode)
        .onChange(of: viewModel.activeConversationID) { _, _ in
            speechController.cancel()
        }
        .onChange(of: mode) { _, newMode in
            if newMode != .chat {
                speechController.cancel()
            }
        }
        .onDisappear {
            speechController.cancel()
        }
        .alert("Chat umbenennen", isPresented: renameAlertPresented) {
            TextField("Titel", text: $renameDraft)
            Button("Abbrechen", role: .cancel) {
                renamingConversation = nil
            }
            Button("Speichern") {
                guard let conversation = renamingConversation else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    _ = viewModel.renameConversation(conversation.id, title: renameDraft)
                }
                renamingConversation = nil
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Der Titel wird nur lokal auf diesem Gerät gespeichert.")
        }
        .alert("Chat löschen?", isPresented: deleteAlertPresented) {
            Button("Abbrechen", role: .cancel) {
                deletingConversation = nil
            }
            Button("Löschen", role: .destructive) {
                guard let conversation = deletingConversation else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    viewModel.deleteConversation(conversation.id)
                }
                deletingConversation = nil
            }
        } message: {
            Text("Der Verlauf wird dauerhaft von diesem Gerät entfernt.")
        }
    }

    private var panelTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: mode == .history ? .leading : .trailing))
    }

    private var chatArea: some View {
        VStack(spacing: 0) {
            collapseHandle
            chatHeader
            Divider().opacity(0.16)
            transcript
            Divider().opacity(0.12)
            MessageInputView(
                draft: $viewModel.draft,
                speechController: speechController,
                canSend: viewModel.canSend,
                assistantEnabled: accessState.canUseAssistant,
                isSending: viewModel.isSending,
                focusDismissTrigger: focusDismissTrigger,
                onSend: send,
                onStop: viewModel.cancelCurrentInference
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("NautiInlineChat")
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            iconButton("clock.arrow.circlepath", label: "Chat-Historie öffnen") {
                mode = .history
            }

            NautiSymbolAvatar()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.activeConversation.title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                if viewModel.isSending {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Nauti arbeitet")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Skipper-KI")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            iconButton("square.and.pencil", label: "Neuer Chat") {
                _ = viewModel.createConversation()
            }

            iconButton("chevron.down", label: "Nauti Chat einklappen", action: onCollapse)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var historyArea: some View {
        VStack(spacing: 0) {
            collapseHandle

            HStack(spacing: 10) {
                iconButton("chevron.left", label: "Zum Chat") {
                    mode = .chat
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Verlauf")
                        .font(.system(size: 17, weight: .bold))
                    Text("\(viewModel.conversations.count) Unterhaltungen")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Nauti arbeitet")
                }

                iconButton("square.and.pencil", label: "Neuer Chat") {
                    _ = viewModel.createConversation()
                    mode = .chat
                }

                iconButton("chevron.down", label: "Nauti Chat einklappen", action: onCollapse)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            searchField
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider().opacity(0.16)

            NautiHistoryList(
                conversations: filteredConversations,
                activeConversationID: viewModel.activeConversationID,
                onSelect: { conversationID in
                    viewModel.selectConversation(conversationID)
                    mode = .chat
                },
                onTogglePin: { conversation in
                    viewModel.togglePin(conversation.id)
                },
                onRename: beginRename,
                onDelete: { deletingConversation = $0 }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("NautiInlineHistory")
    }

    private var collapseHandle: some View {
        Capsule()
            .fill(Color.primary.opacity(0.24))
            .frame(width: 38, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .contentShape(Rectangle())
            .onTapGesture(perform: onCollapse)
            .gesture(collapseGesture)
            .accessibilityIdentifier("NautiInlineDragHandle")
            .accessibilityLabel("Nauti einklappen")
            .accessibilityAddTraits(.isButton)
    }

    private var collapseGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                guard value.translation.height > 44
                        || value.predictedEndTranslation.height > 120 else { return }
                onCollapse()
            }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Chats suchen", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche löschen")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let warning = viewModel.persistenceWarning {
                        localHistoryWarning(warning)
                    }

                    if !accessState.canUseAssistant {
                        NautiAccessNotice(
                            state: accessState,
                            onRetryAvailability: onRetryAvailability
                        )
                    }

                    ForEach(viewModel.messages) { message in
                        NautiMessageBubble(message: message, onPayloadAction: onPayloadAction)
                            .id(message.id)
                    }

                    if viewModel.isGeneratingActiveConversation {
                        NautiTypingBubble()
                            .id("typing")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.isGeneratingActiveConversation) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.activeConversationID) { _, _ in
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var filteredConversations: [NautiConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.sortedConversations }
        return viewModel.sortedConversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        )
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { deletingConversation != nil },
            set: { if !$0 { deletingConversation = nil } }
        )
    }

    private func beginRename(_ conversation: NautiConversation) {
        renameDraft = conversation.title
        renamingConversation = conversation
    }

    private func send() {
        guard viewModel.canSend, accessState.canUseAssistant else { return }
        Task {
            if let dispatch = await viewModel.sendCurrentDraft(when: accessState) {
                onAction(dispatch)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func iconButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func localHistoryWarning(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(warning)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                viewModel.clearPersistenceWarning()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hinweis schließen")
        }
        .padding(.vertical, 8)
    }
}

private struct NautiHistoryList: View {
    let conversations: [NautiConversation]
    let activeConversationID: UUID
    let onSelect: (UUID) -> Void
    let onTogglePin: (NautiConversation) -> Void
    let onRename: (NautiConversation) -> Void
    let onDelete: (NautiConversation) -> Void

    var body: some View {
        Group {
            if conversations.isEmpty {
                ContentUnavailableView(
                    "Keine Chats gefunden",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Passe deine Suche an oder beginne einen neuen Chat.")
                )
            } else {
                List {
                    ForEach(conversations) { conversation in
                        conversationRow(conversation)
                            .listRowBackground(
                                conversation.id == activeConversationID
                                    ? Color.primary.opacity(0.08)
                                    : Color.clear
                            )
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    onTogglePin(conversation)
                                } label: {
                                    Label(
                                        conversation.isPinned ? "Lösen" : "Anpinnen",
                                        systemImage: conversation.isPinned ? "pin.slash" : "pin"
                                    )
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    onDelete(conversation)
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }

                                Button {
                                    onRename(conversation)
                                } label: {
                                    Label("Umbenennen", systemImage: "pencil")
                                }
                                .tint(.indigo)
                            }
                            .contextMenu {
                                Button {
                                    onTogglePin(conversation)
                                } label: {
                                    Label(
                                        conversation.isPinned ? "Nicht mehr anpinnen" : "Anpinnen",
                                        systemImage: conversation.isPinned ? "pin.slash" : "pin"
                                    )
                                }
                                Button {
                                    onRename(conversation)
                                } label: {
                                    Label("Umbenennen", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    onDelete(conversation)
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func conversationRow(_ conversation: NautiConversation) -> some View {
        Button {
            onSelect(conversation.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(conversation.id == activeConversationID ? Color.cyan : .secondary)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(relativeUpdatedAt(conversation.updatedAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                        .accessibilityLabel("Angepinnt")
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("NautiConversation-\(conversation.id.uuidString)")
    }

    private func relativeUpdatedAt(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

private struct MessageInputView: View {
    @Binding var draft: String
    @Bindable var speechController: NautiSpeechInputController

    let canSend: Bool
    let assistantEnabled: Bool
    let isSending: Bool
    let focusDismissTrigger: Int
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(\.openURL) private var openURL
    @FocusState private var inputFocused: Bool
    @State private var dictationPrefix = ""

    var body: some View {
        VStack(spacing: 7) {
            if let error = speechController.errorMessage {
                speechError(error)
            }

            HStack(alignment: .bottom, spacing: 7) {
                TextField("Nachricht", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .disabled(!assistantEnabled || isSending)
                    .padding(.leading, 13)
                    .padding(.vertical, 10)

                microphoneButton

                if isSending {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nauti-Antwort stoppen")
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(sendEnabled ? Color.cyan : Color.secondary.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!sendEnabled)
                    .accessibilityLabel("Senden")
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                }
            }
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        inputFocused ? Color.appPrimary.opacity(0.85) : Color.primary.opacity(0.12),
                        lineWidth: inputFocused ? 1.3 : 0.8
                    )
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onChange(of: speechController.transcript) { _, transcript in
            guard speechController.isActive || !transcript.isEmpty else { return }
            draft = joinedDraft(prefix: dictationPrefix, transcript: transcript)
        }
        .onChange(of: focusDismissTrigger) { _, _ in
            inputFocused = false
        }
        .onDisappear {
            inputFocused = false
        }
    }

    private var sendEnabled: Bool {
        canSend && assistantEnabled && !speechController.isActive && !isSending
    }

    private var microphoneButton: some View {
        Button {
            guard assistantEnabled, !isSending else { return }
            if speechController.isActive {
                Task { await speechController.stop() }
            } else {
                dictationPrefix = draft
                inputFocused = false
                Task { await speechController.start() }
            }
        } label: {
            ZStack {
                if speechController.isRecording {
                    SpeechPulseView()
                }

                if speechController.state == .preparing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.red)
                } else {
                    Image(systemName: speechController.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(speechController.isRecording ? Color.white : Color.primary)
                }
            }
            .frame(width: 36, height: 36)
            .background(
                speechController.isRecording ? Color.red : Color.primary.opacity(0.09),
                in: Circle()
            )
        }
        .buttonStyle(.plain)
        .disabled(!assistantEnabled || isSending)
        .accessibilityLabel(speechController.isRecording ? "Diktat stoppen" : "Diktat starten")
        .padding(.bottom, 4)
    }

    private func speechError(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Einstellungen") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
            .font(.system(size: 11, weight: .bold))
            Button {
                speechController.clearError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fehlerhinweis schließen")
        }
        .padding(.vertical, 6)
    }

    private func send() {
        guard sendEnabled else { return }
        onSend()
    }

    private func joinedDraft(prefix: String, transcript: String) -> String {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return transcript }
        if transcript.isEmpty { return prefix }
        return "\(prefix) \(transcript)"
    }
}

private struct SpeechPulseView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.red.opacity(0.42 - Double(index) * 0.10), lineWidth: 1.4)
                    .scaleEffect(reduceMotion ? 1.15 : (animate ? 1.75 + CGFloat(index) * 0.22 : 0.82))
                    .opacity(reduceMotion ? 0.7 : (animate ? 0 : 0.9))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeOut(duration: 1.25)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.22),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
