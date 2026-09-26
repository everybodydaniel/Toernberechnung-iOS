import Foundation
import XCTest
@testable import Toernberechnung

/// Vergleich mit dem ausgefüllten Referenzblatt der Werkzeugautoren:
/// "Excel-Tool-Törnberechnung - Beispiel 2 - Emden-Norderney".
///
/// Gemeinsame Eingaben: Tiefgang 1,10 m · BSH-Wasserstand +0,30 m · Tide "Mt".
///
/// | Sp. | WP | Bezugsort | HW | Versatz | Ankunft | MTH | Modus | Niveau | Kartentiefe |
/// |---|---|---|---|---|---|---|---|---|---|
/// | L  | Emden Außenhafen   | Emden     | 16:25 | 0    | 10:00 | 3,3 | MHW      | 3,90 | +1,20 |
/// | R  | Wattenhoch Emshörn | Borkum    | 14:56 | +12′ | 13:24 | 2,6 | Lottiefe | 2,30 | –     |
/// | X  | Wattenhoch Memmert | Norderney | 15:19 | 0    | 15:19 | 2,6 | MHW      | 3,10 | −0,80 |
/// | AD | Norderney Hafen    | Norderney | 15:19 | 0    | 16:19 | 2,5 | MHW      | 3,10 | +1,20 |
///
/// Streckenabschnitte: 17,0 sm bei 6 kn und −1 kn Strömung · 11,5 sm bei 6 kn · 6,0 sm bei 6 kn.
final class ExcelParityReferenceSheetTests: XCTestCase {

    private let accuracy = 1e-6
    private let stationEmden = "507P"
    private let stationBorkum = "101P"
    private let stationNorderney = "111P"

    /// Mitternacht am Datum des Referenzblatts. Alle weiteren Zeiten sind Abstände in Sekunden.
    private let midnight = Date(timeIntervalSince1970: 1_623_369_600)

    private func time(_ hours: Int, _ minutes: Int) -> Date {
        midnight.addingTimeInterval(Double(hours) * 3_600 + Double(minutes) * 60)
    }

    // MARK: - Fahrtdauerberechnung (Excel O61…AM71)

    func testReferenceSheetTravelBlockMatches() {
        let legs = [
            makeLeg(distanceNm: 17.0, speedKnots: 6, currentKnots: -1),
            makeLeg(distanceNm: 11.5, speedKnots: 6, currentKnots: 0),
            makeLeg(distanceNm: 6.0, speedKnots: 6, currentKnots: 0)
        ]
        let results = RouteCalculationService.calculateLegResults(
            startTime: time(10, 0),
            legs: legs
        )

        // O69 / U69 / AA69
        XCTAssertEqual(results[0].speedOverGroundKnots, 5, accuracy: accuracy)
        XCTAssertEqual(results[1].speedOverGroundKnots, 6, accuracy: accuracy)
        XCTAssertEqual(results[2].speedOverGroundKnots, 6, accuracy: accuracy)

        // O71 / U71 / AA71, von Excel-Tagesbruchteilen in Stunden umgerechnet
        XCTAssertEqual(results[0].travelTimeHours, 0.141_666_666_666_666_66 * 24, accuracy: accuracy)
        XCTAssertEqual(results[1].travelTimeHours, 0.079_861_111_111_111_12 * 24, accuracy: accuracy)
        XCTAssertEqual(results[2].travelTimeHours, 0.041_666_666_666_666_664 * 24, accuracy: accuracy)

        // O73 / U73 / AA73
        XCTAssertEqual(results[0].arrivalTime.timeIntervalSince(time(13, 24)), 0, accuracy: 1e-6)
        XCTAssertEqual(results[1].arrivalTime.timeIntervalSince(time(15, 19)), 0, accuracy: 1e-6)
        XCTAssertEqual(results[2].arrivalTime.timeIntervalSince(time(16, 19)), 0, accuracy: 1e-6)

        // AM61 / AM71
        XCTAssertEqual(results[2].cumulativeDistanceNm, 34.5, accuracy: accuracy)
        XCTAssertEqual(
            results[2].cumulativeTravelTimeHours,
            0.263_194_444_444_444_45 * 24,
            accuracy: accuracy
        )
    }

    // MARK: - Tiefenberechnung (Excel L35…L57)

