import XCTest
@testable import Toernberechnung

final class LocalAIInferenceTests: XCTestCase {
    func testContextKeepsLatestTwelveMessagesWithinEightThousandCharacters() {
        let messages = (0..<20).map { index in
            NautiConversationMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "\(index)-" + String(repeating: "x", count: 900)
            )
        }

        let limited = NautiInferenceRequest(messages: messages).limited()

        XCTAssertLessThanOrEqual(limited.messages.count, 12)
        XCTAssertLessThanOrEqual(limited.messages.reduce(0) { $0 + $1.text.count }, 8_000)
        XCTAssertTrue(limited.messages.last?.text.hasPrefix("19-") == true)
    }

    func testPlanTripRequiresStartDestinationAndDeparture() {
        let incomplete = NautiAppAction(
            kind: .planTrip,
            startHarbourID: "emden_harbor",
            destinationHarbourID: "norderney_harbor"
        )

        let result = NautiActionValidator.validate(incomplete, reply: "Ich plane den Törn.")

        XCTAssertNil(result.action)
        XCTAssertTrue(result.text.contains("Tag"))
        XCTAssertTrue(result.text.contains("Uhrzeit"))
    }

    func testValidPlanTripIsTypedAndDeduplicatesStops() {
        let action = NautiAppAction(
            kind: .planTrip,
            startHarbourID: "emden_harbor",
            destinationHarbourID: "norderney_harbor",
            intermediateStopIDs: ["juist_harbor", "juist_harbor", "emden_harbor"],
            departureAt: "2026-07-12T14:00:00+02:00",
            saveTrip: true
        )

        let result = NautiActionValidator.validate(action, reply: "Ich bereite den Törn vor.")

        XCTAssertEqual(result.action?.kind, .planTrip)
        XCTAssertEqual(result.action?.intermediateStopIDs, ["juist_harbor"])
        XCTAssertEqual(result.action?.saveTrip, true)
    }

    func testDeterministicRouterPlansSimpleTripWithoutAskingAgain() {
        let requestedAt = Date(timeIntervalSince1970: 1_784_225_640)
        let request = NautiInferenceRequest(
            messages: [
                NautiConversationMessage(role: .user, text: "Plane einen Törn von Emden nach Norderney")
            ],
            requestedAt: requestedAt
        )

        let result = NautiDeterministicIntentRouter.route(request)

        XCTAssertEqual(result?.action?.kind, .planTrip)
        XCTAssertEqual(result?.action?.startHarbourID, "emden_harbor")
        XCTAssertEqual(result?.action?.destinationHarbourID, "norderney_harbor")
        XCTAssertEqual(result?.action?.departureDate, requestedAt)
        XCTAssertFalse(result?.text.contains("Starthafen") == true)
    }

    func testDeterministicRouterPlansTripWithStopTimeSaveAndGPS() {
        let requestedAt = Date(timeIntervalSince1970: 1_784_225_640)
        let request = NautiInferenceRequest(
            messages: [
                NautiConversationMessage(
                    role: .user,
                    text: "Berechne einen Törn von Emden nach Norderney mit Zwischenstopp in Juist morgen um 12 Uhr und speichere ihn und starte GPS"
                )
            ],
            requestedAt: requestedAt
        )

        let result = NautiDeterministicIntentRouter.route(request)

        XCTAssertEqual(result?.action?.kind, .planTrip)
        XCTAssertEqual(result?.action?.startHarbourID, "emden_harbor")
        XCTAssertEqual(result?.action?.destinationHarbourID, "norderney_harbor")
        XCTAssertEqual(result?.action?.intermediateStopIDs, ["juist_harbor"])
        XCTAssertEqual(result?.action?.saveTrip, true)
        XCTAssertEqual(result?.action?.openNavigation, true)
        XCTAssertEqual(result?.action?.departureDate.map(AppDateFormatters.hourMinute.string), "12:00")
    }

    func testDataActionRequiresKnownHarbourAndValidDate() {
        let missingHarbour = NautiAppAction(
            kind: .getWeatherSummary,
            targetDate: "2026-07-13"
        )
        let invalidDate = NautiAppAction(
            kind: .getWeatherSummary,
            harbourID: "juist_harbor",
            targetDate: "morgen"
        )

        XCTAssertNil(NautiActionValidator.validate(missingHarbour, reply: "Wetter").action)
        XCTAssertNil(NautiActionValidator.validate(invalidDate, reply: "Wetter").action)
    }

    func testExplicitWeatherCommandWinsOverPreviousTripContext() {
        let request = NautiInferenceRequest(
            messages: [
                NautiConversationMessage(role: .user, text: "Plane einen Törn von Borkum nach Juist für jetzt"),
                NautiConversationMessage(role: .assistant, text: "Ich habe den Törn vorbereitet."),
                NautiConversationMessage(role: .user, text: "Zeig mir das Wetter von Juist an")
            ],
            requestedAt: Date(timeIntervalSince1970: 1_784_225_640)
        )

        let result = NautiDeterministicIntentRouter.route(request)

        XCTAssertEqual(result?.action?.kind, .getWeatherSummary)
        XCTAssertEqual(result?.action?.harbourID, "juist_harbor")
        XCTAssertFalse(result?.text.contains("Törn") == true)
    }

    func testWeatherFollowUpReusesMostRecentlyMentionedHarbour() {
        let request = NautiInferenceRequest(messages: [
            NautiConversationMessage(role: .user, text: "Zeig mir das Wetter von Juist an"),
            NautiConversationMessage(role: .assistant, text: "Der Törn ist geplant."),
            NautiConversationMessage(role: .user, text: "Du sollst das Wetter anzeigen")
        ])

        let result = NautiDeterministicIntentRouter.route(request)

        XCTAssertEqual(result?.action?.kind, .getWeatherSummary)
        XCTAssertEqual(result?.action?.harbourID, "juist_harbor")
    }

    func testTripSanitizerRemovesStopsNotMentionedByUser() {
        let request = NautiInferenceRequest(
            messages: [
                NautiConversationMessage(role: .user, text: "Plane einen Törn von Borkum nach Juist für jetzt")
            ],
            requestedAt: Date(timeIntervalSince1970: 1_784_225_640)
        )
        let generated = NautiInferenceResult(
            text: "Route mit Emden und Wangerooge.",
            action: NautiAppAction(
                kind: .planTrip,
                startHarbourID: "borkum_harbor",
                destinationHarbourID: "juist_harbor",
                intermediateStopIDs: ["emden_harbor", "wangerooge_harbor"],
                departureAt: "2026-07-16T19:00:00+02:00"
            )
        )

        let result = NautiDeterministicIntentRouter.sanitize(generated, for: request)

        XCTAssertEqual(result.action?.intermediateStopIDs, [])
        XCTAssertFalse(result.text.contains("Emden"))
        XCTAssertFalse(result.text.contains("Wangerooge"))
        XCTAssertEqual(result.action?.departureDate, request.requestedAt)
    }

    func testMessageActionRequiresRecipientAndBody() {
        let missingBody = NautiAppAction(
            kind: .sendMessage,
            recipientQuery: "Daniel"
        )
        let valid = NautiAppAction(
            kind: .sendMessage,
            recipientKind: .direct,
            recipientQuery: " Daniel ",
            messageText: " Moin! "
        )

        XCTAssertNil(NautiActionValidator.validate(missingBody, reply: "Nachricht").action)
        let result = NautiActionValidator.validate(valid, reply: "Nachricht")
        XCTAssertEqual(result.action?.recipientQuery, "Daniel")
        XCTAssertEqual(result.action?.messageText, "Moin!")
    }

    func testEventRequiresValidTimeRangeAndDefaultsToPersonalLater() {
        let invalid = NautiAppAction(
            kind: .createEvent,
            eventTitle: "Ablegen",
            eventStartAt: "2026-07-16T16:00:00+02:00",
            eventEndAt: "2026-07-16T14:00:00+02:00"
        )
        let valid = NautiAppAction(
            kind: .createEvent,
            eventTitle: " Ablegen ",
            eventNotes: " Schwimmwesten prüfen ",
            eventStartAt: "2026-07-16T14:10:00+02:00",
            eventEndAt: "2026-07-16T16:10:00+02:00"
        )

        XCTAssertNil(NautiActionValidator.validate(invalid, reply: "Termin").action)
        let result = NautiActionValidator.validate(valid, reply: "Termin")
        XCTAssertEqual(result.action?.eventTitle, "Ablegen")
        XCTAssertEqual(result.action?.eventNotes, "Schwimmwesten prüfen")
    }

    func testCrewActionValidatesSkipperIDAndCanonicalRole() {
        let invalid = NautiAppAction(
            kind: .addCrewMember,
            skipperID: "x!",
            crewRole: "Navigator"
        )
        let valid = NautiAppAction(
            kind: .addCrewMember,
            skipperID: "jS0ZI3QxafXHco6imCDxVjSUWRq1",
            crewRole: "Navigator"
        )

        XCTAssertNil(NautiActionValidator.validate(invalid, reply: "Crew").action)
        XCTAssertEqual(
            NautiActionValidator.validate(valid, reply: "Crew").action?.crewRole,
            "Navigation"
        )
    }

    @MainActor
    func testDispatcherResolvesOnlyKnownConversationAndPersonalEvent() async {
        let store = CrewspaceStore(authTokenProvider: { "token" })
        store.merge(CrewspaceConversationDTO(
            id: "conversation-1",
            title: "Daniel",
            kind: "direct",
            memberIDs: ["self", "daniel-id"],
            memberNames: ["Test", "Daniel"],
            lastMessage: nil,
            lastMessageAt: nil,
            unreadCount: 0,
            updatedAt: .now
        ))

        let message = NautiAppAction(
            kind: .sendMessage,
            recipientKind: .direct,
            recipientQuery: "Daniel",
            messageText: "Moin"
        )
        let event = NautiAppAction(
            kind: .createEvent,
            eventTitle: "Ablegen",
            eventStartAt: "2026-07-16T14:10:00+02:00",
            eventEndAt: "2026-07-16T16:10:00+02:00"
        )

        let preparedMessage = await NautiCommandDispatcher.prepare(
            message,
            store: store,
            currentSkipperID: "self",
            activeGroupID: ""
        )
        guard case .pending(.sendMessage(let resolvedMessage)) = preparedMessage else {
            return XCTFail("Der bekannte Kontakt muss eindeutig vorbereitet werden.")
        }
        XCTAssertEqual(resolvedMessage.conversationID, "conversation-1")

        let preparedEvent = await NautiCommandDispatcher.prepare(
            event,
            store: store,
            currentSkipperID: "self",
            activeGroupID: ""
        )
        guard case .pending(.createEvent(let resolvedEvent)) = preparedEvent else {
            return XCTFail("Ein Termin ohne Empfänger muss persönlich bleiben.")
        }
        XCTAssertNil(resolvedEvent.conversationID)
        XCTAssertEqual(resolvedEvent.targetTitle, "Persönlicher Kalender")
    }

    func testManagerRejectsConcurrentInferenceAndCancelsActiveTask() async throws {
        let backend = BlockingLocalAIBackend()
        let manager = LocalAIInferenceManager(backend: backend)
        let request = sampleRequest()
        let first = Task { try await manager.infer(request) }

        for _ in 0..<200 {
            if await backend.didStart() { break }
            await Task.yield()
        }
        let didStart = await backend.didStart()
        XCTAssertTrue(didStart)

        do {
            _ = try await manager.infer(request)
            XCTFail("A second inference must be rejected while one is active")
        } catch let error as LocalAIInferenceError {
            XCTAssertEqual(error, .busy)
        }

        await manager.cancelCurrentInference()
        do {
            _ = try await first.value
            XCTFail("The active inference should have been cancelled")
        } catch let error as LocalAIInferenceError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testManagerReleasesBackendResources() async {
        let backend = BlockingLocalAIBackend()
        let manager = LocalAIInferenceManager(backend: backend)

        await manager.releaseResources()

        let releaseCount = await backend.releaseCount()
        XCTAssertEqual(releaseCount, 1)
    }

    func testManagerReleasesBackendAfterSuccessfulInference() async throws {
        let backend = SuccessfulLocalAIBackend()
        let manager = LocalAIInferenceManager(backend: backend)

        _ = try await manager.infer(sampleRequest())

        let releaseCount = await backend.releaseCount()
        XCTAssertEqual(releaseCount, 1)
    }

    @MainActor
    func testAccessControllerMapsLocalAvailability() async {
        let client = StaticLocalAIClient(
            availabilityValue: .unavailable(.appleIntelligenceNotEnabled),
            result: NautiInferenceResult(text: "", action: nil)
        )
        let controller = AIAccessController(inferenceClient: client)

        await controller.refresh()

        XCTAssertEqual(controller.state, .unavailable(.appleIntelligenceNotEnabled))
        XCTAssertFalse(controller.state.canUseAssistant)
    }

    @MainActor
    func testChatViewModelUsesInjectedLocalClient() async {
        let action = NautiAppAction(
            kind: .getTideSummary,
            harbourID: "juist_harbor",
            targetDate: "2026-07-13"
        )
        let client = StaticLocalAIClient(
            availabilityValue: .available,
            result: NautiInferenceResult(text: "Ich lade die Gezeiten.", action: action)
        )
        let viewModel = NautiChatViewModel(
            inferenceClient: client,
            repository: MemoryNautiConversationRepository()
        )
        viewModel.draft = "Wie sind morgen die Gezeiten auf Juist?"

        let returnedDispatch = await viewModel.sendCurrentDraft()

        XCTAssertEqual(returnedDispatch?.action, action)
        XCTAssertEqual(returnedDispatch?.conversationID, viewModel.activeConversationID)
        XCTAssertEqual(viewModel.messages.suffix(2).map(\.role), [.user, .assistant])
        XCTAssertEqual(viewModel.messages.last?.text, "Ich lade die Gezeiten.")
    }

    @MainActor
    func testChatHistoryIsBoundedToOneHundredMessages() {
        let viewModel = NautiChatViewModel(
            inferenceClient: StaticLocalAIClient(),
            repository: MemoryNautiConversationRepository()
        )

        for index in 0..<120 {
            viewModel.appendAssistantMessage("Antwort \(index)")
        }

        XCTAssertEqual(viewModel.messages.count, 100)
        XCTAssertEqual(viewModel.messages.first?.text, "Moin, ich bin Nauti. Wie kann ich dir helfen?")
        XCTAssertEqual(viewModel.messages.last?.text, "Antwort 119")
    }

    private func sampleRequest() -> NautiInferenceRequest {
        NautiInferenceRequest(messages: [
            NautiConversationMessage(role: .user, text: "Plane einen Törn.")
        ])
    }
}

