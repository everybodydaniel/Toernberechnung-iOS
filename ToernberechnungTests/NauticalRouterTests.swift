import XCTest
import CoreLocation
@testable import Toernberechnung

// MARK: - NauticalRouter Dijkstra Tests

final class NauticalRouterTests: XCTestCase {

    func testRouteFromEmdenToBorkumPassesEmsFairway() {
        let emden  = CLLocationCoordinate2D(latitude: 53.3421, longitude: 7.1852)
        let borkum = CLLocationCoordinate2D(latitude: 53.5606, longitude: 6.7502)

        let path = NauticalRouter.route(from: emden, to: borkum)

        XCTAssertGreaterThan(path.count, 3, "Emden→Borkum must include Ems fairway WPs")
        let ids = Set(path.map(\.id))
        XCTAssertTrue(
            ids.contains("ems_knock") || ids.contains("ems_rysum") || ids.contains("ems_emden_w"),
            "Route must traverse the Ems fairway"
        )
    }

    func testRouteFromNorderneyToWangerooge_VisitsBottleneckWatt() {
        let norderney  = CLLocationCoordinate2D(latitude: 53.7024, longitude: 7.1637)
        let wangerooge = CLLocationCoordinate2D(latitude: 53.7755, longitude: 7.8683)

        let path = NauticalRouter.route(from: norderney, to: wangerooge)
        let bottleneck = path.min(by: { $0.chartDepth < $1.chartDepth })

        XCTAssertNotNil(bottleneck)
        XCTAssertLessThan(
            bottleneck!.chartDepth, 1.5,
            "Norderney→Wangerooge should expose a shallow Watt WP"
        )
    }

    func testNearestFindsCatalogWaypoint() {
        // The reference graph names the Juist harbour WPs
        // `juist_hbr` / `juist_hbr_p`. Either is acceptable.
        let near = NauticalRouter.nearest(
            to: CLLocationCoordinate2D(latitude: 53.6722, longitude: 6.9982)
        )
        XCTAssertTrue(
            ["juist_hbr", "juist_hbr_p"].contains(near.id),
            "expected Juist harbour WP, got \(near.id)"
        )
    }

    /// Every harbour pair must produce a real A* route (never the
    /// straight-line `[start,end]` fallback) and must not plough through a
    /// Ruhezone/Schutzgebiet. Guards the two bugs fixed in the routing port:
    /// harbour pins snapping into disconnected basins, and the Ruhezone
    /// traversal cost being too low to make A* arc around.
    func testAllHarbourPairsProduceNavigableRoutes() {
        SeaMask.shared.build()
        // The test host app also kicks off an ASYNC build in its init(); if
        // that background build is mid-flight our synchronous build() is a
        // `guard !isBuilding` no-op. Wait until the mask is genuinely ready,
        // otherwise every leg short-circuits to a straight [start,end].
        let deadline = Date().addingTimeInterval(15)
        while !SeaMask.shared.isReady && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(SeaMask.shared.isReady, "SeaMask never became ready")
        let svc = NauticalRouteService.shared

        // The exact HarbourOption pins from DWDService.swift.
        let harbours: [(String, CLLocationCoordinate2D)] = [
            ("Borkum",     .init(latitude: 53.5606, longitude: 6.7502)),
            ("Emden",      .init(latitude: 53.3421, longitude: 7.1852)),
            ("Juist",      .init(latitude: 53.6722, longitude: 6.9982)),
            ("Norderney",  .init(latitude: 53.7024, longitude: 7.1637)),
            ("Baltrum",    .init(latitude: 53.7229, longitude: 7.3669)),
            ("Langeoog",   .init(latitude: 53.7263, longitude: 7.4968)),
            ("Spiekeroog", .init(latitude: 53.7632, longitude: 7.6955)),
            ("Wangerooge", .init(latitude: 53.7755, longitude: 7.8683)),
        ]

        // Ruhezone samples (~200 m spacing) the smoothed route passes through.
        func ruheCount(_ coords: [CLLocationCoordinate2D]) -> Int {
            var count = 0
            guard coords.count > 1 else { return 0 }
            for k in 0..<(coords.count - 1) {
                let a = coords[k]; let b = coords[k + 1]
                let len = GridConfig.approxMeters(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
                let steps = max(1, Int(len / 200))
                for s in 0...steps {
                    let t = Double(s) / Double(steps)
                    let lat = a.latitude + (b.latitude - a.latitude) * t
                    let lon = a.longitude + (b.longitude - a.longitude) * t
                    if SeaMask.shared.cellAtLatLng(lat: lat, lon: lon) == .ruhezone { count += 1 }
                }
            }
            return count
        }

        for i in 0..<harbours.count {
            for j in (i + 1)..<harbours.count {
                let (na, a) = harbours[i]; let (nb, b) = harbours[j]
                let coords = svc.calculateMultiStopRoute(stops: [a, b]).coordinates
                XCTAssertGreaterThan(coords.count, 2, "\(na)->\(nb) fell back to a straight line")
                // A short residual transit near harbours that sit next to a
                // zone is unavoidable; a route ploughing straight through one
                // (the old cost-2.0 behaviour was 46-54) must not regress.
                XCTAssertLessThan(ruheCount(coords), 15, "\(na)->\(nb) ploughs through a Ruhezone")
            }
        }
    }
}

// MARK: - Rule of Twelfths parity

final class RuleOfTwelfthsTests: XCTestCase {

