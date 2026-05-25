import Testing
import Foundation
@testable import Toernberechnung

/// Black-Box-Tests für die Zwölftelregel mit parametrisierten Äquivalenzklassen.
///
/// Pro EK aus dem Testkonzept (Schritt 2) wird hier ein Repräsentant geprüft.
/// Zusätzlich: Boundary-Value-Analyse an den Bucket-Grenzen 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12 h
/// sowie an der Epsilon-Schwelle (0.01 h).
@Suite("TwelfthsRuleStrategy – Äquivalenzklassen & Grenzwerte")
struct TwelfthsRuleStrategyTests {

    private let strategy = TwelfthsRuleStrategy()
    private let mth = 2.4  // typischer mittlerer Tidenhub Nordsee

    // MARK: - EK1: Epsilon-Zone (|dev| < 0.01)

    @Test("EK1 – exakt am HW liefert FmW=0")
    func ek1_exactHighWater() {
        let r = strategy.missingWater(deviationHours: 0, meanTidalRangeMeters: mth)
        #expect(r.isValid)
        #expect(r.fmwMeters == 0)
        #expect(r.messages.contains("keine Fehlmenge"))
    }

    @Test("EK1 – innerhalb Epsilon (0,005 h) liefert FmW=0")
    func ek1_withinEpsilon() {
        let r = strategy.missingWater(deviationHours: 0.005, meanTidalRangeMeters: mth)
        #expect(r.isValid)
        #expect(r.fmwMeters == 0)
    }

    @Test("EK1 – Grenze 0.009 (knapp im Epsilon)")
    func ek1_boundaryInside() {
        let r = strategy.missingWater(deviationHours: 0.009, meanTidalRangeMeters: mth)
        #expect(r.fmwMeters == 0)
    }

    // MARK: - EK2 – EK12: Buckets 1..12

    /// Parametrisierte Tests für alle 11 Zeit-Buckets.
    /// `(deviationHours, expectedTwelfths)`.
    @Test(
        "EKs 2–12 – Bucket-Treffer",
        arguments: [
            (0.5,  1),   // EK2 mid
            (1.0,  1),   // EK2 obere Grenze
            (1.5,  3),   // EK3 mid
            (2.0,  3),   // EK3 obere Grenze
            (2.5,  6),   // EK4 mid
            (3.0,  6),   // EK4 obere Grenze
            (3.5,  9),   // EK5 mid
            (4.0,  9),   // EK5 obere Grenze
            (4.5,  11),  // EK6 mid
            (5.0,  11),  // EK6 obere Grenze
            (6.0,  12),  // EK7 mid (Niedrigwasser-Bereich)
            (7.0,  12),  // EK7 obere Grenze
            (7.5,  11),  // EK8 mid (steigend)
            (8.0,  11),  // EK8 obere Grenze
            (8.5,  9),   // EK9 mid
            (9.0,  9),   // EK9 obere Grenze
            (9.5,  6),   // EK10 mid
            (10.0, 6),   // EK10 obere Grenze
            (10.5, 3),   // EK11 mid
            (11.0, 3),   // EK11 obere Grenze
            (11.5, 1),   // EK12 mid
            (12.0, 1)    // EK12 obere Grenze (letzter gültiger Punkt)
        ]
    )
    func bucketHits(deviation: Double, expectedTwelfths: Int) {
        let r = strategy.missingWater(deviationHours: deviation, meanTidalRangeMeters: mth)
        #expect(r.isValid, "EK-Treffer muss gültig sein")
        let oneTwelfth = mth / 12.0
        let expected = Double(expectedTwelfths) * oneTwelfth
        #expect(abs(r.fmwMeters - expected) < 0.0001,
                "Bei dev=\(deviation)h erwartet FmW=\(expected), erhalten \(r.fmwMeters)")
        #expect(abs(r.oneTwelfthMeters - oneTwelfth) < 0.0001)
    }

    // MARK: - EK13: ungültig (> 12 h)

    @Test("EK13 – > 12 h ist ungültig")
    func ek13_beyondTwelve() {
        let r = strategy.missingWater(deviationHours: 13, meanTidalRangeMeters: mth)
        #expect(!r.isValid)
        #expect(r.fmwMeters == 0)
        #expect(!r.messages.isEmpty)
    }

    @Test("EK13 – Grenze 12.0001 (knapp ungültig)")
    func ek13_boundaryJustBeyond() {
        let r = strategy.missingWater(deviationHours: 12.0001, meanTidalRangeMeters: mth)
        #expect(!r.isValid)
    }

    // MARK: - Symmetrie: negative deviation wird via abs() gespiegelt

    @Test("Negative Abweichung wird via abs() symmetrisch behandelt")
    func negativeDeviationSymmetric() {
        let positive = strategy.missingWater(deviationHours:  3.5, meanTidalRangeMeters: mth)
        let negative = strategy.missingWater(deviationHours: -3.5, meanTidalRangeMeters: mth)
        #expect(positive == negative)
    }

    // MARK: - EK_a/EK_b/EK_c für MTH

    @Test("MTH=0 → FmW=0 für jeden gültigen Abstand")
    func ekMTH_zero() {
        let r = strategy.missingWater(deviationHours: 6, meanTidalRangeMeters: 0)
        #expect(r.isValid)
        #expect(r.fmwMeters == 0)
        #expect(r.oneTwelfthMeters == 0)
    }

    @Test("MTH<0 (Robustness) → negative FmW (dokumentiertes Verhalten)")
    func ekMTH_negativeIsDocumented() {
        let r = strategy.missingWater(deviationHours: 3, meanTidalRangeMeters: -2.4)
        #expect(r.isValid)
        #expect(r.fmwMeters < 0,
                "Negative MTH liefert negative FmW – aktueller Vertrag, Aufrufer muss validieren")
    }

    @Test("Sehr großer MTH wird korrekt skaliert (Linearität)")
    func ekMTH_large() {
        let small = strategy.missingWater(deviationHours: 3, meanTidalRangeMeters: 2.0)
        let large = strategy.missingWater(deviationHours: 3, meanTidalRangeMeters: 20.0)
        #expect(abs(large.fmwMeters - small.fmwMeters * 10) < 0.0001)
    }
}
