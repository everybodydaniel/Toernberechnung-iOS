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
/// **Epsilon tolerance improvement over Excel:**
/// If `deviationHours < 0.01`, FmW is set to 0 regardless of floating-point rounding.
/// This avoids the Excel behavior where an arrival time that is nominally at HW
/// but differs by microseconds due to floating-point arithmetic produces a non-zero FmW.
struct TwelfthsRuleStrategy: TidalHeightStrategy {

    /// Epsilon tolerance for treating arrival as "at high water".
    /// If the absolute deviation is below this threshold, FmW = 0.
    ///
    /// This is an intentional improvement over the Excel workbook, which uses
    /// raw floating-point comparison and can produce tiny non-zero FmW values
    /// at exact high water due to rounding artifacts.
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
}
