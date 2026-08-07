// swiftlint:disable file_length
import Foundation
import SwiftData

struct SocialFeedAPI {
    static let defaultBaseURL: URL = {
        let configured = (
            ProcessInfo.processInfo.environment["CREWSPACE_API_BASE_URL"]
                ?? Bundle.main.object(forInfoDictionaryKey: "CrewspaceAPIBaseURL") as? String
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: configured),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            // Deliberately non-routable: release builds must provide the HTTPS
            // endpoint through CREWSPACE_API_BASE_URL.
            return URL(string: "https://crewspace.invalid")!
        }
        return url
    }()

    var baseURL: URL = Self.defaultBaseURL
    var session: URLSession = .shared
    var authTokenProvider: (() async throws -> String?)?
    var skipperIDProvider: (() -> String?)?

    func fetchPosts(skipperID: String? = nil) async throws -> [FeedPostDTO] {
        var components = URLComponents(url: baseURL.appendingPathComponent("posts"), resolvingAgainstBaseURL: false)
        if let skipperID, !skipperID.isEmpty {
            components?.queryItems = [URLQueryItem(name: "skipperId", value: skipperID)]
        }
        guard let url = components?.url else { throw SocialFeedAPIError.invalidURL }
        return try await request(url: url, method: "GET", body: Optional<Data>.none)
    }

    func fetchProfile(skipperID: String) async throws -> SkipperProfileDTO {
        var components = URLComponents(url: baseURL.appendingPathComponent("profiles/\(skipperID)"), resolvingAgainstBaseURL: false)
        if let viewerID = skipperIDProvider?(), !viewerID.isEmpty {
            components?.queryItems = [URLQueryItem(name: "viewerId", value: viewerID)]
        }
        guard let url = components?.url else { throw SocialFeedAPIError.invalidURL }
        return try await request(url: url, method: "GET", body: Optional<Data>.none)
    }

    func updateProfile(
        skipperID: String,
        name: String,
        boatType: String,
        homeHarbour: String?,
        bio: String?,
        profileImageURL: String?
    ) async throws -> SkipperProfileDTO {
        guard let currentSkipperID = skipperIDProvider?(), currentSkipperID == skipperID else {
            throw SocialFeedAPIError.authenticationRequired
        }
        let body = UpdateProfileRequest(
            skipperID: currentSkipperID,
            name: name,
            boatType: boatType,
            homeHarbour: homeHarbour,
            bio: bio,
            profileImageURL: profileImageURL
        )
        return try await request(
            url: baseURL.appendingPathComponent("profiles/\(skipperID)"),
            method: "PUT",
            body: body
        )
    }

    func updateBoatType(skipperID: String, boatType: String) async throws -> SkipperProfileDTO {
        guard let currentSkipperID = skipperIDProvider?(), currentSkipperID == skipperID else {
            throw SocialFeedAPIError.authenticationRequired
        }
        let normalizedBoatType = BoatTypeCatalog.normalized(boatType)
        do {
            return try await request(
                url: baseURL.appendingPathComponent("profiles/\(skipperID)/boat-type"),
                method: "PATCH",
                body: UpdateBoatTypeRequest(boatType: normalizedBoatType)
            )
        } catch let error as SocialFeedAPIError where error.httpStatusCode == 405 {
            // Compatibility with servers deployed before the dedicated PATCH
            // endpoint. Preserve every existing profile field via the older PUT.
            let profile = try await fetchProfile(skipperID: skipperID)
            return try await updateProfile(
                skipperID: skipperID,
                name: profile.name,
                boatType: normalizedBoatType,
                homeHarbour: profile.homeHarbour,
                bio: profile.bio,
                profileImageURL: profile.profileImageURL
            )
        }
    }

    func toggleFollow(profileID: String) async throws -> SkipperProfileDTO {
        guard let skipperID = skipperIDProvider?(), !skipperID.isEmpty else {
            throw SocialFeedAPIError.authenticationRequired
        }
        return try await request(
            url: baseURL.appendingPathComponent("profiles/\(profileID)/follow"),
            method: "POST",
            body: LikePostRequest(skipperID: skipperID)
        )
    }

    func createPost(
        skipperName: String,
        skipperProfileImageURL: String?,
        text: String,
        imageURL: String?
    ) async throws -> FeedPostDTO {
        guard let skipperID = skipperIDProvider?(), !skipperID.isEmpty else {
            throw SocialFeedAPIError.authenticationRequired
        }
        let body = CreatePostRequest(
            skipperID: skipperID,
            skipperName: skipperName,
            skipperProfileImageURL: skipperProfileImageURL,
            text: text,
            imageURL: imageURL
        )
        return try await request(
            url: baseURL.appendingPathComponent("posts"),
            method: "POST",
            body: body
        )
    }

    func likePost(postID: String) async throws -> FeedPostDTO {
        guard let skipperID = skipperIDProvider?(), !skipperID.isEmpty else {
            throw SocialFeedAPIError.authenticationRequired
        }
        return try await request(
            url: baseURL.appendingPathComponent("posts/\(postID)/like"),
            method: "POST",
            body: LikePostRequest(skipperID: skipperID)
        )
    }

    func deletePost(postID: String) async throws {
        guard let skipperID = skipperIDProvider?(), !skipperID.isEmpty else {
            throw SocialFeedAPIError.authenticationRequired
        }
        try await requestVoid(
            url: baseURL.appendingPathComponent("posts/\(postID)"),
            method: "DELETE",
            body: DeletePostRequest(skipperID: skipperID)
        )
    }

    func createComment(
        postID: String,
        skipperName: String,
        text: String
    ) async throws -> CommentResponse {
        guard let skipperID = skipperIDProvider?(), !skipperID.isEmpty else {
            throw SocialFeedAPIError.authenticationRequired
        }
        let body = CreateCommentRequest(skipperID: skipperID, skipperName: skipperName, text: text)
        return try await request(
            url: baseURL.appendingPathComponent("posts/\(postID)/comment"),
            method: "POST",
            body: body
        )
    }

    func fetchComments(postID: String) async throws -> [FeedCommentDTO] {
        try await request(
            url: baseURL.appendingPathComponent("posts/\(postID)/comments"),
            method: "GET",
            body: Optional<Data>.none
        )
    }

    func createPresignedUpload(contentType: String, fileExtension: String) async throws -> PresignedUploadDTO {
        let body = PresignUploadRequest(contentType: contentType, fileExtension: fileExtension)
        return try await request(
            url: baseURL.appendingPathComponent("uploads/presign"),
            method: "POST",
            body: body
        )
    }

    func uploadImage(_ data: Data, to upload: PresignedUploadDTO, contentType: String) async throws {
        guard let url = URL(string: upload.uploadURL) else { throw SocialFeedAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = upload.method
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        upload.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SocialFeedAPIError.uploadFailed
        }
    }

    private func request<Response: Decodable, Body: Encodable>(
        url: URL,
        method: String,
        body: Body?
    ) async throws -> Response {
        let data = try body.map { try Self.encoder.encode($0) }
        return try await request(url: url, method: method, body: data)
    }

    private func request<Response: Decodable>(
        url: URL,
        method: String,
        body: Data?
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let authToken = try await authTokenProvider?(), !authToken.isEmpty else {
            throw SocialFeedAPIError.authenticationRequired
        }
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocialFeedAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SocialFeedAPIError.server(statusCode: http.statusCode, message: Self.serverErrorMessage(from: data))
        }
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func requestVoid<Body: Encodable>(
        url: URL,
        method: String,
        body: Body?
    ) async throws {
        let data = try body.map { try Self.encoder.encode($0) }
        try await requestVoid(url: url, method: method, body: data)
    }

    private func requestVoid(
        url: URL,
        method: String,
        body: Data?
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let authToken = try await authTokenProvider?(), !authToken.isEmpty else {
            throw SocialFeedAPIError.authenticationRequired
        }
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocialFeedAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SocialFeedAPIError.server(statusCode: http.statusCode, message: Self.serverErrorMessage(from: data))
        }
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let decoded = try? JSONDecoder().decode(ServerErrorResponse.self, from: data) {
            return decoded.error
        }
        return String(data: data, encoding: .utf8)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = iso8601WithFractionalSeconds.date(from: raw) ?? iso8601.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ungültiges Datum: \(raw)")
        }
        return decoder
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum SocialFeedAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case authenticationRequired
    case uploadFailed
    case server(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Die Server-URL ist ungültig."
        case .invalidResponse: return "Der TideNode-Server hat ungültig geantwortet."
        case .authenticationRequired: return "Bitte melde dich zuerst an."
        case .uploadFailed: return "Das Medium konnte nicht auf den TideNode-Server geladen werden."
        case let .server(statusCode, message):
            if let message, !message.isEmpty {
                return "Der TideNode-Server meldet HTTP \(statusCode): \(message)"
            }
            return "Der TideNode-Server meldet HTTP \(statusCode)."
        }
    }

    var httpStatusCode: Int? { if case let .server(statusCode, _) = self { return statusCode }; return nil }
    var responseMessage: String? { if case let .server(_, message) = self { return message }; return nil }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}

