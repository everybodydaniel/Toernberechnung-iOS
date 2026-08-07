import SwiftData
import SwiftUI
import UIKit

enum SocialLoginMode: String, CaseIterable, Identifiable {
    case login = "Login"
    case register = "Registrieren"

    var id: Self { self }
}

struct SocialPasswordReview {
    let password: String
    let confirmation: String

    var hasMinimumLength: Bool {
        password.count >= 8
    }

    var hasMixedCase: Bool {
        password.rangeOfCharacter(from: .lowercaseLetters) != nil
            && password.rangeOfCharacter(from: .uppercaseLetters) != nil
    }

    var hasNumber: Bool {
        password.rangeOfCharacter(from: .decimalDigits) != nil
    }

    var hasSymbol: Bool {
        password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil
    }

    var passwordsMatch: Bool {
        !confirmation.isEmpty && password == confirmation
    }

    var hasMismatch: Bool {
        !confirmation.isEmpty && password != confirmation
    }

    var canCreateAccount: Bool {
        hasMinimumLength && hasMixedCase && hasNumber && passwordsMatch
    }

    var score: Int {
        [
            hasMinimumLength,
            hasMixedCase,
            hasNumber,
            hasSymbol,
            password.count >= 12
        ].filter { $0 }.count
    }

    var progress: CGFloat {
        password.isEmpty ? 0.08 : CGFloat(score) / 5
    }

    var title: String {
        guard !password.isEmpty else { return "Passwortstärke" }
        switch score {
        case 0...1: return "Schwach"
        case 2: return "Solide"
        case 3: return "Gut"
        default: return "Stark"
        }
    }

    var color: Color {
        guard !password.isEmpty else { return Color.secondary }
        switch score {
        case 0...1: return Color.orange
        case 2: return Color(hex: 0xF59E0B)
        case 3: return Color.appPrimary
        default: return Color.green
        }
    }

    var blockingMessage: String {
        if !hasMinimumLength { return "Nutze mindestens 8 Zeichen." }
        if !hasMixedCase { return "Nutze Groß- und Kleinbuchstaben." }
        if !hasNumber { return "Nutze mindestens eine Zahl." }
        if !passwordsMatch { return "Die Passwort-Bestätigung stimmt noch nicht." }
        return ""
    }
}

