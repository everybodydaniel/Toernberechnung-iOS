// swiftlint:disable file_length
import PhotosUI
import SwiftUI
import UIKit

private enum CrewspaceSection: String, CaseIterable, Identifiable {
    case chats = "Chats"
    case planning = "Planung"
    case crew = "Crew"

    var id: Self { self }

    var icon: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .planning: return "calendar"
        case .crew: return "person.3.fill"
        }
    }
}

struct CrewspaceView: View {
    @Environment(SocialAuthViewModel.self) private var auth
    @Environment(CrewspaceStore.self) private var store

    let onOpenSettings: () -> Void

    @State private var section: CrewspaceSection = .chats
    @State private var searchText = ""
    @State private var selectedDate = Date()
    @State private var newConversationShown = false
    @State private var newEventShown = false
    @State private var eventToShare: CrewspaceEventDTO?
    @State private var eventToEdit: CrewspaceEventDTO?
    @State private var navigationPath: [CrewspaceConversationDTO] = []

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    private var api: CrewspaceAPI {
        CrewspaceAPI(authTokenProvider: { try await auth.validIDToken() })
    }

    private var conversations: [CrewspaceConversationDTO] { store.conversations }
    private var events: [CrewspaceEventDTO] { store.events }
    private var isLoading: Bool { store.isLoading }
    private var errorMessage: String? { store.errorMessage }

    private var visibleConversations: [CrewspaceConversationDTO] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.memberNames.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                crewspaceHeader
                sectionPicker

