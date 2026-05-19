import XCTest
@testable import Toernberechnung

final class TwelfthsRuleStrategyTests: XCTestCase {
    let strategy = TwelfthsRuleStrategy()
    let mth = 2.5

    func testExactHighWater() {
        let result = strategy.missingWater(deviationHours: 0, meanTidalRangeMeters: mth)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.fmwMeters, 0, "FmW at exact HW must be 0")
    }

    func testEpsilonNearHighWater() {
        let result = strategy.missingWater(deviationHours: 0.005, meanTidalRangeMeters: mth)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.fmwMeters, 0, "FmW within epsilon must be 0")
    }

    func testOneHourDeviation() {
        let result = strategy.missingWater(deviationHours: 0.5, meanTidalRangeMeters: mth)
        XCTAssertTrue(result.isValid)
        let oneTwelfth = mth / 12.0
        XCTAssertEqual(result.fmwMeters, 1 * oneTwelfth, accuracy: 0.001)
        XCTAssertEqual(result.oneTwelfthMeters, oneTwelfth, accuracy: 0.001)
    }

    func testTwoHourDeviation() {
        let result = strategy.missingWater(deviationHours: 1.5, meanTidalRangeMeters: mth)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.fmwMeters, 3 * (mth / 12.0), accuracy: 0.001)
    }

    func testThreeHourDeviation() {
        let result = strategy.missingWater(deviationHours: 2.5, meanTidalRangeMeters: mth)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.fmwMeters, 6 * (mth / 12.0), accuracy: 0.001)
    }

    func testFourHourDeviation() {
        let result = strategy.missingWater(deviationHours: 3.5, meanTidalRangeMeters: mth)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.fmwMeters, 9 * (mth / 12.0), accuracy: 0.001)
    }

    func testSixHourDeviationFullRange() {
        let result = strategy.missingWater(deviationHours: 6, meanTidalRangeMeters: mth)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.fmwMeters, mth, accuracy: 0.001, "At 6h from HW, FmW must equal the full tidal range")
    }

    func testSymmetricRisingTide() {
        let result = strategy.missingWater(deviationHours: 8.5, meanTidalRangeMeters: mth)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.fmwMeters, 9 * (mth / 12.0), accuracy: 0.001)
    }

    func testBeyondTwelveHoursInvalid() {
        let result = strategy.missingWater(deviationHours: 13, meanTidalRangeMeters: mth)
        XCTAssertFalse(result.isValid, "Deviation > 12h must be invalid")
    }
}

final class RouteCalculationStaticTests: XCTestCase {

    func testSpeedOverGround() {
        let sog = RouteCalculationService.calculateSpeedOverGround(
            speedThroughWaterKnots: 6.0,
            tidalCurrentKnots: -1.0
        )
        XCTAssertEqual(sog, 5.0)
    }

    func testSpeedOverGroundFavorable() {
        let sog = RouteCalculationService.calculateSpeedOverGround(
            speedThroughWaterKnots: 6.0,
            tidalCurrentKnots: 1.5
        )
        XCTAssertEqual(sog, 7.5)
    }

    func testTravelTime() {
        let hours = RouteCalculationService.calculateTravelTimeHours(
            distanceNm: 17,
            speedOverGroundKnots: 5.0
        )
        XCTAssertNotNil(hours)
        XCTAssertEqual(hours!, 3.4, accuracy: 0.001)
    }

    func testTravelTimeZeroSOG() {
        let hours = RouteCalculationService.calculateTravelTimeHours(
            distanceNm: 17,
            speedOverGroundKnots: 0
        )
        XCTAssertNil(hours, "SOG <= 0 must return nil")
    }

    func testHighWaterOffset() {
        let hw = Date(timeIntervalSince1970: 1_000_000)
        let shifted = RouteCalculationService.applyHighWaterOffset(
            referenceHWTime: hw,
            offsetMinutes: 25
        )
        XCTAssertEqual(shifted.timeIntervalSince(hw), 25 * 60, accuracy: 0.1)
    }

    func testHighWaterOffsetNegative() {
        let hw = Date(timeIntervalSince1970: 1_000_000)
        let shifted = RouteCalculationService.applyHighWaterOffset(
            referenceHWTime: hw,
            offsetMinutes: -10
        )
        XCTAssertEqual(shifted.timeIntervalSince(hw), -10 * 60, accuracy: 0.1)
    }

