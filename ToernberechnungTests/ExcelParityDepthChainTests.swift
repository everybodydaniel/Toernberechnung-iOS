import Foundation
import XCTest
@testable import Toernberechnung

/// Prüft, ob die Tiefenberechnung von `RouteCalculationService` die Zeilen
/// `L29`…`L57` des "Excel-Tool-Törnberechnung_V2.1" nachbildet.
///
/// ```
/// L29  HW am WP        = L23 ± M25/M27
/// L35  1/12tel         = L33 / 12
/// L37  Abweichung      = ABS(L29 - L31) * 24
/// L39  FmW             = <Staffel> * L35
/// L45  Basis - FmW     = (L41 | L43) - L39
/// L47  BSH-Wasserstand = $AD$13
/// L49  HG              = L45 + L47          ("leer" bei Lottiefe)
/// L53  WT              = L45 + L47 + L51
/// L57  WuK             = L53 - M55
/// ```
///
/// Jeder Fall verwendet `calculate(route:…)`. Die Prüfungen erfassen dadurch
/// auch die Auswahl der Eingabedaten und nicht nur die Rechenschritte.
final class ExcelParityDepthChainTests: XCTestCase {

    private let accuracy = 1e-9
    private let stationID = "TEST"
    /// Excel `L31` für Wegpunkt 1: geplante Startzeit.
    private let startTime = Date(timeIntervalSince1970: 1_768_500_000)

    // MARK: - Testdaten

    /// Erstellt eine Route mit zwei Wegpunkten und Fahrtdauer 0. Beide Punkte
    /// werden zu `startTime` erreicht; `deviationHours` bestimmt allein den
    /// Abstand zum Hochwasser.
    ///
    /// Der Anbieter liefert die Wasserstandskorrektur mit `.localOfficial`,
    /// damit die Excel-Rechenschritte unabhängig von Quellenhinweisen geprüft werden.
    private func makeRoute(
        mode: WaypointCalculationMode,
        meanHighWaterMeters: Double? = nil,
        lottiefeMeters: Double? = nil,
        chartDepthMeters: Double? = nil,
        meanTidalRangeMeters: Double,
        deviationHours: Double,
        highWaterOffsetMinutes: Int = 0
    ) -> RoutePlan {
        func sourced(_ value: Double?) -> SourcedValue<Double>? {
            value.map { SourcedValue(value: $0, source: .manual, sourceNotes: nil) }
        }

        // Excel L23 enthält das Referenzhochwasser. L29 addiert den Wegpunktversatz.
        // Die Referenzzeit wird entsprechend zurückgesetzt, damit der gewünschte Abstand entsteht.
        let referenceHighWater = startTime
            .addingTimeInterval(-deviationHours * 3_600)
            .addingTimeInterval(-Double(highWaterOffsetMinutes) * 60)

        let start = RouteWaypoint(
            id: UUID(),
            name: "WP 1",
            latitude: 53.7,
            longitude: 7.2,
            tidalReferenceStation: "Testpegel",
            tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: highWaterOffsetMinutes,
            meanTidalRangeMeters: sourced(meanTidalRangeMeters),
            meanHighWaterMeters: sourced(meanHighWaterMeters),
            lottiefeMeters: sourced(lottiefeMeters),
            chartDepthMeters: sourced(chartDepthMeters),
            calculationMode: mode,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: referenceHighWater,
            notes: "",
            category: "Wattenhoch",
            island: nil
        )
        var destination = start
        destination.id = UUID()
        destination.name = "WP 2"

        let leg = RouteLeg(
            id: UUID(),
            fromWaypointID: start.id,
            toWaypointID: destination.id,
            distanceNm: 0,
            courseDegrees: nil,
            speedThroughWaterKnots: 6,
            tidalCurrentKnots: 0
        )

        return RoutePlan(
            id: UUID(),
            date: startTime,
            routeName: "Parität",
            plannedStartTime: startTime,
            waypoints: [start, destination],
            legs: [leg],
            bshWaterLevelCorrectionMeters: nil,
            tidalStateLabel: "Mitteltide"
        )
    }

    /// Excel `$AD$13` als amtliche lokale Vorhersage liefern.
    /// Diese Testdaten erzeugen keinen zusätzlichen Quellenhinweis.
    private func makeProvider(waterLevelCorrectionMeters: Double) -> MockTideDataProvider {
        let provider = MockTideDataProvider()
        provider.correctionsByStation[stationID] = WaterLevelCorrectionResolution(
            meters: waterLevelCorrectionMeters,
            quality: .localOfficial,
            localStationID: stationID,
            sourceStationID: stationID,
            sourceStationName: "Testpegel",
            issuedAt: startTime,
            detail: "Lokale amtliche Scheitelwertvorhersage."
        )
        return provider
    }

