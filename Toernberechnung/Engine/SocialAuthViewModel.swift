import Foundation
import Observation
import Security

@Observable
@MainActor
final class SocialAuthViewModel {
    private(set) var skipperID: String?
    private(set) var displayName: String?
    private(set) var email: String?
    private(set) var isSigningIn = false
    private(set) var authError: String?

    private var idToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?

    private let firebaseAPIKey: String
    private let session: URLSession
    @ObservationIgnored var beforeSignOut: (() async -> Void)?

    var isAuthenticated: Bool {
        skipperID != nil && idToken != nil && refreshToken != nil
    }

    var isConfigured: Bool {
        !firebaseAPIKey.isEmpty && !firebaseAPIKey.contains("$(")
    }

    init(session: URLSession = .shared) {
        self.session = session
        firebaseAPIKey = Self.infoPlistValue("FirebaseWebAPIKey")
            .ifEmpty(Self.googleServiceInfoValue("API_KEY"))
        loadStoredSession()
    }

    func signInWithEmail(email: String, password: String) async {
        guard isConfigured else {
            authError = "Firebase Web API Key fehlt in der Info.plist."
            return
        }

        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            authError = "E-Mail und Passwort sind erforderlich."
            return
        }

        isSigningIn = true
        authError = nil

        do {
            let response = try await authenticateWithEmail(
                path: "accounts:signInWithPassword",
                email: email,
                password: password
            )
            apply(
                firebaseIDToken: response.idToken,
                refreshToken: response.refreshToken,
                skipperID: response.localID,
                displayName: response.displayName,
                email: response.email,
                expiresIn: response.expiresIn
            )
        } catch {
            authError = error.localizedDescription
        }