private struct StaticLocalAIClient: LocalAIInferenceClient {
    let availabilityValue: LocalAIAvailability
    let result: NautiInferenceResult

    init(
        availabilityValue: LocalAIAvailability = .available,
        result: NautiInferenceResult = NautiInferenceResult(text: "Moin", action: nil)
    ) {
        self.availabilityValue = availabilityValue
        self.result = result
    }

    func availability() async -> LocalAIAvailability { availabilityValue }
    func infer(_ request: NautiInferenceRequest) async throws -> NautiInferenceResult { result }
    func cancelCurrentInference() async { }
    func releaseResources() async { }
}

private actor BlockingLocalAIBackend: LocalAIModelBackend {
    private var started = false
    private var releases = 0

    func availability() async -> LocalAIAvailability { .available }

    func infer(_ request: NautiInferenceRequest) async throws -> NautiInferenceResult {
        started = true
        try await Task.sleep(for: .seconds(30))
        return NautiInferenceResult(text: "Fertig", action: nil)
    }

    func releaseResources() async {
        releases += 1
    }

    func didStart() -> Bool { started }
    func releaseCount() -> Int { releases }
}

private actor SuccessfulLocalAIBackend: LocalAIModelBackend {
    private var releases = 0

    func availability() async -> LocalAIAvailability { .available }

    func infer(_ request: NautiInferenceRequest) async throws -> NautiInferenceResult {
        NautiInferenceResult(text: "Fertig", action: nil)
    }

    func releaseResources() async {
        releases += 1
    }

    func releaseCount() -> Int { releases }
}