struct FeedPostDTO: Codable, Identifiable {
    let id: String
    let skipperID: String
    let skipperName: String
    let skipperProfileImageURL: String?
    let text: String
    let imageURL: String?
    let likedBySkipperIDs: [String]
    let commentIDs: [String]
    let likeCount: Int
    let commentCount: Int
    let createdAt: Date
    let updatedAt: Date
    let profile: SkipperProfileDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case skipperID = "skipper_id"
        case skipperName = "skipper_name"
        case skipperProfileImageURL = "skipper_profile_image_url"
        case text
        case imageURL = "image_url"
        case likedBySkipperIDs = "liked_by_skipper_ids"
        case commentIDs = "comment_ids"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case profile
    }
}

struct SkipperProfileDTO: Codable, Identifiable {
    let id: String
    let name: String
    let boatType: String
    let profileImageURL: String?
    let homeHarbour: String?
    let bio: String?
    let postIDs: [String]
    let followerCount: Int
    let followingCount: Int
    let isFollowedByCurrentSkipper: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case boatType = "boat_type"
        case profileImageURL = "profile_image_url"
        case homeHarbour = "home_harbour"
        case bio
        case postIDs = "post_ids"
        case followerCount = "follower_count"
        case followingCount = "following_count"
        case isFollowedByCurrentSkipper = "is_followed_by_current_skipper"
    }
}