        isSigningIn = false
    }

    func registerWithEmail(email: String, password: String, displayName: String) async {
        guard isConfigured else {
            authError = "Firebase Web API Key fehlt in der Info.plist."
            return
        }

        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            authError = "E-Mail und Passwort sind erforderlich."
            return
        }
        guard password.count >= 8 else {
            authError = "Das Passwort muss mindestens 8 Zeichen haben."
            return
        }

        isSigningIn = true
        authError = nil

        do {
            let signUp = try await authenticateWithEmail(
                path: "accounts:signUp",
                email: email,
                password: password
            )
            let profile = try await updateFirebaseProfileIfNeeded(
                idToken: signUp.idToken,
                displayName: displayName
            )
            apply(
                firebaseIDToken: profile?.idToken ?? signUp.idToken,
                refreshToken: profile?.refreshToken ?? signUp.refreshToken,
                skipperID: profile?.localID ?? signUp.localID,
                displayName: profile?.displayName ?? displayName.nilIfEmpty ?? signUp.displayName,
                email: profile?.email ?? signUp.email,
                expiresIn: profile?.expiresIn ?? signUp.expiresIn
            )
        } catch {
            authError = error.localizedDescription
        }

        isSigningIn = false
    }

    func validIDToken() async throws -> String {
        if let idToken, let expiresAt, expiresAt > Date().addingTimeInterval(90) {
            return idToken
        }
        return try await refreshFirebaseToken()
    }

    func updateDisplayName(_ value: String) async throws {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SocialAuthError.firebase("Der Name darf nicht leer sein.") }
        let token = try await validIDToken()
        guard let response = try await updateFirebaseProfileIfNeeded(idToken: token, displayName: name) else {
            return
        }
        applyAccountUpdate(response, fallbackDisplayName: name, fallbackEmail: email)
    }

    func updateEmailAddress(_ value: String) async throws {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), address.contains(".") else {
            throw SocialAuthError.firebase("Die E-Mail-Adresse ist ungültig.")
        }
        let request = FirebaseEmailUpdateRequest(
            idToken: try await validIDToken(),
            email: address,
            returnSecureToken: true
        )
        var urlRequest = URLRequest(url: try firebaseURL(path: "accounts:update"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.encoder.encode(request)
        let data = try await firebaseData(for: urlRequest)
        let response = try Self.decoder.decode(FirebaseProfileUpdateResponse.self, from: data)
        applyAccountUpdate(response, fallbackDisplayName: displayName, fallbackEmail: address)
    }

    func sendPasswordResetEmail() async throws {
        guard let email, !email.isEmpty else { throw SocialAuthError.notSignedIn }
        let request = FirebasePasswordResetRequest(requestType: "PASSWORD_RESET", email: email)
        var urlRequest = URLRequest(url: try firebaseURL(path: "accounts:sendOobCode"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.encoder.encode(request)
        _ = try await firebaseData(for: urlRequest)
    }

    func signOut() async {
        await beforeSignOut?()
        idToken = nil
        refreshToken = nil
        expiresAt = nil
        skipperID = nil
        displayName = nil
        email = nil
        authError = nil
        Self.deleteStoredSession()
    }

    private func authenticateWithEmail(
        path: String,
        email: String,
        password: String
    ) async throws -> FirebaseEmailAuthResponse {
        let url = try firebaseURL(path: path)
        let body = FirebaseEmailAuthRequest(
            email: email,
            password: password,
            returnSecureToken: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let data = try await firebaseData(for: request)
        return try Self.decoder.decode(FirebaseEmailAuthResponse.self, from: data)
    }

    private func updateFirebaseProfileIfNeeded(
        idToken: String,
        displayName: String
    ) async throws -> FirebaseProfileUpdateResponse? {
        guard !displayName.isEmpty else { return nil }

        let url = try firebaseURL(path: "accounts:update")
        let body = FirebaseProfileUpdateRequest(
            idToken: idToken,
            displayName: displayName,
            returnSecureToken: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let data = try await firebaseData(for: request)
        return try Self.decoder.decode(FirebaseProfileUpdateResponse.self, from: data)
    }

    private func refreshFirebaseToken() async throws -> String {
        guard let refreshToken else {
            throw SocialAuthError.notSignedIn
        }

        var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token")
        components?.queryItems = [URLQueryItem(name: "key", value: firebaseAPIKey)]
        guard let url = components?.url else { throw SocialAuthError.invalidFirebaseConfiguration }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]).data(using: .utf8)

        let data = try await firebaseData(for: request)
        let response = try Self.decoder.decode(FirebaseRefreshResponse.self, from: data)
        apply(
            firebaseIDToken: response.idToken,
            refreshToken: response.refreshToken,
            skipperID: response.userID,
            displayName: displayName,
            email: email,
            expiresIn: response.expiresIn
        )
        guard let idToken else { throw SocialAuthError.notSignedIn }
        return idToken
    }

    private func firebaseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocialAuthError.invalidFirebaseResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? Self.decoder.decode(FirebaseErrorEnvelope.self, from: data))
                .flatMap { $0.error.message }
                ?? "HTTP \(http.statusCode)"
            throw SocialAuthError.firebase(Self.localizedFirebaseMessage(message))
        }
        return data
    }

    private func apply(
        firebaseIDToken: String,
        refreshToken: String,
        skipperID: String,
        displayName: String?,
        email: String?,
        expiresIn: String
    ) {
        let lifetime = TimeInterval(expiresIn) ?? 3600
        self.idToken = firebaseIDToken
        self.refreshToken = refreshToken
        self.skipperID = skipperID
        self.displayName = displayName
        self.email = email
        self.expiresAt = Date().addingTimeInterval(max(60, lifetime - 60))
        self.authError = nil
        storeSession()
    }

    private func applyAccountUpdate(
        _ response: FirebaseProfileUpdateResponse,
        fallbackDisplayName: String?,
        fallbackEmail: String?
    ) {
        displayName = response.displayName?.nilIfEmpty ?? fallbackDisplayName
        email = response.email?.nilIfEmpty ?? fallbackEmail
        if let newIDToken = response.idToken?.nilIfEmpty {
            idToken = newIDToken
        }
        if let newRefreshToken = response.refreshToken?.nilIfEmpty {
            refreshToken = newRefreshToken
        }
        if let expiresIn = response.expiresIn, let lifetime = TimeInterval(expiresIn) {
            expiresAt = Date().addingTimeInterval(max(60, lifetime - 60))
        }
        authError = nil
        storeSession()
    }

    private func firebaseURL(path: String) throws -> URL {
        var components = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/\(path)")
        components?.queryItems = [URLQueryItem(name: "key", value: firebaseAPIKey)]
        guard let url = components?.url else { throw SocialAuthError.invalidFirebaseConfiguration }
        return url
    }

    private func loadStoredSession() {
        guard let data = Self.readStoredSession(),
              let session = try? Self.decoder.decode(SocialAuthSession.self, from: data) else {
            return
        }

        idToken = session.idToken
        refreshToken = session.refreshToken
        expiresAt = session.expiresAt
        skipperID = session.skipperID
        displayName = session.displayName
        email = session.email
    }

    private func storeSession() {
        guard let idToken,
              let refreshToken,
              let expiresAt,
              let skipperID else { return }

        let session = SocialAuthSession(
            idToken: idToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            skipperID: skipperID,
            displayName: displayName,
            email: email
        )
        guard let data = try? Self.encoder.encode(session) else { return }
        Self.writeStoredSession(data)
    }

    private static func infoPlistValue(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func googleServiceInfoValue(_ key: String) -> String {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url),
              let value = plist[key] as? String else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formEncoded(_ values: [String: String]) -> String {
        values.map { key, value in
            "\(Self.escapeFormValue(key))=\(Self.escapeFormValue(value))"
        }
        .joined(separator: "&")
    }

    private static func escapeFormValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func localizedFirebaseMessage(_ message: String) -> String {
        switch message {
        case "EMAIL_EXISTS":
            return "Diese E-Mail-Adresse ist bereits registriert."
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS":
            return "E-Mail oder Passwort ist falsch."
        case "INVALID_EMAIL":
            return "Die E-Mail-Adresse ist ungültig."
        case "WEAK_PASSWORD : Password should be at least 6 characters":
            return "Das Passwort muss mindestens 8 Zeichen haben."
        case "OPERATION_NOT_ALLOWED":
            return "E-Mail/Passwort-Login ist in Firebase noch nicht aktiviert."
        case "CREDENTIAL_TOO_OLD_LOGIN_AGAIN", "TOKEN_EXPIRED", "INVALID_ID_TOKEN":
            return "Bitte melde dich erneut an, bevor du diese Kontodaten änderst."
        default:
            return message
        }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

private struct SocialAuthSession: Codable {
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
    let skipperID: String
    let displayName: String?
    let email: String?
}

private struct FirebaseRefreshResponse: Decodable {
    let idToken: String
    let refreshToken: String
    let expiresIn: String
    let userID: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userID = "user_id"
    }
}

private struct FirebaseEmailAuthRequest: Encodable {
    let email: String
    let password: String
    let returnSecureToken: Bool
}

private struct FirebaseEmailAuthResponse: Decodable {
    let localID: String
    let idToken: String
    let refreshToken: String
    let expiresIn: String
    let email: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case localID = "localId"
        case idToken
        case refreshToken
        case expiresIn
        case email
        case displayName
    }
}

