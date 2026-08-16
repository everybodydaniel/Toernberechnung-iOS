import Foundation

// MARK: - Tidal Height Strategy Protocol

/// Abstraction for computing the tidal water deficit ("Fehlmenge Wasser") based on
/// the time deviation from high water.
///
/// The default implementation is the **Twelfths Rule** (Zwölftelregel), which divides
/// the tidal range into 12 equal parts and assigns water-level changes to hourly buckets.
///
/// Future strategies (e.g. harmonic analysis, sinusoidal interpolation) can be added
/// by conforming to this protocol without modifying `RouteCalculationService`.
protocol TidalHeightStrategy {
    /// Calculate the missing water amount based on time deviation from high water.
    ///
    /// - Parameters:
    ///   - deviationHours: Absolute time difference from relevant high water, in decimal hours.
    ///   - meanTidalRangeMeters: Mean tidal range (Mittlerer Tidenhub) in meters.
    /// - Returns: A `TidalHeightResult` with the computed FmW, 1/12 value, and validity.
    func missingWater(
        deviationHours: Double,
        meanTidalRangeMeters: Double
    ) -> TidalHeightResult

    /// Inverse of `missingWater`: the largest deviation from high water at which
    /// the missing water still does not exceed `maxMissingWaterMeters`.
    ///
    /// This turns the passage question around. Instead of asking "how much water
    /// is missing when I arrive at 14:30?" it answers "until when may I arrive
    /// and still float?" — which is what a passage window needs, and it answers
    /// it without sampling hundreds of candidate times.
    ///
    /// Returns `nil` when even an arrival exactly at high water is not enough.
    func maxDeviationHours(
        forMaxMissingWaterMeters maxMissingWaterMeters: Double,
        meanTidalRangeMeters: Double
    ) -> Double?
}

extension TidalHeightStrategy {
    /// Generic inverse via bisection. Correct for any strategy whose missing
    /// water grows monotonically with the deviation, which every tidal curve
    /// does between high and low water.
    func maxDeviationHours(
        forMaxMissingWaterMeters maxMissingWaterMeters: Double,
        meanTidalRangeMeters: Double
    ) -> Double? {
        guard maxMissingWaterMeters >= 0 else { return nil }

        let atFullCycle = missingWater(
            deviationHours: 12,
            meanTidalRangeMeters: meanTidalRangeMeters
        )
        if atFullCycle.isValid, atFullCycle.fmwMeters <= maxMissingWaterMeters { return 12 }

        var low = 0.0
        var high = 12.0
        for _ in 0 ..< 60 {
            let middle = (low + high) / 2
            let result = missingWater(
                deviationHours: middle,
                meanTidalRangeMeters: meanTidalRangeMeters
            )
            if result.isValid, result.fmwMeters <= maxMissingWaterMeters {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }
}

// MARK: - Tidal Height Result

/// Result of a tidal height strategy computation.
struct TidalHeightResult: Equatable {
    /// Missing water amount in meters (Fehlmenge Wasser / FmW).
    /// At exact high water, this is 0.
    let fmwMeters: Double
    /// One-twelfth of the mean tidal range in meters.
    let oneTwelfthMeters: Double
    /// Whether the calculation is valid. False if deviationHours > 12.
    let isValid: Bool
    /// Explanatory messages (e.g. "keine Fehlmenge" at HW, or error descriptions).
    let messages: [String]
}

// MARK: - Twelfths Rule Strategy

/// The traditional Twelfths Rule (Zwölftelregel) for tidal height estimation.
///
/// The rule divides the tidal cycle into hourly buckets, assigning a number of twelfths
/// of the total tidal range to each hour:
///
/// ```
/// Hour from HW:  0   0-1   1-2   2-3   3-4   4-5   5-7   7-8   8-9   9-10  10-11  11-12  >12
/// Twelfths:      0    1     3     6     9    11    12    11     9     6      3      1    invalid
/// ```
///
/// The pattern reflects the approximate sinusoidal shape of the tidal curve:
/// - Near high water (0-1h): minimal change (1/12)
/// - Mid-tide (2-4h): rapid change (6-9/12)
/// - Near low water (5-7h): full range (12/12)
/// - Rising from low: symmetrical pattern back to high water
///
/// **Epsilon tolerance improvement:**
/// If `deviationHours < 0.01`, FmW is set to 0 regardless of floating-point rounding.
/// This avoids cases where an arrival time that is nominally at HW
/// but differs by microseconds due to floating-point arithmetic produces a non-zero FmW.
struct TwelfthsRuleStrategy: TidalHeightStrategy {

    /// Epsilon tolerance for treating arrival as "at high water".
    /// If the absolute deviation is below this threshold, FmW = 0.
    ///
    /// This is an intentional improvement that uses epsilon comparison
    /// instead of raw floating-point comparison, which can produce tiny
    /// non-zero FmW values at exact high water due to rounding artifacts.
    static let hwEpsilonHours: Double = 0.01

    func missingWater(
        deviationHours: Double,
        meanTidalRangeMeters: Double
    ) -> TidalHeightResult {
        let oneTwelfth = meanTidalRangeMeters / 12.0

        // Exact high water (within epsilon tolerance).
        if abs(deviationHours) < Self.hwEpsilonHours {
            return TidalHeightResult(
                fmwMeters: 0,
                oneTwelfthMeters: oneTwelfth,
                isValid: true,
                messages: ["keine Fehlmenge"]
            )
        }

        let hours = abs(deviationHours)

        // Deviation exceeds one full tidal cycle — calculation is meaningless.
        guard hours <= 12 else {
            return TidalHeightResult(
                fmwMeters: 0,
                oneTwelfthMeters: oneTwelfth,
                isValid: false,
                messages: ["Berechnung nicht möglich: Ankunftszeit liegt mehr als 12 Stunden vom relevanten Hochwasser entfernt."]
            )
        }

        let twelfths: Double
        switch hours {
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
        default:    twelfths = 0 // unreachable due to guard
        }

        return TidalHeightResult(
            fmwMeters: twelfths * oneTwelfth,
            oneTwelfthMeters: oneTwelfth,
            isValid: true,
            messages: []
        )
    }

    /// Closed form of the inverse — the staircase read from right to left.
    ///
    /// Because the rule is a step function, the answer is always the upper edge
    /// of the last bucket whose twelfths still fit into the budget:
    ///
    /// ```
    /// budget < 1/12  → 0 h  (only exactly at high water)
    /// budget < 3/12  → 1 h
    /// budget < 6/12  → 2 h
    /// budget < 9/12  → 3 h
    /// budget < 11/12 → 4 h
    /// budget < 12/12 → 5 h
    /// otherwise      → 12 h (the whole cycle floats)
    /// ```
    func maxDeviationHours(
        forMaxMissingWaterMeters maxMissingWaterMeters: Double,
        meanTidalRangeMeters: Double
    ) -> Double? {
        guard maxMissingWaterMeters >= 0 else { return nil }

        let oneTwelfth = meanTidalRangeMeters / 12
        // Without a tidal range there is no deficit to begin with.
        guard oneTwelfth > 0 else { return 12 }

        // A hair of tolerance so a budget that is mathematically exactly N/12
        // is not pushed into the previous bucket by floating point noise.
        let budgetInTwelfths = maxMissingWaterMeters / oneTwelfth + 1e-9

        switch budgetInTwelfths {
        case ..<1: return 0
        case ..<3: return 1
        case ..<6: return 2
        case ..<9: return 3
        case ..<11: return 4
        case ..<12: return 5
        default: return 12
        }
    }
}
