import Foundation
import SwiftUI
import XCTest
@testable import Toernberechnung

final class NautiConversationPersistenceTests: XCTestCase {
    func testFileRepositoryRoundTripPreservesRichMessages() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let timestamp = Date(timeIntervalSince1970: 1_788_575_200)

        let weather = NautiWeatherCard(
            harbourName: "Juist, Hafen",
            dayTitle: "Montag",
            condition: "Leicht bewölkt",
            icon: "cloud.sun.fill",
            minTemperatureC: 15,
            maxTemperatureC: 21,
            maxWindKnots: 18,
            maxGustKnots: 25,
            precipitationChance: 20,
            precipitationMM: 0.8,
            slots: [
                NautiWeatherSlot(
                    timeLabel: "12 Uhr",
                    temperatureC: 20,
                    windKnots: 16,
                    windDirection: 270,
                    precipitationChance: 10,
                    icon: "sun.max.fill"
                )
            ],
            sourceText: "Apple Weather",
            harbourID: "juist_harbor",
            targetDate: timestamp
        )
        let tide = NautiTideCard(
            harbourName: "Juist, Hafen",
            stationName: "Juist Anleger",
            dayTitle: "Montag",
            events: [
                NautiTideCardEvent(
                    type: "HW",
                    timeLabel: "13:42",
                    heightMeters: 3.1,
                    heightText: "3,10 m"
                )
            ],
            sourceText: "BSH",
            harbourID: "juist_harbor",
            targetDate: timestamp
        )
        let conversation = NautiConversation(
            title: "Juist planen",
            createdAt: timestamp,
            updatedAt: timestamp,
            isPinned: true,
            hasCustomTitle: true,
            draft: "Noch eine Frage",
            messages: [
                NautiChatMessage(
                    role: .assistant,
                    text: NautiChatMessage.welcome.text,
                    createdAt: timestamp
                ),
                NautiChatMessage(
                    role: .user,
                    text: "Wie wird das Wetter?",
                    createdAt: timestamp
                ),
                NautiChatMessage(
                    role: .assistant,
                    text: "Hier ist die Vorhersage.",
                    payload: .weather(weather),
                    createdAt: timestamp
                ),
                NautiChatMessage(
                    role: .assistant,
                    text: "Hier sind die Gezeiten.",
                    payload: .tide(tide),
                    createdAt: timestamp
                )
            ]
        )
        let repository = FileNautiConversationRepository(fileURL: location.file)

        try await repository.save([conversation])
        let restored = try await repository.load()

