import Foundation

/// Route adapter for the Android-compatible ten-minute departure scan.
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
        let recommendedDeparture: Date
        let recommendedClearanceMeters: Double
        /// Arrival at the limiting waypoint for `recommendedDeparture`.
        let bottleneckArrival: Date?
        let bottleneckDepthDetail: String?

        init(
            start: Date,
            end: Date,
            anchoredHighWater: Date?,
            bottleneckName: String?,
            waterLevelQuality: WaterLevelCorrectionQuality = .localOfficial,
            waterLevelDetail: String? = nil,
            recommendedDeparture: Date? = nil,
            recommendedClearanceMeters: Double = 0,
            bottleneckArrival: Date? = nil,
            bottleneckDepthDetail: String? = nil
        ) {
            self.start = start
            self.end = end
            self.anchoredHighWater = anchoredHighWater
            self.bottleneckName = bottleneckName
            self.waterLevelQuality = waterLevelQuality
            self.waterLevelDetail = waterLevelDetail
            self.recommendedDeparture = recommendedDeparture ?? start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            self.recommendedClearanceMeters = recommendedClearanceMeters
            self.bottleneckArrival = bottleneckArrival
            self.bottleneckDepthDetail = bottleneckDepthDetail
        }

        func contains(_ date: Date) -> Bool { date >= start && date <= end }

        /// A single safe sample proves no interval of usable duration.
        var hasUsableDuration: Bool { end > start }

        var displayString: String {
            if !hasUsableDuration {
                return "Nur Prüfzeitpunkt \(AppDateFormatters.hourMinute.string(from: start)) Uhr – kein Zeitfenster"
            }
            if !AppDateFormatters.berlinCalendar.isDate(start, inSameDayAs: end) {
                return "\(AppDateFormatters.shortWeekdayDateTime.string(from: start)) – \(AppDateFormatters.shortWeekdayDateTime.string(from: end))"
            }
            return "\(AppDateFormatters.hourMinute.string(from: Date(timeIntervalSince1970: ceil(start.timeIntervalSince1970 / 60) * 60)))" +
            " – \(AppDateFormatters.hourMinute.string(from: Date(timeIntervalSince1970: floor(end.timeIntervalSince1970 / 60) * 60))) Uhr"
        }
    }

    // MARK: - Config

    private let calculationService: RouteCalculationService
    /// Original scan resolution.
    var scanIncrementSeconds: TimeInterval = 600
    /// Search range before the selected departure.
    var scanBackwardHours: Double = 12
    /// Search range after the selected departure.
    var scanForwardHours: Double = 24
    var scanSelectedDay: Bool = false

    init(calculationService: RouteCalculationService = RouteCalculationService()) {
        self.calculationService = calculationService
    }

    // MARK: - Entry point

    /// Route-wide departure window search.
    func findSafeWindow(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider,
        confirmedComparisonGaugeIDs: [String: String] = [:]
    ) async -> Window? {
        let solution = await solve(
            route: route,
            boatSettings: boatSettings,
            tideDataProvider: tideDataProvider,
            confirmedComparisonGaugeIDs: confirmedComparisonGaugeIDs
        )
        return solution.routeWindow
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
                sweepIncrementSeconds: scanIncrementSeconds,
                dayBased: scanSelectedDay
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