    func testDeviationHours() {
        let arrival = Date(timeIntervalSince1970: 1_000_000)
        let hw = Date(timeIntervalSince1970: 1_000_000 + 7200)
        let deviation = RouteCalculationService.calculateDeviationHours(
            arrivalTime: arrival,
            highWaterTime: hw
        )
        XCTAssertEqual(deviation, 2.0, accuracy: 0.001)
    }

    func testFindNearestHighWater() {
        let target = Date(timeIntervalSince1970: 1_000_000)
        let events = [
            TideEvent(time: Date(timeIntervalSince1970: 990_000), heightMeters: 3.0, type: "HW", phase: nil),
            TideEvent(time: Date(timeIntervalSince1970: 1_002_000), heightMeters: 3.1, type: "HW", phase: nil),
            TideEvent(time: Date(timeIntervalSince1970: 1_050_000), heightMeters: 3.2, type: "HW", phase: nil),
        ]
        let nearest = RouteCalculationService.findNearestHighWater(to: target, from: events)
        XCTAssertEqual(nearest?.timeIntervalSince1970, 1_002_000)
    }

    func testDetermineWaypointStatusGo() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: 0.5,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .go)
    }

    func testDetermineWaypointStatusWarning() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: 0.2,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .warning)
    }

    func testDetermineWaypointStatusNoGo() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: -0.1,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .noGo)
    }

    func testDetermineRouteStatusAllGo() {
        let status = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .go, .go]
        )
        XCTAssertEqual(status, .go)
    }

    func testDetermineRouteStatusOneNoGo() {
        let status = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .noGo, .go]
        )
        XCTAssertEqual(status, .noGo)
    }

    func testDetermineRouteStatusOneIncomplete() {
        let status = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .incomplete, .go]
        )
        XCTAssertEqual(status, .incomplete)
    }

    func testDetermineRouteStatusOneWarning() {
        let status = RouteCalculationService.determineRouteStatus(
            waypointStatuses: [.go, .warning, .go]
        )
        XCTAssertEqual(status, .warning)
    }
}

final class CombinedStatusTests: XCTestCase {

    func testBothGo() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .go, weather: .go), .go)
    }

    func testTidalNoGo() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .noGo, weather: .go), .noGo)
    }

    func testWeatherNoGo() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .go, weather: .noGo), .noGo)
    }

    func testBothNoGo() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .noGo, weather: .noGo), .noGo)
    }

    func testTidalWarning() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .warning, weather: .go), .warning)
    }

    func testWeatherWarning() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .go, weather: .warning), .warning)
    }

    func testTidalIncomplete() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .incomplete, weather: .go), .incomplete)
    }

    func testMissingWeatherDoesNotHideTidalGoNoGo() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .go, weather: .incomplete), .go)
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .warning, weather: .incomplete), .warning)
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .noGo, weather: .incomplete), .noGo)
    }
}

final class LegCalculationTests: XCTestCase {

