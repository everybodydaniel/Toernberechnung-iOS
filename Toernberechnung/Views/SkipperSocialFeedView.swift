import PhotosUI
import SwiftData
import SwiftUI
import UIKit

private enum SocialFeedFilter: String, CaseIterable, Identifiable {
    case all = "Für dich"
    case newest = "Neu"
    case photos = "Fotos"

    var id: Self { self }
}

struct SkipperSocialFeedView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SocialAuthViewModel.self) private var auth
    @Query(sort: \FeedPost.createdAt, order: .reverse) private var posts: [FeedPost]

    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileImageURL") private var profileImageURL = ""

    @State private var draft = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var isLoading = false
    @State private var isPosting = false
    @State private var errorMessage: String?
    @State private var commentPost: FeedPost?
    @State private var authMode: SocialLoginMode = .login
    @State private var authEmail = ""
    @State private var authPassword = ""
    @State private var authPasswordConfirmation = ""
    @State private var authDisplayName = ""
    @State private var authFormMessage: String?
    @State private var isPasswordVisible = false
    @State private var isPasswordConfirmationVisible = false
    @State private var selectedFilter: SocialFeedFilter = .all

    private var skipperID: String {
        auth.skipperID ?? ""
    }

    private var skipperName: String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (auth.displayName ?? "Skipper") : trimmed
    }

    private var api: SocialFeedAPI {
        SocialFeedAPI(
            authTokenProvider: { try await auth.validIDToken() },
            skipperIDProvider: { auth.skipperID }
        )
    }

    private var hasRemoteWarning: Bool {
        auth.isAuthenticated && errorMessage != nil
    }

    private var visiblePosts: [FeedPost] {
        switch selectedFilter {
        case .all, .newest:
            return posts
        case .photos:
            return posts.filter { post in
                guard let imageURL = post.imageURL else { return false }
                return !imageURL.isEmpty
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    feedHeader

                    if hasRemoteWarning, let errorMessage {
                        feedNotice(errorMessage, icon: "wifi.exclamationmark")
                    }

                    if auth.isAuthenticated {
                        feedTabs
                        composer
                        postTimeline
                    } else {
                        authPanel
                        signedOutPreview
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.appBackground)
            .refreshable {
                await refresh()
            }
            .navigationDestination(for: String.self) { skipperID in
                SkipperProfileView(skipperID: skipperID)
            }
        }
        .task {
            if auth.isAuthenticated {
                await refresh()
            }
        }
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                Task { await refresh() }
            } else {
                errorMessage = nil
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            Task { await loadSelectedPhoto(item) }
        }
        .sheet(item: $commentPost) { post in
            FeedCommentSheet(
                post: post,
                currentSkipperName: skipperName
            )
        }
    }

    private var feedHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Feed")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text(auth.isAuthenticated ? "Aktuelle Posts und Gespräche" : "Einloggen und Beiträge lesen oder posten.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }

            Spacer()

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x0077B6))
                    .frame(width: 44, height: 44)
                    .appCircularGlass(diameter: 44, tint: Color.white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!auth.isAuthenticated)

            if !skipperID.isEmpty {
                NavigationLink(value: skipperID) {
                    SkipperAvatarView(urlString: profileImageURL, name: skipperName, diameter: 46)
                }
                .buttonStyle(.plain)
            } else {
                SkipperAvatarView(urlString: profileImageURL, name: skipperName, diameter: 46)
            }
        }
        .padding(.vertical, 4)
    }

    private var feedTabs: some View {
        HStack(spacing: 10) {
            ForEach(SocialFeedFilter.allCases) { filter in
                feedTab(filter)
            }
            Spacer(minLength: 0)
        }
    }

    private func feedTab(_ filter: SocialFeedFilter) -> some View {
        let selected = selectedFilter == filter
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                selectedFilter = filter
            }
        } label: {
            Text(filter.rawValue)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(selected ? .white : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(selected ? Color(hex: 0x0077B6) : Color.fieldBackground, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var signedOutPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bereit für den Feed", systemImage: "bolt.horizontal.circle.fill")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Color.appPrimary)
            Text("Der Feed lädt erst nach deiner Anmeldung. Danach bleiben gespeicherte Beiträge sichtbar, falls der Server kurz nicht erreichbar ist.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .appCardSurface(cornerRadius: 18)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SkipperAvatarView(urlString: profileImageURL, name: skipperName, diameter: 44)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(skipperName)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Color.appPrimary)
                        Spacer()
                    }

                    TextField("Was gibt's Neues?", text: $draft, axis: .vertical)
                        .lineLimit(3...7)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .medium))
                        .frame(minHeight: 92, alignment: .topLeading)
                }
            }

            if let selectedImageData, let image = UIImage(data: selectedImageData) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button {
                        self.selectedPhoto = nil
                        self.selectedImageData = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.black.opacity(0.58), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }

            HStack {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .heavy))
                        .frame(width: 40, height: 40)
                        .background(Color(hex: 0x0077B6).opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: 0x0077B6))

                Spacer()

                Button {
                    Task { await publishPost() }
                } label: {
                    if isPosting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Posten", systemImage: "paperplane.fill")
                    }
                }
                .disabled(!canPublish)
                .appProminentButton(tint: Color(hex: 0x0077B6))
                .opacity(canPublish ? 1 : 0.5)
            }
        }
        .padding(16)
        .background(Color.cardBackground.opacity(0.88), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
    }

    private var postTimeline: some View {
        Group {
            if isLoading && posts.isEmpty {
                ProgressView("Feed wird geladen...")
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .appCardSurface(cornerRadius: 18)
            } else if posts.isEmpty {
                emptyState
            } else if visiblePosts.isEmpty {
                filteredEmptyState
            } else {
                ForEach(visiblePosts) { post in
                    FeedPostCard(
                        post: post,
                        currentSkipperID: skipperID,
                        likeAction: { Task { await like(post) } },
                        commentAction: { commentPost = post },
                        deleteAction: post.skipperID == skipperID ? { Task { await delete(post) } } : nil
                    )
                }
            }
        }
    }

    private func feedNotice(_ message: String, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sailboat.circle.fill")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(Color(hex: 0x0077B6))
            Text("Noch keine Posts")
                .font(.system(size: 22, weight: .heavy))
            Text("Schreib den ersten Beitrag oder lade ein Foto hoch.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .appCardSurface(cornerRadius: 18)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedFilter == .photos ? "photo.on.rectangle.angled" : "clock")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(Color(hex: 0x0077B6))
            Text(selectedFilter == .photos ? "Noch keine Fotos" : "Keine neuen Posts")
                .font(.system(size: 20, weight: .heavy))
            Text(selectedFilter == .photos ? "Sobald jemand ein Bild postet, erscheint es hier." : "Der Feed ist aktuell.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .appCardSurface(cornerRadius: 18)
    }

    private var canPublish: Bool {
        auth.isAuthenticated
            && !isPosting
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedImageData != nil)
    }

    @MainActor
    private func refresh() async {
        guard auth.isAuthenticated else {
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let remotePosts = try await api.fetchPosts()
            SocialFeedCache.upsert(posts: remotePosts, in: modelContext)
        } catch {
            errorMessage = posts.isEmpty
                ? "Server gerade nicht erreichbar. Sobald er antwortet, lädt der Feed automatisch."
                : "Server gerade nicht erreichbar. Gespeicherte Beiträge bleiben sichtbar."
        }
        isLoading = false
    }

    @MainActor
    private func publishPost() async {
        guard canPublish else { return }
        isPosting = true
        errorMessage = nil

        do {
            let imageURL = try await uploadSelectedImageIfNeeded()
            let post = try await api.createPost(
                skipperName: skipperName,
                skipperProfileImageURL: profileImageURL.isEmpty ? nil : profileImageURL,
                text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                imageURL: imageURL
            )
            SocialFeedCache.upsert(post: post, in: modelContext)
            draft = ""
            selectedPhoto = nil
            selectedImageData = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isPosting = false
    }

    @MainActor
    private func like(_ post: FeedPost) async {
        do {
            let updated = try await api.likePost(postID: post.id)
            SocialFeedCache.upsert(post: updated, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ post: FeedPost) async {
        guard post.skipperID == skipperID else { return }
        do {
            try await api.deletePost(postID: post.id)
            modelContext.delete(post)
            try? modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadSelectedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            selectedImageData = compressImageData(data)
        } catch {
            errorMessage = "Bild konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }

    private func uploadSelectedImageIfNeeded() async throws -> String? {
        guard let selectedImageData else { return nil }
        do {
            let upload = try await api.createPresignedUpload(contentType: "image/jpeg", fileExtension: "jpg")
            try await api.uploadImage(selectedImageData, to: upload, contentType: "image/jpeg")
            return upload.publicURL
        } catch SocialFeedAPIError.server(statusCode: 503, message: let message) {
            throw SocialFeedAPIError.server(
                statusCode: 503,
                message: message ?? "Bild-Uploads sind noch nicht konfiguriert. Textposts funktionieren bereits."
            )
        }
    }

    private func compressImageData(_ data: Data) -> Data {
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.82) else {
            return data
        }
        return jpeg
    }
}

private extension SkipperSocialFeedView {
    var trimmedAuthEmail: String {
        authEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAuthDisplayName: String {
        authDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isAuthEmailValid: Bool {
        let email = trimmedAuthEmail
        return email.contains("@") && email.contains(".") && !email.contains(" ")
    }

    var passwordReview: SocialPasswordReview {
        SocialPasswordReview(password: authPassword, confirmation: authPasswordConfirmation)
    }

    var canSubmitEmailAuth: Bool {
        guard auth.isConfigured, !auth.isSigningIn, isAuthEmailValid, !authPassword.isEmpty else {
            return false
        }

        if authMode == .register {
            return !trimmedAuthDisplayName.isEmpty && passwordReview.canCreateAccount
        }

        return true
    }

    var authPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            authPanelHeader
            authFeedback
            authModeSwitch
            emailAuthFields
        }
        .appCardSurface(cornerRadius: 24)
    }

    var authPanelHeader: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "sailboat.fill")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0x0077B6), Color(hex: 0x14B8A6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(authMode == .register ? "Account erstellen" : "Willkommen zurück")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Color.appPrimary)
                Text(authMode == .register ? "Sicher registrieren und direkt posten." : "Einloggen und Feed synchronisieren.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    var authFeedback: some View {
        if let authError = auth.authError {
            feedNotice(authError, icon: "exclamationmark.triangle.fill")
        } else if let authFormMessage, !authFormMessage.isEmpty {
            feedNotice(authFormMessage, icon: "lock.fill")
        } else if !auth.isConfigured {
            feedNotice(
                "Firebase ist noch nicht konfiguriert. GoogleService-Info.plist muss im App-Target enthalten sein oder FIREBASE_WEB_API_KEY gesetzt werden.",
                icon: "gear.badge.questionmark"
            )
        }
    }

    var authModeSwitch: some View {
        SocialAuthModeSwitch(selection: $authMode)
            .onChange(of: authMode) { _, _ in
                authFormMessage = nil
                authPassword = ""
                authPasswordConfirmation = ""
                isPasswordVisible = false
                isPasswordConfirmationVisible = false
            }
    }

    var emailAuthFields: some View {
        VStack(spacing: 12) {
            if authMode == .register {
                SocialAuthInputField(
                    title: "Name",
                    icon: "person.fill",
                    text: $authDisplayName,
                    textContentType: .name,
                    capitalization: .words
                )
            }

            SocialAuthInputField(
                title: "E-Mail",
                icon: "envelope.fill",
                text: $authEmail,
                keyboardType: .emailAddress,
                textContentType: .emailAddress,
                capitalization: .never
            )

            SocialAuthInputField(
                title: "Passwort",
                icon: "lock.fill",
                text: $authPassword,
                isSecure: true,
                isPasswordVisible: $isPasswordVisible,
                textContentType: authMode == .register ? .newPassword : .password,
                capitalization: .never
            )

            if authMode == .register {
                registerPasswordFields
            }

            authSubmitButton
            authModeToggleButton
        }
    }

    var registerPasswordFields: some View {
        VStack(spacing: 12) {
            PasswordStrengthMeter(review: passwordReview)

            SocialAuthInputField(
                title: "Passwort bestätigen",
                icon: "checkmark.shield.fill",
                text: $authPasswordConfirmation,
                isSecure: true,
                isPasswordVisible: $isPasswordConfirmationVisible,
                textContentType: .newPassword,
                capitalization: .never
            )

            PasswordRequirementGrid(review: passwordReview)

            if passwordReview.hasMismatch {
                Text("Die Passwörter stimmen noch nicht überein.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var authSubmitButton: some View {
        Button {
            Task { await submitEmailAuth() }
        } label: {
            if auth.isSigningIn {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(authMode == .register ? "Account erstellen" : "Einloggen", systemImage: "key.fill")
            }
        }
        .disabled(!canSubmitEmailAuth)
        .appProminentButton(tint: Color(hex: 0x3C82FF))
        .opacity(canSubmitEmailAuth ? 1 : 0.5)
    }

    var authModeToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                authMode = authMode == .register ? .login : .register
                authFormMessage = nil
                authPassword = ""
                authPasswordConfirmation = ""
            }
        } label: {
            Text(authMode == .register ? "Schon registriert? Einloggen" : "Noch kein Account? Registrieren")
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(hex: 0x3C82FF))
    }

    @MainActor
    func submitEmailAuth() async {
        authFormMessage = nil

        guard isAuthEmailValid else {
            authFormMessage = "Bitte gib eine gültige E-Mail-Adresse ein."
            return
        }

        if authMode == .register, !passwordReview.canCreateAccount {
            authFormMessage = passwordReview.blockingMessage
            return
        }

        let displayName = trimmedAuthDisplayName
        switch authMode {
        case .login:
            await auth.signInWithEmail(email: authEmail, password: authPassword)
        case .register:
            await auth.registerWithEmail(
                email: authEmail,
                password: authPassword,
                displayName: displayName
            )
        }

        if auth.isAuthenticated {
            authPassword = ""
            authPasswordConfirmation = ""
            if profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profileName = displayName.isEmpty ? (auth.displayName ?? "") : displayName
            }
        }
    }
}
