import Foundation
import CoreLocation
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

    /// Lottiefe 1,45 − Tiefgang 1,10 = 0,35 m Budget; MTH 2,40 ⇒ 1/12 = 0,20 m, 3/12 = 0,60 m.
    /// Android scan: the last safe ten-minute sample is HW +/- 80 minutes.
    func testBottleneckWindowUsesAndroidTenMinuteSamples() async {
        let solution = await solve(lottiefe: 1.45, meanTidalRange: 2.4, distanceNm: 0)
        let bottleneck = solution.bottlenecks.first

        XCTAssertEqual(bottleneck?.arrivalWindow?.lowerBound, highWater.addingTimeInterval(-4_800))
        XCTAssertEqual(bottleneck?.arrivalWindow?.upperBound, highWater.addingTimeInterval(4_800))
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

        // Android's ten-minute scan intersects WP1 [-80, +80] minutes
        // and WP2 [-140, +20] minutes, giving [-80, +20].
        XCTAssertEqual(window?.start, highWater.addingTimeInterval(-4_800))
        XCTAssertEqual(window?.end, highWater.addingTimeInterval(1_200))
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

    func testReportedBottleneckTimeIsArrivalAtTheConstriction() async throws {
        // Six nautical miles at six knots put the limiting second waypoint one
        // hour after the recommended departure.
        let solution = await solve(
            lottiefe: 1.45,
            meanTidalRange: 2.4,
            distanceNm: 6,
            secondLottiefe: 1.20
        )
        let window = try XCTUnwrap(solution.routeWindow)

        XCTAssertEqual(window.bottleneckName, "WP 2")
        XCTAssertEqual(
            try XCTUnwrap(window.bottleneckArrival),
            window.recommendedDeparture.addingTimeInterval(3_600)
        )
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

    // MARK: - Safety Margin, Completeness, and Window Selection (Regressions)

    func testSafetyMarginExcludesBorderlineTimes() async {
        let first = makeWaypoint(name: "WP 1", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: highWater)
        let second = makeWaypoint(name: "WP 2", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: highWater)
        let leg = RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id, distanceNm: 0,
                           courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let route = RoutePlan(id: UUID(), date: highWater, routeName: "Margin Test", plannedStartTime: highWater,
                              waypoints: [first, second], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt")

        let solution0 = await PassageWindowSolver().solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0),
            tideDataProvider: MockTideDataProvider()
        )
        let solution30 = await PassageWindowSolver().solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.30),
            tideDataProvider: MockTideDataProvider()
        )

        guard let window0 = solution0.routeWindow, let window30 = solution30.routeWindow else {
            return XCTFail("Beide Fenster müssen berechenbar sein")
        }

        XCTAssertEqual(window0.start, highWater.addingTimeInterval(-4_800))
        XCTAssertEqual(window0.end, highWater.addingTimeInterval(4_800))

        XCTAssertEqual(window30.start, highWater.addingTimeInterval(-600))
        XCTAssertEqual(window30.end, highWater.addingTimeInterval(600))

        // HW +/- 1 h (3600 s) is inside window0, but strictly excluded from window30.
        let oneHourBefore = highWater.addingTimeInterval(-3_600)
        XCTAssertTrue(window0.contains(oneHourBefore))
        XCTAssertFalse(window30.contains(oneHourBefore))
    }

    func testForecastCoverageBoundaryDoesNotSplitOnePhysicalWindow() async throws {
        let provider = MockTideDataProvider()
        provider.highWatersByStation[stationID] = [
            TideEvent(time: highWater, heightMeters: 3.0, type: "HW", phase: nil)
        ]
        let fallback = WaterLevelCorrectionResolution(
            meters: 0, quality: .modelForecast,
            localStationID: stationID, sourceStationID: nil, sourceStationName: nil,
            issuedAt: highWater, detail: "Testprognose"
        )
        provider.correctionSeriesByStation[stationID] = WaterLevelCorrectionSeries(
            samples: [
                .init(time: highWater.addingTimeInterval(-1_800), meters: 0, quality: .modelForecast),
                .init(time: highWater.addingTimeInterval(1_800), meters: 0, quality: .modelForecast)
            ],
            fallback: fallback
        )

        var first = makeWaypoint(name: "WP 1", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        var second = makeWaypoint(name: "WP 2", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        first.bshWaterLevelCorrectionOverride = nil
        second.bshWaterLevelCorrectionOverride = nil
        let leg = RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id, distanceNm: 0,
                           courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let route = RoutePlan(id: UUID(), date: highWater, routeName: "Coverage Boundary", plannedStartTime: highWater,
                              waypoints: [first, second], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt")

        let solution = await PassageWindowSolver().solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0),
            tideDataProvider: provider
        )
        let window = try XCTUnwrap(solution.routeWindow)

        XCTAssertEqual(solution.routeWindows.count, 1)
        XCTAssertEqual(window.start.timeIntervalSince(highWater), -4_800, accuracy: 0.01)
        XCTAssertEqual(window.end.timeIntervalSince(highWater), 4_800, accuracy: 0.01)
    }

    func testMissingWaypointFailsEntireWindowAndReportsMissing() async {
        let first = makeWaypoint(name: "WP 1", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: highWater)
        var second = makeWaypoint(name: "WP 2", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: highWater)
        second.lottiefeMeters = nil
        second.chartDepthMeters = nil

        let leg = RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id, distanceNm: 0,
                           courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let route = RoutePlan(id: UUID(), date: highWater, routeName: "Missing Test", plannedStartTime: highWater,
                              waypoints: [first, second], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt")

        let solution = await PassageWindowSolver().solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0),
            tideDataProvider: MockTideDataProvider()
        )

        XCTAssertNil(solution.routeWindow)
        XCTAssertTrue(solution.routeWindows.isEmpty)
        XCTAssertEqual(solution.missingWaypointNames, ["WP 2"])
    }

    func testMultipleHighWatersReturnAllWindowsAndSelectTheCurrentOne() async {
        let hw1 = highWater
        let hw2 = highWater.addingTimeInterval(12.4 * 3_600)
        let provider = MockTideDataProvider()
        provider.highWatersByStation[stationID] = [
            TideEvent(time: hw1, heightMeters: 3.0, type: "HW", phase: nil),
            TideEvent(time: hw2, heightMeters: 3.0, type: "HW", phase: nil)
        ]
        provider.correctionsByStation[stationID] = manualCorrection()

        let first = makeWaypoint(name: "WP 1", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let second = makeWaypoint(name: "WP 2", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let leg = RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id, distanceNm: 0,
                           courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let route = RoutePlan(id: UUID(), date: hw1, routeName: "Two Tides", plannedStartTime: hw1,
                              waypoints: [first, second], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt")

        var config = PassageWindowSolver.Configuration()
        config.dayBased = false
        config.searchBackwardHours = 2
        config.searchForwardHours = 16

        let solution = await PassageWindowSolver(configuration: config).solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0),
            tideDataProvider: provider
        )

        XCTAssertEqual(solution.routeWindows.count, 2)
        XCTAssertEqual(solution.routeWindows.first, solution.routeWindow)
        XCTAssertEqual(solution.routeWindow?.anchoredHighWater, hw1)
        XCTAssertTrue(solution.routeWindow?.contains(route.plannedStartTime) ?? false)
    }

    func testDepartureBetweenTidesSelectsTheNextFutureWindow() async {
        let hw1 = highWater
        let hw2 = highWater.addingTimeInterval(12.4 * 3_600)
        let selectedDeparture = hw1.addingTimeInterval(4 * 3_600)
        let provider = MockTideDataProvider()
        provider.highWatersByStation[stationID] = [
            TideEvent(time: hw1, heightMeters: 3.0, type: "HW", phase: nil),
            TideEvent(time: hw2, heightMeters: 3.0, type: "HW", phase: nil)
        ]
        provider.correctionsByStation[stationID] = manualCorrection()

        let first = makeWaypoint(name: "WP 1", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let second = makeWaypoint(name: "WP 2", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let leg = RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id, distanceNm: 0,
                           courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let route = RoutePlan(id: UUID(), date: hw1, routeName: "Next Tide", plannedStartTime: selectedDeparture,
                              waypoints: [first, second], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt")

        var config = PassageWindowSolver.Configuration()
        config.dayBased = false
        config.searchBackwardHours = 8
        config.searchForwardHours = 16

        let solution = await PassageWindowSolver(configuration: config).solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0),
            tideDataProvider: provider
        )

        XCTAssertEqual(solution.routeWindows.count, 2)
        XCTAssertEqual(solution.routeWindow?.anchoredHighWater, hw2)
        XCTAssertGreaterThan(solution.routeWindow?.start ?? .distantPast, selectedDeparture)
    }

    func testDepartureAfterAllTidesFallsBackToTheLatestPastWindow() async {
        let hw1 = highWater
        let hw2 = highWater.addingTimeInterval(12.4 * 3_600)
        let selectedDeparture = hw2.addingTimeInterval(4 * 3_600)
        let provider = MockTideDataProvider()
        provider.highWatersByStation[stationID] = [
            TideEvent(time: hw1, heightMeters: 3.0, type: "HW", phase: nil),
            TideEvent(time: hw2, heightMeters: 3.0, type: "HW", phase: nil)
        ]
        provider.correctionsByStation[stationID] = manualCorrection()

        let first = makeWaypoint(name: "WP 1", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let second = makeWaypoint(name: "WP 2", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let leg = RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id, distanceNm: 0,
                           courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let route = RoutePlan(id: UUID(), date: hw1, routeName: "Previous Tide", plannedStartTime: selectedDeparture,
                              waypoints: [first, second], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt")

        var config = PassageWindowSolver.Configuration()
        config.dayBased = false
        config.searchBackwardHours = 20
        config.searchForwardHours = 2

        let solution = await PassageWindowSolver(configuration: config).solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0),
            tideDataProvider: provider
        )

        XCTAssertEqual(solution.routeWindows.count, 2)
        XCTAssertEqual(solution.routeWindow?.anchoredHighWater, hw2)
        XCTAssertLessThan(solution.routeWindow?.end ?? .distantFuture, selectedDeparture)
    }

    func testCalendarDayIncludesBothNightAndDayTides() async {
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: highWater)
        // Night HW at 02:30, Day HW at 14:30
        let nightHW = calendar.date(bySettingHour: 2, minute: 30, second: 0, of: dayStart)!
        let dayHW = calendar.date(bySettingHour: 14, minute: 30, second: 0, of: dayStart)!

        let provider = MockTideDataProvider()
        provider.highWatersByStation[stationID] = [
            TideEvent(time: nightHW, heightMeters: 3.0, type: "HW", phase: nil),
            TideEvent(time: dayHW, heightMeters: 3.0, type: "HW", phase: nil)
        ]
        provider.correctionsByStation[stationID] = manualCorrection()

        let first = makeWaypoint(name: "WP 1", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let second = makeWaypoint(name: "WP 2", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let leg = RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id, distanceNm: 0,
                           courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let route = RoutePlan(id: UUID(), date: dayStart, routeName: "Day vs Night", plannedStartTime: dayStart,
                              waypoints: [first, second], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt")

        let solution = await PassageWindowSolver().solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0),
            tideDataProvider: provider
        )
        XCTAssertEqual(solution.routeWindows.count, 2)
        XCTAssertEqual(solution.routeWindow?.anchoredHighWater, nightHW)
        XCTAssertTrue(solution.routeWindow.map { calendar.component(.hour, from: $0.recommendedDeparture) < 6 } ?? false)
    }

    func testLateDepartureWithNightArrivalRemainsAvailable() async {
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: highWater)
        let eveningHW = dayStart.addingTimeInterval(21 * 3_600) // 21:00

        let provider = MockTideDataProvider()
        provider.highWatersByStation[stationID] = [
            TideEvent(time: eveningHW, heightMeters: 3.0, type: "HW", phase: nil)
        ]
        provider.correctionsByStation[stationID] = manualCorrection()

        let first = makeWaypoint(name: "Start", lottiefe: 1.45, meanTidalRange: 2.4, manualHighWaterTime: nil)
        let second = makeWaypoint(name: "Ziel", lottiefe: 10.0, meanTidalRange: 2.4, manualHighWaterTime: nil)
        // 18 nm at 6 kn = 3 hours travel time -> departure ~20:30 means arrival ~23:30 (night)
        let leg = RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id, distanceNm: 18,
                           courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let route = RoutePlan(id: UUID(), date: dayStart, routeName: "Late Route", plannedStartTime: dayStart,
                              waypoints: [first, second], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt")

        let solution = await PassageWindowSolver().solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0),
            tideDataProvider: provider
        )
        XCTAssertEqual(solution.routeWindows.count, 1)
    }

    func testNegativeChartDepthCalculatesWindowCorrectly() async {
        // MHW 2.80 m, chart depth -0.80 m (dries out 0.80 m above chart datum).
        // At HW: water depth = 2.80 + (-0.80) = 2.00 m.
        // With draft 1.10 m and safety margin 0.30 m:
        // required depth = 1.40 m -> allows missing water up to 2.00 - 1.40 = 0.60 m.
        // With MTH 2.40 m, 1/12 = 0.20 m, 3/12 = 0.60 m -> +/- 2 hours.
        let wp1 = RouteWaypoint(
            id: UUID(), name: "Trockenfallend", latitude: 53.7, longitude: 7.2,
            tidalReferenceStation: "Testpegel", tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: 2.40, source: .manual, sourceNotes: nil),
            meanHighWaterMeters: SourcedValue(value: 2.80, source: .manual, sourceNotes: nil),
            lottiefeMeters: nil,
            chartDepthMeters: SourcedValue(value: -0.80, source: .manual, sourceNotes: "Trockenfallend"),
            calculationMode: .meanHighWater,
            bshWaterLevelCorrectionOverride: 0,
            manualHighWaterTime: highWater,
            notes: "", category: "Wattenhoch", island: nil
        )
        let wp2 = RouteWaypoint(
            id: UUID(), name: "Deep", latitude: 53.7, longitude: 7.2,
            tidalReferenceStation: "Testpegel", tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: 2.40, source: .manual, sourceNotes: nil),
            meanHighWaterMeters: SourcedValue(value: 2.80, source: .manual, sourceNotes: nil),
            lottiefeMeters: nil,
            chartDepthMeters: SourcedValue(value: 5.0, source: .manual, sourceNotes: nil),
            calculationMode: .meanHighWater,
            bshWaterLevelCorrectionOverride: 0,
            manualHighWaterTime: highWater,
            notes: "", category: "Fahrwasser", island: nil
        )
        let leg = RouteLeg(
            id: UUID(), fromWaypointID: wp1.id, toWaypointID: wp2.id, distanceNm: 0,
            courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0
        )
        let route = RoutePlan(
            id: UUID(), date: highWater, routeName: "Negative Chart Depth", plannedStartTime: highWater,
            waypoints: [wp1, wp2], legs: [leg], bshWaterLevelCorrectionMeters: nil, tidalStateLabel: "Mt"
        )

        let solution = await PassageWindowSolver().solve(
            route: route,
            boatSettings: BoatSettings(draftMeters: 1.10, safetyMarginMeters: 0.30),
            tideDataProvider: MockTideDataProvider()
        )

        guard let window = solution.routeWindow else {
            return XCTFail("Fenster für trockenfallende Tiefe muss berechenbar sein")
        }

        // 0.60 m allowable drop on MTH 2.40 (1/12 = 0.20 m, 3/12 = 0.60 m) corresponds to exactly +/- 2 hours (7200 s).
        XCTAssertEqual(window.start, highWater.addingTimeInterval(-7_200))
        XCTAssertEqual(window.end, highWater.addingTimeInterval(7_200))
        XCTAssertEqual(window.recommendedDeparture, highWater)
        XCTAssertEqual(window.recommendedClearanceMeters, 0.90, accuracy: 1e-3)
    }

    func testAstronomicalCurveUsesIndividualBSHEventHeights() throws {
        let lowWater = highWater.addingTimeInterval(6 * 3_600)
        let curve = AstronomicalTideCurve(
            events: [
                TideEvent(time: highWater, heightMeters: 3.20, type: "HW", phase: nil),
                TideEvent(time: lowWater, heightMeters: 0.60, type: "NW", phase: nil)
            ],
            meanHighWater: 3.0,
            meanRange: 2.4,
            offset: 0
        )

        XCTAssertFalse(curve.estimatedHeights)
        XCTAssertEqual(try XCTUnwrap(curve.height(at: highWater)), 3.20, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(curve.height(at: highWater.addingTimeInterval(3 * 3_600))),
            1.90,
            accuracy: 1e-9
        )
        XCTAssertEqual(try XCTUnwrap(curve.height(at: lowWater)), 0.60, accuracy: 1e-9)
    }

    func testAstronomicalCurveRejectsMissingEventHeightsLikeAndroid() throws {
        let lowWater = highWater.addingTimeInterval(6 * 3_600)
        let curve = AstronomicalTideCurve(
            events: [
                TideEvent(time: highWater, heightMeters: nil, type: "HW", phase: nil),
                TideEvent(time: lowWater, heightMeters: nil, type: "NW", phase: nil)
            ],
            meanHighWater: 3.0,
            meanRange: 2.4,
            offset: 0
        )

        XCTAssertFalse(curve.estimatedHeights)
        XCTAssertNil(curve.height(at: highWater))
        XCTAssertNil(curve.height(at: highWater.addingTimeInterval(3_600)))
        XCTAssertNil(curve.height(at: lowWater))
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

extension PassageWindowSolverTests {
    @MainActor
    func testBorkumLangeoogRetainsShallowCatalogPointsAfterSeaMaskLoads() async throws {
        let start = HarbourOption.byID("borkum_harbor")
        let destination = HarbourOption.byID("langeoog_harbor")
        let from = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
        let to = CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)
        let before = NauticalRouter.route(from: from, to: to)
        if !SeaMask.shared.isReady { SeaMask.shared.build() }
        let after = NauticalRouter.route(from: from, to: to)
        XCTAssertEqual(after, before)
        XCTAssertFalse(after.isEmpty)
        XCTAssertFalse(after.contains { $0.id.hasPrefix("AStar_") })

        let provider = MockTideDataProvider()
        let model = RoutePlannerViewModel(tideDataProvider: provider)
        model.departure = highWater
        model.startHarbourID = start.id
        model.destinationHarbourID = destination.id
        var plan = try XCTUnwrap(model.routePlan)
        // Deterministic HW/NW input covering the entire scan and all arrivals.
        // This is a calculation fixture, not a prediction for a real trip.
        for index in plan.waypoints.indices {
            plan.waypoints[index].meanTidalRangeMeters = SourcedValue(value: 2.4, source: .manual, sourceNotes: nil)
            plan.waypoints[index].meanHighWaterMeters = SourcedValue(value: 2.8, source: .manual, sourceNotes: nil)
            plan.waypoints[index].bshWaterLevelCorrectionOverride = 0
            provider.tidalEventsByStation[plan.waypoints[index].tidalReferenceStationID] = (-4 ... 8).map { phase in
                TideEvent(time: highWater.addingTimeInterval(Double(phase) * 6 * 3_600),
                          heightMeters: phase.isMultiple(of: 2) ? 2.8 : 0.4,
                          type: phase.isMultiple(of: 2) ? "HW" : "NW", phase: nil)
            }
        }
        XCTAssertTrue(plan.waypoints.contains { ($0.chartDepthMeters?.value ?? .infinity) < 0 },
                      "The assessment must include Android drying chart depths")
        let solution = await PassageWindowScanner().solve(
            route: plan, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.3),
            tideDataProvider: provider
        )
        // Depending on overlapping constrictions this route may have no safe
        // window, but it must never be declared open throughout the scan.
        if let window = solution.routeWindow {
            XCTAssertLessThan(window.end.timeIntervalSince(window.start), 12 * 3_600)
            XCTAssertFalse(window.displayString.contains("00:00 – 23:59"))
        }
        XCTAssertFalse(solution.hasInvalidLeg)
        XCTAssertTrue(solution.missingWaypointNames.isEmpty)
    }

    @MainActor
    func testJuistRouteHasTideLimitedWindowWithCompleteEvents() async throws {
        let model = RoutePlannerViewModel(tideDataProvider: MockTideDataProvider())
        model.departure = highWater
        model.startHarbourID = "norderney_harbor"
        model.destinationHarbourID = "juist_harbor"
        let plan = try XCTUnwrap(model.routePlan)
        let events = (-8 ... 12).map { phase in
            TideEvent(time: highWater.addingTimeInterval(Double(phase) * 21_600),
                      heightMeters: phase.isMultiple(of: 2) ? 2.8 : 0.4,
                      type: phase.isMultiple(of: 2) ? "HW" : "NW", phase: nil)
        }
        var scanner = PassageWindowScanner()
        scanner.scanSelectedDay = true
        let solution = await scanner.solve(
            route: plan, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.3),
            tideDataProvider: AndroidForecastFixtureProvider(events: events)
        )
        XCTAssertTrue(solution.missingWaypointNames.isEmpty)
        XCTAssertFalse(solution.routeWindows.isEmpty)
        XCTAssertTrue(solution.routeWindows.allSatisfy {
            AppDateFormatters.berlinCalendar.isDate($0.start, inSameDayAs: highWater)
                && AppDateFormatters.berlinCalendar.isDate($0.end, inSameDayAs: highWater)
        })
        XCTAssertTrue(solution.routeWindows.allSatisfy { $0.end.timeIntervalSince($0.start) < 12 * 3_600 })
    }

    func testAndroidRelativeScanBoundsAndFirstBestTie() async throws {
        let first = makeWaypoint(name: "Deep 1", lottiefe: 10, meanTidalRange: 2.4, manualHighWaterTime: nil)
        var second = first
        second.id = UUID()
        let provider = MockTideDataProvider()
        // Constant heights deliberately keep every candidate safe and equal.
        provider.tidalEventsByStation[stationID] = (-4 ... 8).map { phase in
            TideEvent(time: highWater.addingTimeInterval(Double(phase) * 6 * 3_600),
                      heightMeters: 2.8, type: phase.isMultiple(of: 2) ? "HW" : "NW", phase: nil)
        }
        let route = RoutePlan(
            id: UUID(), date: highWater, routeName: "Android bounds", plannedStartTime: highWater,
            waypoints: [first, second],
            legs: [RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id,
                            distanceNm: 0, courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)],
            bshWaterLevelCorrectionMeters: 0, tidalStateLabel: "Test"
        )
        let result = await PassageWindowScanner().solve(
            route: route, boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.3),
            tideDataProvider: provider
        )
        let window = try XCTUnwrap(result.routeWindow)
        XCTAssertEqual(window.start, highWater.addingTimeInterval(-12 * 3_600))
        XCTAssertEqual(window.end, highWater.addingTimeInterval(24 * 3_600))
        XCTAssertEqual(window.recommendedDeparture, window.start)
        XCTAssertLessThan(window.waterLevelDetail?.count ?? 0, 200)
        XCTAssertTrue(window.displayString.contains(AppDateFormatters.shortWeekdayDateTime.string(from: window.start)))
    }

    @MainActor
    func testEmdenToNorderneyIncludesAndroidMemmertBottleneck() async throws {
        let provider = MockTideDataProvider()
        let model = RoutePlannerViewModel(tideDataProvider: provider)
        model.departure = highWater
        model.startHarbourID = "emden_harbor"
        model.destinationHarbourID = "norderney_harbor"
        var plan = try XCTUnwrap(model.routePlan)
        XCTAssertTrue(plan.waypoints.contains { $0.name == "memmert_w" })
        XCTAssertFalse(plan.waypoints.contains { $0.name == "sea_borkum_n" })
        for index in plan.waypoints.indices {
            plan.waypoints[index].bshWaterLevelCorrectionOverride = 0
            provider.tidalEventsByStation[plan.waypoints[index].tidalReferenceStationID] = (-6 ... 10).map { phase in
                TideEvent(time: highWater.addingTimeInterval(Double(phase) * 6 * 3_600),
                          heightMeters: phase.isMultiple(of: 2) ? 2.8 : 0.4,
                          type: phase.isMultiple(of: 2) ? "HW" : "NW", phase: nil)
            }
        }
        let boat = BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.3)
        let solution = await PassageWindowScanner().solve(route: plan, boatSettings: boat, tideDataProvider: provider)
        XCTAssertFalse(solution.routeWindows.isEmpty)
        XCTAssertTrue(solution.missingWaypointNames.isEmpty)
        for window in solution.routeWindows {
            XCTAssertGreaterThan(window.end, window.start)
            XCTAssertLessThan(window.end.timeIntervalSince(window.start), 12 * 3_600)
        }
        let tooDeep = await PassageWindowScanner().solve(
            route: plan, boatSettings: BoatSettings(draftMeters: 4, safetyMarginMeters: 0.3), tideDataProvider: provider)
        XCTAssertTrue(tooDeep.routeWindows.isEmpty, "Draft must affect Emden–Norderney")
    }

    func testSingleSampleIsNotDisplayedAsAnInterval() {
        let window = PassageWindowScanner.Window(start: highWater, end: highWater,
                                                 anchoredHighWater: highWater, bottleneckName: "Test")
        XCTAssertFalse(window.hasUsableDuration)
        XCTAssertTrue(window.displayString.contains("kein Zeitfenster"))
    }

    func testNoInventedTideOutsideCoverage() {
        let curve = AstronomicalTideCurve(events: [
            TideEvent(time: highWater, heightMeters: 3, type: "HW", phase: nil),
            TideEvent(time: highWater.addingTimeInterval(6 * 3_600), heightMeters: 0.5, type: "NW", phase: nil)
        ], meanHighWater: 3, meanRange: 2.5, offset: 0)
        XCTAssertNil(curve.height(at: highWater.addingTimeInterval(-1)))
        XCTAssertNil(curve.height(at: highWater.addingTimeInterval(12 * 3_600)))
        XCTAssertFalse(ContinuousTwelfthsStrategy().missingWater(deviationHours: 12, meanTidalRangeMeters: 2.5).isValid)
    }
}