    func testReferenceSheetDepthChainMatches() async {
        let result = await calculateReferenceSheet()
        XCTAssertEqual(result.waypointResults.count, 4)

        // Spalte L — Emden Außenhafen, 6,42 h vor HW ⇒ volle 12/12 Fehlmenge.
        assertColumn(
            result.waypointResults[0], name: "L",
            oneTwelfth: 0.275, deviation: 6.416_666_7, missingWater: 3.3,
            base: 0.6, tideHeight: 0.9, availableDepth: 2.1, clearance: 1.0
        )

        // Spalte R — Wattenhoch Emshörn, Lottiefe-Modus ⇒ HG bleibt leer.
        assertColumn(
            result.waypointResults[1], name: "R",
            oneTwelfth: 0.216_666_7, deviation: 1.733_333_3, missingWater: 0.65,
            base: 1.65, tideHeight: nil, availableDepth: 1.95, clearance: 0.85
        )

        // Spalte X: Wattenhoch Memmert, Ankunft genau zum Hochwasser.
        //
        // Hier unterscheiden sich App und Referenzblatt durch Rundung:
        //
        //   X29 (eingegebenes HW)     = 0.638194444444444_4
        //   X31 (berechnete Ankunft)  = 0.638194444444444_51   (L31 + O71 + U71)
        //   ⇒ X37 = 2,66e-15 h = 9,59 Pikosekunden
        //
        // Excel vergleicht in `IF(X37=0,"keine Fehlmenge",…)` ohne Toleranz mit 0.
        // Die winzige Abweichung fällt damit in den ersten Stundenbereich und
        // ergibt ein volles Zwölftel Fehlmenge: 0,2167 m. Das Blatt zeigt dadurch
        // 1,28 m Wasser unter Kiel statt 1,50 m.
        //
        // `TwelfthsRuleStrategy.hwEpsilonHours` erkennt mit 0,01 h (36 s) Toleranz
        // die geplante Ankunft zum Hochwasser. In Spalte AD beträgt die berechnete
        // Abweichung 1.000000000000001_8 h; Excel wählt dort trotzdem über `<=1`
        // ein Zwölftel, ebenso wie die App. Die Rundung wirkt also uneinheitlich.
        //
        // Die App übernimmt deshalb keine zusätzliche Fehlmenge für eine beliebig
        // kleine Rundungsabweichung.
        assertColumn(
            result.waypointResults[2], name: "X",
            oneTwelfth: 0.216_666_7, deviation: 0, missingWater: 0,
            base: 3.1, tideHeight: 3.4,
            availableDepth: 2.6, clearance: 1.5
        )

        // Spalte AD — Norderney Hafen, genau 1 h nach HW.
        assertColumn(
            result.waypointResults[3], name: "AD",
            oneTwelfth: 0.208_333_3, deviation: 1.0, missingWater: 0.208_333_3,
            base: 2.891_666_7, tideHeight: 3.191_666_7,
            availableDepth: 4.391_666_7, clearance: 3.291_666_7
        )

        XCTAssertEqual(result.totalDistanceNm, 34.5, accuracy: accuracy)
    }

    /// Sichert die Begründung der Abweichung in Spalte X ab, damit eine Änderung
    /// an `hwEpsilonHours` den Excel-Rundungsfehler nicht unbemerkt wieder einführt.
    func testPicosecondDeviationIsTreatedAsExactHighWater() {
        let strategy = TwelfthsRuleStrategy()
        let excelNoiseHours = 2.664_535_259_100_375_7e-15

        let atNoise = strategy.missingWater(
            deviationHours: excelNoiseHours,
            meanTidalRangeMeters: 2.6
        )
        XCTAssertEqual(atNoise.fmwMeters, 0, accuracy: 1e-12)
        XCTAssertEqual(atNoise.messages, ["keine Fehlmenge"])

        // Excel würde für diese Pikosekunden ein volles Zwölftel Fehlmenge berechnen.
        XCTAssertEqual(2.6 / 12, 0.216_666_666_666_666_67, accuracy: 1e-12)

        // Direkt außerhalb der Toleranz gilt wieder die normale Staffel.
        // Die Toleranz fängt nur kleine Abweichungen nahe dem Hochwasser ab.
        let justOutside = strategy.missingWater(
            deviationHours: 0.02,
            meanTidalRangeMeters: 2.6
        )
        XCTAssertEqual(justOutside.fmwMeters, 2.6 / 12, accuracy: 1e-12)
    }

    // MARK: - Testdaten