    func testSingleLegTiming() {
        let startTime = Date(timeIntervalSince1970: 1_000_000)
        let leg = RouteLeg(
            id: UUID(),
            fromWaypointID: UUID(),
            toWaypointID: UUID(),
            distanceNm: 17.0,
            speedThroughWaterKnots: 6.0,
            tidalCurrentKnots: -1.0
        )

        let results = RouteCalculationService.calculateLegResults(startTime: startTime, legs: [leg])
        XCTAssertEqual(results.count, 1)

        let result = results[0]
        XCTAssertEqual(result.speedOverGroundKnots, 5.0)
        XCTAssertEqual(result.travelTimeHours, 3.4, accuracy: 0.001)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.departureTime, startTime)
        XCTAssertEqual(result.arrivalTime.timeIntervalSince(startTime), 3.4 * 3600, accuracy: 1)
    }

    func testMultipleLegCumulativeDistance() {
        let startTime = Date(timeIntervalSince1970: 1_000_000)
        let legs = [
            RouteLeg(id: UUID(), fromWaypointID: UUID(), toWaypointID: UUID(),
                     distanceNm: 17.0, speedThroughWaterKnots: 6.0, tidalCurrentKnots: -1.0),
            RouteLeg(id: UUID(), fromWaypointID: UUID(), toWaypointID: UUID(),
                     distanceNm: 11.5, speedThroughWaterKnots: 6.0, tidalCurrentKnots: 0.0),
            RouteLeg(id: UUID(), fromWaypointID: UUID(), toWaypointID: UUID(),
                     distanceNm: 6.0, speedThroughWaterKnots: 6.0, tidalCurrentKnots: 0.0),
        ]

        let results = RouteCalculationService.calculateLegResults(startTime: startTime, legs: legs)
        XCTAssertEqual(results.count, 3)

        XCTAssertEqual(results[0].cumulativeDistanceNm, 17.0, accuracy: 0.001)
        XCTAssertEqual(results[1].cumulativeDistanceNm, 28.5, accuracy: 0.001)
        XCTAssertEqual(results[2].cumulativeDistanceNm, 34.5, accuracy: 0.001)

        XCTAssertEqual(results[0].arrivalTime, results[1].departureTime)
        XCTAssertEqual(results[1].arrivalTime, results[2].departureTime)
    }

    func testInvalidLegNegativeSOG() {
        let startTime = Date(timeIntervalSince1970: 1_000_000)
        let leg = RouteLeg(
            id: UUID(), fromWaypointID: UUID(), toWaypointID: UUID(),
            distanceNm: 5.0, speedThroughWaterKnots: 2.0, tidalCurrentKnots: -3.0
        )

        let results = RouteCalculationService.calculateLegResults(startTime: startTime, legs: [leg])
        XCTAssertFalse(results[0].isValid)
        XCTAssertFalse(results[0].messages.isEmpty)
    }
}

final class EmdenNorderneyRegressionTests: XCTestCase {

    /// Regressionstest auf Basis der Excel-Arbeitsmappe „Törnberechnung“.
    ///
    /// Route: Emden Außenhafen → Wattenhoch Emshörn → Wattenhoch Memmert → Norderney Hafen
    /// Testet die komplette Mehrwegpunkt-Berechnung mit Mock-Tidendaten.
    func testEmdenNorderneyFullRoute() async {
        let service = RouteCalculationService()
        let mockProvider = MockTideDataProvider()

        let hwTime = makeDate(year: 2025, month: 7, day: 15, hour: 10, minute: 0)

        mockProvider.highWatersByStation["507P"] = [
            TideEvent(time: hwTime, heightMeters: 3.9, type: "HW", phase: nil)
        ]
        mockProvider.highWatersByStation["101P"] = [
            TideEvent(time: hwTime, heightMeters: 3.0, type: "HW", phase: nil)
        ]
        mockProvider.highWatersByStation["111P"] = [
            TideEvent(time: hwTime, heightMeters: 3.1, type: "HW", phase: nil)
        ]

        let startTime = makeDate(year: 2025, month: 7, day: 15, hour: 7, minute: 0)
        let route = makeEmdenNorderneyRoute(startTime: startTime)

        let boatSettings = BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0)

        let result = await service.calculate(
            route: route,
            boatSettings: boatSettings,
            tideDataProvider: mockProvider
        )

        XCTAssertEqual(result.waypointResults.count, 4, "Must have 4 waypoint results")
        XCTAssertEqual(result.legResults.count, 3, "Must have 3 leg results")

        XCTAssertEqual(result.totalDistanceNm, 34.5, accuracy: 0.1)

        for wpResult in result.waypointResults {
            XCTAssertNotEqual(wpResult.status, .incomplete,
                "Waypoint \(wpResult.waypoint.name) must not be incomplete")
        }

        let emdenResult = result.waypointResults[0]
        XCTAssertEqual(emdenResult.arrivalTime, startTime)
        XCTAssertNotNil(emdenResult.relevantHighWaterTime)
        XCTAssertNotNil(emdenResult.deviationHours)
        XCTAssertNotNil(emdenResult.clearanceUnderKeelWuKMeters)

        let norderneyResult = result.waypointResults[3]
        XCTAssertNotNil(norderneyResult.clearanceUnderKeelWuKMeters)

