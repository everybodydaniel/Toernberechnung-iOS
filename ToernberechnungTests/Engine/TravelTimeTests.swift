import XCTest
@testable import Toernberechnung

/// Tests für die statischen Geschwindigkeits-/Reisezeit-Funktionen.
final class TravelTimeTests: XCTestCase {

    // MARK: - calculateSpeedOverGround

    func test_SOG_simpleAddition() {
        XCTAssertEqual(
            RouteCalculationService.calculateSpeedOverGround(speedThroughWaterKnots: 6, tidalCurrentKnots: 1.5),
            7.5
        )
    }

    func test_SOG_negativeCurrent_reducesSOG() {
        XCTAssertEqual(
            RouteCalculationService.calculateSpeedOverGround(speedThroughWaterKnots: 6, tidalCurrentKnots: -2),
            4
        )
    }

    func test_SOG_currentExceedsSTW_resultsInNegative() {
        let sog = RouteCalculationService.calculateSpeedOverGround(speedThroughWaterKnots: 4, tidalCurrentKnots: -5)
        XCTAssertEqual(sog, -1)
    }

    // MARK: - calculateTravelTimeHours (Äquivalenzklassen)

    // EKT1: SOG < 0 → nil
    func test_EKT1_negativeSOG_returnsNil() {
        XCTAssertNil(RouteCalculationService.calculateTravelTimeHours(distanceNm: 10, speedOverGroundKnots: -1))
    }

    // EKT2: SOG = 0 → nil
    func test_EKT2_zeroSOG_returnsNil() {
        XCTAssertNil(RouteCalculationService.calculateTravelTimeHours(distanceNm: 10, speedOverGroundKnots: 0))
    }

    // EKT3: distance > 0, SOG > 0 → korrekter Wert
    func test_EKT3_validInput_returnsDistanceOverSOG() throws {
        let time = try XCTUnwrap(RouteCalculationService.calculateTravelTimeHours(distanceNm: 12, speedOverGroundKnots: 6))
        XCTAssertEqual(time, 2.0, accuracy: 1e-9)
    }

    // EKT4: distance = 0, SOG > 0 → 0
    func test_EKT4_zeroDistance_returnsZero() throws {
        let time = try XCTUnwrap(RouteCalculationService.calculateTravelTimeHours(distanceNm: 0, speedOverGroundKnots: 6))
        XCTAssertEqual(time, 0, accuracy: 1e-9)
    }

    // EKT5: distance < 0 (untypisch) → negativer Wert (dokumentiert)
    func test_EKT5_negativeDistance_returnsNegativeTime() throws {
        let time = try XCTUnwrap(RouteCalculationService.calculateTravelTimeHours(distanceNm: -5, speedOverGroundKnots: 5))
        XCTAssertEqual(time, -1.0, accuracy: 1e-9,
                       "Vertrag akzeptiert negative Distanz, Aufrufer muss validieren")
    }

    // Grenzwert: extrem kleine SOG → extrem große Zeit
    func test_boundary_tinyButPositiveSOG_returnsLargeTime() {
        let time = RouteCalculationService.calculateTravelTimeHours(distanceNm: 10, speedOverGroundKnots: 0.0001)
        XCTAssertEqual(time ?? 0, 100_000, accuracy: 1)
    }

    // MARK: - calculateLegResults

    func test_legResults_chainsArrivalTimesCorrectly() {
        let start = TestFixtures.berlinDate("2026-05-25 09:00")
        let legs = [
            RouteLeg(id: UUID(), fromWaypointID: UUID(), toWaypointID: UUID(),
                     distanceNm: 6, courseDegrees: nil,
                     speedThroughWaterKnots: 6, tidalCurrentKnots: 0),
            RouteLeg(id: UUID(), fromWaypointID: UUID(), toWaypointID: UUID(),
                     distanceNm: 3, courseDegrees: nil,
                     speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        ]

        let results = RouteCalculationService.calculateLegResults(startTime: start, legs: legs)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].isValid)
        XCTAssertEqual(results[0].travelTimeHours, 1.0, accuracy: 1e-6)
        XCTAssertEqual(results[1].travelTimeHours, 0.5, accuracy: 1e-6)
        XCTAssertEqual(results[1].cumulativeTravelTimeHours, 1.5, accuracy: 1e-6)
        XCTAssertEqual(results[1].cumulativeDistanceNm, 9, accuracy: 1e-6)
        XCTAssertEqual(results[1].arrivalTime.timeIntervalSince(start), 1.5 * 3600, accuracy: 1)
    }

    func test_legResults_invalidLeg_markedAsInvalidAndAddsMessage() {
        let legs = [
            RouteLeg(id: UUID(), fromWaypointID: UUID(), toWaypointID: UUID(),
                     distanceNm: 6, courseDegrees: nil,
                     speedThroughWaterKnots: 3, tidalCurrentKnots: -3)  // SOG=0 → ungültig
        ]
        let results = RouteCalculationService.calculateLegResults(startTime: Date(), legs: legs)

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isValid)
        XCTAssertEqual(results[0].travelTimeHours, 0)
        XCTAssertFalse(results[0].messages.isEmpty)
    }
}
