import Foundation
import XCTest
@testable import Toernberechnung

/// Die BSH-Wasserstandsabweichung wird zeitabhängig statt nur am Hochwassergipfel angewendet.
/// Diese Tests sichern zwei Eigenschaften ab:
///
/// 1. Fehlende oder unbrauchbare Kurvendaten verwenden den bisherigen Einzelwert.
/// 2. Innerhalb der Kurvenabdeckung bleibt die Quellenqualität erhalten;
///    außerhalb gelten die ausdrücklich vorläufigen Ersatzwerte.
final class WaterLevelCorrectionSeriesTests: XCTestCase {

    private let accuracy = 1e-9
    private let stationID = "111P"
    private let base = Date(timeIntervalSince1970: 1_768_500_000)

    private func peak(
        meters: Double = -0.20,
        quality: WaterLevelCorrectionQuality = .localOfficial
    ) -> WaterLevelCorrectionResolution {
        WaterLevelCorrectionResolution(
            meters: meters,
            quality: quality,
            localStationID: stationID,
            sourceStationID: stationID,
            sourceStationName: "Norderney, Riffgat",
            issuedAt: base,
            detail: "Lokale amtliche Scheitelwertvorhersage."
        )
    }

    /// 10:00 → −0,30 m · 10:30 → −0,10 m
    private func slopingSeries(
        quality: WaterLevelCorrectionQuality = .localOfficial
    ) -> WaterLevelCorrectionSeries {
        WaterLevelCorrectionSeries(
            samples: [
                .init(time: base, meters: -0.30),
                .init(time: base.addingTimeInterval(1_800), meters: -0.10)
            ],
            fallback: peak(quality: quality)
        )
    }

    // MARK: - Auswertung der Zeitreihe

    func testInterpolatesLinearlyBetweenSamples() {
        let series = slopingSeries()
        XCTAssertEqual(series.resolution(at: base).meters, -0.30, accuracy: accuracy)
        XCTAssertEqual(
            series.resolution(at: base.addingTimeInterval(900)).meters,
            -0.20, accuracy: accuracy
        )
        XCTAssertEqual(
            series.resolution(at: base.addingTimeInterval(1_800)).meters,
            -0.10, accuracy: accuracy
        )
    }

    func testFallsBackToAstronomicalZeroOutsideTheCoveredSpan() {
        let series = slopingSeries()
        let before = series.resolution(at: base.addingTimeInterval(-60))
        XCTAssertEqual(before.meters, 0, accuracy: accuracy)
        XCTAssertEqual(before.quality, .outsideForecastHorizon)

        let after = series.resolution(at: base.addingTimeInterval(3_600))
        XCTAssertEqual(after.meters, 0, accuracy: accuracy)
        XCTAssertEqual(after.quality, .outsideForecastHorizon)
    }

    func testEmptyAndSingleSampleSeriesReturnThePeakScalar() {
        let empty = WaterLevelCorrectionSeries.constant(peak())
        XCTAssertNil(empty.coveredSpan)
        XCTAssertEqual(empty.resolution(at: base).meters, peak().meters, accuracy: accuracy)

        let single = WaterLevelCorrectionSeries(
            samples: [.init(time: base, meters: 0.99)],
            fallback: peak()
        )
        XCTAssertEqual(single.resolution(at: base).meters, peak().meters, accuracy: accuracy)
    }

    // MARK: - Sicherheitsbedingung

    /// Innerhalb der Kurvenabdeckung bleibt die Qualität erhalten; außerhalb wird sie herabgesetzt.
    func testQualityIsTimeBoundedToForecastCoverage() {
        for quality in [
            WaterLevelCorrectionQuality.localOfficial,
            .confirmedComparison,
            .manual
        ] {
            let series = slopingSeries(quality: quality)
            for offset in [0.0, 900, 1_800] {
                XCTAssertEqual(
                    series.resolution(at: base.addingTimeInterval(offset)).quality,
                    quality,
                    "Qualität innerhalb der Kurve muss erhalten bleiben"
                )
            }
            for offset in [-3_600.0, 7_200] {
                XCTAssertEqual(
                    series.resolution(at: base.addingTimeInterval(offset)).quality,
                    .outsideForecastHorizon,
                    "Außerhalb der Kurve muss die Güte outsideForecastHorizon sein"
                )
            }
        }
    }