    private func calculate(
        _ route: RoutePlan,
        waterLevelCorrectionMeters: Double,
        draftMeters: Double = 1.1,
        safetyMarginMeters: Double = 0
    ) async -> WaypointCalculationResult {
        let result = await RouteCalculationService().calculate(
            route: route,
            boatSettings: BoatSettings(
                draftMeters: draftMeters,
                safetyMarginMeters: safetyMarginMeters
            ),
            tideDataProvider: makeProvider(waterLevelCorrectionMeters: waterLevelCorrectionMeters)
        )
        return result.waypointResults[0]
    }

    // MARK: - Fall A: MHW-Modus mit negativer Kartentiefe

    /// Werte des Wattenhochs Memmert aus `wadden_sea_catalog.json`.
    /// Eine negative Kartentiefe bedeutet, dass der Punkt oberhalb des Kartennulls trockenfällt.
    func testMHWModeWithNegativeChartDepthMatchesExcelColumn() async {
        let route = makeRoute(
            mode: .meanHighWater,
            meanHighWaterMeters: 3.10,
            chartDepthMeters: -0.80,
            meanTidalRangeMeters: 2.60,
            deviationHours: 3.0
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: -0.25)

        XCTAssertEqual(waypoint.oneTwelfthMeters ?? .nan, 2.60 / 12, accuracy: accuracy)      // L35
        XCTAssertEqual(waypoint.deviationHours ?? .nan, 3.0, accuracy: accuracy)              // L37
        XCTAssertEqual(waypoint.missingWaterFmWMeters ?? .nan, 1.30, accuracy: accuracy)      // L39
        XCTAssertEqual(waypoint.baseWaterAtTideMeters ?? .nan, 1.80, accuracy: accuracy)      // L45
        XCTAssertEqual(waypoint.bshWaterLevelCorrectionMeters, -0.25, accuracy: accuracy)     // L47
        XCTAssertEqual(waypoint.tideHeightHGMeters ?? .nan, 1.55, accuracy: accuracy)         // L49
        XCTAssertEqual(waypoint.chartDepthMetersApplied ?? .nan, -0.80, accuracy: accuracy)   // L51
        XCTAssertEqual(waypoint.availableWaterDepthWTMeters ?? .nan, 0.75, accuracy: accuracy) // L53
        XCTAssertEqual(waypoint.boatDraftMeters, 1.10, accuracy: accuracy)                    // M55
        XCTAssertEqual(waypoint.clearanceUnderKeelWuKMeters ?? .nan, -0.35, accuracy: accuracy) // L57
        XCTAssertEqual(waypoint.status, .noGo)
    }

    // MARK: - Fall B: MHW-Modus mit ausreichender Tiefe

    func testMHWModePassableMatchesExcelColumn() async {
        let route = makeRoute(
            mode: .meanHighWater,
            meanHighWaterMeters: 3.10,
            chartDepthMeters: 1.20,
            meanTidalRangeMeters: 2.50,
            deviationHours: 1.0
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: 0)

        let oneTwelfth = 2.50 / 12
        XCTAssertEqual(waypoint.missingWaterFmWMeters ?? .nan, oneTwelfth, accuracy: accuracy)
        XCTAssertEqual(waypoint.baseWaterAtTideMeters ?? .nan, 3.10 - oneTwelfth, accuracy: accuracy)
        XCTAssertEqual(waypoint.tideHeightHGMeters ?? .nan, 3.10 - oneTwelfth, accuracy: accuracy)
        XCTAssertEqual(
            waypoint.availableWaterDepthWTMeters ?? .nan,
            3.10 - oneTwelfth + 1.20,
            accuracy: accuracy
        )
        XCTAssertEqual(
            waypoint.clearanceUnderKeelWuKMeters ?? .nan,
            3.10 - oneTwelfth + 1.20 - 1.10,
            accuracy: accuracy
        )
        XCTAssertEqual(waypoint.status, .go)
    }

    // MARK: - Fall C: Lottiefe-Modus

    func testLottiefeModeLeavesTideHeightEmpty() async {
        let route = makeRoute(
            mode: .lottiefe,
            lottiefeMeters: 2.30,
            meanTidalRangeMeters: 2.60,
            deviationHours: 2.0
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: 0.15)

        XCTAssertEqual(waypoint.missingWaterFmWMeters ?? .nan, 0.65, accuracy: accuracy)       // L39
        XCTAssertEqual(waypoint.baseWaterAtTideMeters ?? .nan, 1.65, accuracy: accuracy)       // L45
        XCTAssertEqual(waypoint.availableWaterDepthWTMeters ?? .nan, 1.80, accuracy: accuracy) // L53
        XCTAssertEqual(waypoint.clearanceUnderKeelWuKMeters ?? .nan, 0.70, accuracy: accuracy) // L57
        // Excel L49 zeigt im Lottiefe-Modus den Text "leer".
        XCTAssertNil(waypoint.tideHeightHGMeters)
        XCTAssertNil(waypoint.chartDepthMetersApplied)
        XCTAssertEqual(waypoint.status, .go)
    }

