import Foundation
import XCTest
@testable import Toernberechnung

/// The passage calculation the Excel tool cannot do: when is a constriction
/// open, and by how many centimetres does it miss when it is not.
final class PassageWindowSolverTests: XCTestCase {

    private let accuracy = 1e-9
    private let stationID = "TEST"
    private let highWater = Date(timeIntervalSince1970: 1_768_500_000)

    // MARK: - The inverse of the twelfths rule

    /// Budget → largest deviation. With MTH 2,40 one twelfth is 0,20 m.
    func testClosedFormInverseMatchesTheStaircase() {
        let strategy = TwelfthsRuleStrategy()
        let expectations: [(budget: Double, maxDeviation: Double?)] = [
            (-0.01, nil),   // not even at high water
            (0.00, 0),      // exactly at high water
            (0.19, 0),
            (0.20, 1),      // 1/12
            (0.35, 1),
            (0.60, 2),      // 3/12
            (1.20, 3),      // 6/12
            (1.80, 4),      // 9/12
            (2.20, 5),      // 11/12
            (2.40, 12),     // 12/12 — the whole cycle floats
            (5.00, 12)
        ]
        for expectation in expectations {
            let result = strategy.maxDeviationHours(
                forMaxMissingWaterMeters: expectation.budget,
                meanTidalRangeMeters: 2.4
            )
            if let expected = expectation.maxDeviation {
                XCTAssertEqual(
                    result ?? .nan, expected, accuracy: accuracy,
                    "Budget \(expectation.budget) m"
                )
            } else {
                XCTAssertNil(result, "Budget \(expectation.budget) m")
            }
        }
    }

    /// Property test: the closed form and the forward rule must agree on every
    /// deviation, otherwise a window would claim water that is not there.
    func testInverseAgreesWithForwardRuleAcrossRandomInputs() {
        let strategy = TwelfthsRuleStrategy()
        var generator = SystemRandomNumberGenerator()

        for _ in 0 ..< 500 {
            let mth = Double.random(in: 0.5 ... 5.0, using: &generator)
            let budget = Double.random(in: 0 ... 5.0, using: &generator)
            guard let maxDeviation = strategy.maxDeviationHours(
                forMaxMissingWaterMeters: budget,
                meanTidalRangeMeters: mth
            ) else { continue }

            // Inside the window the budget must hold …
            let inside = strategy.missingWater(
                deviationHours: maxDeviation,
                meanTidalRangeMeters: mth
            )
            XCTAssertTrue(inside.isValid)
            XCTAssertLessThanOrEqual(
                inside.fmwMeters, budget + 1e-9,
                "MTH \(mth), Budget \(budget): Fenster verspricht zu viel Wasser"
            )

            // … and just outside it must break, unless the whole cycle floats.
            //
            // The probe steps beyond `hwEpsilonHours`, because a window of zero
            // means "only at high water" and anything inside the epsilon is
            // still treated as exactly high water by design.
            if maxDeviation < 12 {
                let outside = strategy.missingWater(
                    deviationHours: maxDeviation + 0.02,
                    meanTidalRangeMeters: mth
                )
                XCTAssertGreaterThan(
                    outside.fmwMeters, budget - 1e-9,
                    "MTH \(mth), Budget \(budget): Fenster ist zu klein"
                )
            }
        }
    }

    // MARK: - Bottleneck windows

    /// Lottiefe 1,45 − Tiefgang 1,10 = 0,35 m Budget; MTH 2,40 ⇒ 1/12 = 0,20 m.
    /// Because 0,20 ≤ 0,35 < 0,60, the passable deviation is exactly one hour.
    func testBottleneckWindowIsHighWaterPlusMinusTheAnalyticDeviation() async {
        let solution = await solve(lottiefe: 1.45, meanTidalRange: 2.4, distanceNm: 0)
        let bottleneck = solution.bottlenecks.first

        XCTAssertEqual(bottleneck?.arrivalWindow?.lowerBound, highWater.addingTimeInterval(-3_600))
        XCTAssertEqual(bottleneck?.arrivalWindow?.upperBound, highWater.addingTimeInterval(3_600))
        // Without travel time, arrival and departure windows coincide.
        XCTAssertEqual(bottleneck?.departureWindow, bottleneck?.arrivalWindow)
        XCTAssertEqual(bottleneck?.category, "Wattenhoch")
        XCTAssertTrue(bottleneck?.isPassableAtPlannedTime ?? false)
    }