    /// Gesamtprüfung: Ein Vergleichspegel bleibt als vorläufig erkennbar.
    /// Die Datenherkunft überschreibt aber nicht den berechneten Tiefenstatus.
    func testComparisonGaugeRemainsAdvisoryAfterCurveSampling() {
        let sampled = slopingSeries(quality: .confirmedComparison)
            .resolution(at: base.addingTimeInterval(900))
        XCTAssertEqual(sampled.quality, .confirmedComparison)
        XCTAssertFalse(sampled.quality.allowsGreenStatus)
        XCTAssertEqual(
            RouteCalculationService.applyCorrectionQuality(sampled.quality, to: .go),
            .go
        )
        XCTAssertEqual(
            RouteCalculationService.applyCorrectionQuality(sampled.quality, to: .noGo),
            .noGo
        )
    }

    func testSourceMetadataSurvivesSampling() {
        let sampled = slopingSeries().resolution(at: base.addingTimeInterval(900))
        XCTAssertEqual(sampled.localStationID, stationID)
        XCTAssertEqual(sampled.sourceStationName, "Norderney, Riffgat")
        XCTAssertEqual(sampled.issuedAt, base)
        XCTAssertEqual(sampled.detail, "Lokale amtliche Scheitelwertvorhersage.")
    }

    // MARK: - Berechnung einzelner Kurvenpunkte

    /// Beide Werte beziehen sich auf Kartennull. Dieser Bezug fällt in ihrer
    /// Differenz weg. Das entspricht der Differenz der Rohwerte am Hochwassergipfel
    /// in Zentimetern über Pegelnull.
    func testCurvePointCorrectionIsForecastMinusAstronomicalPrediction() {
        let point = WaterLevelCurvePoint(
            time: base,
            astroMetersSkn: 3.11,
            forecastMetersSkn: 2.90,
            measurementMetersSkn: nil
        )
        XCTAssertEqual(point.centralCorrectionMeters ?? .nan, -0.21, accuracy: 1e-9)

        let incomplete = WaterLevelCurvePoint(
            time: base, astroMetersSkn: nil, forecastMetersSkn: 2.90, measurementMetersSkn: nil
        )
        XCTAssertNil(incomplete.centralCorrectionMeters)
    }

    // MARK: - Einbindung der Datenanbieter

    /// Ältere Anbieter ohne Kurve bleiben durch die Standardimplementierung
    /// des Protokolls verwendbar.
    func testProviderWithoutSeriesFallsBackToTheScalarDefault() async {
        let provider = MockTideDataProvider()
        provider.correctionsByStation[stationID] = peak(meters: 0.42)

        let series = await provider.waterLevelCorrectionSeries(
            for: stationID,
            covering: base ... base.addingTimeInterval(3_600),
            anchorHighWaterTime: base,
            confirmedComparisonStationID: nil
        )
        XCTAssertTrue(series.samples.isEmpty)
        XCTAssertEqual(series.resolution(at: base).meters, 0.42, accuracy: accuracy)
    }

    /// Regressionstest: Zwei Wegpunkte mit demselben Pegel und 30 Minuten
    /// unterschiedlicher Ankunft müssen verschiedene Wasserstandskorrekturen erhalten.
    func testArrivalTimeSamplingDiffersBetweenWaypointsOnTheSameGauge() async {
        let provider = MockTideDataProvider()
        provider.correctionSeriesByStation[stationID] = slopingSeries()

        let series = await provider.waterLevelCorrectionSeries(
            for: stationID,
            covering: base ... base.addingTimeInterval(1_800),
            anchorHighWaterTime: base,
            confirmedComparisonStationID: nil
        )
        let early = series.resolution(at: base)
        let late = series.resolution(at: base.addingTimeInterval(1_800))

        XCTAssertNotEqual(early.meters, late.meters)
        XCTAssertEqual(early.meters, -0.30, accuracy: accuracy)
        XCTAssertEqual(late.meters, -0.10, accuracy: accuracy)
        XCTAssertEqual(early.quality, late.quality)
    }
}