private struct FirebaseProfileUpdateRequest: Encodable {
    let idToken: String
    let displayName: String
    let returnSecureToken: Bool
}

private struct FirebaseEmailUpdateRequest: Encodable {
    let idToken: String
    let email: String
    let returnSecureToken: Bool
}

private struct FirebasePasswordResetRequest: Encodable {
    let requestType: String
    let email: String
}

private struct FirebaseProfileUpdateResponse: Decodable {
    let localID: String?
    let idToken: String?
    let refreshToken: String?
    let expiresIn: String?
    let email: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case localID = "localId"
        case idToken
        case refreshToken
        case expiresIn
        case email
        case displayName
    }
}

private struct FirebaseErrorEnvelope: Decodable {
    let error: FirebaseError
}

private struct FirebaseError: Decodable {
    let message: String
}

enum SocialAuthError: LocalizedError {
    case invalidFirebaseConfiguration
    case invalidFirebaseResponse
    case firebase(String)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .invalidFirebaseConfiguration:
            return "Firebase Auth ist nicht korrekt konfiguriert."
        case .invalidFirebaseResponse:
            return "Firebase Auth hat ungültig geantwortet."
        case let .firebase(message):
            return "Firebase Auth: \(message)"
        case .notSignedIn:
            return "Bitte melde dich zuerst an."
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension SocialAuthViewModel {
    static let keychainService = "com.toernberechnung.social-auth"
    static let keychainAccount = "firebase-session"

    static func readStoredSession() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func writeStoredSession(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func deleteStoredSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