extension PassageWindowSolverTests {
    /// Expected values emitted by the original Kotlin RuleOfTwelfths and
    /// PassageWindowScanner (scripts/android_passage_reference.py).
    func testMatchesExecutedKotlinScannerGoldenValues() async throws {
        var first = makeWaypoint(name: "start", lottiefe: 0, meanTidalRange: 2.4, manualHighWaterTime: nil)
        first.calculationMode = .meanHighWater
        first.chartDepthMeters = SourcedValue(value: -0.8, source: .manual, sourceNotes: nil)
        var second = first
        second.id = UUID()
        second.name = "end"
        let provider = MockTideDataProvider()
        provider.tidalEventsByStation[stationID] = (-6 ... 10).map { phase in
            TideEvent(time: highWater.addingTimeInterval(Double(phase) * 21_600),
                      heightMeters: phase.isMultiple(of: 2) ? 2.8 : 0.4,
                      type: phase.isMultiple(of: 2) ? "HW" : "NW", phase: nil)
        }
        let route = RoutePlan(id: UUID(), date: highWater, routeName: "Kotlin fixture", plannedStartTime: highWater,
            waypoints: [first, second], legs: [RouteLeg(id: UUID(), fromWaypointID: first.id, toWaypointID: second.id,
                distanceNm: 6, courseDegrees: nil, speedThroughWaterKnots: 6, tidalCurrentKnots: 0)],
            bshWaterLevelCorrectionMeters: 0, tidalStateLabel: "Test")
        for draft in [1.1, 1.7, 2.4, 4.0] {
            let result = await PassageWindowScanner().solve(route: route,
                boatSettings: BoatSettings(draftMeters: draft, safetyMarginMeters: 0.3), tideDataProvider: provider)
            let actual = result.routeWindows.map { [
                Int($0.start.timeIntervalSince(highWater)), Int($0.end.timeIntervalSince(highWater)),
                Int($0.recommendedDeparture.timeIntervalSince(highWater))
            ] }
            let expected = draft == 1.1 ? [
                [-43200, -39600, -43200], [-7200, 3600, -1800],
                [36000, 46800, 41400], [79200, 86400, 84600]
            ] : []
            XCTAssertEqual(actual, expected, "Kotlin parity at draft \(draft)")
        }
    }

