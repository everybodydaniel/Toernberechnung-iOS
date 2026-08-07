import Foundation
import Observation
import SwiftData

enum BoatTypeCatalog {
    static let defaultType = "Segelyacht"
    static let standardTypes = [
        "Segelyacht",
        "Motoryacht",
        "Katamaran",
        "Jolle",
        "Arbeitsboot"
    ]

    static func normalized(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultType }

        if let standard = standardTypes.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return standard
        }
        return String(trimmed.prefix(80))
    }

    static func selectableTypes(including currentValue: String) -> [String] {
        let currentValue = normalized(currentValue)
        guard !standardTypes.contains(currentValue) else { return standardTypes }
        return standardTypes + [currentValue]
    }
}

enum BoatProfileSyncState: Equatable {
    case localOnly
    case syncing
    case synced
    case failed(String)
}

@MainActor
@Observable
final class BoatProfileStore {
    typealias SyncOperation = @MainActor (_ skipperID: String, _ boatType: String) async throws -> Void

    private(set) var boatType: String
    private(set) var activeSkipperID: String?
    private(set) var syncState: BoatProfileSyncState = .localOnly

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var syncOperation: SyncOperation?
    @ObservationIgnored
    private var syncTask: Task<Void, Never>?
    @ObservationIgnored
    private var syncGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        boatType = BoatTypeCatalog.normalized(defaults.string(forKey: Self.storageKey))
        defaults.set(boatType, forKey: Self.storageKey)
    }

    func activateAccount(
        skipperID: String?,
        sync: SyncOperation? = nil
    ) {
        syncTask?.cancel()
        syncGeneration &+= 1
        activeSkipperID = skipperID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        syncOperation = sync

        guard activeSkipperID != nil, sync != nil else {
            syncState = .localOnly
            return
        }
        startSync()
    }

    func selectBoatType(_ value: String) {
        let normalized = BoatTypeCatalog.normalized(value)
        guard normalized != boatType else {
            if case .failed = syncState {
                retrySync()
            }
            return
        }

        boatType = normalized
        defaults.set(normalized, forKey: Self.storageKey)
        startSync()
    }

    func retrySync() {
        guard activeSkipperID != nil, syncOperation != nil else {
            syncState = .localOnly
            return
        }
        startSync()
    }

    func confirmSynchronized(boatType: String, skipperID: String) {
        guard activeSkipperID == skipperID,
              BoatTypeCatalog.normalized(boatType) == self.boatType else { return }
        syncTask?.cancel()
        syncGeneration &+= 1
        syncState = .synced
    }

    private func startSync() {
        guard let skipperID = activeSkipperID,
              let syncOperation else {
            syncState = .localOnly
            return
        }

        syncTask?.cancel()
        syncGeneration &+= 1
        let generation = syncGeneration
        let selectedBoatType = boatType
        syncState = .syncing

        syncTask = Task { @MainActor [weak self] in
            do {
                try await syncOperation(skipperID, selectedBoatType)
                try Task.checkCancellation()
                guard let self,
                      self.syncGeneration == generation,
                      self.activeSkipperID == skipperID,
                      self.boatType == selectedBoatType else { return }
                self.syncState = .synced
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.syncGeneration == generation,
                      self.activeSkipperID == skipperID,
                      self.boatType == selectedBoatType else { return }
                self.syncState = .failed(error.localizedDescription)
            }
        }
    }

    private static let storageKey = "boatType"
}

@Model
final class FeedPost {
    @Attribute(.unique) var id: String
    var skipperID: String
    var skipperName: String
    var skipperProfileImageURL: String?
    var text: String
    var imageURL: String?
    var likedBySkipperIDs: [String]
    var commentIDs: [String]
    var likeCount: Int
    var commentCount: Int
    var createdAt: Date
    var updatedAt: Date
    var lastSyncedAt: Date

    init(
        id: String,
        skipperID: String,
        skipperName: String,
        skipperProfileImageURL: String? = nil,
        text: String,
        imageURL: String? = nil,
        likedBySkipperIDs: [String] = [],
        commentIDs: [String] = [],
        likeCount: Int = 0,
        commentCount: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastSyncedAt: Date = .now
    ) {
        self.id = id
        self.skipperID = skipperID
        self.skipperName = skipperName
        self.skipperProfileImageURL = skipperProfileImageURL
        self.text = text
        self.imageURL = imageURL
        self.likedBySkipperIDs = likedBySkipperIDs
        self.commentIDs = commentIDs
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
    }
}

@Model
final class FeedComment {
    @Attribute(.unique) var id: String
    var postID: String
    var skipperID: String
    var skipperName: String
    var text: String
    var createdAt: Date
    var lastSyncedAt: Date

    init(
        id: String,
        postID: String,
        skipperID: String,
        skipperName: String,
        text: String,
        createdAt: Date = .now,
        lastSyncedAt: Date = .now
    ) {
        self.id = id
        self.postID = postID
        self.skipperID = skipperID
        self.skipperName = skipperName
        self.text = text
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
    }
}

@Model
final class SkipperProfile {
    @Attribute(.unique) var id: String
    var name: String
    var boatType: String
    var profileImageURL: String?
    var homeHarbour: String?
    var bio: String?
    var postIDs: [String]
    var followerCount: Int
    var followingCount: Int
    @Transient
    var isFollowedByCurrentSkipper: Bool = false
    var lastSyncedAt: Date

    init(
        id: String,
        name: String,
        boatType: String,
        profileImageURL: String? = nil,
        homeHarbour: String? = nil,
        bio: String? = nil,
        postIDs: [String] = [],
        followerCount: Int = 0,
        followingCount: Int = 0,
        isFollowedByCurrentSkipper: Bool = false,
        lastSyncedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.boatType = boatType
        self.profileImageURL = profileImageURL
        self.homeHarbour = homeHarbour
        self.bio = bio
        self.postIDs = postIDs
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.isFollowedByCurrentSkipper = isFollowedByCurrentSkipper
        self.lastSyncedAt = lastSyncedAt
    }
}
