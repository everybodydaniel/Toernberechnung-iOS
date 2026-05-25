import XCTest
@testable import Toernberechnung

/// Tests für `PassageWindowScanner.findSafeWindow`.
///
/// Bewertet den Scanner mit gemocktem TideDataProvider und prüft sowohl
/// das Auffinden eines sicheren Fensters als auch das saubere `nil`-Ergebnis.
final class PassageWindowScannerTests: XCTestCase {

    // MARK: - Sicheres Fenster wird gefunden

    func test_findSafeWindow_returnsWindow_whenRouteIsGenerallySafe() async {
        // Wegpunkt ohne Tidenproblem (sehr viel Wasser) → fast jeder Zeitpunkt ist sicher
        let wp = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 5.0, chartDepth: 5.0)
        let route = RouteFactory.twoPointRoute(from: wp, to: wp, distanceNm: 0.1)

        let provider = MockTideDataProvider()
        provider.highWatersByStation["111P"] = [
            TideEvent(time: route.plannedStartTime, heightMeters: 5.0, type: "HW", phase: "S")
        ]

        let scanner = PassageWindowScanner(
            calculationService: RouteCalculationService()
        )

        let window = await scanner.findSafeWindow(
            route: route,
            boatSettings: RouteFactory.boat(),
            tideDataProvider: provider
        )

        XCTAssertNotNil(window)
        XCTAssertTrue(window!.start <= route.plannedStartTime)
        XCTAssertTrue(window!.end   >= route.plannedStartTime)
    }

    // MARK: - Window DisplayString Test

    func test_window_displayString_formatsCorrectly() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        
        let start = formatter.date(from: "2024/07/20 08:30")!
        let end = formatter.date(from: "2024/07/20 12:45")!
        
        let window = PassageWindowScanner.Window(start: start, end: end)
        
        XCTAssertEqual(window.displayString, "08:30 – 12:45 Uhr")
    }

    // MARK: - RoutePlanModels Tests

    func test_WaypointCalculationMode_displayName() {
        XCTAssertEqual(WaypointCalculationMode.meanHighWater.displayName, "MHW")
        XCTAssertEqual(WaypointCalculationMode.lottiefe.displayName, "Lottiefe")
    }
    
    func test_ValueSource_displayName() {
        XCTAssertEqual(ValueSource.bsh.displayName, "BSH")
        XCTAssertEqual(ValueSource.catalog.displayName, "Vorgabe")
        XCTAssertEqual(ValueSource.cache.displayName, "Cache")
        XCTAssertEqual(ValueSource.manual.displayName, "Manuell")
        XCTAssertEqual(ValueSource.weatherService.displayName, "DWD")
        XCTAssertEqual(ValueSource.unknown.displayName, "Unbekannt")
    }

    // MARK: - Kein sicheres Fenster

    func test_findSafeWindow_returnsNil_whenRouteAlwaysFails() async {
        // Sehr großes Boot, sehr geringe Lottiefe → niemals sicher
        let wp = RouteFactory.lottiefeWaypoint(mth: 2.4, lottiefe: 0.5)
        let route = RouteFactory.twoPointRoute(from: wp, to: wp, distanceNm: 0.1)

        let provider = MockTideDataProvider()
        provider.highWatersByStation["111P"] = [
            TideEvent(time: route.plannedStartTime, heightMeters: 3.0, type: "HW", phase: "S")
        ]

        var scanner = PassageWindowScanner(calculationService: RouteCalculationService())
        scanner.scanBackwardHours = 2   // Scan-Bereich verkleinern → Testlaufzeit kurz halten
        scanner.scanForwardHours  = 2
        scanner.scanIncrementSeconds = 60 * 60

        let window = await scanner.findSafeWindow(
            route: route,
            boatSettings: RouteFactory.boat(draft: 5.0, safetyMargin: 0.3),
            tideDataProvider: provider
        )

        XCTAssertNil(window)
    }

    // MARK: - Performance (NFA1)

    func test_findSafeWindow_performance_isBelowThreshold() {
        let wp = RouteFactory.mhwWaypoint(mth: 2.4, mhw: 5.0, chartDepth: 5.0)
        let route = RouteFactory.twoPointRoute(from: wp, to: wp, distanceNm: 0.1)

        let provider = MockTideDataProvider()
        provider.highWatersByStation["111P"] = [
            TideEvent(time: route.plannedStartTime, heightMeters: 5.0, type: "HW", phase: "S")
        ]

        var scanner = PassageWindowScanner(calculationService: RouteCalculationService())
        scanner.scanBackwardHours = 4
        scanner.scanForwardHours  = 4
        scanner.scanIncrementSeconds = 30 * 60

        measure {
            let exp = expectation(description: "scan completes")
            Task {
                _ = await scanner.findSafeWindow(
                    route: route,
                    boatSettings: RouteFactory.boat(),
                    tideDataProvider: provider
                )
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5.0)
        }
    }
}