        XCTAssertEqual(restored, [conversation])
    }

    func testCorruptedHistoryIsPreservedAsBackup() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(to: location.file)
        let repository = FileNautiConversationRepository(fileURL: location.file)

        do {
            _ = try await repository.load()
            XCTFail("Eine beschädigte Historie muss einen Wiederherstellungshinweis erzeugen.")
        } catch let error as NautiConversationRepositoryError {
            guard case .corruptedHistory(let backupName) = error else {
                return XCTFail("Unerwarteter Repository-Fehler: \(error)")
            }
            XCTAssertTrue(backupName.hasPrefix("conversations-corrupt-"))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: location.directory.appendingPathComponent(backupName).path
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.file.path))
    }

    @MainActor
    func testPinRenameDeleteAndDeterministicReplacement() {
        let viewModel = makeViewModel()
        let firstID = viewModel.activeConversationID
        let secondID = viewModel.createConversation()

        viewModel.togglePin(firstID)
        XCTAssertEqual(viewModel.sortedConversations.first?.id, firstID)
        XCTAssertTrue(viewModel.renameConversation(firstID, title: "  Nordsee-Törn  "))
        XCTAssertFalse(viewModel.renameConversation(firstID, title: "   "))
        XCTAssertEqual(viewModel.conversations.first(where: { $0.id == firstID })?.title, "Nordsee-Törn")

        viewModel.selectConversation(secondID)
        viewModel.deleteConversation(secondID)
        XCTAssertEqual(viewModel.activeConversationID, firstID)

        viewModel.deleteConversation(firstID)
        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertNotEqual(viewModel.activeConversationID, firstID)
        XCTAssertEqual(viewModel.activeConversation.title, NautiConversation.defaultTitle)
    }

    @MainActor
    func testFirstUserMessageCreatesTitleWithMaximumFortyEightCharacters() async {
        let viewModel = makeViewModel()
        viewModel.draft = "Plane einen besonders ausführlichen Törn von Emden über Juist bis nach Norderney"

        _ = await viewModel.sendCurrentDraft()

        XCTAssertLessThanOrEqual(viewModel.activeConversation.title.count, 48)
        XCTAssertTrue(viewModel.activeConversation.title.hasSuffix("…"))
        XCTAssertFalse(viewModel.activeConversation.hasCustomTitle)
    }

    @MainActor
    func testDraftAndHistoryPersistAcrossViewModels() async {
        let repository = MemoryNautiConversationRepository()
        let first = NautiChatViewModel(
            inferenceClient: ConversationTestInferenceClient(),
            repository: repository
        )
        first.draft = "Für später"
        first.appendAssistantMessage("Gespeicherte Antwort")
        await first.persistImmediately()

        let restored = NautiChatViewModel(
            inferenceClient: ConversationTestInferenceClient(),
            repository: repository
        )
        await restored.loadHistory()

        XCTAssertEqual(restored.draft, "Für später")
        XCTAssertEqual(restored.messages.last?.text, "Gespeicherte Antwort")
    }

    @MainActor
    func testConversationKeepsWelcomeAndLatestNinetyNineMessages() {
        let viewModel = makeViewModel()

        for index in 0..<120 {
            viewModel.appendAssistantMessage("Antwort \(index)")
        }

        XCTAssertEqual(viewModel.messages.count, 100)
        XCTAssertEqual(viewModel.messages.first?.role, .assistant)
        XCTAssertEqual(viewModel.messages.first?.text, NautiChatMessage.welcome.text)
        XCTAssertEqual(viewModel.messages.last?.text, "Antwort 119")
    }

    func testInlineDashboardUsesAdaptiveCompactHeight() {
        XCTAssertEqual(
            NautiDashboardGeometry.panelHeight(availableHeight: 844),
            472.64,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NautiDashboardGeometry.panelHeight(availableHeight: 1_000),
            520,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NautiDashboardGeometry.panelHeight(availableHeight: 667),
            380,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NautiDashboardGeometry.panelHeight(availableHeight: 390),
            380,
            accuracy: 0.001
        )
    }

    func testInlineDashboardModesExposeExpansionState() {
        XCTAssertFalse(NautiDashboardMode.dashboard.isExpanded)
        XCTAssertTrue(NautiDashboardMode.chat.isExpanded)
        XCTAssertTrue(NautiDashboardMode.history.isExpanded)
    }

    @MainActor
    private func makeViewModel() -> NautiChatViewModel {
        NautiChatViewModel(
            inferenceClient: ConversationTestInferenceClient(),
            repository: MemoryNautiConversationRepository()
        )
    }

    private func temporaryLocation() -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NautiConversationTests-\(UUID().uuidString)", isDirectory: true)
        return (
            directory,
            directory.appendingPathComponent("conversations-v1.json")
        )
    }
}

actor MemoryNautiConversationRepository: NautiConversationRepository {
    private var stored: [NautiConversation]

    init(_ conversations: [NautiConversation] = []) {
        self.stored = conversations
    }

    func load() async throws -> [NautiConversation] {
        stored
    }

    func save(_ conversations: [NautiConversation]) async throws {
        stored = conversations
    }
}

private struct ConversationTestInferenceClient: LocalAIInferenceClient {
    func availability() async -> LocalAIAvailability { .available }

    func infer(_ request: NautiInferenceRequest) async throws -> NautiInferenceResult {
        NautiInferenceResult(text: "Verstanden.", action: nil)
    }

    func cancelCurrentInference() async { }
    func releaseResources() async { }
}

final class BoatProfileStoreTests: XCTestCase {
    @MainActor
    func testBoatTypeCatalogNormalizesKnownAndCustomValues() {
        XCTAssertEqual(BoatTypeCatalog.normalized(" motoryacht "), "Motoryacht")
        XCTAssertEqual(BoatTypeCatalog.normalized(""), BoatTypeCatalog.defaultType)
        XCTAssertEqual(BoatTypeCatalog.normalized("Traditionssegler"), "Traditionssegler")
        XCTAssertTrue(
            BoatTypeCatalog.selectableTypes(including: "Traditionssegler")
                .contains("Traditionssegler")
        )
    }

    @MainActor
    func testBoatSelectionPersistsDeviceWideWithoutAnAccount() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = BoatProfileStore(defaults: defaults)
        store.selectBoatType("Katamaran")
        let reopenedStore = BoatProfileStore(defaults: defaults)