    private func calculateReferenceSheet() async -> RouteCalculationResult {
        let waypoints = [
            makeWaypoint(
                name: "Emden Außenhafen", stationID: stationEmden, station: "Emden",
                referenceHighWater: time(16, 25), offsetMinutes: 0,
                mth: 3.3, mode: .meanHighWater, level: 3.9, chartDepth: 1.2
            ),
            makeWaypoint(
                name: "Wattenhoch Emshörn Osterems", stationID: stationBorkum, station: "Borkum",
                referenceHighWater: time(14, 56), offsetMinutes: 12,
                mth: 2.6, mode: .lottiefe, level: 2.3, chartDepth: nil
            ),
            makeWaypoint(
                name: "Wattenhoch Memmert Wattfahrwasser", stationID: stationNorderney,
                station: "Norderney",
                referenceHighWater: time(15, 19), offsetMinutes: 0,
                mth: 2.6, mode: .meanHighWater, level: 3.1, chartDepth: -0.8
            ),
            makeWaypoint(
                name: "Norderney Hafen", stationID: stationNorderney, station: "Norderney",
                referenceHighWater: time(15, 19), offsetMinutes: 0,
                mth: 2.5, mode: .meanHighWater, level: 3.1, chartDepth: 1.2
            )
        ]

        let legSpecs: [(distance: Double, speed: Double, current: Double)] = [
            (17.0, 6, -1), (11.5, 6, 0), (6.0, 6, 0)
        ]
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

        let route = RoutePlan(
            id: UUID(),
            date: midnight,
            routeName: "Emden - Norderney",
            plannedStartTime: time(10, 0),
            waypoints: waypoints,
            legs: legs,
            bshWaterLevelCorrectionMeters: nil,
            tidalStateLabel: "Mt"
        )

        // Excel $AD$13 = +0,30 m als amtliche lokale Vorhersage liefern, damit
        // der Status nicht herabgesetzt wird und die Tiefenwerte sichtbar bleiben.
        let provider = MockTideDataProvider()
        for stationID in [stationEmden, stationBorkum, stationNorderney] {
            provider.correctionsByStation[stationID] = WaterLevelCorrectionResolution(
                meters: 0.3,
                quality: .localOfficial,
                localStationID: stationID,
                sourceStationID: stationID,
                sourceStationName: stationID,
                issuedAt: midnight,
                detail: "Lokale amtliche Scheitelwertvorhersage."
            )
        }

        return await RouteCalculationService(tidalHeightStrategy: TwelfthsRuleStrategy()).calculate(
            route: route,
            boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0),
            tideDataProvider: provider
        )
    }

    // Die Vergleichswerte entsprechen den Spalten des Referenzblatts.
    // swiftlint:disable:next function_parameter_count
    private func assertColumn(
        _ waypoint: WaypointCalculationResult,
        name: String,
        oneTwelfth: Double,
        deviation: Double,
        missingWater: Double,
        base: Double,
        tideHeight: Double?,
        availableDepth: Double,
        clearance: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            waypoint.oneTwelfthMeters ?? .nan, oneTwelfth,
            accuracy: accuracy, "Spalte \(name): L35", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.deviationHours ?? .nan, deviation,
            accuracy: accuracy, "Spalte \(name): L37", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.missingWaterFmWMeters ?? .nan, missingWater,
            accuracy: accuracy, "Spalte \(name): L39", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.baseWaterAtTideMeters ?? .nan, base,
            accuracy: accuracy, "Spalte \(name): L45", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.bshWaterLevelCorrectionMeters, 0.3,
            accuracy: accuracy, "Spalte \(name): L47", file: file, line: line
        )
        if let tideHeight {
            XCTAssertEqual(
                waypoint.tideHeightHGMeters ?? .nan, tideHeight,
                accuracy: accuracy, "Spalte \(name): L49", file: file, line: line
            )
        } else {
            XCTAssertNil(
                waypoint.tideHeightHGMeters,
                "Spalte \(name): L49 muss leer sein", file: file, line: line
            )
        }
        XCTAssertEqual(
            waypoint.availableWaterDepthWTMeters ?? .nan, availableDepth,
            accuracy: accuracy, "Spalte \(name): L53", file: file, line: line
        )
        XCTAssertEqual(
            waypoint.clearanceUnderKeelWuKMeters ?? .nan, clearance,
            accuracy: accuracy, "Spalte \(name): L57", file: file, line: line
        )
    }

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

    // Die Vergleichswerte entsprechen den Spalten des Referenzblatts.
    // swiftlint:disable:next function_parameter_count
    private func makeWaypoint(
        name: String,
        stationID: String,
        station: String,
        referenceHighWater: Date,
        offsetMinutes: Int,
        mth: Double,
        mode: WaypointCalculationMode,
        level: Double,
        chartDepth: Double?
    ) -> RouteWaypoint {
        func sourced(_ value: Double?) -> SourcedValue<Double>? {
            value.map { SourcedValue(value: $0, source: .manual, sourceNotes: nil) }
        }
        return RouteWaypoint(
            id: UUID(),
            name: name,
            latitude: nil,
            longitude: nil,
            tidalReferenceStation: station,
            tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: offsetMinutes,
            meanTidalRangeMeters: sourced(mth),
            meanHighWaterMeters: mode == .meanHighWater ? sourced(level) : nil,
            lottiefeMeters: mode == .lottiefe ? sourced(level) : nil,
            chartDepthMeters: sourced(chartDepth),
            calculationMode: mode,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: referenceHighWater,
            notes: "",
            category: name.hasPrefix("Wattenhoch") ? "Wattenhoch" : "Hafen",
            island: nil
        )
    }
}
