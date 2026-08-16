import Foundation

// MARK: - Passage Window Scanner (facade)
//
// The route-wide departure window. `Window` and its helpers stay here because
// the view model and four view sites depend on them; the search itself now
// lives in `PassageWindowSolver`.
//
// What changed: this used to shift the departure time in ten-minute steps and
// recalculate the entire route for every candidate — up to 217 full
// recalculations, each awaiting the tide provider per waypoint. The solver
// resolves the tide data once per waypoint and derives the passable span in
// closed form, which is both exact and dramatically cheaper. The scan
// parameters survive as configuration so existing call sites keep compiling.

struct PassageWindowScanner {

    // MARK: - Public types

    struct Window: Equatable {
        let start: Date
        let end: Date
        /// BSH HW used as anchor (for display).
        let anchoredHighWater: Date?
        /// Bottleneck waypoint name (for display).
        let bottleneckName: String?
        let waterLevelQuality: WaterLevelCorrectionQuality
        let waterLevelDetail: String?

        init(
            start: Date,
            end: Date,
            anchoredHighWater: Date?,
            bottleneckName: String?,
            waterLevelQuality: WaterLevelCorrectionQuality = .localOfficial,
            waterLevelDetail: String? = nil
        ) {
            self.start = start
            self.end = end
            self.anchoredHighWater = anchoredHighWater
            self.bottleneckName = bottleneckName
            self.waterLevelQuality = waterLevelQuality
            self.waterLevelDetail = waterLevelDetail
        }

        func contains(_ date: Date) -> Bool { date >= start && date <= end }

        var displayString: String {
            "\(AppDateFormatters.hourMinute.string(from: start))" +
            " – \(AppDateFormatters.hourMinute.string(from: end)) Uhr"
        }
    }

    // MARK: - Config

    private let calculationService: RouteCalculationService
    /// Original scan resolution.
    var scanIncrementSeconds: TimeInterval = 10 * 60
    /// Search range before the selected departure.
    var scanBackwardHours: Double = 12
    /// Search range after the selected departure.
    var scanForwardHours: Double = 24

    init(calculationService: RouteCalculationService = RouteCalculationService()) {
        self.calculationService = calculationService
    }

    // MARK: - Entry point

    func findSafeWindow(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider,
        confirmedComparisonGaugeIDs: [String: String] = [:]
    ) async -> Window? {
        await solve(
            route: route,
            boatSettings: boatSettings,
            tideDataProvider: tideDataProvider,
            confirmedComparisonGaugeIDs: confirmedComparisonGaugeIDs
        ).routeWindow
    }

    /// Full solution including the per-bottleneck windows.
    func solve(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider,
        confirmedComparisonGaugeIDs: [String: String] = [:]
    ) async -> PassageWindowSolver.Solution {
        guard scanIncrementSeconds > 0,
              scanBackwardHours >= 0,
              scanForwardHours >= 0 else {
            return PassageWindowSolver.Solution(
                routeWindow: nil, bottlenecks: [], hasInvalidLeg: false
            )
        }

        let solver = PassageWindowSolver(
            configuration: PassageWindowSolver.Configuration(
                searchBackwardHours: scanBackwardHours,
                searchForwardHours: scanForwardHours,
                sweepIncrementSeconds: scanIncrementSeconds
            )
        )
        return await solver.solve(
            route: route,
            boatSettings: boatSettings,
            tideDataProvider: tideDataProvider,
            confirmedComparisonGaugeIDs: confirmedComparisonGaugeIDs
        )
    }
}
