import Foundation
import XCTest
@testable import Toernberechnung

/// Prüft die Fahrtdauerberechnung von `RouteCalculationService` gegen die Zeilen
/// `O61`…`O75` des "Excel-Tool-Törnberechnung_V2.1". Ein vollständiges Blatt
/// mit fünf Wegpunkten verwendet zusätzlich von Hand berechnete Erwartungen.
///
/// ```
/// O69  Fahrt über Grund = O65 + O67
/// O71  Fahrzeit         = O61 / O69          (Excel teilt für Tagesbruchteile durch 24)
/// O73  Ankunft          = L31 + O71 ;  U73 = O73 + U71 ;  AA73 = U73 + AA71
/// AM61 gesamt kum. (sm) ;  AM71 gesamt kum. (Fahrzeit)
/// ```
final class ExcelParityRouteTests: XCTestCase {

    private let accuracy = 1e-9
    private let stationID = "TEST"
    private let startTime = Date(timeIntervalSince1970: 1_768_500_000)

    // MARK: - Excel O69 / O71

    func testSpeedOverGroundIsSpeedThroughWaterPlusCurrent() {
        typealias Service = RouteCalculationService
        XCTAssertEqual(
            Service.calculateSpeedOverGround(speedThroughWaterKnots: 6, tidalCurrentKnots: 1.5),
            7.5,
            accuracy: accuracy
        )
        XCTAssertEqual(
            Service.calculateSpeedOverGround(speedThroughWaterKnots: 5, tidalCurrentKnots: -1.2),
            3.8,
            accuracy: accuracy
        )
    }

    func testTravelTimeIsDistanceDividedBySpeedOverGround() {
        typealias Service = RouteCalculationService
        XCTAssertEqual(
            Service.calculateTravelTimeHours(distanceNm: 12, speedOverGroundKnots: 7.5) ?? .nan,
            1.6,
            accuracy: accuracy
        )
        XCTAssertEqual(
            Service.calculateTravelTimeHours(distanceNm: 12, speedOverGroundKnots: 3.8) ?? .nan,
            12.0 / 3.8,
            accuracy: accuracy
        )
    }

    /// Excel liefert hier `#DIV/0!`. Die App markiert den Abschnitt als ungültig,
    /// setzt die Ankunft auf die Abfahrt und nennt die Ursache.
    func testNonPositiveSpeedOverGroundInvalidatesTheLeg() {
        for (speed, current) in [(3.0, -3.0), (2.0, -3.0)] {
            let leg = RouteLeg(
                id: UUID(),
                fromWaypointID: UUID(),
                toWaypointID: UUID(),
                distanceNm: 10,
                courseDegrees: nil,
                speedThroughWaterKnots: speed,
                tidalCurrentKnots: current
            )
            let results = RouteCalculationService.calculateLegResults(startTime: startTime, legs: [leg])
            let result = results[0]

            XCTAssertFalse(result.isValid, "SOG \(speed + current) kn darf nicht gültig sein")
            XCTAssertEqual(result.travelTimeHours, 0, accuracy: accuracy)
            XCTAssertEqual(result.arrivalTime, result.departureTime)
            XCTAssertTrue(
                result.messages.contains { $0.contains("Geschwindigkeit über Grund") },
                "Es fehlt die Begründung für die ungültige Etappe"
            )
            XCTAssertNil(RouteCalculationService.calculateTravelTimeHours(
                distanceNm: 10,
                speedOverGroundKnots: speed + current
            ))
        }
    }

    /// Excel `O73 = L31 + O71`, `U73 = O73 + U71`, `AA73 = U73 + AA71`
    /// sowie die Summenzellen `AM61` und `AM71`.
    func testArrivalTimesChainAndCumulativesAccumulate() {
        let legs = [
            makeLeg(distanceNm: 12, speedKnots: 6, currentKnots: 2),   // SOG 8,0 → 1,50 h
            makeLeg(distanceNm: 10, speedKnots: 5, currentKnots: -1),  // SOG 4,0 → 2,50 h
            makeLeg(distanceNm: 6, speedKnots: 6, currentKnots: 0)     // SOG 6,0 → 1,00 h
        ]
        let results = RouteCalculationService.calculateLegResults(startTime: startTime, legs: legs)

        XCTAssertEqual(results[0].speedOverGroundKnots, 8, accuracy: accuracy)
        XCTAssertEqual(results[0].travelTimeHours, 1.5, accuracy: accuracy)
        XCTAssertEqual(results[0].arrivalTime, startTime.addingTimeInterval(5_400))

        XCTAssertEqual(results[1].departureTime, results[0].arrivalTime)
        XCTAssertEqual(results[1].arrivalTime, startTime.addingTimeInterval(14_400))

        XCTAssertEqual(results[2].departureTime, results[1].arrivalTime)
        XCTAssertEqual(results[2].arrivalTime, startTime.addingTimeInterval(18_000))

        // AM61 / AM71
        XCTAssertEqual(results[2].cumulativeDistanceNm, 28, accuracy: accuracy)
        XCTAssertEqual(results[2].cumulativeTravelTimeHours, 5, accuracy: accuracy)
    }