struct FeedCommentDTO: Codable, Identifiable {
    let id: String
    let postID: String
    let skipperID: String
    let skipperName: String
    let text: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case postID = "post_id"
        case skipperID = "skipper_id"
        case skipperName = "skipper_name"
        case text
        case createdAt = "created_at"
    }
}

// MARK: - Crewspace

struct CrewspaceSkipperDTO: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let boatType: String
    let homeHarbour: String?
    let bio: String?
    let profileImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case boatType = "boat_type"
        case homeHarbour = "home_harbour"
        case bio
        case profileImageURL = "profile_image_url"
    }
}

struct CrewspaceGroupInfoDTO: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let info: String
    let createdBy: String
    let canManage: Bool
    let members: [CrewspaceGroupMemberDTO]
    var onboardCount: Int { members.filter(\.isOnBoard).count }
    enum CodingKeys: String, CodingKey {
        case id, title, info, members
        case createdBy = "created_by"
        case canManage = "can_manage"
    }
}

struct CrewspaceGroupMemberDTO: Codable, Identifiable, Hashable {
    let skipperID: String
    let name: String
    let profileImageURL: String?
    let permissionRole: String
    let crewRole: String
    let isOnBoard: Bool
    let joinedAt: Date
    var id: String { skipperID }
    var isOwner: Bool { permissionRole == "owner" }
    enum CodingKeys: String, CodingKey {
        case name
        case skipperID = "skipper_id"
        case profileImageURL = "profile_image_url"
        case permissionRole = "permission_role"
        case crewRole = "crew_role"
        case isOnBoard = "is_on_board"
        case joinedAt = "joined_at"
    }
}

struct CrewspaceConversationDTO: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String
    let memberIDs: [String]
    let memberNames: [String]
    let lastMessage: String?
    let lastMessageAt: Date?
    let unreadCount: Int
    let updatedAt: Date
    let chatAvailable: Bool

    var isGroup: Bool { kind == "group" }

    enum CodingKeys: String, CodingKey {
        case id, title, kind
        case memberIDs = "member_ids"
        case memberNames = "member_names"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
        case unreadCount = "unread_count"
        case updatedAt = "updated_at"
        case chatAvailable = "chat_available"
    }

    init(
        id: String,
        title: String,
        kind: String,
        memberIDs: [String],
        memberNames: [String],
        lastMessage: String?,
        lastMessageAt: Date?,
        unreadCount: Int,
        updatedAt: Date,
        chatAvailable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.memberIDs = memberIDs
        self.memberNames = memberNames
        self.lastMessage = lastMessage
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.updatedAt = updatedAt
        self.chatAvailable = chatAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(String.self, forKey: .kind)
        memberIDs = try container.decodeIfPresent([String].self, forKey: .memberIDs) ?? []
        memberNames = try container.decodeIfPresent([String].self, forKey: .memberNames) ?? []
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        chatAvailable = try container.decodeIfPresent(Bool.self, forKey: .chatAvailable) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(memberIDs, forKey: .memberIDs)
        try container.encode(memberNames, forKey: .memberNames)
        try container.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try container.encodeIfPresent(lastMessageAt, forKey: .lastMessageAt)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(chatAvailable, forKey: .chatAvailable)
    }
}