    /// The departure window is the arrival window shifted back by the travel
    /// time — valid because SOG does not depend on the departure time.
    func testDepartureWindowIsShiftedByTheTravelTime() async {
        // 12 sm at 6 kn = 2 h to the second waypoint.
        let solution = await solve(lottiefe: 1.45, meanTidalRange: 2.4, distanceNm: 12)
        guard solution.bottlenecks.count == 2 else {
            return XCTFail("Es müssen zwei Engstellen ausgewertet werden")
        }

        let second = solution.bottlenecks[1]
        XCTAssertEqual(second.travelOffsetHours, 2, accuracy: accuracy)
        XCTAssertEqual(
            second.departureWindow?.lowerBound,
            second.arrivalWindow?.lowerBound.addingTimeInterval(-7_200)
        )
        XCTAssertEqual(
            second.departureWindow?.upperBound,
            second.arrivalWindow?.upperBound.addingTimeInterval(-7_200)
        )
    }

    /// The route window is the intersection of all bottleneck windows.
    func testRouteWindowIsTheIntersectionOfAllBottlenecks() async {
        // 6 sm at 6 kn ⇒ the second waypoint is reached one hour later.
        let solution = await solve(lottiefe: 1.45, meanTidalRange: 2.4, distanceNm: 6)
        let window = solution.routeWindow

        // Both waypoints float HW ± 1 h. For WP2 that span has to be entered an
        // hour earlier, so its departure window is HW − 2 h … HW. Intersected
        // with WP1's HW − 1 h … HW + 1 h this leaves HW − 1 h … HW.
        XCTAssertEqual(window?.start, highWater.addingTimeInterval(-3_600))
        XCTAssertEqual(window?.end, highWater)
        XCTAssertFalse(solution.hasInvalidLeg)
    }

    /// Bottleneck windows that do not overlap close the route entirely.
    func testNonOverlappingBottlenecksLeaveNoRouteWindow() async {
        // 18 sm at 6 kn ⇒ three hours of travel. WP1 must be left within
        // HW ± 1 h, but WP2 then demands a departure in HW − 4 h … HW − 2 h.
        let solution = await solve(lottiefe: 1.45, meanTidalRange: 2.4, distanceNm: 18)

        XCTAssertNil(solution.routeWindow)
        XCTAssertEqual(solution.bottlenecks.count, 2)
        XCTAssertNotNil(solution.bottlenecks[0].departureWindow)
        XCTAssertNotNil(solution.bottlenecks[1].departureWindow)
    }

    /// A waypoint that never floats closes the whole route.
    func testWaypointThatNeverFloatsYieldsNoWindowAndReportsTheShortfall() async {
        // Lottiefe 0,80 m with a 1,10 m draft: 0,30 m missing even at high water.
        let solution = await solve(lottiefe: 0.80, meanTidalRange: 2.4, distanceNm: 0)

        XCTAssertNil(solution.routeWindow)
        let bottleneck = solution.bottlenecks.first
        XCTAssertNil(bottleneck?.arrivalWindow)
        XCTAssertFalse(bottleneck?.isPassableAtPlannedTime ?? true)
        XCTAssertEqual(bottleneck?.shortfallMeters ?? .nan, 0.30, accuracy: 1e-9)
        XCTAssertEqual(bottleneck?.plannedClearanceMeters ?? .nan, -0.30, accuracy: 1e-9)
    }

    func testLimitingBottleneckIsTheOneWithTheLeastWater() async {
        let solution = await solve(
            lottiefe: 1.45,
            meanTidalRange: 2.4,
            distanceNm: 0,
            secondLottiefe: 1.20
        )
        XCTAssertEqual(solution.limiting?.waypointName, "WP 2")
        XCTAssertEqual(solution.routeWindow?.bottleneckName, "WP 2")
    }

    func testInvalidLegProducesNoWindowAtAll() async {
        let solution = await solve(
            lottiefe: 1.45,
            meanTidalRange: 2.4,
            distanceNm: 10,
            speedKnots: 2,
            currentKnots: -3
        )
        XCTAssertTrue(solution.hasInvalidLeg)
        XCTAssertNil(solution.routeWindow)
        XCTAssertTrue(solution.bottlenecks.isEmpty)
    }

