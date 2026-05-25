import XCTest
@testable import Toernberechnung

/// Tests für `determineRouteStatus` – Aggregation der Wegpunkt-Status zur Route.
///
/// Prioritätsreihenfolge laut `RouteCalculationService.determineRouteStatus`:
/// invalid → noGo → incomplete → warning → go.
final class RouteStatusTests: XCTestCase {

    // EKR1

    func test_EKR1_invalidPresent_returnsNoGo() {
        let result = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .invalid, .go]
        )
        XCTAssertEqual(result, .noGo, "Invalid hat höchste Priorität → noGo")
    }

    // EKR2

    func test_EKR2_noGoPresent_returnsNoGo() {
        let result = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .warning, .noGo, .go]
        )
        XCTAssertEqual(result, .noGo)
    }

    // EKR3

    func test_EKR3_incompletePresent_returnsIncomplete() {
        let result = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .incomplete, .warning]
        )
        XCTAssertEqual(result, .incomplete)
    }

    // EKR4

    func test_EKR4_warningPresent_returnsWarning() {
        let result = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .warning, .go]
        )
        XCTAssertEqual(result, .warning)
    }

    // EKR5

    func test_EKR5_allGo_returnsGo() {
        let result = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .go, .go]
        )
        XCTAssertEqual(result, .go)
    }

    // EKR6 – Edge-Case leeres Array

    func test_EKR6_empty_returnsGo() {
        let result = RouteCalculationService.determineRouteStatus(waypointStatuses: [])
        XCTAssertEqual(result, .go, "Leere Eingabe fällt auf default 'go' durch – dokumentiertes Verhalten")
    }

    // Prioritätstests: invalid schlägt noGo

    func test_invalidBeatsNoGo() {
        let result = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.invalid, .noGo]
        )
        XCTAssertEqual(result, .noGo, "invalid → noGo gemäß Vertrag")
    }

    func test_noGoBeatsIncomplete() {
        let result = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.noGo, .incomplete]
        )
        XCTAssertEqual(result, .noGo)
    }

    func test_incompleteBeatsWarning() {
        let result = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.incomplete, .warning]
        )
        XCTAssertEqual(result, .incomplete)
    }
}