struct CrewspaceMessageDTO: Codable, Identifiable, Hashable {
    let id: String
    let clientMessageID: String?
    let conversationID: String
    let senderID: String
    let senderName: String
    let text: String
    let mediaURL: String?
    let mediaType: String?
    let mediaDurationSeconds: Double?
    let poll: CrewspacePollDTO?
    let event: CrewspaceEventDTO?
    let createdAt: Date
    var deliveryState: CrewspaceMessageDeliveryState?
    var deliveryError: String?

    enum CodingKeys: String, CodingKey {
        case id, text, poll, event
        case clientMessageID = "client_message_id"
        case conversationID = "conversation_id"
        case senderID = "sender_id"
        case senderName = "sender_name"
        case mediaURL = "media_url"
        case mediaType = "media_type"
        case mediaDurationSeconds = "media_duration_seconds"
        case createdAt = "created_at"
        case deliveryState = "delivery_state"
        case deliveryError = "delivery_error"
    }

    init(
        id: String,
        clientMessageID: String? = nil,
        conversationID: String,
        senderID: String,
        senderName: String,
        text: String,
        mediaURL: String? = nil,
        mediaType: String? = nil,
        mediaDurationSeconds: Double? = nil,
        poll: CrewspacePollDTO? = nil,
        event: CrewspaceEventDTO? = nil,
        createdAt: Date,
        deliveryState: CrewspaceMessageDeliveryState? = nil,
        deliveryError: String? = nil
    ) {
        self.id = id
        self.clientMessageID = clientMessageID
        self.conversationID = conversationID
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.mediaURL = mediaURL
        self.mediaType = mediaType
        self.mediaDurationSeconds = mediaDurationSeconds
        self.poll = poll
        self.event = event
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.deliveryError = deliveryError
    }
}

enum CrewspaceMessageDeliveryState: String, Codable, Hashable {
    case pending
    case uploading
    case sent
    case failed
}

struct CrewspaceMessagePageDTO: Codable, Hashable {
    let messages: [CrewspaceMessageDTO]
    let nextBeforeCursor: String?
    let nextAfterCursor: String?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case messages
        case nextBeforeCursor = "next_before_cursor"
        case nextAfterCursor = "next_after_cursor"
        case hasMore = "has_more"
    }
}

struct CrewspaceRealtimeEventDTO: Codable, Hashable {
    let version: Int
    let type: String
    let eventID: String?
    let occurredAt: Date?
    let message: CrewspaceMessageDTO?
    let conversation: CrewspaceConversationDTO?

    enum CodingKeys: String, CodingKey {
        case version, type, message, conversation
        case eventID = "event_id"
        case occurredAt = "occurred_at"
    }
}

struct CrewspaceBlockListDTO: Codable, Hashable {
    let blockedUIDs: [String]

    enum CodingKeys: String, CodingKey {
        case blockedUIDs = "blocked_uids"
    }

    init(blockedUIDs: [String]) {
        self.blockedUIDs = blockedUIDs
    }

    init(from decoder: Decoder) throws {
        if let values = try? decoder.singleValueContainer().decode([String].self) {
            blockedUIDs = values
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockedUIDs = try container.decodeIfPresent([String].self, forKey: .blockedUIDs) ?? []
    }
}

struct CrewspacePollDTO: Codable, Identifiable, Hashable {
    let id: String
    let question: String
    let allowsMultiple: Bool
    let closesAt: Date?
    let totalVotes: Int
    let options: [CrewspacePollOptionDTO]

    enum CodingKeys: String, CodingKey {
        case id, question, options
        case allowsMultiple = "allows_multiple"
        case closesAt = "closes_at"
        case totalVotes = "total_votes"
    }
}

struct CrewspacePollOptionDTO: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let voteCount: Int
    let isSelected: Bool

    enum CodingKeys: String, CodingKey {
        case id, label
        case voteCount = "vote_count"
        case isSelected = "is_selected"
    }
}

struct CrewspaceEventDTO: Codable, Identifiable, Hashable {
    let id: String
    let conversationID: String?
    let conversationTitle: String?
    let creatorID: String
    let creatorName: String?
    let title: String
    let startsAt: Date
    let endsAt: Date
    let location: String?
    let notes: String?
    let attachmentURL: String?
    let attachmentName: String?
    let attachmentContentType: String?

