import XCTest
@testable import Toernberechnung

final class TideNodeNautiStateTests: XCTestCase {
    private let departure = Date(timeIntervalSince1970: 1_725_000_000)

    func testAppearanceOffersOnlyLightAndDarkAndMigratesSystemToLight() {
        XCTAssertEqual(AppAppearanceMode.allCases, [.light, .dark])
        XCTAssertEqual(AppAppearanceMode.resolved(from: "system"), .light)
        XCTAssertEqual(AppAppearanceMode.resolved(from: "dark"), .dark)
    }

    func testSafeRouteInsidePassageWindowDoesNotCreateProactiveIssue() {
        let window = PassageWindowScanner.Window(
            start: departure.addingTimeInterval(-900),
            end: departure.addingTimeInterval(900),
            anchoredHighWater: nil,
            bottleneckName: nil
        )

        let issue = NautiProactiveIssueResolver.resolve(
            routeStatus: .go,
            weatherStatus: .go,
            routeTitle: "Emden - Norderney",
            departure: departure,
            passageWindow: window
        )

        XCTAssertNil(issue)
    }

    func testWeatherNoGoCreatesWeatherFocusedIssue() {
        let issue = NautiProactiveIssueResolver.resolve(
            routeStatus: .noGo,
            weatherStatus: .noGo,
            routeTitle: "Emden - Norderney",
            departure: departure,
            passageWindow: nil
        )

        XCTAssertEqual(issue?.id, "weather-no-go")
        XCTAssertEqual(issue?.primaryAction, .showWeather)
        XCTAssertEqual(issue?.secondaryAction, .openPlanner)
    }

    func testTidalNoGoCreatesRouteFocusedIssue() {
        let issue = NautiProactiveIssueResolver.resolve(
            routeStatus: .noGo,
            weatherStatus: .go,
            routeTitle: "Emden - Norderney",
            departure: departure,
            passageWindow: nil
        )

        XCTAssertEqual(issue?.accent, .red)
        XCTAssertEqual(issue?.primaryAction, .showPassageWindow)
    }

    func testUnsafeDepartureSuggestsStartOfPassageWindow() {
        let suggestedDeparture = departure.addingTimeInterval(3_600)
        let window = PassageWindowScanner.Window(
            start: suggestedDeparture,
            end: suggestedDeparture.addingTimeInterval(7_200),
            anchoredHighWater: nil,
            bottleneckName: "Nadelöhr"
        )

        let issue = NautiProactiveIssueResolver.resolve(
            routeStatus: .go,
            weatherStatus: .go,
            routeTitle: "Emden - Norderney",
            departure: departure,
            passageWindow: window
        )

        XCTAssertEqual(issue?.accent, .amber)
        guard case let .adoptSuggestedDeparture(value)? = issue?.secondaryAction else {
            return XCTFail("Expected a suggested departure action")
        }
        XCTAssertEqual(value, suggestedDeparture)
    }

    func testAssistantAccessCanBeGatedWithoutAffectingManualWorkflow() {
        XCTAssertTrue(AIAccessState.available.canUseAssistant)
        XCTAssertFalse(AIAccessState.locked.canUseAssistant)
        XCTAssertFalse(AIAccessState.unavailable(.deviceNotEligible).canUseAssistant)
    }

    @MainActor
    func testRoutePlannerStartsWithoutPreselectedHarboursOrRoute() {
        let viewModel = RoutePlannerViewModel()

        XCTAssertEqual(viewModel.startHarbourID, "")
        XCTAssertEqual(viewModel.destinationHarbourID, "")
        XCTAssertFalse(viewModel.hasCompleteRouteInput)
        XCTAssertNil(viewModel.routePlan)
        XCTAssertEqual(viewModel.routeTitle, "Törn noch nicht geplant")
    }

    @MainActor
    func testIntermediateStopsCanBePreparedBeforeRouteEndpoints() throws {
        let harbours = HarbourOption.options
        XCTAssertGreaterThanOrEqual(harbours.count, 2)
        let viewModel = RoutePlannerViewModel()

        let added = viewModel.addIntermediateStops(harbourIDs: [harbours[1].id, harbours[0].id])

        XCTAssertEqual(added, 2)
        XCTAssertEqual(viewModel.intermediateStops.map(\.harbourID), [harbours[1].id, harbours[0].id])
        XCTAssertFalse(viewModel.hasCompleteRouteInput)
        XCTAssertNil(viewModel.routePlan)
    }

