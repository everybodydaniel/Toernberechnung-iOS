import XCTest
@testable import Toernberechnung

/// Integrations-Tests für `RouteCalculationService.calculate(...)`.
///
/// Der Service ist die Kernkomponente; alle Eingaben sind als RoutePlan + BoatSettings + Provider
/// gemockt. Hier wird das Zusammenspiel der einzelnen Pure-Funktionen verifiziert.
final class RouteCalculationServiceTests: XCTestCase {

    // MARK: - Eingabevalidierung (FA12)

    func test_calculate_draftZero_returnsIncompleteWithError() async {
        let service = RouteCalculationService()
        let route = RouteFactory.twoPointRoute(
            from: RouteFactory.mhwWaypoint(),
            to:   RouteFactory.mhwWaypoint()
        )
        let result = await service.calculate(
            route: route,
            boatSettings: RouteFactory.boat(draft: 0),
            tideDataProvider: MockTideDataProvider()
        )
        XCTAssertEqual(result.tidalStatus, .incomplete)
        XCTAssertEqual(result.combinedStatus, .incomplete)
        XCTAssertTrue(result.messages.contains { $0.contains("Tiefgang") })
    }

    func test_calculate_negativeSafetyMargin_returnsIncomplete() async {
        let service = RouteCalculationService()
        let route = RouteFactory.twoPointRoute(
            from: RouteFactory.mhwWaypoint(),
            to:   RouteFactory.mhwWaypoint()
        )
        let result = await service.calculate(
            route: route,
            boatSettings: RouteFactory.boat(draft: 1.5, safetyMargin: -0.1),
            tideDataProvider: MockTideDataProvider()
        )
        XCTAssertEqual(result.tidalStatus, .incomplete)
        XCTAssertTrue(result.messages.contains { $0.contains("Sicherheitsmarge") })
    }