    var isPrivate: Bool { conversationID == nil }

    enum CodingKeys: String, CodingKey {
        case id, title, location, notes
        case conversationID = "conversation_id"
        case conversationTitle = "conversation_title"
        case creatorID = "creator_id"
        case creatorName = "creator_name"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case attachmentURL = "attachment_url"
        case attachmentName = "attachment_name"
        case attachmentContentType = "attachment_content_type"
    }
}

struct CrewspaceEventDraft: Encodable {
    let conversationID: String?
    let title: String
    let startsAt: Date
    let endsAt: Date
    let location: String?
    let notes: String?
    let attachmentURL: String?
    let attachmentName: String?
    let attachmentContentType: String?

    enum CodingKeys: String, CodingKey {
        case title, location, notes
        case conversationID = "conversation_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case attachmentURL = "attachment_url"
        case attachmentName = "attachment_name"
        case attachmentContentType = "attachment_content_type"
    }
}

struct CrewspaceAPI {
    var baseURL: URL = SocialFeedAPI.defaultBaseURL
    var session: URLSession = .shared
    var authTokenProvider: () async throws -> String

    func conversations() async throws -> [CrewspaceConversationDTO] {
        try await request(path: "crewspace/conversations", method: "GET", body: Optional<EmptyBody>.none)
    }

    func upsertMe(name: String) async throws -> CrewspaceSkipperDTO {
        try await request(
            path: "crewspace/me",
            method: "PUT",
            body: CrewspaceMeRequest(name: name)
        )
    }

    func skipper(id: String) async throws -> CrewspaceSkipperDTO {
        try await request(path: "crewspace/skippers/\(id)", method: "GET", body: Optional<EmptyBody>.none)
    }

    func createDirectConversation(skipperID: String) async throws -> CrewspaceConversationDTO {
        try await request(
            path: "crewspace/direct",
            method: "POST",
            body: DirectConversationRequest(skipperID: skipperID)
        )
    }

    func createGroup(title: String, info: String = "", memberIDs: [String]) async throws -> CrewspaceConversationDTO {
        try await request(
            path: "crewspace/conversations",
            method: "POST",
            body: GroupConversationRequest(title: title, info: info, memberIDs: memberIDs)
        )
    }

    func groupInfo(conversationID: String) async throws -> CrewspaceGroupInfoDTO {
        try await request(path: "crewspace/conversations/\(conversationID)/profile", method: "GET", body: Optional<EmptyBody>.none)
    }

    func updateGroupInfo(conversationID: String, title: String, info: String) async throws -> CrewspaceGroupInfoDTO {
        try await request(
            path: "crewspace/conversations/\(conversationID)/profile",
            method: "PUT",
            body: UpdateCrewspaceGroupRequest(title: title, info: info)
        )
    }

    func addGroupMember(
        conversationID: String,
        skipperID: String,
        crewRole: String,
        isOnBoard: Bool = false
    ) async throws -> CrewspaceGroupInfoDTO {
        try await request(
            path: "crewspace/conversations/\(conversationID)/members",
            method: "POST",
            body: UpdateCrewspaceMemberRequest(
                skipperID: skipperID,
                crewRole: crewRole,
                isOnBoard: isOnBoard
            )
        )
    }

    func updateGroupMember(
        conversationID: String,
        skipperID: String,
        crewRole: String,
        isOnBoard: Bool
    ) async throws -> CrewspaceGroupInfoDTO {
        try await request(
            path: "crewspace/conversations/\(conversationID)/members/\(skipperID)",
            method: "PUT",
            body: UpdateCrewspaceMemberRequest(
                skipperID: skipperID,
                crewRole: crewRole,
                isOnBoard: isOnBoard
            )
        )
    }

    func removeGroupMember(conversationID: String, skipperID: String) async throws {
        try await requestVoid(path: "crewspace/conversations/\(conversationID)/members/\(skipperID)", method: "DELETE")
    }

    func messages(conversationID: String) async throws -> [CrewspaceMessageDTO] {
        try await request(
            path: "crewspace/conversations/\(conversationID)/messages",
            method: "GET",
            body: Optional<EmptyBody>.none
        )
    }

