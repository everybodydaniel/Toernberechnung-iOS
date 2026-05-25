import XCTest
@testable import Toernberechnung

/// Leichte Tests für `RoutePlannerViewModel`: rein die abgeleiteten Zustände
/// (Statustexte, Befahrbarkeit, Multi-Wegpunkt-Erkennung), ohne die asynchrone
/// Berechnungs-Pipeline zu starten.
final class RoutePlannerViewModelTests: XCTestCase {

    // MARK: - Abgeleitete Zustände

    func test_statusText_whenCalculationResultIsNil_showsRunning() {
        let vm = RoutePlannerViewModel()
        XCTAssertEqual(vm.statusText, "Berechnung läuft…")
    }

    func test_isPassable_falseWhenNoResult() {
        let vm = RoutePlannerViewModel()
        XCTAssertFalse(vm.isPassable)
    }

    func test_routeTitle_combinesHarbourNames() {
        let vm = RoutePlannerViewModel()
        let title = vm.routeTitle
        XCTAssertTrue(title.contains("→"))
        XCTAssertTrue(title.contains(vm.startHarbour.name))
        XCTAssertTrue(title.contains(vm.destinationHarbour.name))
    }

    func test_isMultiWaypoint_falseForEmptyOrTwoPointRoute() {
        let vm = RoutePlannerViewModel()
        XCTAssertFalse(vm.isMultiWaypoint, "Ohne Routenplan: kein Multi-Wegpunkt")

        let wp = RouteFactory.mhwWaypoint()
        vm.routePlan = RouteFactory.twoPointRoute(from: wp, to: wp)
        XCTAssertFalse(vm.isMultiWaypoint, "Zweipunkt-Route: kein Multi-Wegpunkt")
    }

    func test_isMultiWaypoint_trueForThreePoints() {
        let vm = RoutePlannerViewModel()
        let wp1 = RouteFactory.mhwWaypoint(name: "A")
        let wp2 = RouteFactory.mhwWaypoint(name: "B")
        let wp3 = RouteFactory.mhwWaypoint(name: "C")
        let legs = [
            RouteLeg(id: UUID(), fromWaypointID: wp1.id, toWaypointID: wp2.id,
                     distanceNm: 1, courseDegrees: nil,
                     speedThroughWaterKnots: 6, tidalCurrentKnots: 0),
            RouteLeg(id: UUID(), fromWaypointID: wp2.id, toWaypointID: wp3.id,
                     distanceNm: 1, courseDegrees: nil,
                     speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        ]
        vm.routePlan = RoutePlan(
            id: UUID(), date: Date(),
            routeName: "Multi", plannedStartTime: Date(),
            waypoints: [wp1, wp2, wp3], legs: legs,
            bshWaterLevelCorrectionMeters: 0, tidalStateLabel: "Mitteltide"
        )
        XCTAssertTrue(vm.isMultiWaypoint)
    }

    // MARK: - combinedStatus

    func test_combinedStatus_combinesTidalAndWeather() {
        let vm = RoutePlannerViewModel()
        vm.weatherStatus = .warning
        vm.calculationResult = RouteCalculationResult(
            waypointResults: [], legResults: [],
            totalDistanceNm: 0, totalTravelTimeHours: 0,
            worstClearanceUnderKeel: nil,
            tidalStatus: .go, weatherStatus: .incomplete,
            combinedStatus: .go,
            messages: []
        )
        XCTAssertEqual(vm.combinedStatus, .warning,
                       "ViewModel kombiniert tide=go + weather=warning → warning")
    }
}