    func testMatchesExecutedKotlinAcrossBothDSTTransitions() throws {
        let cases: [(String, [Double])] = [
            ("2026-03-29T00:00:00+01:00", [0.4, 0.5714285714285714, 1.342857142857143, 1.8571428571428572,
                                          2.3142857142857145, 2.628571428571428, 2.8]),
            ("2026-10-25T00:00:00+02:00", [0.4, 0.6800000000000002, 1.2400000000000002, 1.2400000000000002,
                                          1.96, 2.52, 2.8])
        ]
        for (timestamp, expected) in cases {
            let start = try XCTUnwrap(BSHDateParser.date(from: timestamp))
            for hour in 0 ... 6 {
                let actual = AstronomicalTideCurve.waterLevel(start: start, heightStart: 0.4,
                    end: start.addingTimeInterval(21_600), heightEnd: 2.8, target: start.addingTimeInterval(Double(hour) * 3_600))
                XCTAssertEqual(actual, expected[hour], accuracy: 1e-12)
            }
        }
    }
}

private final class AndroidForecastFixtureProvider: TideDataProvider {
    var usesAndroidForecastLevels: Bool { true }
    let events: [TideEvent]
    init(events: [TideEvent]) { self.events = events }
    func routeEvents(for waypoint: RouteWaypoint, covering span: ClosedRange<Date>) async throws -> [TideEvent] { events }
    func highWaters(for stationID: String, around date: Date) async throws -> [TideEvent] { events.filter { $0.type == "HW" } }
    func meanTidalRange(for stationID: String) async throws -> Double? { nil }
    func meanHighWater(for stationID: String) async throws -> Double? { nil }
    func stationReference(for stationID: String, around date: Date) async throws -> TideStationReference? { nil }
    func waterLevelCorrection(for stationID: String, at highWaterTime: Date,
                              confirmedComparisonStationID: String?) async -> WaterLevelCorrectionResolution {
        .unavailable(stationID: stationID, detail: "Must not add forecast surge twice")
    }
}