    func messagePage(
        conversationID: String,
        before: String? = nil,
        after: String? = nil,
        limit: Int = 100
    ) async throws -> CrewspaceMessagePageDTO {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("crewspace/conversations/\(conversationID)/messages/page"),
            resolvingAgainstBaseURL: false
        )
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]
        if let before, !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
        }
        if let after, !after.isEmpty {
            query.append(URLQueryItem(name: "after", value: after))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw SocialFeedAPIError.invalidURL }
        return try await request(url: url, method: "GET", body: Optional<EmptyBody>.none)
    }

    func sendMessage(
        conversationID: String,
        clientMessageID: String = UUID().uuidString.lowercased(),
        text: String,
        mediaURL: String? = nil,
        mediaType: String? = nil,
        mediaDurationSeconds: Double? = nil
    ) async throws -> CrewspaceMessageDTO {
        try await request(
            path: "crewspace/conversations/\(conversationID)/messages",
            method: "POST",
            body: SendMessageRequest(
                clientMessageID: clientMessageID,
                text: text,
                mediaURL: mediaURL,
                mediaType: mediaType,
                mediaDurationSeconds: mediaDurationSeconds
            )
        )
    }

    func registerDevice(installationID: String) async throws {
        try await requestVoid(
            path: "crewspace/devices",
            method: "PUT",
            body: CrewspaceDeviceRequest(installationID: installationID, platform: "ios")
        )
    }

    func unregisterDevice(installationID: String) async throws {
        guard let encoded = installationID.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) else {
            throw SocialFeedAPIError.invalidURL
        }
        try await requestVoid(path: "crewspace/devices/\(encoded)", method: "DELETE")
    }

    func blocks() async throws -> CrewspaceBlockListDTO {
        try await request(path: "crewspace/blocks", method: "GET", body: Optional<EmptyBody>.none)
    }

    func block(skipperID: String) async throws {
        try await requestVoid(path: "crewspace/blocks/\(skipperID)", method: "PUT")
    }

    func unblock(skipperID: String) async throws {
        try await requestVoid(path: "crewspace/blocks/\(skipperID)", method: "DELETE")
    }

    func createPoll(
        conversationID: String,
        question: String,
        options: [String],
        allowsMultiple: Bool
    ) async throws -> CrewspaceMessageDTO {
        try await request(
            path: "crewspace/conversations/\(conversationID)/polls",
            method: "POST",
            body: CreateCrewspacePollRequest(
                question: question,
                options: options,
                allowsMultiple: allowsMultiple
            )
        )
    }

    func vote(pollID: String, optionIDs: [String]) async throws -> CrewspacePollDTO {
        try await request(
            path: "crewspace/polls/\(pollID)/vote",
            method: "POST",
            body: VoteCrewspacePollRequest(optionIDs: optionIDs)
        )
    }

    func createMediaUpload(contentType: String, fileExtension: String) async throws -> PresignedUploadDTO {
        try await request(
            path: "crewspace/uploads/presign",
            method: "POST",
            body: PresignUploadRequest(contentType: contentType, fileExtension: fileExtension)
        )
    }

    func uploadMedia(_ data: Data, to upload: PresignedUploadDTO, contentType: String) async throws {
        guard let url = URL(string: upload.uploadURL) else { throw SocialFeedAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = upload.method
        request.httpBody = data
        request.timeoutInterval = 60
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        upload.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SocialFeedAPIError.uploadFailed
        }
    }

    func markRead(conversationID: String) async throws {
        try await requestVoid(path: "crewspace/conversations/\(conversationID)/read", method: "POST")
    }

    func events() async throws -> [CrewspaceEventDTO] {
        try await request(path: "crewspace/events", method: "GET", body: Optional<EmptyBody>.none)
    }

    func createEvent(_ draft: CrewspaceEventDraft) async throws -> CrewspaceEventDTO {
        try await request(
            path: "crewspace/events",
            method: "POST",
            body: draft
        )
    }

    func updateEvent(eventID: String, draft: CrewspaceEventDraft) async throws -> CrewspaceEventDTO {
        try await request(
            path: "crewspace/events/\(eventID)",
            method: "PUT",
            body: draft
        )
    }

    func deleteEvent(eventID: String) async throws {
        try await requestVoid(path: "crewspace/events/\(eventID)", method: "DELETE")
    }

    func removeConversation(conversationID: String) async throws {
        try await requestVoid(path: "crewspace/conversations/\(conversationID)", method: "DELETE")
    }

    func shareEvent(eventID: String, conversationID: String) async throws -> CrewspaceEventDTO {
        try await request(
            path: "crewspace/events/\(eventID)/share",
            method: "POST",
            body: ShareCrewspaceEventRequest(conversationID: conversationID)
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SocialFeedAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SocialFeedAPIError.server(
                statusCode: http.statusCode,
                message: (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?.error
            )
        }
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func request<Response: Decodable, Body: Encodable>(
        url: URL,
        method: String,
        body: Body?
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SocialFeedAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SocialFeedAPIError.server(
                statusCode: http.statusCode,
                message: (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?.error
            )
        }
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func requestVoid<Body: Encodable>(path: String, method: String, body: Body?) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SocialFeedAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SocialFeedAPIError.server(
                statusCode: http.statusCode,
                message: (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?.error
            )
        }
    }

    private func requestVoid(path: String, method: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SocialFeedAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SocialFeedAPIError.server(statusCode: http.statusCode, message: nil)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.crewspaceWithFractional.date(from: value)
                ?? ISO8601DateFormatter.crewspaceStandard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ungültiges Datum")
        }
        return decoder
    }()
}

