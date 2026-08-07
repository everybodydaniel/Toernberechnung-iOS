import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Crewspace editors intentionally live with the reusable feed components.
// swiftlint:disable file_length

struct FeedPostCard: View {
    let post: FeedPost
    let currentSkipperID: String
    let likeAction: () -> Void
    let commentAction: () -> Void
    let deleteAction: (() -> Void)?

    private var isLiked: Bool {
        post.likedBySkipperIDs.contains(currentSkipperID)
    }

    private var isOwnPost: Bool {
        post.skipperID == currentSkipperID
    }

    private var shareText: String {
        var parts: [String] = []
        if !post.text.isEmpty {
            parts.append(post.text)
        }
        if let imageURL = post.imageURL, !imageURL.isEmpty {
            parts.append(imageURL)
        }
        if parts.isEmpty {
            return "Post von \(post.skipperName)"
        }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink(value: post.skipperID) {
                SkipperAvatarView(urlString: post.skipperProfileImageURL, name: post.skipperName, diameter: 46)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        NavigationLink(value: post.skipperID) {
                            Text(post.skipperName)
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(Color.primary)
                        }
                        .buttonStyle(.plain)

                        Text("@\(post.skipperID.prefix(6))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)

                        Text("·")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Color.secondary)

                        Text(AppDateFormatters.shortWeekdayDateTime.string(from: post.createdAt))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        postMenu
                    }

                    if !post.text.isEmpty {
                        Text(post.text)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }

                if let imageURL = post.imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(Color.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .empty:
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 420)
                    .background(Color.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                HStack {
                    PostActionButton(
                        title: "\(post.commentCount)",
                        icon: "bubble.left",
                        color: Color.secondary,
                        action: commentAction
                    )
                    Spacer()
                    PostActionButton(
                        title: "\(post.likeCount)",
                        icon: isLiked ? "heart.fill" : "heart",
                        color: isLiked ? Color.red : Color.secondary,
                        action: likeAction
                    )
                    Spacer()
                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground.opacity(0.88), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var postMenu: some View {
        if isOwnPost, let deleteAction {
            Menu {
                Button(role: .destructive, action: deleteAction) {
                    Label("Post löschen", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .frame(width: 30, height: 30)
        }
    }
}

struct CrewspaceAudioMessageView: View {
    let urlString: String
    let duration: TimeInterval
    let foregroundColor: Color

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(foregroundColor.opacity(0.13), in: Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 3) {
                ForEach(0..<11, id: \.self) { index in
                    Capsule()
                        .fill(foregroundColor.opacity(0.72))
                        .frame(width: 3, height: CGFloat(8 + (index * 7) % 17))
                }
            }

            Text(formattedDuration)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(foregroundColor)
        .padding(.vertical, 2)
        .onDisappear {
            playbackTask?.cancel()
            player?.pause()
        }
    }

    private var formattedDuration: String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            playbackTask?.cancel()
            isPlaying = false
            return
        }
        guard let url = URL(string: urlString) else { return }
        let activePlayer = player ?? AVPlayer(url: url)
        player = activePlayer
        activePlayer.play()
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task {
            let remaining = duration > 0 ? duration : 60
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                activePlayer.pause()
                activePlayer.seek(to: .zero)
                isPlaying = false
            }
        }
    }
}

@Observable
@MainActor
final class CrewspaceAudioRecorder {
    struct Recording {
        let url: URL
        let duration: TimeInterval
    }

    private var recorder: AVAudioRecorder?
    private var timerTask: Task<Void, Never>?
    private var recordingURL: URL?

    var isRecording = false
    var duration: TimeInterval = 0

    var pulseVisible: Bool {
        Int(duration * 2).isMultiple(of: 2)
    }

    var formattedDuration: String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start() async throws {
        guard !isRecording else { return }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard granted else { throw CrewspaceMediaError.microphonePermissionDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crewspace-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 96_000
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else { throw CrewspaceMediaError.recordingCouldNotStart }

        self.recorder = recorder
        recordingURL = url
        duration = 0
        isRecording = true
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRecording else { return }
                self.duration = recorder.currentTime
            }
        }
    }

    func stop() -> Recording? {
        guard let recorder, let recordingURL else { return nil }
        let finalDuration = max(duration, recorder.currentTime)
        recorder.stop()
        finishSession()
        return Recording(url: recordingURL, duration: finalDuration)
    }

    func cancel() {
        let url = recordingURL
        recorder?.stop()
        finishSession()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func finishSession() {
        timerTask?.cancel()
        timerTask = nil
        recorder = nil
        recordingURL = nil
        isRecording = false
        duration = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum CrewspaceMediaError: LocalizedError {
    case photoCouldNotBeRead
    case microphonePermissionDenied
    case recordingCouldNotStart

    var errorDescription: String? {
        switch self {
        case .photoCouldNotBeRead:
            return "Das ausgewählte Foto konnte nicht gelesen werden."
        case .microphonePermissionDenied:
            return "Der Mikrofonzugriff ist deaktiviert. Du kannst ihn in den iOS-Einstellungen erlauben."
        case .recordingCouldNotStart:
            return "Die Audioaufnahme konnte nicht gestartet werden."
        }
    }
}

private struct PostActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(color)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
    }
}

struct SkipperAvatarView: View {
    let urlString: String?
    let name: String
    let diameter: CGFloat

    var body: some View {
        ZStack {
            if let url = Self.remoteURL(from: urlString) {
                AsyncImage(url: url) { phase in
                    if !Self.usesInitials(for: phase), let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 1))
    }

    static func remoteURL(from urlString: String?) -> URL? {
        guard let rawValue = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    static func usesInitials(for phase: AsyncImagePhase) -> Bool {
        if case .success = phase {
            return false
        }
        return true
    }

    private var initials: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: diameter * 0.42, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x0077B6), Color.appPrimary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

struct CrewspaceNewConversationSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case direct = "Direkt"
        case group = "Gruppe"
        var id: Self { self }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let api: CrewspaceAPI
    let onCreated: (CrewspaceConversationDTO) -> Void

    @State private var mode: Mode = .direct
    @State private var skipperID = ""
    @State private var groupTitle = ""
    @State private var groupInfo = ""
    @State private var members: [CrewspaceSkipperDTO] = []
    @State private var foundSkipper: CrewspaceSkipperDTO?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var contentVisible = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Art", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if mode == .group {
                        VStack(spacing: 10) {
                            TextField("Gruppenname", text: $groupTitle)
                                .appFieldSurface(cornerRadius: 16)
                            TextField("Gruppeninfo (optional)", text: $groupInfo, axis: .vertical)
                                .lineLimit(2...4)
                                .appFieldSurface(cornerRadius: 16)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("SKIPPER ÜBER ID FINDEN")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.secondary)
                        HStack(spacing: 9) {
                            TextField("Skipper-ID", text: $skipperID)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button { Task { await findSkipper() } } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(width: 38, height: 38)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.appPrimary)
                        }
                        .appFieldSurface(cornerRadius: 16)
                    }

                    if let foundSkipper {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(foundSkipper.name).font(.system(size: 16, weight: .heavy))
                                Text(foundSkipper.homeHarbour?.nilIfEmpty ?? "Über Skipper-ID gefunden")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            if mode == .group {
                                Button(members.contains(foundSkipper) ? "Hinzugefügt" : "Hinzufügen") {
                                    if !members.contains(foundSkipper) { members.append(foundSkipper) }
                                }
                                .buttonStyle(.bordered)
                                .tint(Color.appPrimary)
                            }
                        }
                        .padding(14)
                        .appCardSurface(cornerRadius: 20)
                    }