extension PassageWindowSolverTests {
    @MainActor
    func testAll56HarbourPairsUseForecastHeightsWithoutMeanTideMetadata() async throws {
        let events = (-8 ... 12).map { phase -> TideEvent in
            var event = TideEvent(time: highWater.addingTimeInterval(Double(phase) * 21_600),
                heightMeters: phase.isMultiple(of: 2) ? 2.8 : 0.4,
                type: phase.isMultiple(of: 2) ? "HW" : "NW", phase: nil)
            event.androidCurrentTimestampIsISO8601 = false // BSH's space-separated timestamp
            return event
        }
        let provider = AndroidForecastFixtureProvider(events: events)
        let boat = BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.3)
        var count = 0
        for from in HarbourOption.options {
            for to in HarbourOption.options where from.id != to.id {
                let model = RoutePlannerViewModel(tideDataProvider: provider)
                model.departure = highWater
                model.startHarbourID = from.id
                model.destinationHarbourID = to.id
                let plan = try XCTUnwrap(model.routePlan)
                let result = await PassageWindowScanner().solve(route: plan, boatSettings: boat, tideDataProvider: provider)
                XCTAssertFalse(result.hasInvalidLeg, "\(from.name) → \(to.name)")
                XCTAssertTrue(result.missingWaypointNames.isEmpty)
                for window in result.routeWindows {
                    if plan.waypoints.contains(where: { ($0.chartDepthMeters?.value ?? 0) + 0.4 - boat.draftMeters < boat.safetyMarginMeters - 0.01 }) {
                        XCTAssertLessThan(window.end.timeIntervalSince(window.start), 12 * 3_600,
                                          "\(from.name) → \(to.name) cannot bridge low water")
                    }
                    let assessed = await RouteCalculationService().calculate(route: {
                        var selected = plan
                        selected.plannedStartTime = window.recommendedDeparture
                        return selected
                    }(), boatSettings: boat, tideDataProvider: provider)
                    let values = assessed.waypointResults.compactMap(\.clearanceUnderKeelWuKMeters)
                    XCTAssertEqual(values.count, plan.waypoints.count)
                    XCTAssertEqual(try XCTUnwrap(values.min()), window.recommendedClearanceMeters, accuracy: 1e-9)
                }
                count += 1
            }
        }
        XCTAssertEqual(count, 56)
    }

    func testAndroidCurrentAndWholeSecondTravel() {
        let events = [
            TideEvent(time: highWater, heightMeters: 0.4, type: "NW", phase: nil),
            TideEvent(time: highWater.addingTimeInterval(21_600), heightMeters: 2.8, type: "HW", phase: nil)
        ]
        let departure = highWater.addingTimeInterval(10_800)
        let east = AndroidPassageLeg(distanceNm: 6, speedKnots: 6, courseDegrees: 90, events: events)
        XCTAssertEqual(east.speedOverGround(at: departure), 8.5, accuracy: 1e-12)
        XCTAssertEqual(east.arrival(after: departure).timeIntervalSince(departure), 2541)
        let west = AndroidPassageLeg(distanceNm: 6, speedKnots: 6, courseDegrees: 270, events: events)
        XCTAssertEqual(west.speedOverGround(at: departure), 3.5, accuracy: 1e-12)
        let rawBSHEvents = events.map { event -> TideEvent in
            var event = event
            event.androidCurrentTimestampIsISO8601 = false
            return event
        }
        let raw = AndroidPassageLeg(distanceNm: 6, speedKnots: 6, courseDegrees: 90, events: rawBSHEvents)
        XCTAssertEqual(raw.speedOverGround(at: departure), 6, "Match Android's direct ISO parser, not TideTimes")
    }
}