    // MARK: - The performance guarantee

    /// The permanent lock against the return of the brute-force scan: the old
    /// implementation recalculated the whole route for every candidate time,
    /// which meant up to 217 tide lookups **per waypoint**. One lookup per
    /// waypoint is the whole point of the solver.
    func testSolverResolvesTideDataOncePerWaypoint() async {
        let provider = MockTideDataProvider()
        provider.correctionsByStation[stationID] = manualCorrection()
        provider.highWatersByStation[stationID] = [
            TideEvent(time: highWater, heightMeters: 3.0, type: "HW", phase: nil)
        ]

        var waypoints: [RouteWaypoint] = []
        for index in 0 ..< 6 {
            waypoints.append(makeWaypoint(
                name: "WP \(index + 1)",
                lottiefe: 1.45,
                meanTidalRange: 2.4,
                manualHighWaterTime: nil     // forces a provider lookup
            ))
        }
        let legs = (0 ..< 5).map { index in
            RouteLeg(
                id: UUID(),
                fromWaypointID: waypoints[index].id,
                toWaypointID: waypoints[index + 1].id,
                distanceNm: 6, courseDegrees: nil,
                speedThroughWaterKnots: 6, tidalCurrentKnots: 0
            )
        }
        let route = RoutePlan(
            id: UUID(), date: highWater, routeName: "Sechs Wegepunkte",
            plannedStartTime: highWater, waypoints: waypoints, legs: legs,
            bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mitteltide"
        )

        _ = await PassageWindowSolver().solve(
            route: route,
            boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0),
            tideDataProvider: provider
        )

        XCTAssertEqual(
            provider.highWatersCallCount[stationID], 6,
            "Der Löser darf die Gezeitendaten genau einmal je Wegepunkt anfordern"
        )
    }

    // MARK: - Fixture

    private func manualCorrection() -> WaterLevelCorrectionResolution {
        WaterLevelCorrectionResolution(
            meters: 0, quality: .manual,
            localStationID: stationID, sourceStationID: nil, sourceStationName: nil,
            issuedAt: nil, detail: "Manuell."
        )
    }

    private func makeWaypoint(
        name: String,
        lottiefe: Double,
        meanTidalRange: Double,
        manualHighWaterTime: Date?
    ) -> RouteWaypoint {
        RouteWaypoint(
            id: UUID(), name: name, latitude: 53.7, longitude: 7.2,
            tidalReferenceStation: "Testpegel", tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: meanTidalRange, source: .manual, sourceNotes: nil),
            meanHighWaterMeters: nil,
            lottiefeMeters: SourcedValue(value: lottiefe, source: .manual, sourceNotes: nil),
            chartDepthMeters: nil,
            calculationMode: .lottiefe,
            bshWaterLevelCorrectionOverride: 0,
            manualHighWaterTime: manualHighWaterTime,
            notes: "", category: "Wattenhoch", island: nil
        )
    }

    private func solve(
        lottiefe: Double,
        meanTidalRange: Double,
        distanceNm: Double,
        secondLottiefe: Double? = nil,
        speedKnots: Double = 6,
        currentKnots: Double = 0
    ) async -> PassageWindowSolver.Solution {
        let first = makeWaypoint(
            name: "WP 1", lottiefe: lottiefe,
            meanTidalRange: meanTidalRange, manualHighWaterTime: highWater
        )
        let second = makeWaypoint(
            name: "WP 2", lottiefe: secondLottiefe ?? lottiefe,
            meanTidalRange: meanTidalRange, manualHighWaterTime: highWater
        )
        let leg = RouteLeg(
            id: UUID(), fromWaypointID: first.id, toWaypointID: second.id,
            distanceNm: distanceNm, courseDegrees: nil,
            speedThroughWaterKnots: speedKnots, tidalCurrentKnots: currentKnots
        )
        let route = RoutePlan(
            id: UUID(), date: highWater, routeName: "Test",
            plannedStartTime: highWater, waypoints: [first, second], legs: [leg],
            bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mitteltide"
        )

        return await PassageWindowSolver().solve(
            route: route,
            boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0),
            tideDataProvider: MockTideDataProvider()
        )
    }
}