    /// Prüft, dass Kartentiefe im Lottiefe-Modus nicht angewendet wird
    /// ("nicht bei Lottiefe" in Excel). Ein gesetzter Wert darf kein Ergebnis ändern.
    func testLottiefeModeIgnoresChartDepthEntirely() async {
        let withoutChartDepth = await calculate(
            makeRoute(
                mode: .lottiefe,
                lottiefeMeters: 2.30,
                meanTidalRangeMeters: 2.60,
                deviationHours: 2.0
            ),
            waterLevelCorrectionMeters: 0.15
        )
        let withChartDepth = await calculate(
            makeRoute(
                mode: .lottiefe,
                lottiefeMeters: 2.30,
                chartDepthMeters: 5.0,
                meanTidalRangeMeters: 2.60,
                deviationHours: 2.0
            ),
            waterLevelCorrectionMeters: 0.15
        )

        XCTAssertEqual(
            withChartDepth.availableWaterDepthWTMeters,
            withoutChartDepth.availableWaterDepthWTMeters
        )
        XCTAssertEqual(
            withChartDepth.clearanceUnderKeelWuKMeters,
            withoutChartDepth.clearanceUnderKeelWuKMeters
        )
        XCTAssertNil(withChartDepth.chartDepthMetersApplied)
        XCTAssertEqual(withChartDepth.status, withoutChartDepth.status)
    }

    // MARK: - Fall D: Abstand über einen Gezeitenzyklus

    /// Excel rechnet hier weiter: `L39` wird Text, `L45` fängt ihn mit `IFERROR`
    /// ab und verwendet `SUM(L41:Q44)`, also MHW ohne Fehlmenge.
    /// Die App lehnt diese Berechnung ab.
    func testDeviationBeyondTidalCycleIsInvalidInsteadOfSilentlyIgnored() async {
        let route = makeRoute(
            mode: .meanHighWater,
            meanHighWaterMeters: 3.10,
            chartDepthMeters: 1.20,
            meanTidalRangeMeters: 2.50,
            deviationHours: 13.0
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: 0)

        XCTAssertEqual(waypoint.status, .invalid)
        XCTAssertNil(waypoint.missingWaterFmWMeters)
        XCTAssertNil(waypoint.availableWaterDepthWTMeters)
        XCTAssertNil(waypoint.clearanceUnderKeelWuKMeters)
    }

    // MARK: - Fall E: Hochwasserversatz (Excel L29)

    /// Excel `L29 = IF(M25>0, L23+M25, IF(M27>0, L23-M27, L23))`.
    func testHighWaterOffsetShiftsTheWaypointHighWater() async {
        let route = makeRoute(
            mode: .meanHighWater,
            meanHighWaterMeters: 3.10,
            chartDepthMeters: 1.20,
            meanTidalRangeMeters: 2.50,
            deviationHours: 2.0,
            highWaterOffsetMinutes: 45
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: 0)

        // Die Testdaten gleichen den Versatz aus. Der Abstand bleibt bei 2 h;
        // das Wegpunkthochwasser liegt 45 Minuten nach dem Referenzhochwasser.
        XCTAssertEqual(waypoint.deviationHours ?? .nan, 2.0, accuracy: 1e-6)
        let waypointHighWater = try? XCTUnwrap(waypoint.relevantHighWaterTime)
        XCTAssertEqual(
            waypointHighWater?.timeIntervalSince1970 ?? .nan,
            startTime.addingTimeInterval(-2 * 3_600).timeIntervalSince1970,
            accuracy: 1e-6
        )
    }

    // MARK: - Fall F: Statusgrenzen

    func testWaypointStatusBoundaries() {
        typealias Service = RouteCalculationService
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: -0.01, safetyMargin: 0), .noGo)
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: 0, safetyMargin: 0), .go)
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: 0, safetyMargin: 0.30), .warning)
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: 0.29, safetyMargin: 0.30), .warning)
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: 0.30, safetyMargin: 0.30), .go)
    }

    func testRouteStatusAggregationPrecedence() {
        typealias Service = RouteCalculationService
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.go, .go]), .go)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.go, .warning]), .warning)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.go, .incomplete]), .incomplete)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.warning, .incomplete]), .incomplete)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.warning, .noGo]), .noGo)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.invalid, .go]), .incomplete)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.invalid, .noGo]), .noGo)
    }
}
