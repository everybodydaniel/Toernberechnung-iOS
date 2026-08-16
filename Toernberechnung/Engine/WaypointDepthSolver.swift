import Foundation

// MARK: - Waypoint Depth Solver

/// The depth chain of the Törn calculation, rows `L35`…`L57` of the reference
/// tool "Excel-Tool-Törnberechnung_V2.1".
///
/// ```
/// L35  1/12tel         = L33 / 12
/// L39  FmW             = <Zwölftelstaffel> * L35
/// L45  Basis - FmW     = (L41 | L43) - L39
/// L49  HG              = L45 + L47            ("leer" im Lottiefe-Modus)
/// L53  WT              = L45 + L47 + L51
/// L57  WuK             = L53 - M55
/// ```
///
/// This is deliberately the **only** implementation of that chain. Both the
/// route calculation (`RouteCalculationService`) and the passage window search
/// call it, so the two can never drift apart and report different clearances
/// for the same waypoint at the same time.
///
/// The solver is pure and synchronous: every input is already resolved. Looking
/// values up (MTH from the gauge, MHW from the catalog, the surge from the BSH
/// forecast) is the caller's job.
enum WaypointDepthSolver {

    /// Fully resolved inputs for one waypoint at one point in time.
    struct Inputs: Equatable {
        let calculationMode: WaypointCalculationMode
        /// Excel `L41` (MHW über SKN) or `L43` (Lottiefe), depending on the mode.
        let referenceLevelMeters: Double
        /// Excel `L51`. Only applied in `.meanHighWater` mode; may be negative
        /// when the spot dries out above chart datum.
        let chartDepthMeters: Double?
        /// Excel `L33` — mean tidal range (Mittlerer Tidenhub).
        let meanTidalRangeMeters: Double
        /// Excel `L37` — absolute deviation from the waypoint's high water.
        let deviationHours: Double
        /// Excel `L47` — BSH water level correction (Windstau).
        let waterLevelCorrectionMeters: Double
        /// Excel `M55` — boat draft.
        let draftMeters: Double
    }

    /// Every intermediate the Excel sheet shows, so the UI can render the chain
    /// row by row instead of only the final clearance.
    struct Output: Equatable {
        let oneTwelfthMeters: Double            // L35
        let missingWaterMeters: Double          // L39
        let baseMeters: Double                  // L45
        /// Excel `L49`. Nil in Lottiefe mode, where the sheet prints "leer".
        let tideHeightHGMeters: Double?
        /// Excel `L51` as actually applied. Nil in Lottiefe mode.
        let chartDepthApplied: Double?
        let availableWaterDepthMeters: Double   // L53
        let clearanceUnderKeelMeters: Double    // L57
    }

    enum Failure: Error, Equatable {
        /// Excel prints "rel. HW od. Startzeit fehlt !!!" and then silently
        /// continues with a bare MHW. The app refuses instead.
        case deviationExceedsTidalCycle(messages: [String])
        /// Excel `L51` is empty although the MHW mode needs it.
        case missingChartDepth
    }

    static func solve(
        _ inputs: Inputs,
        strategy: TidalHeightStrategy = TwelfthsRuleStrategy()
    ) -> Result<Output, Failure> {
        let tidal = strategy.missingWater(
            deviationHours: inputs.deviationHours,
            meanTidalRangeMeters: inputs.meanTidalRangeMeters
        )
        guard tidal.isValid else {
            return .failure(.deviationExceedsTidalCycle(messages: tidal.messages))
        }

        let base = inputs.referenceLevelMeters - tidal.fmwMeters

        switch inputs.calculationMode {
        case .meanHighWater:
            guard let chartDepth = inputs.chartDepthMeters else {
                return .failure(.missingChartDepth)
            }
            let tideHeight = base + inputs.waterLevelCorrectionMeters
            let availableDepth = tideHeight + chartDepth
            return .success(Output(
                oneTwelfthMeters: tidal.oneTwelfthMeters,
                missingWaterMeters: tidal.fmwMeters,
                baseMeters: base,
                tideHeightHGMeters: tideHeight,
                chartDepthApplied: chartDepth,
                availableWaterDepthMeters: availableDepth,
                clearanceUnderKeelMeters: availableDepth - inputs.draftMeters
            ))

        case .lottiefe:
            // The Excel cell is labelled "nicht bei Lottiefe": a sounded depth
            // already includes the ground, so adding the chart depth on top
            // would count it twice. Any value present is ignored on purpose.
            let availableDepth = base + inputs.waterLevelCorrectionMeters
            return .success(Output(
                oneTwelfthMeters: tidal.oneTwelfthMeters,
                missingWaterMeters: tidal.fmwMeters,
                baseMeters: base,
                tideHeightHGMeters: nil,
                chartDepthApplied: nil,
                availableWaterDepthMeters: availableDepth,
                clearanceUnderKeelMeters: availableDepth - inputs.draftMeters
            ))
        }
    }
}