        XCTAssertNotEqual(result.tidalStatus, .incomplete)
    }

    func testEmdenNorderneyMissingTideData() async {
        let service = RouteCalculationService()
        let emptyProvider = MockTideDataProvider()

        let startTime = makeDate(year: 2025, month: 7, day: 15, hour: 7, minute: 0)
        let route = makeEmdenNorderneyRoute(startTime: startTime)
        let boatSettings = BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.0)

        let result = await service.calculate(
            route: route,
            boatSettings: boatSettings,
            tideDataProvider: emptyProvider
        )

        XCTAssertEqual(result.tidalStatus, .incomplete, "Missing tide data must produce incomplete status")
        XCTAssertTrue(
            result.waypointResults.contains(where: { $0.status == .incomplete }),
            "At least one waypoint must be incomplete when tide data is missing"
        )
    }

    func testInvalidDraftRejectsCalculation() async {
        let service = RouteCalculationService()
        let mockProvider = MockTideDataProvider()
        let startTime = makeDate(year: 2025, month: 7, day: 15, hour: 7, minute: 0)
        let route = makeEmdenNorderneyRoute(startTime: startTime)

        let boatSettings = BoatSettings(draftMeters: 0, safetyMarginMeters: 0)
        let result = await service.calculate(
            route: route, boatSettings: boatSettings, tideDataProvider: mockProvider
        )

        XCTAssertEqual(result.tidalStatus, .incomplete)
        XCTAssertFalse(result.messages.isEmpty, "Must contain validation error")
    }

    func testSafetyMarginWarning() async {
        let service = RouteCalculationService()
        let mockProvider = MockTideDataProvider()

        let hwTime = makeDate(year: 2025, month: 7, day: 15, hour: 10, minute: 0)
        for stationID in ["507P", "101P", "111P"] {
            mockProvider.highWatersByStation[stationID] = [
                TideEvent(time: hwTime, heightMeters: 3.5, type: "HW", phase: nil)
            ]
        }

        let startTime = makeDate(year: 2025, month: 7, day: 15, hour: 9, minute: 50)
        let route = makeEmdenNorderneyRoute(startTime: startTime)

        let boatSettings = BoatSettings(draftMeters: 1.1, safetyMarginMeters: 10.0)
        let result = await service.calculate(
            route: route, boatSettings: boatSettings, tideDataProvider: mockProvider
        )

        let goCount = result.waypointResults.filter { $0.status == .go }.count
        XCTAssertEqual(goCount, 0, "No waypoint should be Go with 10m safety margin")
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeEmdenNorderneyRoute(startTime: Date) -> RoutePlan {
        let emden = RouteWaypoint(
            id: UUID(), name: "Emden Außenhafen",
            latitude: 53.3372, longitude: 7.1892,
            tidalReferenceStation: "Emden, Große Seeschleuse",
            tidalReferenceStationID: "507P",
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: 3.3, source: .catalog),
            meanHighWaterMeters: SourcedValue(value: 3.9, source: .catalog),
            chartDepthMeters: SourcedValue(value: 1.2, source: .catalog),
            calculationMode: .meanHighWater,
            notes: "Starthafen"
        )
        let wattenhoch1 = RouteWaypoint(
            id: UUID(), name: "Wattenhoch Emshörn",
            latitude: 53.52, longitude: 6.88,
            tidalReferenceStation: "Borkum, Fischerbalje",
            tidalReferenceStationID: "101P",
            highWaterOffsetMinutes: 12,
            meanTidalRangeMeters: SourcedValue(value: 2.6, source: .catalog),
            lottiefeMeters: SourcedValue(value: 2.3, source: .catalog),
            calculationMode: .lottiefe,
            notes: "Wattenhoch Lottiefe"
        )
        let wattenhoch2 = RouteWaypoint(
            id: UUID(), name: "Wattenhoch Memmert",
            latitude: 53.63, longitude: 6.94,
            tidalReferenceStation: "Norderney, Riffgat",
            tidalReferenceStationID: "111P",
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: 2.6, source: .catalog),
            meanHighWaterMeters: SourcedValue(value: 3.1, source: .catalog),
            chartDepthMeters: SourcedValue(value: -0.8, source: .catalog),
            calculationMode: .meanHighWater,
            notes: "Wattfahrwasser"
        )
        let norderney = RouteWaypoint(
            id: UUID(), name: "Norderney Hafen",
            latitude: 53.694, longitude: 7.157,
            tidalReferenceStation: "Norderney, Riffgat",
            tidalReferenceStationID: "111P",
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: 2.5, source: .catalog),
            meanHighWaterMeters: SourcedValue(value: 3.1, source: .catalog),
            chartDepthMeters: SourcedValue(value: 1.2, source: .catalog),
            calculationMode: .meanHighWater,
            notes: "Zielhafen"
        )

        let waypoints = [emden, wattenhoch1, wattenhoch2, norderney]
        let legs = [
            RouteLeg(id: UUID(), fromWaypointID: emden.id, toWaypointID: wattenhoch1.id,
                     distanceNm: 17.0, speedThroughWaterKnots: 6.0, tidalCurrentKnots: -1.0),
            RouteLeg(id: UUID(), fromWaypointID: wattenhoch1.id, toWaypointID: wattenhoch2.id,
                     distanceNm: 11.5, speedThroughWaterKnots: 6.0, tidalCurrentKnots: 0.0),
            RouteLeg(id: UUID(), fromWaypointID: wattenhoch2.id, toWaypointID: norderney.id,
                     distanceNm: 6.0, speedThroughWaterKnots: 6.0, tidalCurrentKnots: 0.0),
        ]

        return RoutePlan(
            id: UUID(), date: startTime, routeName: "Emden → Norderney (Test)",
            plannedStartTime: startTime, waypoints: waypoints, legs: legs,
            bshWaterLevelCorrectionMeters: 0.3, tidalStateLabel: "Mitteltide"
        )
    }
}

