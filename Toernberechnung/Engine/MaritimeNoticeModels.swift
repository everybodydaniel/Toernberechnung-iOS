import Foundation

enum MaritimeNoticePublicationState: String, Codable, CaseIterable, Sendable {
    case current
    case updated
    case revoked
    case expired

    var isArchived: Bool {
        self == .revoked || self == .expired
    }

    var label: String {
        switch self {
        case .current: return "Aktuell"
        case .updated: return "Geändert"
        case .revoked: return "Aufgehoben"
        case .expired: return "Abgelaufen"
        }
    }
}

enum MaritimeNoticeParseStatus: String, Codable, Sendable {
    case parsed
    case partial
    case failed
}

struct MaritimeNoticeCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let label: String?
}

struct MaritimeNoticeSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bfsNumber: String
    let isTemporary: Bool
    let publisher: String
    let title: String
    let regionPath: String
    let location: String?
    let publishedAt: Date?
    let validFrom: Date?
    let validUntil: Date?
    let publicationState: MaritimeNoticePublicationState
    let revision: Int
    let updatedAt: Date
    let sourceURL: URL?
    let parseStatus: MaritimeNoticeParseStatus

    enum CodingKeys: String, CodingKey {
        case id
        case bfsNumber = "bfs_number"
        case isTemporary = "is_temporary"
        case publisher
        case title
        case regionPath = "region_path"
        case location
        case publishedAt = "published_at"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
        case publicationState = "publication_state"
        case revision
        case updatedAt = "updated_at"
        case sourceURL = "source_url"
        case parseStatus = "parse_status"
    }

    func isCurrent(at date: Date = .now) -> Bool {
        guard !publicationState.isArchived else { return false }
        if let validFrom, validFrom > date { return true }
        return validUntil.map { $0 >= date } ?? true
    }

    var displayTitle: String {
        guard !regionPath.isEmpty, title.contains(regionPath) else { return title }
        let readableRegion = regionPath.replacingOccurrences(of: ".", with: " · ")
        return title.replacingOccurrences(of: regionPath, with: readableRegion)
    }
}

struct MaritimeNoticeDetail: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bfsNumber: String
    let isTemporary: Bool
    let publisher: String
    let title: String
    let regionPath: String
    let location: String?
    let body: String
    let publishedAt: Date?
    let validFrom: Date?
    let validUntil: Date?
    let publicationState: MaritimeNoticePublicationState
    let revision: Int
    let updatedAt: Date
    let sourceURL: URL?
    let chartReferences: [String]
    let coordinates: [MaritimeNoticeCoordinate]
    let previousNotices: [String]
    let parseStatus: MaritimeNoticeParseStatus

    enum CodingKeys: String, CodingKey {
        case id
        case bfsNumber = "bfs_number"
        case isTemporary = "is_temporary"
        case publisher
        case title
        case regionPath = "region_path"
        case location
        case body
        case publishedAt = "published_at"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
        case publicationState = "publication_state"
        case revision
        case updatedAt = "updated_at"
        case sourceURL = "source_url"
        case chartReferences = "chart_references"
        case coordinates
        case previousNotices = "previous_notices"
        case parseStatus = "parse_status"
    }
}

struct MaritimeNoticeListResponse: Codable, Sendable {
    var notices: [MaritimeNoticeSummary]
    let nextCursor: String?
    let lastIngestedAt: Date?
    var isStale: Bool

    enum CodingKeys: String, CodingKey {
        case notices
        case nextCursor = "next_cursor"
        case lastIngestedAt = "last_ingested_at"
        case isStale = "is_stale"
    }
}

struct MaritimeNoticeReadState: Codable, Equatable, Sendable {
    private(set) var readRevisions: [String: Int] = [:]

    func isUnread(_ notice: MaritimeNoticeSummary) -> Bool {
        (readRevisions[notice.id] ?? 0) < notice.revision
    }

    mutating func markRead(_ notice: MaritimeNoticeSummary) {
        readRevisions[notice.id] = max(readRevisions[notice.id] ?? 0, notice.revision)
    }

    mutating func markAllRead(_ notices: [MaritimeNoticeSummary]) {
        notices.forEach { markRead($0) }
    }

    func unreadCount(in notices: [MaritimeNoticeSummary]) -> Int {
        notices.lazy.filter(isUnread).count
    }
}
