import Foundation

// MARK: - Rule of Twelfths
//
// Two complementary modes are exposed:
//
// 1. `steppedFehlmenge(...)` — STEPPED lookup that mirrors the traditional
//    Zwölftelregel formula for tidal height estimation.
//    Hour ranges and twelfths:
//
//        0–1 h  →  1/12
//        1–2 h  →  3/12
//        2–3 h  →  6/12
//        3–4 h  →  9/12
//        4–5 h  → 11/12
//        5–7 h  → 12/12  (LW stand window)
//        7–8 h  → 11/12
//        8–9 h  →  9/12
//        9–10 h →  6/12
//       10–11 h →  3/12
//       11–12 h →  1/12
//        >12 h  → invalid
//
// 2. `continuousWaterLevel(...)` — smooth interpolation between a known HW
//    and the surrounding LW, identical to the original implementation.
//    Useful for plotting graphs and for sub-hour passage-window scans.

enum RuleOfTwelfths {

    // MARK: - Stepped Fehlmenge

    /// Stepped Fehlmenge lookup. Returns `nil` if the deviation exceeds 12 h.
    /// This function is the canonical reference for the Zwölftelregel.
    static func steppedFehlmenge(
        deviationHours: Double,
        meanTidalRangeMeters mth: Double
    ) -> Double? {
        let h = abs(deviationHours)
        guard h <= 12 else { return nil }
        let oneTwelfth = mth / 12.0
        let twelfths: Double
        switch h {
        case ...0:  twelfths = 0          // exact HW → no deficit
        case ...1:  twelfths = 1
        case ...2:  twelfths = 3
        case ...3:  twelfths = 6
        case ...4:  twelfths = 9
        case ...5:  twelfths = 11
        case ...7:  twelfths = 12
        case ...8:  twelfths = 11
        case ...9:  twelfths = 9
        case ...10: twelfths = 6
        case ...11: twelfths = 3
        case ...12: twelfths = 1
        default:    return nil
        }
        return twelfths * oneTwelfth
    }

    // MARK: - Continuous Interpolation

    /// Predict water level at `targetTime` given a bracketing pair of tide
    /// events (typically NW → HW or HW → NW). Uses the 12/1 distribution.
    static func continuousWaterLevel(
        timeStart: Date, heightStart: Double,
        timeEnd: Date,   heightEnd: Double,
        targetTime: Date
    ) -> Double {
        if targetTime <= timeStart { return heightStart }
        if targetTime >= timeEnd   { return heightEnd }

        let total = timeEnd.timeIntervalSince(timeStart)
        guard total > 0 else { return heightEnd }
        let phase = targetTime.timeIntervalSince(timeStart) / total

        let twelfthsPerSegment: [Double] = [1, 2, 3, 3, 2, 1]
        let segmentLength = 1.0 / 6.0
        let segmentIndex = max(0, min(5, Int(phase / segmentLength)))
        let fractionInSegment = (phase - Double(segmentIndex) * segmentLength) / segmentLength

        var accumulated: Double = 0
        for i in 0 ..< segmentIndex { accumulated += twelfthsPerSegment[i] }
        accumulated += twelfthsPerSegment[segmentIndex] * fractionInSegment

        return heightStart + (heightEnd - heightStart) * (accumulated / 12.0)
    }

    // MARK: - UKC helpers

    /// Under-keel clearance.
    ///
    /// `waterLevel` is the live water level relative to chart datum (LAT/SKN).
    /// `chartDatumDepth` is the depth at chart datum (positive = water).
    /// `boatDraft` is the boat's draft (positive).
    static func underKeelClearance(
        waterLevel: Double,
        chartDatumDepth: Double,
        boatDraft: Double
    ) -> Double {
        (waterLevel + chartDatumDepth) - boatDraft
    }

    /// Strict Go evaluation: `UKC >= safetyMargin`.
    static func isGo(ukc: Double, safetyMargin: Double) -> Bool {
        ukc >= safetyMargin
    }
}
