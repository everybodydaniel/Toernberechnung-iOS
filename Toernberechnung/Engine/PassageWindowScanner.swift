import Foundation

/// Verbindet die Routenplanung mit der Abfahrtssuche im Zehn-Minuten-Raster.
struct PassageWindowScanner {

    // MARK: - Öffentliche Typen

    struct Window: Equatable {
        let start: Date
        let end: Date
        /// BSH-Hochwasser als zeitlicher Bezug für die Anzeige.
        let anchoredHighWater: Date?
        /// Name des begrenzenden Wegpunkts für die Anzeige.
        let bottleneckName: String?
        let waterLevelQuality: WaterLevelCorrectionQuality
        let waterLevelDetail: String?
        let recommendedDeparture: Date
        let recommendedClearanceMeters: Double
        /// Ankunft am begrenzenden Wegpunkt bei `recommendedDeparture`.
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

        /// Ein einzelner geeigneter Zeitpunkt belegt kein Zeitfenster mit nutzbarer Dauer.
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

    // MARK: - Konfiguration

    private let calculationService: RouteCalculationService
    /// Ursprüngliche Schrittweite der Suche.
    var scanIncrementSeconds: TimeInterval = 600
    /// Suchbereich vor der gewählten Abfahrt.
    var scanBackwardHours: Double = 12
    /// Suchbereich nach der gewählten Abfahrt.
    var scanForwardHours: Double = 24
    var scanSelectedDay: Bool = false

    init(calculationService: RouteCalculationService = RouteCalculationService()) {
        self.calculationService = calculationService
    }

    // MARK: - Einstiegspunkt

    /// Suche nach Abfahrtsfenstern für die gesamte Route.
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

    /// Vollständiges Ergebnis einschließlich der Zeitfenster einzelner Engstellen.
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
