import Foundation
import Observation

protocol MaritimeNoticeProviding: Sendable {
    func notices(forceRefresh: Bool) async throws -> MaritimeNoticeListResponse
    func detail(for noticeID: String, revision: Int) async throws -> MaritimeNoticeDetail
}

actor MaritimeNoticeService: MaritimeNoticeProviding {
    private struct CacheFile: Codable {
        var response: MaritimeNoticeListResponse
        var details: [String: MaritimeNoticeDetail]
        var fetchedAt: Date
        var etag: String?
    }

    private let baseURL: URL
    private let session: URLSession
    private let fileManager: FileManager
    private let cacheURL: URL
    private let cacheTTL: TimeInterval
    private let offlineMaximumAge: TimeInterval
    private var cache: CacheFile?
    private var didLoadDiskCache = false

    init(
        baseURL: URL = SocialFeedAPI.defaultBaseURL,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        cacheURL: URL? = nil,
        cacheTTL: TimeInterval = 15 * 60,
        offlineMaximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.baseURL = baseURL
        self.session = session
        self.fileManager = fileManager
        self.cacheTTL = cacheTTL
        self.offlineMaximumAge = offlineMaximumAge
        self.cacheURL = cacheURL ?? Self.defaultCacheURL(fileManager: fileManager)
    }

    func notices(forceRefresh: Bool = false) async throws -> MaritimeNoticeListResponse {
        try loadDiskCacheIfNeeded()
        if !forceRefresh,
           let cache,
           Date().timeIntervalSince(cache.fetchedAt) < cacheTTL {
            return cache.response
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("maritime-notices"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "status", value: "all"),
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = components?.url else { throw MaritimeNoticeServiceError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = cache?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MaritimeNoticeServiceError.invalidResponse
            }
            if http.statusCode == httpNotModified, var cache {
                cache.fetchedAt = .now
                cache.response.isStale = false
                self.cache = cache
                try persist(cache)
                return cache.response
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MaritimeNoticeServiceError.server(statusCode: http.statusCode)
            }

            var decoded = try Self.decoder.decode(MaritimeNoticeListResponse.self, from: data)
            decoded.notices.sort { $0.updatedAt > $1.updatedAt }
            decoded.isStale = false
            let updated = CacheFile(
                response: decoded,
                details: cache?.details ?? [:],
                fetchedAt: .now,
                etag: http.value(forHTTPHeaderField: "ETag")
            )
            cache = updated
            try persist(updated)
            return decoded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard var cache,
                  Date().timeIntervalSince(cache.fetchedAt) <= offlineMaximumAge else {
                throw MaritimeNoticeServiceError.network(error.localizedDescription)
            }
            cache.response.isStale = true
            self.cache = cache
            return cache.response
        }
    }

    func detail(for noticeID: String, revision: Int) async throws -> MaritimeNoticeDetail {
        try loadDiskCacheIfNeeded()
        if let detail = cache?.details[noticeID], detail.revision >= revision {
            return detail
        }

        let url = baseURL
            .appendingPathComponent("maritime-notices")
            .appendingPathComponent(noticeID)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MaritimeNoticeServiceError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MaritimeNoticeServiceError.server(statusCode: http.statusCode)
            }
            let detail = try Self.decoder.decode(MaritimeNoticeDetail.self, from: data)
            if var cache {
                cache.details[noticeID] = detail
                self.cache = cache
                try persist(cache)
            }
            return detail
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let detail = cache?.details[noticeID] { return detail }
            throw MaritimeNoticeServiceError.network(error.localizedDescription)
        }
    }

    private func loadDiskCacheIfNeeded() throws {
        guard !didLoadDiskCache else { return }
        didLoadDiskCache = true
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheURL)
            cache = try Self.decoder.decode(CacheFile.self, from: data)
        } catch {
            let backup = cacheURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: cacheURL, to: backup)
        }
    }

    private func persist(_ cache: CacheFile) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(cache)
        try data.write(to: cacheURL, options: .atomic)
    }

    private static func defaultCacheURL(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("TideNode", isDirectory: true)
            .appendingPathComponent("MaritimeNotices", isDirectory: true)
            .appendingPathComponent("notices-v1.json")
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
            let primary = ISO8601DateFormatter()
            primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            guard let date = primary.date(from: raw) ?? fallback.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ungültiges Datum: \(raw)")
            }
            return date
        }
        return decoder
    }()

    private var httpNotModified: Int { 304 }
}

