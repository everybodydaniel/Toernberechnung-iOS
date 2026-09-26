import Foundation
import XCTest
@testable import Toernberechnung

/// Prüft `TwelfthsRuleStrategy` gegen die Excel-Formel `L39` des
/// "Excel-Tool-Törnberechnung_V2.1".
///
/// Excel `L35` (ein Zwölftel) = `SUM(L33)/12`; `L39` wählt ein Vielfaches davon:
///
/// ```
/// ≤1 → 1   ≤2 → 3   ≤3 → 6   ≤4 → 9   ≤5 → 11  ≤7 → 12
/// ≤8 → 11  ≤9 → 9   ≤10 → 6  ≤11 → 3  ≤12 → 1  >12 → Fehlertext
/// ```
///
/// Die obere Grenze jedes Bereichs ist eingeschlossen (`IF(L37<=1, …)`).
/// Deshalb wird jede volle Stunde ausdrücklich geprüft. Eine falsche Grenze
/// würde die Fehlmenge um ein ganzes Zwölftel verändern.
final class ExcelParityTwelfthsTests: XCTestCase {

    private let strategy = TwelfthsRuleStrategy()
    /// Excel `L33`, so gewählt, dass ein Zwölftel genau 0,20 m beträgt.
    private let mth = 2.4
    private let accuracy = 1e-9

    private func fmw(_ deviationHours: Double) -> TidalHeightResult {
        strategy.missingWater(deviationHours: deviationHours, meanTidalRangeMeters: mth)
    }

    func testOneTwelfthMatchesExcelL35() {
        XCTAssertEqual(fmw(1).oneTwelfthMeters, 0.20, accuracy: accuracy)
        XCTAssertEqual(
            strategy.missingWater(deviationHours: 1, meanTidalRangeMeters: 3.6).oneTwelfthMeters,
            0.30,
            accuracy: accuracy
        )
    }

    /// Excel: `IF(L37=0,"keine Fehlmenge",…)`.
    func testExactHighWaterHasNoMissingWater() {
        let atHighWater = fmw(0)
        XCTAssertEqual(atHighWater.fmwMeters, 0, accuracy: accuracy)
        XCTAssertTrue(atHighWater.isValid)
        XCTAssertEqual(atHighWater.messages, ["keine Fehlmenge"])

        // Die App toleriert zusätzlich Gleitkommaabweichungen unter 0,01 h.
        // Excel vergleicht direkt mit 0. Die Toleranz erhält bei kleinen Rundungsfehlern
        // das erwartete Ergebnis einer Ankunft zum Hochwasser.
        XCTAssertEqual(fmw(0.005).fmwMeters, 0, accuracy: accuracy)
    }

    /// Jeden Bereich an seiner eingeschlossenen oberen Grenze und knapp darüber prüfen.
    func testEveryBucketMatchesTheExcelStaircase() {
        let expectations: [(deviation: Double, twelfths: Double)] = [
            (0.5, 1), (1.0, 1),
            (1.0001, 3), (2.0, 3),
            (2.5, 6), (3.0, 6),
            (3.5, 9), (4.0, 9),
            (4.5, 11), (5.0, 11),
            (5.5, 12), (6.0, 12), (7.0, 12),
            (7.5, 11), (8.0, 11),
            (8.5, 9), (9.0, 9),
            (9.5, 6), (10.0, 6),
            (10.5, 3), (11.0, 3),
            (11.5, 1), (12.0, 1)
        ]

        for expectation in expectations {
            let result = fmw(expectation.deviation)
            XCTAssertTrue(result.isValid, "Δ \(expectation.deviation) h muss gültig sein")
            XCTAssertEqual(
                result.fmwMeters,
                expectation.twelfths * 0.20,
                accuracy: accuracy,
                "Δ \(expectation.deviation) h ⇒ \(expectation.twelfths)/12"
            )
        }
    }

    /// Excel `IF(L37>12,"rel. HW od. Startzeit fehlt !!!")`.
    ///
    /// Bewusste Abweichung: Excel fängt den Fehlertext in `L45` über
    /// `IFERROR(…, SUM(L41:Q44))` ab und rechnet mit MHW ohne Fehlmenge weiter.
    /// Die App lehnt diese Berechnung ab.
    func testDeviationBeyondTidalCycleIsRejected() {
        let beyond = fmw(12.0001)
        XCTAssertFalse(beyond.isValid)
        XCTAssertFalse(beyond.messages.isEmpty)
        XCTAssertEqual(beyond.oneTwelfthMeters, 0.20, accuracy: accuracy)
    }

    /// Excel `L37 = ABS(L29-L31)*24`: Der Betrag wird vor der Auswahl gebildet.
    func testDeviationIsSymmetricAroundHighWater() {
        for hours in [1.0, 3.0, 5.0, 7.0, 12.0] {
            XCTAssertEqual(
                fmw(-hours).fmwMeters,
                fmw(hours).fmwMeters,
                accuracy: accuracy,
                "Δ ±\(hours) h muss dieselbe Fehlmenge ergeben"
            )
        }
    }

    /// Excel prüft dies mit `IF(L33=0,"",…)`. Die App prüft es in
    /// `RouteCalculationService`; hier werden nur die Rechenschritte abgesichert.
    func testZeroTidalRangeStaysFinite() {
        let result = strategy.missingWater(deviationHours: 3, meanTidalRangeMeters: 0)
        XCTAssertEqual(result.oneTwelfthMeters, 0, accuracy: accuracy)
        XCTAssertEqual(result.fmwMeters, 0, accuracy: accuracy)
        XCTAssertTrue(result.fmwMeters.isFinite)
    }
}
