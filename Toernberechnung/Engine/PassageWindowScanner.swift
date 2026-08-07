import Foundation

// MARK: - Passage Window Scanner (route-wide)

/// Searches safe departure windows by shifting the departure time and
/// recalculating the complete expanded route. A candidate belongs to a window
/// only when every waypoint has a valid, non-negative clearance under keel.
/// This is intentionally the original route-wide algorithm: no single
/// bottleneck or tide event is allowed to stand in for the remaining route.

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
        guard scanIncrementSeconds > 0,
              scanBackwardHours >= 0,
              scanForwardHours >= 0 else { return nil }

        let center = route.plannedStartTime
        let scanStart = center.addingTimeInterval(-scanBackwardHours * 3_600)
        let scanEnd = center.addingTimeInterval(scanForwardHours * 3_600)

        var windows: [Window] = []
        var openWindow: OpenWindow?
        var candidate = scanStart

        while candidate <= scanEnd {
            guard !Task.isCancelled else { return nil }

            var shiftedRoute = route
            shiftedRoute.plannedStartTime = candidate
            let result = await calculationService.calculate(
                route: shiftedRoute,
                boatSettings: boatSettings,
                tideDataProvider: tideDataProvider,
                confirmedComparisonGaugeIDs: confirmedComparisonGaugeIDs
            )

            if let assessment = safeAssessment(for: result, expectedWaypointCount: route.waypoints.count) {
                if openWindow == nil {
                    openWindow = OpenWindow(start: candidate, end: candidate, assessment: assessment)
                } else {
                    openWindow?.end = candidate
                    openWindow?.merge(assessment)
                }
            } else if let completed = openWindow {
                windows.append(completed.window)
                openWindow = nil
            }

            candidate = candidate.addingTimeInterval(scanIncrementSeconds)
        }

        if let completed = openWindow {
            windows.append(completed.window)
        }

        if let active = windows.first(where: { $0.contains(center) }) {
            return active
        }
        return windows.first(where: { $0.start > center })
    }

    // MARK: - Candidate assessment

    private struct SafeAssessment {
        let quality: WaterLevelCorrectionQuality
        let detail: String?
        let anchoredHighWater: Date?
        let bottleneckName: String?
    }

    private struct OpenWindow {
        let start: Date
        var end: Date
        var assessment: SafeAssessment

        mutating func merge(_ candidate: SafeAssessment) {
            if PassageWindowScanner.qualityRank(candidate.quality)
                > PassageWindowScanner.qualityRank(assessment.quality) {
                assessment = candidate
            }
        }

        var window: Window {
            Window(
                start: start,
                end: end,
                anchoredHighWater: assessment.anchoredHighWater,
                bottleneckName: assessment.bottleneckName,
                waterLevelQuality: assessment.quality,
                waterLevelDetail: assessment.detail
            )
        }
    }

    /// Mirrors the original definition: `.go` and `.warning` are passable.
    /// A result made `.incomplete` solely by forecast quality remains usable as
    /// a provisional window when every clearance value was actually computed.
    private func safeAssessment(
        for result: RouteCalculationResult,
        expectedWaypointCount: Int
    ) -> SafeAssessment? {
        guard result.waypointResults.count == expectedWaypointCount,
              result.legResults.allSatisfy(\.isValid),
              !result.waypointResults.isEmpty,
              result.waypointResults.allSatisfy({ waypoint in
                  guard let clearance = waypoint.clearanceUnderKeelWuKMeters else { return false }
                  return clearance >= 0 && waypoint.status != .invalid && waypoint.status != .noGo
              }) else {
            return nil
        }

        let bottleneck = result.waypointResults.min { lhs, rhs in
            (lhs.clearanceUnderKeelWuKMeters ?? .greatestFiniteMagnitude)
                < (rhs.clearanceUnderKeelWuKMeters ?? .greatestFiniteMagnitude)
        }
        let quality = result.waypointResults
            .map(\.waterLevelCorrectionQuality)
            .max(by: { Self.qualityRank($0) < Self.qualityRank($1) })
            ?? .unavailable

        return SafeAssessment(
            quality: quality,
            detail: detail(for: quality),
            anchoredHighWater: bottleneck?.relevantHighWaterTime,
            bottleneckName: bottleneck?.waypoint.name
        )
    }

    private static func qualityRank(_ quality: WaterLevelCorrectionQuality) -> Int {
        switch quality {
        case .localOfficial: return 0
        case .manual: return 1
        case .confirmedComparison: return 2
        case .stale: return 3
        case .outsideForecastHorizon: return 4
        case .unavailable: return 5
        }
    }

    private func detail(for quality: WaterLevelCorrectionQuality) -> String? {
        switch quality {
        case .localOfficial:
            return nil
        case .manual:
            return "Das Passagefenster verwendet eine manuelle Wasserstandskorrektur."
        case .confirmedComparison:
            return "Das Passagefenster verwendet einen bestätigten Vergleichspegel."
        case .stale:
            return "Die Wasserstandsprognose für das Passagefenster ist veraltet."
        case .outsideForecastHorizon:
            return "Das Passagefenster basiert auf astronomischen Gezeitendaten."
        case .unavailable:
            return "Für das Passagefenster liegt keine aktuelle lokale Wasserstandsprognose vor."
        }
    }

}