    func test_calculate_singleWaypoint_returnsIncomplete() async {
        let service = RouteCalculationService()
        let waypoint = RouteFactory.mhwWaypoint()
        let route = RoutePlan(
            id: UUID(), date: Date(),
            routeName: "Single", plannedStartTime: Date(),
            waypoints: [waypoint], legs: [],
            bshWaterLevelCorrectionMeters: 0,
            tidalStateLabel: "Mitteltide"
        )
        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(),
            tideDataProvider: MockTideDataProvider()
        )
        XCTAssertEqual(result.tidalStatus, .incomplete)
        XCTAssertTrue(result.messages.contains { $0.contains("mindestens") })
    }

    func test_calculate_legCountMismatch_returnsIncomplete() async {
        let service = RouteCalculationService()
        let wp1 = RouteFactory.mhwWaypoint()
        let wp2 = RouteFactory.mhwWaypoint()
        var route = RouteFactory.twoPointRoute(from: wp1, to: wp2)
        route.legs.removeAll()

        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(),
            tideDataProvider: MockTideDataProvider()
        )
        XCTAssertEqual(result.tidalStatus, .incomplete)
    }

    // MARK: - Happy-Path: vollständige Berechnung MHW

    func test_calculate_mhwHappyPath_producesGoStatus() async {
        let service = RouteCalculationService()
        let startTime = TestFixtures.berlinDate("2026-05-25 11:30")  // 30 min vor HW
        let highWater = TestFixtures.berlinDate("2026-05-25 12:00")

        // Wegpunkt: viel Wasser, gute Marge → erwartet GO
        let wp1 = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 1.5, chartDepth: 3.0)
        let wp2 = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 1.5, chartDepth: 3.0)

        let route = RouteFactory.twoPointRoute(
            from: wp1, to: wp2,
            distanceNm: 0.5, speedKnots: 6, startTime: startTime
        )

        let provider = MockTideDataProvider()
        provider.highWatersByStation["111P"] = [
            TideEvent(time: highWater, heightMeters: 3.5, type: "HW", phase: "S")
        ]

        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(draft: 1.5, safetyMargin: 0.3),
            tideDataProvider: provider
        )

        XCTAssertEqual(result.tidalStatus, .go)
        XCTAssertEqual(result.waypointResults.count, 2)
        XCTAssertGreaterThan(result.totalDistanceNm, 0)
        XCTAssertNotNil(result.worstClearanceUnderKeel)
    }

    // MARK: - MHW-Pfad: tiefen Wegpunkt → noGo

    func test_calculate_mhwInsufficientDepth_producesNoGo() async {
        let service = RouteCalculationService()
        let startTime = TestFixtures.berlinDate("2026-05-25 18:00")  // 6h von HW → tiefste Tide
        let highWater = TestFixtures.berlinDate("2026-05-25 12:00")

        // Geringes MHW, geringe Kartentiefe, großes Boot → erwartet noGo
        let wp1 = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 0.0, chartDepth: 0.5)
        let wp2 = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 0.0, chartDepth: 0.5)

        let route = RouteFactory.twoPointRoute(
            from: wp1, to: wp2,
            distanceNm: 0.5, speedKnots: 6, startTime: startTime
        )
        let provider = MockTideDataProvider()
        provider.highWatersByStation["111P"] = [
            TideEvent(time: highWater, heightMeters: 3.5, type: "HW", phase: "S")
        ]

        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(draft: 2.0, safetyMargin: 0.3),
            tideDataProvider: provider
        )

        XCTAssertEqual(result.tidalStatus, .noGo)
    }

    // MARK: - Lottiefe-Pfad: WT = Lottiefe − FmW + BSH; Kartentiefe wird NICHT angewendet

    func test_calculate_lottiefeMode_doesNotApplyChartDepth() async {
        let service = RouteCalculationService()
        let startTime = TestFixtures.berlinDate("2026-05-25 12:00")
        let highWater = startTime

        let wp1 = RouteFactory.lottiefeWaypoint(mth: 2.4, lottiefe: 2.0)
        let wp2 = RouteFactory.lottiefeWaypoint(mth: 2.4, lottiefe: 2.0)

        let route = RouteFactory.twoPointRoute(
            from: wp1, to: wp2,
            distanceNm: 0.1, speedKnots: 6, startTime: startTime
        )
        let provider = MockTideDataProvider()
        provider.highWatersByStation["111P"] = [
            TideEvent(time: highWater, heightMeters: 3.5, type: "HW", phase: "S")
        ]

        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(draft: 1.5, safetyMargin: 0.3),
            tideDataProvider: provider
        )

        // Bei HW (FmW=0, BSH=0): WT = Lottiefe = 2.0; WuK = 2.0 - 1.5 = 0.5 → GO
        XCTAssertEqual(result.tidalStatus, .go)
        let first = result.waypointResults.first
        XCTAssertNil(first?.chartDepthMetersApplied,
                     "Lottiefe-Modus darf die Kartentiefe nicht anwenden")
        XCTAssertNil(first?.tideHeightHGMeters,
                     "Lottiefe-Modus liefert keine HG")
    }

    // MARK: - Manuelle HW-Zeit übersteuert Provider (FA18)

    func test_calculate_manualHighWaterOverridesProvider() async {
        let service = RouteCalculationService()
        let startTime  = TestFixtures.berlinDate("2026-05-25 12:00")
        let manualHW   = TestFixtures.berlinDate("2026-05-25 12:00")
        let providerHW = TestFixtures.berlinDate("2026-05-25 18:00")

        let wp = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 1.5, chartDepth: 3.0, manualHW: manualHW)

        let route = RouteFactory.twoPointRoute(
            from: wp, to: wp,
            distanceNm: 0.1, startTime: startTime
        )
        let provider = MockTideDataProvider()
        provider.highWatersByStation["111P"] = [
            TideEvent(time: providerHW, heightMeters: 3.5, type: "HW", phase: "S")
        ]

        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(),
            tideDataProvider: provider
        )

        let first = result.waypointResults.first
        XCTAssertEqual(first?.relevantHighWaterTime, manualHW,
                       "Manuelle HW-Zeit muss Provider-HW übersteuern")
    }

    // MARK: - Fehlende MTH → incomplete (FA13)

    func test_calculate_missingMTH_markedAsIncomplete() async {
        let service = RouteCalculationService()
        var wp = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 1.5, chartDepth: 3.0)
        wp.meanTidalRangeMeters = nil  // keine MTH im Wegpunkt, Provider liefert auch nichts

        let route = RouteFactory.twoPointRoute(from: wp, to: wp)
        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(),
            tideDataProvider: MockTideDataProvider()
        )

        XCTAssertEqual(result.tidalStatus, .incomplete)
        let first = result.waypointResults.first
        XCTAssertEqual(first?.status, .incomplete)
        XCTAssertTrue(first?.messages.contains { $0.contains("MTH") } ?? false)
    }

    // MARK: - Provider wirft → keine HW-Daten → incomplete

    func test_calculate_providerThrows_resultsInIncomplete() async {
        let service = RouteCalculationService()
        let wp = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 1.5, chartDepth: 3.0)
        let route = RouteFactory.twoPointRoute(from: wp, to: wp)

        let provider = MockTideDataProvider()
        provider.shouldThrow = true

        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(),
            tideDataProvider: provider
        )

        XCTAssertEqual(result.tidalStatus, .incomplete)
    }

    // MARK: - Wetterkombination im Service-Default: weather=.incomplete

    func test_calculate_defaultWeatherStatusIsIncomplete() async {
        let service = RouteCalculationService()
        let wp = RouteFactory.mhwWaypoint()
        let route = RouteFactory.twoPointRoute(from: wp, to: wp)
        let result = await service.calculate(
            route: route, boatSettings: RouteFactory.boat(),
            tideDataProvider: RouteFactory.provider()
        )
        XCTAssertEqual(result.weatherStatus, .incomplete,
                       "Service liefert weather=incomplete; Kombination passiert im ViewModel")
    }
}