    // MARK: - Vollständiges Blatt mit fünf Wegpunkten

    /// Bildet ein vollständiges Excel-Blatt nach: fünf Wegpunktspalten (L, R, X, AD, AJ),
    /// MHW- und Lottiefe-Modi, vier Streckenabschnitte und ein gemeinsamer BSH-Wasserstand.
    /// Alle Erwartungswerte wurden von Hand mit den Excel-Formeln berechnet.
    func testFiveWaypointSheetMatchesExcelReference() async {
        // Abschnitte so wählen, dass alle Fahrtdauern ganze Sekunden ergeben.
        let legSpecs: [(distance: Double, speed: Double, current: Double)] = [
            (12.0, 6.0, 2.0),   // SOG 8,0 → 1,50 h → 5 400 s
            (10.0, 5.0, -1.0),  // SOG 4,0 → 2,50 h → 9 000 s
            (6.0, 6.0, 0.0),    // SOG 6,0 → 1,00 h → 3 600 s
            (4.5, 5.5, 0.5)     // SOG 6,0 → 0,75 h → 2 700 s
        ]
        let arrivals: [TimeInterval] = [0, 5_400, 14_400, 18_000, 20_700]

        let waypointSpecs: [WaypointSpec] = [
            WaypointSpec(mode: .meanHighWater, level: 3.10, chartDepth: 1.00, mth: 2.40, deviationHours: 1.0),
            WaypointSpec(mode: .lottiefe, level: 2.50, chartDepth: nil, mth: 2.40, deviationHours: 2.0),
            WaypointSpec(mode: .meanHighWater, level: 3.00, chartDepth: -0.50, mth: 3.00, deviationHours: 3.0),
            WaypointSpec(mode: .lottiefe, level: 1.80, chartDepth: nil, mth: 2.40, deviationHours: 0.0),
            WaypointSpec(mode: .meanHighWater, level: 3.20, chartDepth: 2.00, mth: 2.40, deviationHours: 5.0)
        ]

        let route = makeSheetRoute(
            waypointSpecs: waypointSpecs,
            legSpecs: legSpecs,
            arrivals: arrivals
        )

        let provider = MockTideDataProvider()
        provider.correctionsByStation[stationID] = WaterLevelCorrectionResolution(
            meters: -0.10,                       // Excel $AD$13
            quality: .localOfficial,
            localStationID: stationID,
            sourceStationID: stationID,
            sourceStationName: "Testpegel",
            issuedAt: startTime,
            detail: "Lokale amtliche Scheitelwertvorhersage."
        )

        let result = await RouteCalculationService().calculate(
            route: route,
            boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0),
            tideDataProvider: provider
        )

        let expected: [ColumnExpectation] = [
            ColumnExpectation(arrival: 0, oneTwelfth: 0.20, fmw: 0.20,
                              base: 2.90, hg: 2.80, wt: 3.80, wuk: 2.70, status: .go),
            ColumnExpectation(arrival: 5_400, oneTwelfth: 0.20, fmw: 0.60,
                              base: 1.90, hg: nil, wt: 1.80, wuk: 0.70, status: .go),
            ColumnExpectation(arrival: 14_400, oneTwelfth: 0.25, fmw: 1.50,
                              base: 1.50, hg: 1.40, wt: 0.90, wuk: -0.20, status: .noGo),
            ColumnExpectation(arrival: 18_000, oneTwelfth: 0.20, fmw: 0.00,
                              base: 1.80, hg: nil, wt: 1.70, wuk: 0.60, status: .go),
            ColumnExpectation(arrival: 20_700, oneTwelfth: 0.20, fmw: 2.20,
                              base: 1.00, hg: 0.90, wt: 2.90, wuk: 1.80, status: .go)
        ]

        XCTAssertEqual(result.waypointResults.count, 5)
        for (index, expectation) in expected.enumerated() {
            assertColumn(result.waypointResults[index], matches: expectation, index: index)
        }