    @MainActor
    func testIntermediateStopBatchPreservesOrderAndFiltersInvalidOrUnavailableHarbours() throws {
        let harbours = HarbourOption.options
        XCTAssertGreaterThanOrEqual(harbours.count, 4)
        let viewModel = RoutePlannerViewModel()
        viewModel.startHarbourID = harbours[0].id
        viewModel.destinationHarbourID = harbours[1].id

        let added = viewModel.addIntermediateStops(harbourIDs: [
            harbours[0].id,
            harbours[3].id,
            "unknown-harbour",
            harbours[2].id,
            harbours[3].id,
            harbours[1].id
        ])

        XCTAssertEqual(added, 2)
        XCTAssertEqual(viewModel.intermediateStops.map(\.harbourID), [harbours[3].id, harbours[2].id])
    }

    @MainActor
    func testSelectingEndpointsRemovesPreparedStopCollisionsInOrder() throws {
        let harbours = HarbourOption.options
        XCTAssertGreaterThanOrEqual(harbours.count, 3)
        let viewModel = RoutePlannerViewModel()
        viewModel.addIntermediateStops(harbourIDs: [harbours[0].id, harbours[1].id, harbours[2].id])

        viewModel.startHarbourID = harbours[1].id

        XCTAssertEqual(
            viewModel.intermediateStops.map(\.harbourID),
            [harbours[0].id, harbours[2].id]
        )

        viewModel.destinationHarbourID = harbours[0].id

        XCTAssertEqual(viewModel.intermediateStops.map(\.harbourID), [harbours[2].id])
        XCTAssertEqual(Set(
            [viewModel.startHarbourID, viewModel.destinationHarbourID]
                + viewModel.intermediateStops.map(\.harbourID)
        ).count, 3)
    }

    @MainActor
    func testUpdatingIntermediateStopRejectsUnknownEndpointsAndDuplicates() throws {
        let harbours = HarbourOption.options
        XCTAssertGreaterThanOrEqual(harbours.count, 5)
        let viewModel = RoutePlannerViewModel()
        viewModel.startHarbourID = harbours[0].id
        viewModel.destinationHarbourID = harbours[1].id
        viewModel.addIntermediateStops(harbourIDs: [harbours[2].id, harbours[3].id])
        let firstStopID = try XCTUnwrap(viewModel.intermediateStops.first?.id)
        let originalIDs = viewModel.intermediateStops.map(\.harbourID)

        XCTAssertFalse(viewModel.updateIntermediateStop(id: firstStopID, to: "unknown-harbour"))
        XCTAssertFalse(viewModel.updateIntermediateStop(id: firstStopID, to: harbours[0].id))
        XCTAssertFalse(viewModel.updateIntermediateStop(id: firstStopID, to: harbours[1].id))
        XCTAssertFalse(viewModel.updateIntermediateStop(id: firstStopID, to: harbours[3].id))
        XCTAssertFalse(viewModel.updateIntermediateStop(id: UUID(), to: harbours[4].id))
        XCTAssertEqual(viewModel.intermediateStops.map(\.harbourID), originalIDs)

        XCTAssertTrue(viewModel.updateIntermediateStop(id: firstStopID, to: harbours[4].id))
        XCTAssertEqual(
            viewModel.intermediateStops.map(\.harbourID),
            [harbours[4].id, harbours[3].id]
        )
    }

    func testManualLogbookDraftRequiresACompleteRoute() {
        var draft = LogbookEntryDraft()
        XCTAssertFalse(draft.isValid)

        draft.startName = "Emden, Hafen"
        draft.destinationName = "Norderney, Hafen"
        draft.distanceNM = 21.4

        XCTAssertTrue(draft.isValid)
    }

    func testLogbookDraftCopiesAnExistingEntryForEditing() {
        let record = CalculationRecord(
            routeTitle: "Abendtörn",
            startName: "Juist, Hafen",
            destinationName: "Norderney, Hafen",
            departureAt: departure,
            arrivalAt: departure.addingTimeInterval(5_400),
            distanceNM: 11.8,
            status: "Fahrt abgeschlossen",
            fmw: 0.2,
            wt: 2.4,
            wuk: 1.1,
            weatherSummary: "West 4",
            tideSummary: "Steigend",
            crewSummary: "2 Personen",
            notes: "Ruhige Fahrt",
            isActualVoyage: true,
            actualDistanceNM: 12.1,
            averageSOGKnots: 5.2,
            maxSOGKnots: 7.0,
            voyageDurationSeconds: 5_400,
            breadcrumbJSON: "[]"
        )

        let draft = LogbookEntryDraft(record: record)

        XCTAssertEqual(draft.routeTitle, "Abendtörn")
        XCTAssertEqual(draft.startName, "Juist, Hafen")
        XCTAssertEqual(draft.destinationName, "Norderney, Hafen")
        XCTAssertEqual(draft.weatherSummary, "West 4")
        XCTAssertEqual(draft.notes, "Ruhige Fahrt")
        XCTAssertTrue(draft.isValid)
        XCTAssertTrue(record.isActualVoyage)
        XCTAssertEqual(record.actualDistanceNM, 12.1)
        XCTAssertEqual(record.breadcrumbJSON, "[]")
    }
}
