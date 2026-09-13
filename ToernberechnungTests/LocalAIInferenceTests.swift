import XCTest
@testable import Toernberechnung

final class LocalAIInferenceTests: XCTestCase {
    func testCrewspaceEditorRequestsRecognizeGermanCommands() {
        for text in ["Ich möchte ein Crewmitglied hinzufügen", "Füge ein Crewmitglied an Bord hinzu", "Crewmitglied anlegen"] {
            XCTAssertEqual(NautiDeterministicIntentRouter.crewspaceEditor(in: text), .crewMember, text)
        }
        for text in ["Ich möchte einen Termin hinzufügen", "Trage einen Termin ein", "Neuer Termin", "Erstelle ein Event", "Ich möchte ein Termin planen", "Ich möchte einen Termin planen", "Plane einen Termin für morgen", "Termin vereinbaren", "Ein Event organisieren"] {
            XCTAssertEqual(NautiDeterministicIntentRouter.crewspaceEditor(in: text), .event, text)
        }
        for text in ["Kein Crewmitglied hinzufügen", "Termin nicht anlegen", "Ich möchte keinen Termin planen", "Termin löschen", "Welche Termine habe ich?", "Wie wird das Wetter?"] {
            XCTAssertNil(NautiDeterministicIntentRouter.crewspaceEditor(in: text), text)
        }
    }

    func testLocalContextKeepsCurrentQuestionAndOnlyCompleteRecentMessages() throws {
        let question = "Was muss ich beim Trockenfallen mit 1,5 m Tiefgang beachten?"
        let request = NautiInferenceRequest(messages: [
            .init(role: .user, text: String(repeating: "a", count: 1_000)),
            .init(role: .assistant, text: String(repeating: "b", count: 800)),
            .init(role: .user, text: question)
        ])
        let result = try request.preparedForLocalModel()
        XCTAssertEqual(result.messages.map(\.text), [String(repeating: "b", count: 800), question])
        XCTAssertEqual(result.requestedAt, request.requestedAt)
        let retry = try request.preparedForLocalModel(historyCharacterLimit: 0)
        XCTAssertEqual(retry.messages.map(\.text), [question])
    }

    func testLocalContextRejectsOversizedQuestionRatherThanTruncatingIt() {
        let request = NautiInferenceRequest(messages: [
            .init(role: .user, text: String(repeating: "x", count: 2_001))
        ])
        XCTAssertThrowsError(try request.preparedForLocalModel()) { error in
            XCTAssertEqual(error as? LocalAIInferenceError, .contextTooLarge)
        }
    }

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

    func testAnswerFormattingRendersEmphasisAndSeparatesInlineHeadings() {
        let answer = NautiAnswerFormatting.attributed("Vorbereitung: 1. **Schiff**: prüfen. 2. **Crew**: einweisen.")
        XCTAssertEqual(String(answer.characters), "Vorbereitung:\n\n1. Schiff: prüfen.\n\n2. Crew: einweisen.")
        let values = "Tiefgang 1.5 m, Abfahrt 10.30 Uhr.\n\nReserve einplanen."
        XCTAssertEqual(String(NautiAnswerFormatting.attributed(values).characters), values)
    }

    func testKnowledgeQuestionsReachLanguageModel() {
        let questions = [
            "Erkläre mir die Gezeiten im Wattenmeer.",
            "Was ist der Tidenhub?",
            "Wie plane ich einen Törn im Wattenmeer?",
            "Wie bereite ich ein Törn vor?",
            "Wie bereite ich einen Törn im Wattenmeer vor?",
            "Welche Wetterzeichen muss ich beachten?",
            "Warum kentert der Strom nicht immer bei Hochwasser?",
            "Erläutere den Einfluss von Wind auf den Wasserstand.",
            "Was bedeutet Niedrigwasser für das Trockenfallen bei Juist?"
        ]
        for question in questions {
            let request = NautiInferenceRequest(messages: [.init(role: .user, text: question)])
            XCTAssertNil(NautiDeterministicIntentRouter.route(request), question)
        }
    }

    func testConcreteDataRequestsStillRouteDirectly() {
        let cases: [(String, NautiActionKind)] = [
            ("Wie ist das Wetter morgen auf Juist?", .getWeatherSummary),
            ("Gezeiten für Norderney heute", .getTideSummary),
            ("Wasserstand in Emden", .getWaterLevelSummary),
            ("Öffne den Wetterbereich für Juist", .showWeather)
        ]
        for (text, kind) in cases {
            let request = NautiInferenceRequest(messages: [.init(role: .user, text: text)])
            XCTAssertEqual(NautiDeterministicIntentRouter.route(request)?.action?.kind, kind, text)
        }
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