extension PassageWindowSolverTests {
    @MainActor
    func testLiveBSHEmdenNorderneyForecastPassageHasShallowBottleneck() async throws {
        let provider = BSHTideDataProvider()
        let model = RoutePlannerViewModel(tideDataProvider: provider)
        model.departure = Date()
        model.startHarbourID = "emden_harbor"
        model.destinationHarbourID = "norderney_harbor"
        let plan = try XCTUnwrap(model.routePlan)
        XCTAssertTrue(plan.waypoints.contains { $0.name == "memmert_w" })
        let forecast = try? await provider.routeEvents(for: plan.waypoints[0],
            covering: plan.plannedStartTime ... plan.plannedStartTime)
        if (forecast?.count ?? 0) < 4 {
            throw XCTSkip("BSH-Pegelprognose derzeit nicht vollständig verfügbar")
        }
        let result = await PassageWindowScanner().solve(route: plan,
            boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.3), tideDataProvider: provider)
        XCTAssertFalse(result.hasInvalidLeg)
        XCTAssertTrue(result.missingWaypointNames.isEmpty, result.missingWaypointNames.joined(separator: ", "))
        for window in result.routeWindows {
            XCTAssertLessThan(window.end.timeIntervalSince(window.start), 12 * 3_600)
            XCTAssertFalse(window.displayString.contains("Ganztägig"))
        }
    }
}

