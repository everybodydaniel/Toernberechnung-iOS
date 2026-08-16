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
        // Previously this returned the full 380pt floor, leaving only 10pt of
        // the container — enough to push the chat header up behind the
        // AppHeader. The panel is hard-clipped, so it now reserves 76pt of
        // header clearance instead.
        XCTAssertEqual(
            NautiDashboardGeometry.panelHeight(availableHeight: 390),
            314,
            accuracy: 0.001
        )
    }

    /// With the keyboard up, `availableHeight` shrinks and the panel must stay
    /// inside it so the chat input is never clipped away.
    func testInlineDashboardHeightLeavesRoomForKeyboardAndHeader() {
        // iPhone 17 (874pt) minus a ~336pt German keyboard, 8pt bottom inset.
        let withKeyboard = NautiDashboardGeometry.panelHeight(
            availableHeight: 538,
            bottomInset: 8
        )
        XCTAssertLessThanOrEqual(withKeyboard, 538 - 8 - 76)
        XCTAssertGreaterThanOrEqual(withKeyboard, 220)

        // The floor still wins over an absurdly small container.
        XCTAssertEqual(
            NautiDashboardGeometry.panelHeight(availableHeight: 200, bottomInset: 8),
            220,
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

final class SkipperAvatarViewTests: XCTestCase {
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