    func testSteppedFehlmengeMatchesLookupTable() {
        // The stepped formula returns exactly these multiples of MTH/12:
        //   ≤1h →1   ≤2h →3   ≤3h →6   ≤4h →9   ≤5h →11
        //   ≤7h →12  ≤8h →11  ≤9h →9   ≤10h →6  ≤11h →3   ≤12h →1
        let mth = 3.6
        let expectations: [(Double, Double)] = [
            (0.5, 1), (1.5, 3), (2.5, 6), (3.5, 9), (4.5, 11),
            (6.0, 12), (7.5, 11), (8.5, 9), (9.5, 6), (10.5, 3), (11.5, 1)
        ]
        for (hours, twelfths) in expectations {
            guard let v = RuleOfTwelfths.steppedFehlmenge(
                deviationHours: hours, meanTidalRangeMeters: mth
            ) else {
                XCTFail("nil result for \(hours)h"); continue
            }
            XCTAssertEqual(v, twelfths * (mth / 12), accuracy: 1e-6,
                "Parity broken at \(hours)h")
        }
    }

    func testFehlmengeNilBeyond12Hours() {
        XCTAssertNil(
            RuleOfTwelfths.steppedFehlmenge(deviationHours: 12.5, meanTidalRangeMeters: 3)
        )
    }

    func testContinuousMonotonicallyRises() {
        let start = Date(timeIntervalSince1970: 0)
        let end   = Date(timeIntervalSince1970: 6 * 3600)
        var previous = 0.5
        for hour in stride(from: 0.0, through: 6.0, by: 0.5) {
            let t = start.addingTimeInterval(hour * 3600)
            let level = RuleOfTwelfths.continuousWaterLevel(
                timeStart: start, heightStart: 0.5,
                timeEnd: end, heightEnd: 4.1,
                targetTime: t
            )
            XCTAssertGreaterThanOrEqual(level + 1e-6, previous,
                "Continuous 12ths must be monotonic when rising")
            previous = level
        }
    }
}

// MARK: - PassageWindowScanner HW-anchored sweep

final class PassageWindowScannerTests: XCTestCase {

    func testWindowOpensSymmetricallyAroundHighWater() async throws {
        // Synthetic bottleneck: MHW=3.0 m, MTH=2.0 m, chartDepth=0.5 m,
        // draft=2.0 m, safety margin=0.3 m, no BSH correction.
        //   WuK(0h)   = 3.0       + 0 + 0.5 − 2.0 = 1.5  ≥ 0.3 ✓
        //   WuK(±3h)  = (3 − 1.0) + 0 + 0.5 − 2.0 = 0.5  ≥ 0.3 ✓  (6/12·MTH)
        //   WuK(±4h)  = (3 − 1.5) + 0 + 0.5 − 2.0 = 0.0  < 0.3 ✗  (9/12·MTH)
        // → Window must close between 3 h and 4 h on each side of HW.
        let hw = Date(timeIntervalSince1970: 1_700_000_000) // arbitrary

        let bottleneck = RouteWaypoint(
            id: UUID(),
            name: "test_bottleneck",
            latitude: 53.7,
            longitude: 7.0,
            tidalReferenceStation: "Test",
            tidalReferenceStationID: "TEST",
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: 2.0, source: .manual, sourceNotes: nil),
            meanHighWaterMeters:  SourcedValue(value: 3.0, source: .manual, sourceNotes: nil),
            lottiefeMeters: nil,
            chartDepthMeters:     SourcedValue(value: 0.5, source: .manual, sourceNotes: nil),
            calculationMode: .meanHighWater,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: nil,
            notes: "",
            category: "Test",
            island: nil
        )