extension PassageWindowSolverTests {
    func testAndroidForecastIgnoresLegacyFixedCurrentSetting() async {
        var first = makeWaypoint(name: "Start", lottiefe: 0, meanTidalRange: 2.4, manualHighWaterTime: nil)
        first.calculationMode = .meanHighWater
        first.chartDepthMeters = SourcedValue(value: -0.8, source: .manual, sourceNotes: nil)
        var second = first
        second.id = UUID()
        let events = (-2 ... 4).map { phase in
            TideEvent(time: highWater.addingTimeInterval(Double(phase) * 21_600),
                heightMeters: phase.isMultiple(of: 2) ? 2.8 : 0.4,
                type: phase.isMultiple(of: 2) ? "HW" : "NW", phase: nil)
        }
        let route = RoutePlan(id: UUID(), date: highWater, routeName: "Android current", plannedStartTime: highWater,
            waypoints: [first, second], legs: [RouteLeg(id: UUID(), fromWaypointID: first.id,
                toWaypointID: second.id, distanceNm: 0, courseDegrees: nil,
                speedThroughWaterKnots: 6, tidalCurrentKnots: -100)],
            bshWaterLevelCorrectionMeters: 0, tidalStateLabel: "Test")
        let result = await PassageWindowScanner().solve(route: route,
            boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.3),
            tideDataProvider: AndroidForecastFixtureProvider(events: events))
        XCTAssertFalse(result.hasInvalidLeg)
        XCTAssertFalse(result.routeWindows.isEmpty)
    }
}