        XCTAssertEqual(reopenedStore.boatType, "Katamaran")
        XCTAssertEqual(reopenedStore.syncState, .localOnly)
    }

    @MainActor
    func testAccountActivationImmediatelySynchronizesCurrentBoat() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set("Jolle", forKey: "boatType")
        let store = BoatProfileStore(defaults: defaults)
        var synchronizedValue: (String, String)?

        store.activateAccount(skipperID: "skipper-a") { skipperID, boatType in
            synchronizedValue = (skipperID, boatType)
        }
        await waitForSync(store)

        XCTAssertEqual(synchronizedValue?.0, "skipper-a")
        XCTAssertEqual(synchronizedValue?.1, "Jolle")
        XCTAssertEqual(store.syncState, .synced)
    }

    @MainActor
    func testFailedSyncCanBeRetriedAndAccountSwitchIgnoresOldCompletion() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = BoatProfileStore(defaults: defaults)
        var shouldFail = true

        store.activateAccount(skipperID: "skipper-a") { _, _ in
            if shouldFail {
                throw BoatProfileTestError.offline
            }
        }
        await waitForSync(store)
        guard case .failed = store.syncState else {
            return XCTFail("Ein Offline-Fehler muss als ausstehende Synchronisierung sichtbar bleiben.")
        }

        shouldFail = false
        store.retrySync()
        await waitForSync(store)
        XCTAssertEqual(store.syncState, .synced)

        store.activateAccount(skipperID: "skipper-old") { _, _ in
            try await Task.sleep(for: .seconds(2))
        }
        store.activateAccount(skipperID: "skipper-new") { skipperID, _ in
            XCTAssertEqual(skipperID, "skipper-new")
        }
        await waitForSync(store)

        XCTAssertEqual(store.activeSkipperID, "skipper-new")
        XCTAssertEqual(store.syncState, .synced)
    }

    @MainActor
    private func waitForSync(_ store: BoatProfileStore) async {
        for _ in 0..<100 where store.syncState == .syncing {
            await Task.yield()
        }
    }

    private var defaultsSuiteName: String {
        "BoatProfileStoreTests"
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

private enum BoatProfileTestError: LocalizedError {
    case offline

    var errorDescription: String? { "Offline" }
}

final class CrewspaceProfileIsolationTests: XCTestCase {
    @MainActor
    func testAccountSwitchSelectsOnlyTheActiveProfilesAvatar() {
        let previous = SkipperProfile(
            id: "skipper-old",
            name: "Alt",
            boatType: "Jolle",
            profileImageURL: "https://example.com/old.jpg"
        )
        let active = SkipperProfile(
            id: "skipper-new",
            name: "Neu",
            boatType: "Katamaran",
            profileImageURL: "https://example.com/new.jpg"
        )

        XCTAssertIdentical(
            CrewspaceAccountProfileResolver.profile(
                in: [previous, active],
                skipperID: "skipper-new"
            ),
            active
        )
        XCTAssertNil(
            CrewspaceAccountProfileResolver.profile(
                in: [previous],
                skipperID: "skipper-new"
            )
        )
    }

    func testProfileEditorNeverUsesAnotherAccountsNameOrImageAsFallback() {
        let fallback = SkipperProfileEditorFallback.resolve(
            profileID: "skipper-old",
            profileName: "Alter Name",
            profileImageURL: "https://example.com/old.jpg",
            authenticatedSkipperID: "skipper-new",
            authenticatedDisplayName: "Neuer Name"
        )

        XCTAssertEqual(fallback.name, "Neuer Name")
        XCTAssertEqual(fallback.profileImageURL, "")

        let matchingProfile = SkipperProfileEditorFallback.resolve(
            profileID: "skipper-new",
            profileName: "Server Name",
            profileImageURL: "https://example.com/new.jpg",
            authenticatedSkipperID: "skipper-new",
            authenticatedDisplayName: "Firebase Name"
        )
        XCTAssertEqual(matchingProfile.name, "Server Name")
        XCTAssertEqual(matchingProfile.profileImageURL, "https://example.com/new.jpg")
    }

    @MainActor
    func testAvatarUsesInitialsForMissingMalformedAndFailedImages() {
        XCTAssertNotNil(
            SkipperAvatarView.remoteURL(from: "https://example.com/avatar.jpg")
        )
        XCTAssertNil(SkipperAvatarView.remoteURL(from: nil))
        XCTAssertNil(SkipperAvatarView.remoteURL(from: "avatar.jpg"))
        XCTAssertNil(SkipperAvatarView.remoteURL(from: "ftp://example.com/avatar.jpg"))
        XCTAssertTrue(SkipperAvatarView.usesInitials(for: .empty))
        XCTAssertTrue(
            SkipperAvatarView.usesInitials(
                for: .failure(URLError(.cannotLoadFromNetwork))
            )
        )
    }
}

final class SocialFeedBoatTypeRequestTests: XCTestCase {
    func testBoatTypePatchSendsOnlyNormalizedBoatTypeWithAuthentication() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialFeedRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = LockedURLRequestRecorder()
        let responseData = Data(
            #"""
            {
              "id": "skipper-current",
              "name": "Skipper",
              "boat_type": "Jolle",
              "profile_image_url": null,
              "home_harbour": null,
              "bio": null,
              "post_ids": [],
              "follower_count": 0,
              "following_count": 0,
              "is_followed_by_current_skipper": false
            }
            """#.utf8
        )
        SocialFeedRequestURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        defer {
            session.invalidateAndCancel()
            SocialFeedRequestURLProtocol.handler = nil
        }

        let api = SocialFeedAPI(
            baseURL: URL(string: "https://example.com")!,
            session: session,
            authTokenProvider: { "firebase-token" },
            skipperIDProvider: { "skipper-current" }
        )

        let response = try await api.updateBoatType(
            skipperID: "skipper-current",
            boatType: " jolle "
        )
        let request = try XCTUnwrap(recorder.request)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(response.boatType, "Jolle")
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/profiles/skipper-current/boat-type")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer firebase-token"
        )
        XCTAssertEqual(Set(object.keys), Set(["boat_type"]))
        XCTAssertEqual(object["boat_type"] as? String, "Jolle")
    }

    func testBoatTypeFallsBackToProfilePutWhenPatchIsNotDeployed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialFeedRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = LockedURLRequestRecorder()
        let existingProfile = Data(
            #"""
            {
              "id": "skipper-current",
              "name": "Daniel",
              "boat_type": "Segelyacht",
              "profile_image_url": "https://example.com/avatar.jpg",
              "home_harbour": "Emden",
              "bio": "Unterwegs im Wattenmeer",
              "post_ids": [],
              "follower_count": 0,
              "following_count": 0,
              "is_followed_by_current_skipper": false
            }
            """#.utf8
        )
        let updatedProfile = Data(
            String(data: existingProfile, encoding: .utf8)!
                .replacingOccurrences(of: "Segelyacht", with: "Katamaran")
                .utf8
        )
        SocialFeedRequestURLProtocol.handler = { request in
            recorder.record(request)
            let statusCode: Int
            let responseData: Data
            switch (request.httpMethod, request.url?.path) {
            case ("PATCH", "/profiles/skipper-current/boat-type"):
                statusCode = 405
                responseData = Data()
            case ("GET", "/profiles/skipper-current"):
                statusCode = 200
                responseData = existingProfile
            case ("PUT", "/profiles/skipper-current"):
                statusCode = 200
                responseData = updatedProfile
            default:
                statusCode = 404
                responseData = Data()
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        defer {
            session.invalidateAndCancel()
            SocialFeedRequestURLProtocol.handler = nil
        }

        let api = SocialFeedAPI(
            baseURL: URL(string: "https://example.com")!,
            session: session,
            authTokenProvider: { "firebase-token" },
            skipperIDProvider: { "skipper-current" }
        )

        let response = try await api.updateBoatType(
            skipperID: "skipper-current",
            boatType: "Katamaran"
        )
        let requests = recorder.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["PATCH", "GET", "PUT"])
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/profiles/skipper-current/boat-type",
                "/profiles/skipper-current",
                "/profiles/skipper-current"
            ]
        )
        let putBody = try XCTUnwrap(requests.last?.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: putBody) as? [String: Any]
        )
        XCTAssertEqual(response.boatType, "Katamaran")
        XCTAssertEqual(object["name"] as? String, "Daniel")
        XCTAssertEqual(object["boat_type"] as? String, "Katamaran")
        XCTAssertEqual(object["home_harbour"] as? String, "Emden")
        XCTAssertEqual(object["bio"] as? String, "Unterwegs im Wattenmeer")
        XCTAssertEqual(
            object["profile_image_url"] as? String,
            "https://example.com/avatar.jpg"
        )
    }
}

private final class LockedURLRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests.last
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func record(_ request: URLRequest) {
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            recordedRequest.httpBody = body
        }
        lock.lock()
        storedRequests.append(recordedRequest)
        lock.unlock()
    }
}

private final class SocialFeedRequestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