        XCTAssertEqual(result.totalDistanceNm, 32.5, accuracy: accuracy)          // AM61
        XCTAssertEqual(result.totalTravelTimeHours, 5.75, accuracy: accuracy)     // AM71
        XCTAssertEqual(result.worstClearanceUnderKeel ?? .nan, -0.20, accuracy: accuracy)
        XCTAssertEqual(result.tidalStatus, .noGo)
    }

    /// Fasst fünf Spalten und vier Streckenabschnitte in einem `RoutePlan` zusammen.
    private func makeSheetRoute(
        waypointSpecs: [WaypointSpec],
        legSpecs: [(distance: Double, speed: Double, current: Double)],
        arrivals: [TimeInterval]
    ) -> RoutePlan {
        var waypoints: [RouteWaypoint] = []
        for (index, spec) in waypointSpecs.enumerated() {
            let arrival = startTime.addingTimeInterval(arrivals[index])
            waypoints.append(makeWaypoint(
                name: "WP \(index + 1)",
                mode: spec.mode,
                level: spec.level,
                chartDepth: spec.chartDepth,
                mth: spec.mth,
                referenceHighWater: arrival.addingTimeInterval(-spec.deviationHours * 3_600)
            ))
        }

        let legs = legSpecs.enumerated().map { index, spec in
            RouteLeg(
                id: UUID(),
                fromWaypointID: waypoints[index].id,
                toWaypointID: waypoints[index + 1].id,
                distanceNm: spec.distance,
                courseDegrees: nil,
                speedThroughWaterKnots: spec.speed,
                tidalCurrentKnots: spec.current
            )
        }

        return RoutePlan(
            id: UUID(),
            date: startTime,
            routeName: "Excel-Referenzblatt",
            plannedStartTime: startTime,
            waypoints: waypoints,
            legs: legs,
            bshWaterLevelCorrectionMeters: nil,
            tidalStateLabel: "Mitteltide"
        )
    }

    /// Prüft eine Excel-Spalte (`L`, `R`, `X`, `AD`, `AJ`) Zelle für Zelle.
    private func assertColumn(
        _ waypoint: WaypointCalculationResult,
        matches expectation: ColumnExpectation,
        index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let column = ["L", "R", "X", "AD", "AJ"][index]

        XCTAssertEqual(
            waypoint.arrivalTime, startTime.addingTimeInterval(expectation.arrival),
            "Spalte \(column): L31", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.oneTwelfthMeters ?? .nan, expectation.oneTwelfth,
            accuracy: accuracy, "Spalte \(column): L35", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.missingWaterFmWMeters ?? .nan, expectation.fmw,
            accuracy: accuracy, "Spalte \(column): L39", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.baseWaterAtTideMeters ?? .nan, expectation.base,
            accuracy: accuracy, "Spalte \(column): L45", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.bshWaterLevelCorrectionMeters, -0.10,
            accuracy: accuracy, "Spalte \(column): L47", file: file, line: line
        )
        if let expectedHG = expectation.hg {
            XCTAssertEqual(
                waypoint.tideHeightHGMeters ?? .nan, expectedHG,
                accuracy: accuracy, "Spalte \(column): L49", file: file, line: line
            )
        } else {
            XCTAssertNil(
                waypoint.tideHeightHGMeters,
                "Spalte \(column): L49 muss leer sein", file: file, line: line
            )
        }
        XCTAssertEqual(
            waypoint.availableWaterDepthWTMeters ?? .nan, expectation.wt,
            accuracy: accuracy, "Spalte \(column): L53", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.clearanceUnderKeelWuKMeters ?? .nan, expectation.wuk,
            accuracy: accuracy, "Spalte \(column): L57", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.status, expectation.status,
            "Spalte \(column): Status", file: file, line: line
        )
    }

    // MARK: - Typen für Testdaten

    /// Eine Excel-Wegpunktspalte: Modus, Bezugshöhe (L41/L43), Kartentiefe (L51),
    /// mittlerer Tidenhub (L33) und gewünschter Abstand zum Hochwasser (L37).
    private struct WaypointSpec {
        let mode: WaypointCalculationMode
        let level: Double
        let chartDepth: Double?
        let mth: Double
        let deviationHours: Double
    }

    /// Von Hand berechnete Erwartungswerte einer Excel-Spalte.
    private struct ColumnExpectation {
        let arrival: TimeInterval   // L31, relativ zur geplanten Startzeit
        let oneTwelfth: Double      // L35
        let fmw: Double             // L39
        let base: Double            // L45
        let hg: Double?             // L49: nil bedeutet "leer"
        let wt: Double              // L53
        let wuk: Double             // L57
        let status: WaypointStatus
    }

    // MARK: - Hilfsfunktionen für Testdaten

    private func makeLeg(distanceNm: Double, speedKnots: Double, currentKnots: Double) -> RouteLeg {
        RouteLeg(
            id: UUID(),
            fromWaypointID: UUID(),
            toWaypointID: UUID(),
            distanceNm: distanceNm,
            courseDegrees: nil,
            speedThroughWaterKnots: speedKnots,
            tidalCurrentKnots: currentKnots
        )
    }

    private func makeWaypoint(
        name: String,
        mode: WaypointCalculationMode,
        level: Double,
        chartDepth: Double?,
        mth: Double,
        referenceHighWater: Date
    ) -> RouteWaypoint {
        func sourced(_ value: Double?) -> SourcedValue<Double>? {
            value.map { SourcedValue(value: $0, source: .manual, sourceNotes: nil) }
        }
        return RouteWaypoint(
            id: UUID(),
            name: name,
            latitude: 53.7,
            longitude: 7.2,
            tidalReferenceStation: "Testpegel",
            tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: sourced(mth),
            meanHighWaterMeters: mode == .meanHighWater ? sourced(level) : nil,
            lottiefeMeters: mode == .lottiefe ? sourced(level) : nil,
            chartDepthMeters: sourced(chartDepth),
            calculationMode: mode,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: referenceHighWater,
            notes: "",
            category: nil,
            island: nil
        )
    }
}