                Group {
                    if auth.isAuthenticated {
                        selectedContent
                    } else {
                        signedOutView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationDestination(for: CrewspaceConversationDTO.self) { conversation in
                CrewspaceChatView(conversation: conversation) {
                    Task { await refresh() }
                }
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .id(auth.skipperID)
        .task(id: auth.skipperID) {
            guard auth.isAuthenticated else {
                store.reset()
                return
            }
            await refresh()
        }
        .task(id: store.pendingConversationID) {
            await openPendingConversationIfNeeded()
        }
        .sheet(isPresented: $newConversationShown) {
            CrewspaceNewConversationSheet(api: api) { conversation in
                merge(conversation)
                newConversationShown = false
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Color.white)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $newEventShown) {
            CrewspaceEventEditor(initialDate: selectedDate, conversations: conversations, api: api) { event in
                store.replace(event)
                newEventShown = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $eventToEdit) { event in
            CrewspaceEventEditor(
                initialDate: event.startsAt,
                event: event,
                conversations: conversations,
                api: api
            ) { updated in
                replaceEvent(updated)
                eventToEdit = nil
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $eventToShare) { event in
            CrewspaceEventShareSheet(event: event, conversations: conversations, api: api) { shared in
                replaceEvent(shared)
                eventToShare = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
    }

    @MainActor
    private func openPendingConversationIfNeeded() async {
        guard auth.isAuthenticated, let conversationID = store.pendingConversationID else { return }
        if !store.conversations.contains(where: { $0.id == conversationID }) {
            await store.refresh()
        }
        guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else {
            return
        }
        section = .chats
        navigationPath = [conversation]
        store.consumeConversationRoute(conversationID)
    }

    private var crewspaceHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Crewspace")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text("Crew, Gespräche und Termine an einem Ort")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()

            if auth.isAuthenticated, section != .crew {
                Button {
                    if section == .chats { newConversationShown = true } else { newEventShown = true }
                } label: {
                    Image(systemName: section == .chats ? "square.and.pencil" : "calendar.badge.plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                        .appCircularGlass(diameter: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section == .chats ? "Neue Unterhaltung" : "Neuer Termin")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(CrewspaceSection.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { section = item }
                } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .font(.system(size: 12, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(section == item ? .white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(section == item ? Color.appPrimary : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .appFloatingOverlay(cornerRadius: 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch section {
        case .chats:
            chatList
        case .planning:
            planningView
        case .crew:
            CrewspaceCrewView(
                groups: conversations.filter(\.isGroup),
                api: api,
                onCreateGroup: { newConversationShown = true },
                onGroupChanged: { Task { await refresh() } }
            )
        }
    }

    private var chatList: some View {
        List {
                searchField
                    .crewspaceListRow()

                if let next = events.first(where: { $0.startsAt >= .now }) {
                    upcomingEventBanner(next)
                        .crewspaceListRow()
                }

                if isLoading && conversations.isEmpty {
                    ProgressView("Crewspace wird geladen …")
                        .padding(.top, 40)
                        .crewspaceListRow()
                } else if conversations.isEmpty {
                    emptyChats
                        .crewspaceListRow()
                } else {
                    ForEach(visibleConversations) { conversation in
                        NavigationLink(value: conversation) {
                            conversationRow(conversation)
                        }
                        .buttonStyle(.plain)
                        .crewspaceListRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await removeConversation(conversation) }
                            } label: {
                                Label(conversation.isGroup ? "Verlassen" : "Löschen", systemImage: conversation.isGroup ? "rectangle.portrait.and.arrow.right" : "trash")
                            }
                        }
                    }
                }

                if let errorMessage {
                    crewspaceNotice(errorMessage)
                        .crewspaceListRow()
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .refreshable { await refresh() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)
            TextField("Chats durchsuchen", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .appFieldSurface(cornerRadius: 17)
        .padding(.top, 4)
    }

    private func conversationRow(_ conversation: CrewspaceConversationDTO) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(Color.appPrimary.opacity(0.13))
                Image(systemName: conversation.isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.title)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer()
                    if let date = conversation.lastMessageAt {
                        Text(date, style: .time)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.secondary)
                    }
                }
                HStack(spacing: 7) {
                    Text(conversation.lastMessage ?? conversation.memberNames.joined(separator: ", "))
                        .font(.system(size: 13, weight: conversation.unreadCount > 0 ? .bold : .medium))
                        .foregroundStyle(conversation.unreadCount > 0 ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Color.appPrimary, in: Circle())
                    }
                }
            }
        }
        .padding(13)
        .appCardSurface(cornerRadius: 22)
    }

    private var planningView: some View {
        List {
                DatePicker("Tag auswählen", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Color.appPrimary)
                    .appCardSurface(cornerRadius: 24)
                    .crewspaceListRow()

                HStack {
                    Text(dayTitle)
                        .font(.system(size: 20, weight: .heavy))
                    Spacer()
                    Button { newEventShown = true } label: {
                        Label("Termin", systemImage: "plus")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appPrimary)
                }
                .crewspaceListRow()

                if eventsForSelectedDay.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color.appPrimary)
                        Text("Noch nichts geplant")
                            .font(.system(size: 16, weight: .heavy))
                        Text("Termine können direkt mit einem Chat oder einer Crewgruppe geteilt werden.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .appCardSurface(cornerRadius: 24)
                    .crewspaceListRow()
                } else {
                    ForEach(eventsForSelectedDay) { event in
                        eventRow(event)
                            .crewspaceListRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if event.creatorID == auth.skipperID {
                                    Button(role: .destructive) {
                                        Task { await deleteEvent(event) }
                                    } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }

                if let errorMessage { crewspaceNotice(errorMessage).crewspaceListRow() }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .refreshable { await refresh() }
    }

    private var eventsForSelectedDay: [CrewspaceEventDTO] {
        events.filter { Calendar.current.isDate($0.startsAt, inSameDayAs: selectedDate) }
    }

    private var dayTitle: String {
        selectedDate.formatted(
            .dateTime.locale(Locale(identifier: "de_DE")).weekday(.wide).day().month(.wide)
        )
    }

    private func eventRow(_ event: CrewspaceEventDTO) -> some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 2) {
                Text(event.startsAt, style: .time)
                    .font(.system(size: 14, weight: .heavy))
                Text(event.endsAt, style: .time)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            .frame(width: 54)

            Capsule()
                .fill(Color.appPrimary)
                .frame(width: 4, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 16, weight: .heavy))
                Label(
                    eventCalendarSourceTitle(event),
                    systemImage: event.isPrivate ? "lock.fill" : "person.2.fill"
                )
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(event.isPrivate ? Color.appPrimary : Color.secondary)
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                }
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
                CrewspaceEventAttachmentLink(event: event)
            }
            Spacer()
            if event.creatorID == auth.skipperID {
                VStack(spacing: 4) {
                    Button {
                        eventToEdit = event
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Termin bearbeiten")

                    if event.isPrivate {
                        Button {
                            eventToShare = event
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Termin teilen")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appPrimary)
            }
        }
        .padding(14)
        .appCardSurface(cornerRadius: 20)
    }

    private func eventCalendarSourceTitle(_ event: CrewspaceEventDTO) -> String {
        if event.isPrivate {
            return "Privater Kalender"
        }
        if event.creatorID == auth.skipperID {
            return event.conversationTitle ?? "Geteilter Termin"
        }
        let creatorName = event.creatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !creatorName.isEmpty {
            return creatorName
        }
        return event.conversationTitle ?? "Geteilter Termin"
    }

    private func upcomingEventBanner(_ event: CrewspaceEventDTO) -> some View {
        Button {
            selectedDate = event.startsAt
            section = .planning
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.appPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nächster Termin")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.secondary)
                    Text("\(event.title) · \(event.startsAt.formatted(.dateTime.locale(Locale(identifier: "de_DE")).day().month().hour().minute()))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(13)
            .background(Color.appPrimary.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyChats: some View {
        VStack(spacing: 13) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.appPrimary)
            Text("Dein Crewspace ist bereit")
                .font(.system(size: 20, weight: .heavy))
            Text("Starte einen Direktchat über eine Skipper-ID oder erstelle eine Gruppe für deine nächste Tour.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            Button { newConversationShown = true } label: {
                Label("Unterhaltung starten", systemImage: "plus")
            }
            .appProminentButton(tint: Color.appPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .padding(.horizontal, 20)
        .appCardSurface(cornerRadius: 24)
    }

    private var signedOutView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.badge.key.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Color.appPrimary)
            Text("Für Crewspace anmelden")
                .font(.system(size: 24, weight: .heavy))
            Text("Dein Login und deine Skipper-ID findest du jetzt zentral in den Einstellungen.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            Button(action: onOpenSettings) {
                Label("Einstellungen öffnen", systemImage: "gearshape.fill")
            }
            .appProminentButton(tint: Color.appPrimary)
            Spacer()
        }
        .padding(24)
    }

    private func crewspaceNotice(_ text: String) -> some View {
        Label(text, systemImage: "wifi.exclamationmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor
    private func refresh() async {
        guard auth.isAuthenticated else { return }
        await store.refresh()
    }

    private func merge(_ conversation: CrewspaceConversationDTO) {
        store.merge(conversation)
    }

    private func replaceEvent(_ event: CrewspaceEventDTO) {
        store.replace(event)
    }

    @MainActor
    private func deleteEvent(_ event: CrewspaceEventDTO) async {
        do {
            try await store.deleteEvent(event)
        } catch {
            store.record(error)
        }
    }

    @MainActor
    private func removeConversation(_ conversation: CrewspaceConversationDTO) async {
        do {
            try await store.removeConversation(conversation)
        } catch {
            store.record(error)
        }
    }
}

private extension View {
    func crewspaceListRow() -> some View {
        listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct CrewspaceChatView: View {
    @Environment(SocialAuthViewModel.self) private var auth
    @Environment(CrewspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let conversation: CrewspaceConversationDTO
    let onConversationChanged: () -> Void

    @State private var draft = ""
    @State private var isSending = false
    @State private var isUploadingMedia = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var audioRecorder = CrewspaceAudioRecorder()
    @State private var pollEditorShown = false
    @State private var groupInfoShown = false
    @State private var displayTitle: String
    @State private var errorMessage: String?
    @State private var blockConfirmationShown = false

    init(conversation: CrewspaceConversationDTO, onConversationChanged: @escaping () -> Void) {
        self.conversation = conversation
        self.onConversationChanged = onConversationChanged
        _displayTitle = State(initialValue: conversation.title)
    }

    private var api: CrewspaceAPI {
        CrewspaceAPI(authTokenProvider: { try await auth.validIDToken() })
    }

    private var currentConversation: CrewspaceConversationDTO {
        store.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    private var messages: [CrewspaceMessageDTO] {
        store.messages(for: conversation.id)
    }

    private var peerID: String? {
        store.peerID(for: currentConversation)
    }

    private var isPeerBlocked: Bool {
        peerID.map(store.blockedUIDs.contains) ?? false
    }

    private var isChatAvailable: Bool {
        store.isChatAvailable(currentConversation)
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().opacity(0.4)
            messageTimeline
            composer
        }
        .background(Color.appBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await sendPhoto(item) }
        }
        .onDisappear {
            if audioRecorder.isRecording { audioRecorder.cancel() }
        }
        .sheet(isPresented: $pollEditorShown) {
            CrewspacePollEditor(conversationID: conversation.id, api: api) { message in
                store.merge(message)
                pollEditorShown = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $groupInfoShown) {
            CrewspaceGroupInfoSheet(conversationID: conversation.id, api: api) { updated in
                displayTitle = updated.title
                onConversationChanged()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
        }
        .task(id: auth.skipperID) {
            CrewspacePushRouteCenter.shared.activeConversationID = conversation.id
            await store.loadLatestMessages(conversationID: conversation.id)
        }
        .onDisappear {
            if CrewspacePushRouteCenter.shared.activeConversationID == conversation.id {
                CrewspacePushRouteCenter.shared.activeConversationID = nil
            }
        }
        .alert(
            isPeerBlocked ? "Skipper freigeben?" : "Skipper blockieren?",
            isPresented: $blockConfirmationShown
        ) {
            Button("Abbrechen", role: .cancel) {}
            Button(isPeerBlocked ? "Freigeben" : "Blockieren", role: isPeerBlocked ? nil : .destructive) {
                Task { await updateBlockState() }
            }
        } message: {
            Text(
                isPeerBlocked
                    ? "Neue Nachrichten sind danach wieder möglich."
                    : "Der Direktchat wird für beide Seiten gesperrt. Der bisherige Verlauf bleibt sichtbar."
            )
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.appPrimary.opacity(0.14))
                    Image(systemName: conversation.isGroup ? "person.3.fill" : "person.fill")
                        .foregroundStyle(Color.appPrimary)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(conversation.isGroup ? "\(conversation.memberIDs.count) Mitglieder · Gruppeninfo" : "Direktnachricht")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if conversation.isGroup {
                    groupInfoShown = true
                }
            }
            Spacer()
            if let peerID, !conversation.isGroup {
                Button {
                    blockConfirmationShown = true
                } label: {
                    Image(systemName: isPeerBlocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPeerBlocked ? "Skipper freigeben" : "Skipper blockieren")
                .accessibilityValue(peerID)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.canLoadOlderMessages(conversationID: conversation.id) {
                        Button("Ältere Nachrichten laden") {
                            Task { await store.loadOlderMessages(conversationID: conversation.id) }
                        }
                        .font(.system(size: 12, weight: .bold))
                    }

                    if messages.isEmpty {
                        Text("Noch keine Nachrichten. Schreib als Erste:r in diese Unterhaltung.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 48)
                            .padding(.horizontal, 30)
                    }

                    ForEach(messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .padding(10)
                    }
                }
                .padding(14)
            }
            .onChange(of: messages.count) { _, _ in
                guard let id = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func messageBubble(_ message: CrewspaceMessageDTO) -> some View {
        let isMine = message.senderID == auth.skipperID
        let usesCardSurface = message.poll != nil || message.event != nil
        return HStack {
            if isMine { Spacer(minLength: 54) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if !isMine && conversation.isGroup {
                    Text(message.senderName)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)
                }
                messageMedia(message, isMine: isMine)
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isMine && !usesCardSurface ? Color.white : Color.primary)
                }
                Text(message.createdAt, style: .time)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isMine && !usesCardSurface ? Color.white.opacity(0.72) : Color.secondary)
                if isMine, let state = message.deliveryState, state != .sent {
                    HStack(spacing: 5) {
                        Image(systemName: state == .failed ? "exclamationmark.circle.fill" : "clock.fill")
                        Text(state == .uploading ? "Wird hochgeladen" : state == .failed ? "Nicht gesendet" : "Wird gesendet")
                        if state == .failed, let clientMessageID = message.clientMessageID {
                            Button("Erneut") {
                                Task { await store.retry(clientMessageID: clientMessageID) }
                            }
                            .font(.system(size: 9, weight: .heavy))
                        }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isMine && !usesCardSurface ? Color.white.opacity(0.86) : Color.orange)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                isMine && !usesCardSurface ? Color.appPrimary : Color.cardBackground,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            if !isMine { Spacer(minLength: 54) }
        }
    }

    private var composer: some View {
        Group {
            if !isChatAvailable {
                Label("Dieser Direktchat ist derzeit gesperrt.", systemImage: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if audioRecorder.isRecording {
                recordingComposer
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploadingMedia || isSending)

                    Button {
                        pollEditorShown = true
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.appPrimary)
                            .frame(width: 38, height: 42)
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploadingMedia || isSending)

                    TextField("Nachricht", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.system(size: 15, weight: .medium))
                        .appFieldSurface(cornerRadius: 20)

                    Button {
                        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Task { await startRecording() }
                        } else {
                            Task { await send() }
                        }
                    } label: {
                        Group {
                            if isSending || isUploadingMedia {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mic.fill" : "arrow.up")
                                    .font(.system(size: 16, weight: .heavy))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.appPrimary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending || isUploadingMedia)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var recordingComposer: some View {
        HStack(spacing: 12) {
            Button {
                audioRecorder.cancel()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.red)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)

            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(audioRecorder.pulseVisible ? 1 : 0.28)

            Text(audioRecorder.formattedDuration)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
            Text("Sprachnachricht")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Spacer()

            Button {
                Task { await finishRecordingAndSend() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.appPrimary, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func messageMedia(_ message: CrewspaceMessageDTO, isMine: Bool) -> some View {
        if let poll = message.poll {
            CrewspacePollMessageView(poll: poll)
        } else if let event = message.event {
            CrewspaceEventMessageView(event: event)
        } else if message.mediaType == "image", let mediaURL = message.mediaURL, let url = URL(string: mediaURL) {
            Group {
                if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            Label("Foto nicht verfügbar", systemImage: "photo.badge.exclamationmark")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(20)
                        default:
                            ProgressView().padding(28)
                        }
                    }
                }
            }
            .frame(maxWidth: 250, maxHeight: 280)
            .background(Color.black.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else if message.mediaType == "audio", let mediaURL = message.mediaURL {
            CrewspaceAudioMessageView(
                urlString: mediaURL,
                duration: message.mediaDurationSeconds ?? 0,
                foregroundColor: isMine ? .white : Color.primary
            )
        } else if message.mediaType != nil || message.text.isEmpty {
            Label("Nicht unterstützte Nachricht", systemImage: "questionmark.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isMine ? Color.white.opacity(0.9) : Color.secondary)
        }
    }

    @MainActor
    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            _ = try await store.enqueueText(conversationID: conversation.id, text: text)
            draft = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func sendPhoto(_ item: PhotosPickerItem) async {
        isUploadingMedia = true
        defer {
            isUploadingMedia = false
            selectedPhoto = nil
        }
        do {
            guard let originalData = try await item.loadTransferable(type: Data.self) else {
                throw CrewspaceMediaError.photoCouldNotBeRead
            }
            let imageData = compressedJPEG(from: originalData)
            let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await store.enqueueMedia(
                conversationID: conversation.id,
                text: caption,
                data: imageData,
                mediaType: "image",
                contentType: "image/jpeg",
                fileExtension: "jpg"
            )
            draft = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func startRecording() async {
        do {
            try await audioRecorder.start()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func finishRecordingAndSend() async {
        guard let recording = audioRecorder.stop() else { return }
        isUploadingMedia = true
        defer {
            isUploadingMedia = false
            try? FileManager.default.removeItem(at: recording.url)
        }
        do {
            let data = try Data(contentsOf: recording.url)
            _ = try await store.enqueueMedia(
                conversationID: conversation.id,
                text: "",
                data: data,
                mediaType: "audio",
                contentType: "audio/mp4",
                fileExtension: "m4a",
                duration: recording.duration
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func compressedJPEG(from data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, 2_048 / max(longestSide, 1))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let result = resized.jpegData(compressionQuality: 0.82) else { return data }
        return result
    }

    @MainActor
    private func updateBlockState() async {
        guard let peerID else { return }
        do {
            try await store.setBlocked(!isPeerBlocked, skipperID: peerID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