        let leg = RouteLeg(
            id: UUID(),
            fromWaypointID: bottleneck.id, toWaypointID: bottleneck.id,
            distanceNm: 0, courseDegrees: nil,
            speedThroughWaterKnots: 6, tidalCurrentKnots: 0
        )

        let plan = RoutePlan(
            id: UUID(),
            date: hw,
            routeName: "Test",
            plannedStartTime: hw,
            waypoints: [bottleneck, bottleneck],
            legs: [leg],
            bshWaterLevelCorrectionMeters: 0,
            tidalStateLabel: "Mitteltide"
        )

        let mock = MockTideDataProvider()
        mock.highWatersByStation["TEST"] = [
            TideEvent(time: hw, heightMeters: 1.4, type: "HW", phase: nil)
        ]

        let scanner = PassageWindowScanner()
        let window = await scanner.findSafeWindow(
            route: plan,
            boatSettings: BoatSettings(draftMeters: 2.0, safetyMarginMeters: 0.3),
            tideDataProvider: mock
        )
        let unwrapped = try XCTUnwrap(window)

        // Window opening: ≥ 3 h before HW, < 4 h before HW.
        let before = hw.timeIntervalSince(unwrapped.start)
        XCTAssertGreaterThanOrEqual(before, 3 * 3600 - 1)
        XCTAssertLessThan(before, 4 * 3600)
        // Window closing: ≥ 3 h after HW, < 4 h after HW.
        let after = unwrapped.end.timeIntervalSince(hw)
        XCTAssertGreaterThanOrEqual(after, 3 * 3600 - 1)
        XCTAssertLessThan(after, 4 * 3600)
    }

    func testNilWindowWhenHighWaterAlreadyTooShallow() async {
        // MHW too low to clear safety margin even at HW.
        let hw = Date(timeIntervalSince1970: 1_700_000_000)
        let wp = RouteWaypoint(
            id: UUID(), name: "shallow",
            latitude: 53.7, longitude: 7.0,
            tidalReferenceStation: "Test", tidalReferenceStationID: "TEST",
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: 2.0, source: .manual, sourceNotes: nil),
            meanHighWaterMeters: SourcedValue(value: 0.5, source: .manual, sourceNotes: nil),
            lottiefeMeters: nil,
            chartDepthMeters: SourcedValue(value: 0.0, source: .manual, sourceNotes: nil),
            calculationMode: .meanHighWater,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: nil,
            notes: "", category: "Test", island: nil
        )
        let leg = RouteLeg(id: UUID(), fromWaypointID: wp.id, toWaypointID: wp.id,
                           distanceNm: 0, courseDegrees: nil,
                           speedThroughWaterKnots: 6, tidalCurrentKnots: 0)
        let plan = RoutePlan(id: UUID(), date: hw, routeName: "x",
                             plannedStartTime: hw, waypoints: [wp, wp], legs: [leg],
                             bshWaterLevelCorrectionMeters: 0,
                             tidalStateLabel: "x")
        let mock = MockTideDataProvider()
        mock.highWatersByStation["TEST"] = [
            TideEvent(time: hw, heightMeters: 0.5, type: "HW", phase: nil)
        ]
        let window = await PassageWindowScanner().findSafeWindow(
            route: plan,
            boatSettings: BoatSettings(draftMeters: 1.5, safetyMarginMeters: 0.5),
            tideDataProvider: mock
        )
        XCTAssertNil(window, "No window must be returned when HW itself is too shallow")
    }
}