                    if mode == .group, !members.isEmpty {
                        ForEach(members) { member in
                            HStack {
                                Label(member.name, systemImage: "person.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Spacer()
                                Button { members.removeAll { $0.id == member.id } } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(Color.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(11)
                            .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }

                    Button { Task { await create() } } label: {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(mode == .direct ? "Chat starten" : "Gruppe erstellen", systemImage: "arrow.right")
                        }
                    }
                    .disabled(!canCreate || isWorking)
                    .appProminentButton(tint: Color.appPrimary)
                    .opacity(canCreate ? 1 : 0.5)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.white.ignoresSafeArea())
            .navigationTitle("Neue Unterhaltung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .background(Color.white.ignoresSafeArea())
        .preferredColorScheme(.light)
        .scaleEffect(contentVisible ? 1 : 0.965, anchor: .top)
        .offset(y: contentVisible ? 0 : 18)
        .opacity(contentVisible ? 1 : 0)
        .onAppear {
            if reduceMotion {
                contentVisible = true
            } else {
                withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                    contentVisible = true
                }
            }
        }
        .onDisappear {
            contentVisible = false
        }
    }

    private var canCreate: Bool {
        switch mode {
        case .direct: return foundSkipper != nil
        case .group: return !groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !members.isEmpty
        }
    }

    @MainActor
    private func findSkipper() async {
        let id = skipperID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            foundSkipper = try await api.skipper(id: id)
            errorMessage = nil
        } catch {
            foundSkipper = nil
            errorMessage = "Unter dieser ID wurde kein Skipper gefunden."
        }
    }