struct SocialAuthModeSwitch: View {
    @Binding var selection: SocialLoginMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SocialLoginMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selection = mode
                    }
                } label: {
                    Label(mode.rawValue, systemImage: mode == .login ? "rectangle.portrait.and.arrow.right" : "person.badge.plus")
                        .font(.system(size: 13, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(selection == mode ? .white : Color.secondary)
                        .background(
                            selection == mode ? Color(hex: 0x3C82FF) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SocialAuthInputField: View {
    let title: String
    let icon: String
    @Binding var text: String
    var isSecure = false
    var isPasswordVisible: Binding<Bool>?
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var capitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(hex: 0x3C82FF))
                .frame(width: 26, height: 26)
                .background(Color(hex: 0x3C82FF).opacity(0.10), in: Circle())

            field
                .font(.system(size: 15, weight: .semibold))
                .textInputAutocapitalization(capitalization)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .autocorrectionDisabled()

            if isSecure, let isPasswordVisible {
                Button {
                    isPasswordVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isPasswordVisible.wrappedValue ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var field: some View {
        if isSecure, isPasswordVisible?.wrappedValue != true {
            SecureField(title, text: $text)
        } else {
            TextField(title, text: $text)
        }
    }
}

struct PasswordStrengthMeter: View {
    let review: SocialPasswordReview

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(review.title)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(review.color)
                Spacer()
                Text("\(min(review.score, 5))/5")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.fieldBackground)
                    Capsule()
                        .fill(review.color)
                        .frame(width: max(18, proxy.size.width * review.progress))
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(review.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct PasswordRequirementGrid: View {
    let review: SocialPasswordReview

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            requirement("8+ Zeichen", met: review.hasMinimumLength)
            requirement("Aa und aa", met: review.hasMixedCase)
            requirement("Zahl", met: review.hasNumber)
            requirement("Abgleich", met: review.passwordsMatch)
        }
    }

    private func requirement(_ title: String, met: Bool) -> some View {
        Label(title, systemImage: met ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 11, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(met ? Color.green : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((met ? Color.green : Color.secondary).opacity(0.10), in: Capsule())
    }
}

struct CrewspaceAccountSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SocialAuthViewModel.self) private var auth
    @Query private var cachedProfiles: [SkipperProfile]
    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileImageURL") private var profileImageURL = ""

    @State private var mode: SocialLoginMode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var displayName = ""
    @State private var passwordVisible = false
    @State private var confirmationVisible = false
    @State private var formMessage: String?
    @State private var copiedID = false
    @State private var profileShown = false
    @State private var securityShown = false

    private var passwordReview: SocialPasswordReview {
        SocialPasswordReview(password: password, confirmation: confirmation)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard auth.isConfigured,
              !auth.isSigningIn,
              trimmedEmail.contains("@"),
              trimmedEmail.contains("."),
              !password.isEmpty else { return false }
        if mode == .register {
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && passwordReview.canCreateAccount
        }
        return true
    }

    private var accountProfile: SkipperProfile? {
        CrewspaceAccountProfileResolver.profile(
            in: cachedProfiles,
            skipperID: auth.skipperID
        )
    }

    private var accountDisplayName: String {
        accountProfile?.name.nilIfEmpty
            ?? auth.displayName?.nilIfEmpty
            ?? "Skipper"
    }

    private var profileAPI: SocialFeedAPI {
        SocialFeedAPI(
            authTokenProvider: { try await auth.validIDToken() },
            skipperIDProvider: { auth.skipperID }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Crewspace-Konto", systemImage: "person.crop.circle.badge.checkmark")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Color.appPrimary)

            if auth.isAuthenticated {
                signedInContent
            } else {
                signedOutContent
            }
        }
        .appCardSurface(cornerRadius: 24)
        .task(id: auth.skipperID) {
            synchronizeStoredProfile(for: auth.skipperID)
            await refreshAccountProfile(skipperID: auth.skipperID)
        }
        .sheet(isPresented: $profileShown) {
            if let skipperID = auth.skipperID {
                NavigationStack {
                    SkipperProfileView(skipperID: skipperID)
                }
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
            }
        }
        .sheet(isPresented: $securityShown) {
            CrewspaceSecuritySettingsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
    }

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { profileShown = true } label: {
                HStack(spacing: 12) {
                    SkipperAvatarView(
                        urlString: accountProfile?.profileImageURL,
                        name: accountDisplayName,
                        diameter: 48
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(accountDisplayName)
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(Color.primary)
                        Text(auth.email ?? "Angemeldet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Color.appPrimary)
                        Text("Profil")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Crewspace-Profil öffnen")

            if let skipperID = auth.skipperID {
                VStack(alignment: .leading, spacing: 7) {
                    Text("DEINE SKIPPER-ID")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.secondary)
                    HStack(spacing: 10) {
                        Text(skipperID)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = skipperID
                            withAnimation(.easeInOut(duration: 0.2)) { copiedID = true }
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                await MainActor.run { copiedID = false }
                            }
                        } label: {
                            Image(systemName: copiedID ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(copiedID ? Color.green : Color.appPrimary)
                        .accessibilityLabel("Skipper-ID kopieren")
                    }
                    .appFieldSurface(cornerRadius: 15)
                    Text("Mit dieser ID können andere Skipper dich im Crewspace finden und anschreiben.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }

            Button { securityShown = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Color.appPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anmeldung & Sicherheit")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.primary)
                        Text("E-Mail ändern oder Passwort zurücksetzen")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.secondary)
                }
                .padding(13)
                .appFloatingOverlay(cornerRadius: 17)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                Task { await auth.signOut() }
            } label: {
                Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .foregroundStyle(Color.red)
        }
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Melde dich an, um Skipper per ID zu finden, private Chats und Gruppen zu erstellen und Termine gemeinsam zu planen.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)

            SocialAuthModeSwitch(selection: $mode)

            if mode == .register {
                SocialAuthInputField(
                    title: "Name",
                    icon: "person.fill",
                    text: $displayName,
                    textContentType: .name,
                    capitalization: .words
                )
            }

            SocialAuthInputField(
                title: "E-Mail",
                icon: "envelope.fill",
                text: $email,
                keyboardType: .emailAddress,
                textContentType: .emailAddress,
                capitalization: .never
            )

            SocialAuthInputField(
                title: "Passwort",
                icon: "lock.fill",
                text: $password,
                isSecure: true,
                isPasswordVisible: $passwordVisible,
                textContentType: mode == .register ? .newPassword : .password,
                capitalization: .never
            )

            if mode == .register {
                PasswordStrengthMeter(review: passwordReview)
                SocialAuthInputField(
                    title: "Passwort bestätigen",
                    icon: "checkmark.shield.fill",
                    text: $confirmation,
                    isSecure: true,
                    isPasswordVisible: $confirmationVisible,
                    textContentType: .newPassword,
                    capitalization: .never
                )
                PasswordRequirementGrid(review: passwordReview)
            }

            if let message = auth.authError ?? formMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await submit() }
            } label: {
                if auth.isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Label(mode == .register ? "Account erstellen" : "Einloggen", systemImage: "key.fill")
                }
            }
            .disabled(!canSubmit)
            .appProminentButton(tint: Color.appPrimary)
            .opacity(canSubmit ? 1 : 0.5)
        }
        .onChange(of: mode) { _, _ in
            password = ""
            confirmation = ""
            formMessage = nil
        }
    }

    @MainActor
    private func submit() async {
        formMessage = nil
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            formMessage = "Bitte gib eine gültige E-Mail-Adresse ein."
            return
        }
        if mode == .register, !passwordReview.canCreateAccount {
            formMessage = passwordReview.blockingMessage
            return
        }

        switch mode {
        case .login:
            await auth.signInWithEmail(email: trimmedEmail, password: password)
        case .register:
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            await auth.registerWithEmail(email: trimmedEmail, password: password, displayName: name)
            if auth.isAuthenticated { profileName = name }
        }

        if auth.isAuthenticated {
            password = ""
            confirmation = ""
        }
    }

    @MainActor
    private func synchronizeStoredProfile(for skipperID: String?) {
        guard let skipperID, !skipperID.isEmpty else {
            profileName = ""
            profileImageURL = ""
            return
        }

        let matchingProfile = CrewspaceAccountProfileResolver.profile(
            in: cachedProfiles,
            skipperID: skipperID
        )
        profileName = matchingProfile?.name.nilIfEmpty
            ?? auth.displayName?.nilIfEmpty
            ?? ""
        profileImageURL = matchingProfile?.profileImageURL?.nilIfEmpty ?? ""
    }

    @MainActor
    private func refreshAccountProfile(skipperID: String?) async {
        guard auth.isAuthenticated,
              let skipperID,
              !skipperID.isEmpty else { return }

        do {
            let remoteProfile = try await profileAPI.fetchProfile(skipperID: skipperID)
            guard auth.skipperID == skipperID else { return }
            SocialFeedCache.upsert(profile: remoteProfile, in: modelContext)
            profileName = remoteProfile.name
            profileImageURL = remoteProfile.profileImageURL ?? ""
        } catch {
            // Cached profile data and initials remain available while offline.
        }
    }
}

enum CrewspaceAccountProfileResolver {
    static func profile(
        in profiles: [SkipperProfile],
        skipperID: String?
    ) -> SkipperProfile? {
        guard let skipperID, !skipperID.isEmpty else { return nil }
        return profiles.first { $0.id == skipperID }
    }
}

private struct CrewspaceSecuritySettingsSheet: View {
    @Environment(SocialAuthViewModel.self) private var auth

    @State private var email = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Anmeldung & Sicherheit", systemImage: "lock.shield.fill")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(Color.appPrimary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("E-MAIL-ADRESSE")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.secondary)
                        TextField("E-Mail", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .appFieldSurface(cornerRadius: 16)
                        Button { Task { await changeEmail() } } label: {
                            Label("E-Mail ändern", systemImage: "envelope.badge")
                        }
                        .disabled(isWorking || email == auth.email || !email.contains("@"))
                        .appProminentButton(tint: Color.appPrimary)
                    }
                    .padding(16)
                    .appFloatingOverlay(cornerRadius: 24)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("PASSWORT")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.secondary)
                        Text("Firebase sendet einen sicheren Link an \(auth.email ?? "deine hinterlegte E-Mail-Adresse").")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                        Button { Task { await resetPassword() } } label: {
                            Label("Link zum Zurücksetzen senden", systemImage: "key.fill")
                        }
                        .disabled(isWorking)
                        .appProminentButton(tint: Color.appPrimary)
                    }
                    .padding(16)
                    .appFloatingOverlay(cornerRadius: 24)

                    if let message {
                        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isError ? Color.orange : Color.green)
                    }
                }
                .padding(18)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Sicherheit")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { email = auth.email ?? "" }
    }

    @MainActor
    private func changeEmail() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await auth.updateEmailAddress(email)
            message = "Die E-Mail-Adresse wurde aktualisiert."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    @MainActor
    private func resetPassword() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await auth.sendPasswordResetEmail()
            message = "Der Link zum Zurücksetzen wurde versendet."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }
}