private struct EmptyBody: Encodable {}

private struct CrewspaceMeRequest: Encodable {
    let name: String
}

private struct CrewspaceDeviceRequest: Encodable {
    let installationID: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case platform
    }
}

private struct DirectConversationRequest: Encodable {
    let skipperID: String

    enum CodingKeys: String, CodingKey { case skipperID = "skipper_id" }
}

private struct GroupConversationRequest: Encodable {
    let title: String
    let info: String
    let memberIDs: [String]

    enum CodingKeys: String, CodingKey {
        case title, info
        case memberIDs = "member_ids"
    }
}

private struct UpdateCrewspaceGroupRequest: Encodable {
    let title: String; let info: String
}

private struct UpdateCrewspaceMemberRequest: Encodable {
    let skipperID: String
    let crewRole: String
    let isOnBoard: Bool

    enum CodingKeys: String, CodingKey {
        case skipperID = "skipper_id"
        case crewRole = "crew_role"
        case isOnBoard = "is_on_board"
    }
}

private struct SendMessageRequest: Encodable {
    let clientMessageID: String
    let text: String
    let mediaURL: String?
    let mediaType: String?
    let mediaDurationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case text
        case clientMessageID = "client_message_id"
        case mediaURL = "media_url"
        case mediaType = "media_type"
        case mediaDurationSeconds = "media_duration_seconds"
    }
}

private struct CreateCrewspacePollRequest: Encodable {
    let question: String
    let options: [String]
    let allowsMultiple: Bool

    enum CodingKeys: String, CodingKey {
        case question, options
        case allowsMultiple = "allows_multiple"
    }
}

private struct VoteCrewspacePollRequest: Encodable {
    let optionIDs: [String]

    enum CodingKeys: String, CodingKey { case optionIDs = "option_ids" }
}

private struct ShareCrewspaceEventRequest: Encodable {
    let conversationID: String

    enum CodingKeys: String, CodingKey { case conversationID = "conversation_id" }
}

private extension ISO8601DateFormatter {
    static let crewspaceStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let crewspaceWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct CommentResponse: Codable {
    let post: FeedPostDTO
    let comment: FeedCommentDTO
}

struct PresignedUploadDTO: Codable {
    let uploadURL: String
    let publicURL: String
    let method: String
    let headers: [String: String]

    enum CodingKeys: String, CodingKey {
        case uploadURL = "upload_url"
        case publicURL = "public_url"
        case method
        case headers
    }
}

private struct CreatePostRequest: Encodable {
    let skipperID: String
    let skipperName: String
    let skipperProfileImageURL: String?
    let text: String
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case skipperID = "skipper_id"
        case skipperName = "skipper_name"
        case skipperProfileImageURL = "skipper_profile_image_url"
        case text
        case imageURL = "image_url"
    }
}

private struct CreateCommentRequest: Encodable {
    let skipperID: String
    let skipperName: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case skipperID = "skipper_id"
        case skipperName = "skipper_name"
        case text
    }
}

private struct LikePostRequest: Encodable {
    let skipperID: String

    enum CodingKeys: String, CodingKey {
        case skipperID = "skipper_id"
    }
}

private struct UpdateProfileRequest: Encodable {
    let skipperID: String
    let name: String
    let boatType: String
    let homeHarbour: String?
    let bio: String?
    let profileImageURL: String?

    enum CodingKeys: String, CodingKey {
        case skipperID = "skipper_id"
        case name
        case boatType = "boat_type"
        case homeHarbour = "home_harbour"
        case bio
        case profileImageURL = "profile_image_url"
    }
}

private struct UpdateBoatTypeRequest: Encodable {
    let boatType: String