    @MainActor
    private func create() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let conversation: CrewspaceConversationDTO
            switch mode {
            case .direct:
                guard let foundSkipper else { return }
                conversation = try await api.createDirectConversation(skipperID: foundSkipper.id)
            case .group:
                conversation = try await api.createGroup(
                    title: groupTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    info: groupInfo.trimmingCharacters(in: .whitespacesAndNewlines),
                    memberIDs: members.map(\.id)
                )
            }
            onCreated(conversation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CrewspaceEventEditor: View {
    private struct Attachment {
        let data: Data?
        let remoteURL: String?
        let name: String
        let contentType: String
        let fileExtension: String

        var sizeLabel: String {
            guard let data else { return "Bereits hochgeladen" }
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        }
    }

    private enum Target: String, CaseIterable, Identifiable {
        case personal = "Ich"
        case person = "Person"
        case group = "Gruppe"

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss

    let conversations: [CrewspaceConversationDTO]
    let api: CrewspaceAPI
    let onCreated: (CrewspaceEventDTO) -> Void
    private let editingEvent: CrewspaceEventDTO?

    @State private var target = Target.personal
    @State private var conversationID = ""
    @State private var title = ""
    @State private var startsAt = Date().addingTimeInterval(3600)
    @State private var endsAt = Date().addingTimeInterval(7200)
    @State private var location = ""
    @State private var notes = ""
    @State private var attachment: Attachment?
    @State private var fileImporterShown = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        initialDate: Date,
        event: CrewspaceEventDTO? = nil,
        conversations: [CrewspaceConversationDTO],
        api: CrewspaceAPI,
        onCreated: @escaping (CrewspaceEventDTO) -> Void
    ) {
        self.conversations = conversations
        self.api = api
        self.onCreated = onCreated
        editingEvent = event

        let calendar = Calendar.current
        let start: Date
        if let event {
            start = event.startsAt
        } else if calendar.isDateInToday(initialDate) {
            start = Date().addingTimeInterval(3600)
        } else {
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: initialDate) ?? initialDate
        }
        _startsAt = State(initialValue: start)
        _endsAt = State(initialValue: event?.endsAt ?? start.addingTimeInterval(3600))
        _title = State(initialValue: event?.title ?? "")
        _location = State(initialValue: event?.location ?? "")
        _notes = State(initialValue: event?.notes ?? "")
        if let conversationID = event?.conversationID {
            _conversationID = State(initialValue: conversationID)
            _target = State(initialValue: conversations.first(where: { $0.id == conversationID })?.isGroup == true ? .group : .person)
        }
        if let url = event?.attachmentURL,
           let name = event?.attachmentName,
           let contentType = event?.attachmentContentType {
            _attachment = State(initialValue: Attachment(
                data: nil,
                remoteURL: url,
                name: name,
                contentType: contentType,
                fileExtension: URL(string: url)?.pathExtension ?? ""
            ))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Für wen?") {
                    Picker("Empfänger", selection: $target) {
                        ForEach(Target.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(editingEvent != nil)

                    if target != .personal {
                        Picker(target == .person ? "Person" : "Gruppe", selection: $conversationID) {
                            Text("Auswählen").tag("")
                            ForEach(availableConversations) { conversation in
                                Text(conversation.title).tag(conversation.id)
                            }
                        }
                        .disabled(editingEvent != nil)
                        if availableConversations.isEmpty {
                            Text(target == .person
                                ? "Starte zuerst einen Direktchat mit der Person."
                                : "Erstelle zuerst eine Crewgruppe.")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    } else {
                        Label("Der Termin bleibt in deinem persönlichen Kalender und kann später geteilt werden.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .onChange(of: target) { _, _ in conversationID = "" }
                Section("Termin") {
                    TextField("Titel", text: $title)
                    DatePicker("Beginn", selection: $startsAt)
                    DatePicker("Ende", selection: $endsAt, in: startsAt...)
                    TextField("Ort oder Hafen", text: $location)
                    ZStack(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("Notizen")
                                .foregroundStyle(Color.secondary.opacity(0.75))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $notes)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                    }
                }
                Section("Anhang (optional)") {
                    if let attachment {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(Color.appPrimary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(attachment.sizeLabel)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            Button {
                                self.attachment = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button {
                            fileImporterShown = true
                        } label: {
                            Label("Datei auswählen", systemImage: "paperclip")
                        }
                    }
                    Text("PDF, Word, Excel, PowerPoint, Text und ZIP bis 20 MB")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Color.orange) }
                }
            }
            .navigationTitle(editingEvent == nil ? "Neuer Termin" : "Termin bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
        }
        .fileImporter(
            isPresented: $fileImporterShown,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            selectAttachment(result)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && endsAt >= startsAt
            && (target == .personal || !conversationID.isEmpty)
    }

    private var availableConversations: [CrewspaceConversationDTO] {
        switch target {
        case .personal: return []
        case .person: return conversations.filter { !$0.isGroup }
        case .group: return conversations.filter(\.isGroup)
        }
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var uploadedAttachmentURL = attachment?.remoteURL
            if let attachment, let data = attachment.data {
                let upload = try await api.createMediaUpload(
                    contentType: attachment.contentType,
                    fileExtension: attachment.fileExtension
                )
                try await api.uploadMedia(data, to: upload, contentType: attachment.contentType)
                uploadedAttachmentURL = upload.publicURL
            }
            let draft = CrewspaceEventDraft(
                conversationID: target == .personal ? nil : conversationID,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                startsAt: startsAt,
                endsAt: endsAt,
                location: location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                attachmentURL: uploadedAttachmentURL,
                attachmentName: attachment?.name,
                attachmentContentType: attachment?.contentType
            )
            let savedEvent: CrewspaceEventDTO
            if let editingEvent {
                savedEvent = try await api.updateEvent(eventID: editingEvent.id, draft: draft)
            } else {
                savedEvent = try await api.createEvent(draft)
            }
            onCreated(savedEvent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectAttachment(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 20 * 1_024 * 1_024 else {
                errorMessage = "Die Datei ist größer als 20 MB."
                return
            }
            let fileExtension = url.pathExtension.lowercased()
            guard let contentType = Self.contentType(for: fileExtension) else {
                errorMessage = "Dieser Dateityp wird nicht unterstützt."
                return
            }
            attachment = Attachment(
                data: data,
                remoteURL: nil,
                name: url.lastPathComponent,
                contentType: contentType,
                fileExtension: fileExtension
            )
            errorMessage = nil
        } catch {
            errorMessage = "Die Datei konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }

    private static func contentType(for fileExtension: String) -> String? {
        let fallback: [String: String] = [
            "pdf": "application/pdf",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt": "application/vnd.ms-powerpoint",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "rtf": "application/rtf",
            "txt": "text/plain",
            "csv": "text/csv",
            "zip": "application/zip",
            "pages": "application/x-iwork-pages-sffpages",
            "numbers": "application/x-iwork-numbers-sffnumbers",
            "key": "application/x-iwork-keynote-sffkey"
        ]
        return fallback[fileExtension]
    }
}

struct CrewspacePollEditor: View {
    @Environment(\.dismiss) private var dismiss
    let conversationID: String
    let api: CrewspaceAPI
    let onCreated: (CrewspaceMessageDTO) -> Void

    @State private var question = ""
    @State private var options = ["", ""]
    @State private var allowsMultiple = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Frage") {
                    TextField("Worüber soll abgestimmt werden?", text: $question, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Antwortmöglichkeiten") {
                    ForEach(options.indices, id: \.self) { index in
                        HStack {
                            TextField("Antwort \(index + 1)", text: $options[index])
                            if options.count > 2 {
                                Button { options.remove(at: index) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(Color.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if options.count < 10 {
                        Button { options.append("") } label: {
                            Label("Antwort hinzufügen", systemImage: "plus.circle.fill")
                        }
                    }
                }
                Section {
                    Toggle("Mehrere Antworten erlauben", isOn: $allowsMultiple)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Color.orange) }
                }
            }
            .navigationTitle("Neue Umfrage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Senden") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
        }
    }

    private var cleanedOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cleanedOptions.count >= 2
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let message = try await api.createPoll(
                conversationID: conversationID,
                question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                options: cleanedOptions,
                allowsMultiple: allowsMultiple
            )
            onCreated(message)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CrewspacePollMessageView: View {
    @Environment(SocialAuthViewModel.self) private var auth
    let initialPoll: CrewspacePollDTO

    @State private var poll: CrewspacePollDTO
    @State private var selectedIDs: Set<String>
    @State private var isVoting = false
    @State private var errorMessage: String?

    init(poll: CrewspacePollDTO) {
        initialPoll = poll
        _poll = State(initialValue: poll)
        _selectedIDs = State(initialValue: Set(poll.options.filter(\.isSelected).map(\.id)))
    }

    private var api: CrewspaceAPI {
        CrewspaceAPI(authTokenProvider: { try await auth.validIDToken() })
    }

    private var isClosed: Bool {
        poll.closesAt.map { $0 <= .now } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("UMFRAGE", systemImage: "chart.bar.xaxis")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Color.appPrimary)
            Text(poll.question)
                .font(.system(size: 16, weight: .heavy))

            ForEach(poll.options) { option in
                Button {
                    select(option)
                } label: {
                    pollOption(option)
                }
                .buttonStyle(.plain)
                .disabled(isClosed || isVoting)
            }

            if poll.allowsMultiple && !isClosed {
                Button { Task { await vote(Array(selectedIDs)) } } label: {
                    Text("Abstimmen")
                        .font(.system(size: 12, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .background(Color.appPrimary, in: Capsule())
                .foregroundStyle(.white)
                .disabled(isVoting)
            }

            HStack {
                Text("\(poll.totalVotes) Stimmen")
                Spacer()
                Text(isClosed ? "Beendet" : (poll.allowsMultiple ? "Mehrfachauswahl" : "Eine Antwort"))
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.secondary)

            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(Color.orange)
            }
        }
        .frame(maxWidth: 270, alignment: .leading)
        .onChange(of: initialPoll) { _, updated in
            poll = updated
            selectedIDs = Set(updated.options.filter(\.isSelected).map(\.id))
        }
    }

    private func pollOption(_ option: CrewspacePollOptionDTO) -> some View {
        let selected = selectedIDs.contains(option.id)
        let ratio = poll.totalVotes > 0 ? Double(option.voteCount) / Double(poll.totalVotes) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(option.label).lineLimit(2)
                Spacer()
                Text("\(option.voteCount)")
            }
            .font(.system(size: 12, weight: selected ? .heavy : .semibold))
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.appPrimary.opacity(0.65))
                    .frame(width: max(4, proxy.size.width * ratio))
            }
            .frame(height: 4)
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func select(_ option: CrewspacePollOptionDTO) {
        if poll.allowsMultiple {
            if selectedIDs.contains(option.id) { selectedIDs.remove(option.id) } else { selectedIDs.insert(option.id) }
        } else {
            selectedIDs = [option.id]
            Task { await vote([option.id]) }
        }
    }

    @MainActor
    private func vote(_ optionIDs: [String]) async {
        isVoting = true
        defer { isVoting = false }
        do {
            poll = try await api.vote(pollID: poll.id, optionIDs: optionIDs)
            selectedIDs = Set(poll.options.filter(\.isSelected).map(\.id))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CrewspaceEventMessageView: View {
    let event: CrewspaceEventDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("TERMIN", systemImage: "calendar.badge.clock")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Color.appPrimary)

            Text(event.title)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Color.primary)

            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.startsAt.formatted(
                        .dateTime.locale(Locale(identifier: "de_DE")).weekday(.abbreviated).day().month().hour().minute()
                    ))
                    if event.endsAt > event.startsAt {
                        Text("bis \(event.endsAt.formatted(.dateTime.locale(Locale(identifier: "de_DE")).hour().minute()))")
                            .foregroundStyle(Color.secondary)
                    }
                }
            } icon: {
                Image(systemName: "clock.fill")
                    .foregroundStyle(Color.appPrimary)
            }
            .font(.system(size: 12, weight: .semibold))

            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }

            if let notes = event.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CrewspaceEventAttachmentLink(event: event)
        }
        .frame(maxWidth: 270, alignment: .leading)
    }
}

struct CrewspaceEventAttachmentLink: View {
    let event: CrewspaceEventDTO

    var body: some View {
        if let rawURL = event.attachmentURL,
           let url = URL(string: rawURL),
           let name = event.attachmentName {
            Link(destination: url) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(Color.appPrimary)
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.secondary)
                }
                .padding(9)
                .background(Color.appPrimary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

struct CrewspaceEventShareSheet: View {
    private enum ShareTarget: String, CaseIterable, Identifiable {
        case person = "Person"
        case group = "Gruppe"

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    let event: CrewspaceEventDTO
    let conversations: [CrewspaceConversationDTO]
    let api: CrewspaceAPI
    let onShared: (CrewspaceEventDTO) -> Void

    @State private var target = ShareTarget.person
    @State private var conversationID = ""
    @State private var isSharing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Termin") {
                    Text(event.title).font(.headline)
                    Text(event.startsAt.formatted(
                        .dateTime.locale(Locale(identifier: "de_DE")).day().month().year().hour().minute()
                    ))
                }
                Section("Teilen mit") {
                    Picker("Ziel", selection: $target) {
                        ForEach(ShareTarget.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(target.rawValue, selection: $conversationID) {
                        Text("Auswählen").tag("")
                        ForEach(availableConversations) { Text($0.title).tag($0.id) }
                    }
                    if availableConversations.isEmpty {
                        Text(target == .person ? "Keine Direktchats vorhanden." : "Keine Gruppen vorhanden.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .onChange(of: target) { _, _ in conversationID = "" }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Color.orange) }
                }
            }
            .navigationTitle("Termin teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Teilen") { Task { await share() } }
                        .disabled(conversationID.isEmpty || isSharing)
                }
            }
        }
    }

    private var availableConversations: [CrewspaceConversationDTO] {
        switch target {
        case .person: return conversations.filter { !$0.isGroup }
        case .group: return conversations.filter(\.isGroup)
        }
    }

    @MainActor
    private func share() async {
        isSharing = true
        defer { isSharing = false }
        do {
            let shared = try await api.shareEvent(eventID: event.id, conversationID: conversationID)
            onShared(shared)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