enum MaritimeNoticeServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(statusCode: Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Die Adresse des Meldungsdienstes ist ungültig."
        case .invalidResponse:
            return "Der Meldungsdienst hat ungültig geantwortet."
        case .server(let statusCode):
            return "Der Meldungsdienst meldet HTTP \(statusCode)."
        case .network:
            return "Nachrichten für Seefahrer sind gerade nicht erreichbar."
        }
    }
}

@MainActor
@Observable
final class MaritimeNoticeCenter {
    private(set) var notices: [MaritimeNoticeSummary] = []
    private(set) var isLoading = false
    private(set) var isStale = false
    private(set) var lastIngestedAt: Date?
    private(set) var errorMessage: String?
    private(set) var pulseTrigger = 0
    private(set) var readStateVersion = 0

    @ObservationIgnored private let service: any MaritimeNoticeProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readStateKey: String
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var readState: MaritimeNoticeReadState
    @ObservationIgnored private var hasLoadedOnce = false

    init(
        service: any MaritimeNoticeProviding,
        defaults: UserDefaults = .standard,
        readStateKey: String = "maritimeNoticeReadState.v1"
    ) {
        self.service = service
        self.defaults = defaults
        self.readStateKey = readStateKey
        if let data = defaults.data(forKey: readStateKey),
           let state = try? JSONDecoder().decode(MaritimeNoticeReadState.self, from: data) {
            readState = state
        } else {
            readState = MaritimeNoticeReadState()
        }
    }

    var unreadCount: Int {
        _ = readStateVersion
        return readState.unreadCount(in: notices)
    }

    func isUnread(_ notice: MaritimeNoticeSummary) -> Bool {
        _ = readStateVersion
        return readState.isUnread(notice)
    }

    func setActive(_ active: Bool) async {
        if active {
            await refresh(force: false)
            guard pollingTask == nil else { return }
            pollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15 * 60))
                    guard !Task.isCancelled else { return }
                    await self?.refresh(force: false)
                }
            }
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    func refresh(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let previousSignatures = Set(notices.filter(isUnread).map { "\($0.id):\($0.revision)" })
        do {
            let response = try await service.notices(forceRefresh: force)
            notices = response.notices.sorted { $0.updatedAt > $1.updatedAt }
            isStale = response.isStale
            lastIngestedAt = response.lastIngestedAt
            errorMessage = nil

            let newSignatures = Set(notices.filter(isUnread).map { "\($0.id):\($0.revision)" })
            if !newSignatures.isEmpty && (!hasLoadedOnce || !newSignatures.isSubset(of: previousSignatures)) {
                pulseTrigger &+= 1
            }
            hasLoadedOnce = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func detail(for notice: MaritimeNoticeSummary) async -> MaritimeNoticeDetail? {
        do {
            let result = try await service.detail(for: notice.id, revision: notice.revision)
            errorMessage = nil
            markRead(notice)
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func markRead(_ notice: MaritimeNoticeSummary) {
        readState.markRead(notice)
        readStateVersion &+= 1
        persistReadState()
    }

    func markAllRead() {
        readState.markAllRead(notices)
        readStateVersion &+= 1
        persistReadState()
    }

    private func persistReadState() {
        guard let data = try? JSONEncoder().encode(readState) else { return }
        defaults.set(data, forKey: readStateKey)
    }
}