    enum CodingKeys: String, CodingKey {
        case boatType = "boat_type"
    }
}

private struct DeletePostRequest: Encodable {
    let skipperID: String

    enum CodingKeys: String, CodingKey {
        case skipperID = "skipper_id"
    }
}

private struct PresignUploadRequest: Encodable {
    let contentType: String
    let fileExtension: String

    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case fileExtension = "file_extension"
    }
}

@MainActor
enum SocialFeedCache {
    static func upsert(posts: [FeedPostDTO], in context: ModelContext) {
        posts.forEach { dto in
            upsert(post: dto, in: context)
            if let profile = dto.profile {
                upsert(profile: profile, in: context)
            } else {
                upsertProfileFromPost(dto, in: context)
            }
        }
        try? context.save()
    }

    static func upsert(post dto: FeedPostDTO, in context: ModelContext) {
        let existing = existingPost(id: dto.id, in: context)
        let post = existing ?? FeedPost(
            id: dto.id,
            skipperID: dto.skipperID,
            skipperName: dto.skipperName,
            skipperProfileImageURL: dto.skipperProfileImageURL,
            text: dto.text
        )

        post.skipperID = dto.skipperID
        post.skipperName = dto.skipperName
        post.skipperProfileImageURL = dto.skipperProfileImageURL
        post.text = dto.text
        post.imageURL = dto.imageURL
        post.likedBySkipperIDs = dto.likedBySkipperIDs
        post.commentIDs = dto.commentIDs
        post.likeCount = dto.likeCount
        post.commentCount = dto.commentCount
        post.createdAt = dto.createdAt
        post.updatedAt = dto.updatedAt
        post.lastSyncedAt = .now

        if existing == nil {
            context.insert(post)
        }
        try? context.save()
    }

    static func upsert(comments: [FeedCommentDTO], in context: ModelContext) {
        comments.forEach { upsert(comment: $0, in: context) }
        try? context.save()
    }

    static func upsert(comment dto: FeedCommentDTO, in context: ModelContext) {
        let existing = existingComment(id: dto.id, in: context)
        let comment = existing ?? FeedComment(
            id: dto.id,
            postID: dto.postID,
            skipperID: dto.skipperID,
            skipperName: dto.skipperName,
            text: dto.text,
            createdAt: dto.createdAt
        )

        comment.postID = dto.postID
        comment.skipperID = dto.skipperID
        comment.skipperName = dto.skipperName
        comment.text = dto.text
        comment.createdAt = dto.createdAt
        comment.lastSyncedAt = .now

        if existing == nil {
            context.insert(comment)
        }
        try? context.save()
    }

    static func upsert(profile dto: SkipperProfileDTO, in context: ModelContext) {
        let existing = existingProfile(id: dto.id, in: context)
        let profile = existing ?? SkipperProfile(
            id: dto.id,
            name: dto.name,
            boatType: dto.boatType
        )

        profile.name = dto.name
        profile.boatType = dto.boatType
        profile.profileImageURL = dto.profileImageURL
        profile.homeHarbour = dto.homeHarbour
        profile.bio = dto.bio
        profile.postIDs = dto.postIDs
        profile.followerCount = dto.followerCount
        profile.followingCount = dto.followingCount
        profile.isFollowedByCurrentSkipper = dto.isFollowedByCurrentSkipper ?? profile.isFollowedByCurrentSkipper
        profile.lastSyncedAt = .now

        if existing == nil {
            context.insert(profile)
        }
        try? context.save()
    }

    private static func upsertProfileFromPost(_ post: FeedPostDTO, in context: ModelContext) {
        let existing = existingProfile(id: post.skipperID, in: context)
        let profile = existing ?? SkipperProfile(
            id: post.skipperID,
            name: post.skipperName,
            boatType: "Unbekannt"
        )

        profile.name = post.skipperName
        profile.profileImageURL = post.skipperProfileImageURL
        profile.postIDs = Array(Set(profile.postIDs + [post.id]))
        profile.lastSyncedAt = .now

        if existing == nil {
            context.insert(profile)
        }
    }

    private static func existingPost(id: String, in context: ModelContext) -> FeedPost? {
        var descriptor = FetchDescriptor<FeedPost>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func existingComment(id: String, in context: ModelContext) -> FeedComment? {
        var descriptor = FetchDescriptor<FeedComment>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func existingProfile(id: String, in context: ModelContext) -> SkipperProfile? {
        var descriptor = FetchDescriptor<SkipperProfile>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