final class WaddenSeaCatalogTests: XCTestCase {

    /// Lädt den Katalog — erst aus dem Test-Bundle, dann aus dem Haupt-Bundle.
    private func loadCatalog() -> WaddenSeaCatalog? {
        for bundle in [Bundle(for: type(of: self)), Bundle.main] {
            if let url = bundle.url(forResource: "wadden_sea_catalog", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let catalog = try? JSONDecoder().decode(WaddenSeaCatalog.self, from: data) {
                return catalog
            }
        }
        return nil
    }

    func testCatalogLoadsBundled() throws {
        let catalog = try XCTUnwrap(loadCatalog(), "Catalog JSON must be loadable from host app bundle")
        XCTAssertFalse(catalog.stations.isEmpty, "Catalog must contain stations")
        XCTAssertFalse(catalog.waypoints.isEmpty, "Catalog must contain waypoints")
        XCTAssertFalse(catalog.routeTemplates.isEmpty, "Catalog must contain route templates")
    }

    func testStationLookup() throws {
        let catalog = try XCTUnwrap(loadCatalog())
        let station = catalog.station(byID: "507P")
        XCTAssertNotNil(station)
        XCTAssertTrue(station!.name.contains("Emden"))
    }

    func testRouteTemplateHasCorrectWaypointCount() throws {
        let catalog = try XCTUnwrap(loadCatalog())
        let template = try XCTUnwrap(catalog.routeTemplates.first, "No route template found")
        XCTAssertEqual(template.waypointTemplateIDs.count, 4, "Emden→Norderney has 4 waypoints")
        XCTAssertEqual(template.defaultLegDistancesNm.count, 3, "Must have 3 legs")
    }

    func testBuildRoutePlanFromTemplate() throws {
        let catalog = try XCTUnwrap(loadCatalog())
        let template = try XCTUnwrap(catalog.routeTemplates.first)

        let plan = catalog.buildRoutePlan(
            from: template,
            date: Date(),
            startTime: Date(),
            speedKnots: 6.0,
            bshCorrectionMeters: 0.3
        )

        XCTAssertNotNil(plan)
        XCTAssertEqual(plan!.waypoints.count, 4)
        XCTAssertEqual(plan!.legs.count, 3)
        XCTAssertEqual(plan!.bshWaterLevelCorrectionMeters, 0.3)
    }

    func testHarbourWaypoints() throws {
        let catalog = try XCTUnwrap(loadCatalog())
        let harbours = catalog.harbourWaypoints
        XCTAssertTrue(harbours.count >= 5, "Catalog must have at least 5 harbour waypoints")
    }
}
