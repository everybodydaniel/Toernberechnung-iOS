import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct SkipperProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SocialAuthViewModel.self) private var auth
    @Environment(BoatProfileStore.self) private var boatProfile
    @Query private var profiles: [SkipperProfile]
    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileImageURL") private var profileImageURL = ""

    let skipperID: String

    @State private var isLoading = false
    @State private var isSavingProfile = false
    @State private var isTogglingFollow = false
    @State private var errorMessage: String?
    @State private var isEditingProfile = false

    init(skipperID: String) {
        self.skipperID = skipperID

        _profiles = Query(
            filter: #Predicate<SkipperProfile> { $0.id == skipperID },
            sort: \SkipperProfile.name,
            order: .forward
        )
    }

    private var profile: SkipperProfile? {
        profiles.first
    }

    private var currentSkipperID: String {
        auth.skipperID ?? ""
    }

    private var isOwnProfile: Bool {
        skipperID == currentSkipperID
    }

    private var editorFallback: SkipperProfileEditorFallback {
        SkipperProfileEditorFallback.resolve(
            profileID: profile?.id,
            profileName: profile?.name,
            profileImageURL: profile?.profileImageURL,
            authenticatedSkipperID: auth.skipperID,
            authenticatedDisplayName: auth.displayName
        )
    }

    private var api: SocialFeedAPI {
        SocialFeedAPI(
            authTokenProvider: { try await auth.validIDToken() },
            skipperIDProvider: { auth.skipperID }
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                profileHeader

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 4)
                }

                if isLoading && profile == nil {
                    ProgressView("Profil wird geladen...")
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .navigationTitle(profile?.name ?? "Profil")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshProfile() }
        .refreshable { await refreshProfile() }
        .sheet(isPresented: $isEditingProfile) {
            EditSkipperProfileSheet(
                profile: profile?.id == auth.skipperID ? profile : nil,
                fallbackName: editorFallback.name,
                fallbackImageURL: editorFallback.profileImageURL,
                isSaving: isSavingProfile,
                saveAction: { draft in
                    Task { await saveProfile(draft) }
                }
            )
        }
        .onChange(of: auth.skipperID) { _, activeSkipperID in
            if activeSkipperID != skipperID {
                isEditingProfile = false
            }
        }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                SkipperAvatarView(
                    urlString: profile?.profileImageURL,
                    name: profile?.name ?? "S",
                    diameter: 68
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text(profile?.name ?? "Skipper")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)

                    if let homeHarbour = profile?.homeHarbour, !homeHarbour.isEmpty {
                        Label(homeHarbour, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }

                    if let bio = profile?.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }

                Spacer()
            }

            profileActionButton
        }
        .appCardSurface(cornerRadius: 22)
    }

    @ViewBuilder
    private var profileActionButton: some View {
        if isOwnProfile {
            Button {
                isEditingProfile = true
            } label: {
                Label("Profil bearbeiten", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .appProminentButton(tint: Color(hex: 0x0077B6))
        } else {
            Button {
                Task { await toggleFollow() }
            } label: {
                if isTogglingFollow {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Label(profile?.isFollowedByCurrentSkipper == true ? "Folge ich" : "Folgen", systemImage: profile?.isFollowedByCurrentSkipper == true ? "checkmark" : "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .appProminentButton(tint: profile?.isFollowedByCurrentSkipper == true ? Color.secondary : Color(hex: 0x0077B6))
            .disabled(isTogglingFollow || currentSkipperID.isEmpty)
        }
    }

    @MainActor
    private func toggleFollow() async {
        guard !isOwnProfile, !currentSkipperID.isEmpty else { return }
        isTogglingFollow = true
        errorMessage = nil
        do {
            let updated = try await api.toggleFollow(profileID: skipperID)
            SocialFeedCache.upsert(profile: updated, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
        isTogglingFollow = false
    }

    @MainActor
    private func saveProfile(_ draft: EditSkipperProfileDraft) async {
        guard isOwnProfile else { return }
        isSavingProfile = true
        errorMessage = nil
        do {
            var uploadedImageURL = draft.profileImageURL
            if let imageData = draft.profileImageData {
                let upload = try await api.createPresignedUpload(contentType: "image/jpeg", fileExtension: "jpg")
                try await api.uploadImage(imageData, to: upload, contentType: "image/jpeg")
                uploadedImageURL = upload.publicURL
            }
            guard auth.skipperID == skipperID else {
                isSavingProfile = false
                return
            }
            try await auth.updateDisplayName(draft.name)
            let updated = try await api.updateProfile(
                skipperID: skipperID,
                name: draft.name,
                boatType: draft.boatType,
                homeHarbour: draft.homeHarbour,
                bio: draft.bio,
                profileImageURL: uploadedImageURL
            )
            guard auth.skipperID == skipperID else {
                isSavingProfile = false
                return
            }
            SocialFeedCache.upsert(profile: updated, in: modelContext)
            profileName = updated.name
            profileImageURL = updated.profileImageURL ?? ""
            boatProfile.confirmSynchronized(
                boatType: updated.boatType,
                skipperID: skipperID
            )
            isEditingProfile = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isSavingProfile = false
    }

    @MainActor
    private func refreshProfile() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let remoteProfile = try await api.fetchProfile(skipperID: skipperID)
            SocialFeedCache.upsert(profile: remoteProfile, in: modelContext)
        } catch {
            errorMessage = "Offline-Profil wird angezeigt: \(error.localizedDescription)"
        }
    }
}

struct SkipperProfileEditorFallback: Equatable {
    let name: String
    let profileImageURL: String

    static func resolve(
        profileID: String?,
        profileName: String?,
        profileImageURL: String?,
        authenticatedSkipperID: String?,
        authenticatedDisplayName: String?
    ) -> Self {
        let activeID = cleaned(authenticatedSkipperID)
        let profileBelongsToActiveAccount = activeID != nil && cleaned(profileID) == activeID
        let resolvedName = profileBelongsToActiveAccount ? cleaned(profileName) : nil
        let resolvedImageURL = profileBelongsToActiveAccount ? cleaned(profileImageURL) : nil

        return Self(
            name: resolvedName ?? cleaned(authenticatedDisplayName) ?? "Skipper",
            profileImageURL: resolvedImageURL ?? ""
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct EditSkipperProfileDraft {
    var name: String
    var boatType: String
    var homeHarbour: String?
    var bio: String?
    var profileImageURL: String?
    var profileImageData: Data?
}

private struct EditSkipperProfileSheet: View {
    let profile: SkipperProfile?
    let fallbackName: String
    let fallbackImageURL: String
    let isSaving: Bool
    let saveAction: (EditSkipperProfileDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(BoatProfileStore.self) private var boatProfile
    @State private var name: String
    @State private var homeHarbour: String
    @State private var bio: String
    @State private var profileImageURL: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var selectedImage: UIImage?

    init(
        profile: SkipperProfile?,
        fallbackName: String,
        fallbackImageURL: String,
        isSaving: Bool,
        saveAction: @escaping (EditSkipperProfileDraft) -> Void
    ) {
        self.profile = profile
        self.fallbackName = fallbackName
        self.fallbackImageURL = fallbackImageURL
        self.isSaving = isSaving
        self.saveAction = saveAction
        _name = State(initialValue: profile?.name ?? fallbackName)
        _homeHarbour = State(initialValue: profile?.homeHarbour ?? "")
        _bio = State(initialValue: profile?.bio ?? "")
        _profileImageURL = State(initialValue: profile?.profileImageURL ?? fallbackImageURL)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Group {
                        if let selectedImage {
                            Image(uiImage: selectedImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 92, height: 92)
                                .clipShape(Circle())
                        } else {
                            SkipperAvatarView(
                                urlString: profileImageURL,
                                name: name.isEmpty ? fallbackName : name,
                                diameter: 92
                            )
                        }
                    }
                    .padding(.top, 10)

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Profilbild auswählen", systemImage: "photo.badge.plus")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appPrimary)

                    editField("Name", text: $name, icon: "person.fill")
                    BoatTypePicker()
                    editField("Heimathafen", text: $homeHarbour, icon: "mappin.and.ellipse", placeholder: "z.B. Emden")

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Biografie", systemImage: "text.alignleft")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(Color.secondary)
                        TextField("Erzähl kurz etwas über dich und dein Boot.", text: $bio, axis: .vertical)
                            .lineLimit(4...7)
                            .textFieldStyle(.plain)
                            .padding(14)
                            .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("Profil bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveAction(
                            EditSkipperProfileDraft(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                boatType: boatProfile.boatType,
                                homeHarbour: optionalText(homeHarbour),
                                bio: optionalText(bio),
                                profileImageURL: optionalText(profileImageURL),
                                profileImageData: selectedImageData
                            )
                        )
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Sichern")
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    private func editField(_ title: String, text: Binding<String>, icon: String, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color.secondary)
            TextField(placeholder.isEmpty ? title : placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(14)
                .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func optionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, 1_280 / max(longestSide, 1))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        selectedImage = resized
        selectedImageData = resized.jpegData(compressionQuality: 0.84)
    }
}
