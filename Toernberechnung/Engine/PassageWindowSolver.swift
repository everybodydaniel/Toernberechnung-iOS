import Foundation

/// Prüft mögliche Abfahrten alle zehn Minuten,
/// verbindet aufeinanderfolgende geeignete Zeitpunkte und wählt das aktuelle, nächste oder letzte Fenster.
/// Gezeitendaten werden einmal geladen; jeder Zeitpunkt wird an allen Wegpunkten geprüft.
struct PassageWindowSolver {
    struct BottleneckWindow: Identifiable, Equatable {
        let id: UUID
        let waypointName: String
        let category: String?
        let arrivalWindow: ClosedRange<Date>?
        let departureWindow: ClosedRange<Date>?
        let travelOffsetHours: Double
        let plannedArrivalTime: Date
        let plannedClearanceMeters: Double?
        let shortfallMeters: Double
        let quality: WaterLevelCorrectionQuality
        var isPassableAtPlannedTime: Bool { plannedClearanceMeters != nil && shortfallMeters <= 0 }
    }

    struct Solution: Equatable {
        let routeWindow: PassageWindowScanner.Window?
        let bottlenecks: [BottleneckWindow]
        let hasInvalidLeg: Bool
        var routeWindows: [PassageWindowScanner.Window] = []
        var missingWaypointNames: [String] = []
        var hasCoverageGaps: Bool = false
        var limiting: BottleneckWindow? {
            bottlenecks.min { ($0.plannedClearanceMeters ?? -.infinity) < ($1.plannedClearanceMeters ?? -.infinity) }
        }
    }

    struct Configuration: Equatable {
        // Für Aufrufer, die ausdrücklich einen relativen Suchbereich anfordern.
        var searchBackwardHours: Double = 12
        var searchForwardHours: Double = 24
        var sweepIncrementSeconds: TimeInterval = 600
        var boundaryToleranceSeconds: TimeInterval = 1
        var dayBased: Bool = false
        var notBefore: Date? = nil
    }

    var configuration: Configuration
    private let tidalHeightStrategy: TidalHeightStrategy

    init(configuration: Configuration = Configuration(), tidalHeightStrategy: TidalHeightStrategy = ContinuousTwelfthsStrategy()) {
        self.configuration = configuration
        self.tidalHeightStrategy = tidalHeightStrategy
    }

    func solve(route: RoutePlan, boatSettings: BoatSettings, tideDataProvider: TideDataProvider,
               confirmedComparisonGaugeIDs: [String: String] = [:]) async -> Solution {
        guard configuration.sweepIncrementSeconds.isFinite, configuration.sweepIncrementSeconds > 0,
              configuration.searchBackwardHours.isFinite, configuration.searchBackwardHours >= 0,
              configuration.searchForwardHours.isFinite, configuration.searchForwardHours >= 0,
              route.waypoints.count >= 2, route.legs.count == route.waypoints.count - 1,
              boatSettings.draftMeters.isFinite, boatSettings.draftMeters > 0,
              boatSettings.safetyMarginMeters.isFinite, boatSettings.safetyMarginMeters >= 0 else {
            return Solution(routeWindow: nil, bottlenecks: [], hasInvalidLeg: true)
        }
        let legs = RouteCalculationService.calculateLegResults(startTime: route.plannedStartTime, legs: route.legs)
        let validLegs = tideDataProvider.usesForecastWaterLevels
            ? route.legs.allSatisfy { $0.distanceNm.isFinite && $0.distanceNm >= 0 &&
                $0.speedThroughWaterKnots.isFinite && $0.speedThroughWaterKnots > 0 }
            : legs.allSatisfy(\.isValid)
        guard validLegs else {
            return Solution(routeWindow: nil, bottlenecks: [], hasInvalidLeg: true)
        }
        let calendar = AppDateFormatters.berlinCalendar
        let dayStart = calendar.startOfDay(for: route.date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let lower = configuration.dayBased ? dayStart : route.plannedStartTime.addingTimeInterval(-configuration.searchBackwardHours * 3_600)
        let upper = configuration.dayBased ? dayEnd.addingTimeInterval(-1) : route.plannedStartTime.addingTimeInterval(configuration.searchForwardHours * 3_600)
        let start = max(lower, configuration.notBefore ?? lower)
        guard start <= upper else { return Solution(routeWindow: nil, bottlenecks: [], hasInvalidLeg: false) }
        let span = start ... upper
        let offsets: [Double]
        if tideDataProvider.usesForecastWaterLevels {
            var elapsed = 0.0
            offsets = [0] + route.legs.map { leg in
                elapsed += leg.distanceNm / leg.speedThroughWaterKnots
                return elapsed
            }
        } else {
            offsets = [0] + legs.map(\.cumulativeTravelTimeHours)
        }
        let resolved = await resolveContexts(route, boatSettings, offsets, span, tideDataProvider, confirmedComparisonGaugeIDs)
        let missing = route.waypoints.indices.filter { resolved[$0] == nil }.map { route.waypoints[$0].name }
        guard missing.isEmpty else {
            return Solution(routeWindow: nil, bottlenecks: [], hasInvalidLeg: false, missingWaypointNames: missing)
        }
        var contexts = resolved.compactMap { $0 }
        if tideDataProvider.usesForecastWaterLevels {
            let models = route.legs.indices.map { index in
                TidalPassageLeg(distanceNm: route.legs[index].distanceNm,
                    speedKnots: route.legs[index].speedThroughWaterKnots,
                    courseDegrees: TidalPassageLeg.course(from: route.waypoints[index], to: route.waypoints[index + 1]),
                    events: contexts[index].forecastEvents)
            }
            for index in contexts.indices { contexts[index].tidalTravelLegs = Array(models.prefix(index)) }
        }
        let (pieces, hasGaps) = findPieces(for: contexts, span: span, margin: boatSettings.safetyMarginMeters)
        // Alle zusammenhängenden geeigneten Zeitfenster behalten. Die Auswahl ist von
        // der Liste für die Oberfläche unabhängig.
        let clampedSelected = selectRelevantWindow(from: pieces, around: route.plannedStartTime)
        let anchor = clampedSelected?.recommendedDeparture ?? route.plannedStartTime
        let bottlenecks = contexts.map { context -> BottleneckWindow in
            let arrival = context.arrival(forDeparture: anchor)
            let clearance = context.clearance(atArrival: arrival, strategy: tidalHeightStrategy)
            let (waypointPieces, _) = findPieces(for: [context], span: span, margin: boatSettings.safetyMarginMeters)
            let matchingPiece = waypointPieces.first { $0.contains(anchor) }
                ?? waypointPieces.min(by: {
                    abs($0.recommendedDeparture.timeIntervalSince(anchor))
                        < abs($1.recommendedDeparture.timeIntervalSince(anchor))
                })
            let departureWin = matchingPiece.map { $0.start ... $0.end }
            let arrivalWin = departureWin.flatMap { window -> ClosedRange<Date>? in
                let first = context.arrival(forDeparture: window.lowerBound)
                let last = context.arrival(forDeparture: window.upperBound)
                return first <= last ? first ... last : nil
            }
            return BottleneckWindow(
                id: context.waypointID, waypointName: context.name, category: context.category,
                arrivalWindow: arrivalWin, departureWindow: departureWin,
                travelOffsetHours: arrival.timeIntervalSince(anchor) / 3_600, plannedArrivalTime: arrival,
                plannedClearanceMeters: clearance,
                shortfallMeters: clearance.map { max(0, boatSettings.safetyMarginMeters - $0) } ?? .infinity,
                quality: context.quality(at: arrival)
            )
        }
        return Solution(routeWindow: clampedSelected, bottlenecks: bottlenecks, hasInvalidLeg: false,
                        routeWindows: pieces, hasCoverageGaps: hasGaps)
    }

    private func selectRelevantWindow(
        from windows: [PassageWindowScanner.Window],
        around departure: Date
    ) -> PassageWindowScanner.Window? {
        if let current = windows
            .filter({ $0.contains(departure) })
            .max(by: { $0.recommendedClearanceMeters < $1.recommendedClearanceMeters }) {
            return current
        }
        if let next = windows
            .filter({ $0.start > departure })
            .min(by: { $0.start < $1.start }) {
            return next
        }
        return windows
            .filter({ $0.end < departure })
            .max(by: { $0.end < $1.end })
    }

    private func findPieces(
        for contexts: [WaypointTideContext],
        span: ClosedRange<Date>,
        margin: Double
    ) -> (pieces: [PassageWindowScanner.Window], hasGaps: Bool) {
        var pieces: [PassageWindowScanner.Window] = []
        var openWindow: PassageWindowScanner.Window?
        var hasGaps = false
        var candidate = span.lowerBound

        // Grenzen einschließen, 1 cm Toleranz verwenden, fehlende Daten
        // ausschließen und bei Gleichstand den ersten besten Wert wählen. Zwischenwerte werden nicht interpoliert.
        while candidate <= span.upperBound {
            guard !Task.isCancelled else { return ([], true) }
            if let values = clearances(contexts, at: candidate) {
                if values.allSatisfy({ $0 >= margin - 0.01 }) {
                    let sample = windowSample(contexts, values: values, at: candidate)
                    openWindow = openWindow.map { merge($0, sample) } ?? sample
                } else {
                    if let window = openWindow { pieces.append(window) }
                    openWindow = nil
                }
            } else {
                hasGaps = true
                if let window = openWindow { pieces.append(window) }
                openWindow = nil
            }
            candidate = candidate.addingTimeInterval(configuration.sweepIncrementSeconds)
        }
        if let window = openWindow { pieces.append(window) }
        return (pieces, hasGaps)
    }

    private func resolveContexts(_ route: RoutePlan, _ boat: BoatSettings, _ offsets: [Double],
                                 _ span: ClosedRange<Date>, _ provider: TideDataProvider,
                                 _ comparisons: [String: String]) async -> [WaypointTideContext?] {
        // Nacheinander auflösen, um den Stationszwischenspeicher des Actors zu nutzen und viele gleichzeitige Anfragen zu vermeiden.
        var result: [WaypointTideContext?] = []
        for (index, waypoint) in route.waypoints.enumerated() {
            let context = await WaypointTideContext.resolve(
                waypoint: waypoint, plannedArrivalTime: route.plannedStartTime.addingTimeInterval(offsets[index] * 3_600),
                travelOffsetHours: offsets[index], draftMeters: boat.draftMeters,
                manualCorrectionMeters: waypoint.bshWaterLevelCorrectionOverride ?? route.bshWaterLevelCorrectionMeters,
                searchSpan: span, tideDataProvider: provider,
                confirmedComparisonStationID: comparisons[waypoint.tidalReferenceStationID]
            )
            result.append(context)
        }
        return result
    }

    private func clearances(_ contexts: [WaypointTideContext], at departure: Date) -> [Double]? {
        let values = contexts.compactMap {
            $0.clearance(atArrival: $0.arrival(forDeparture: departure), strategy: tidalHeightStrategy)
        }
        return values.count == contexts.count && values.allSatisfy(\.isFinite) ? values : nil
    }

    private func windowSample(
        _ contexts: [WaypointTideContext], values: [Double], at departure: Date
    ) -> PassageWindowScanner.Window {
        let limiting = values.indices.min { values[$0] < values[$1] }!
        let context = contexts[limiting]
        let arrival = context.arrival(forDeparture: departure)
        let quality = contexts.reduce(WaterLevelCorrectionQuality.localOfficial) {
            Self.worstQuality($0, $1.quality(at: $1.arrival(forDeparture: departure)))
        }
        let highWater = context.nearestWaypointHighWater(to: arrival)
        return .init(
            start: departure, end: departure,
            anchoredHighWater: highWater.flatMap { abs($0.timeIntervalSince(arrival)) < 400 * 60 ? $0 : nil },
            bottleneckName: context.name, waterLevelQuality: quality,
            waterLevelDetail: Self.detail(for: quality),
            recommendedDeparture: departure, recommendedClearanceMeters: values[limiting],
            bottleneckArrival: arrival, bottleneckDepthDetail: context.depthSourceDescription
        )
    }

    private func merge(_ first: PassageWindowScanner.Window, _ second: PassageWindowScanner.Window) -> PassageWindowScanner.Window {
        let best = first.recommendedClearanceMeters >= second.recommendedClearanceMeters ? first : second
        let quality = Self.worstQuality(first.waterLevelQuality, second.waterLevelQuality)
        return .init(start: first.start, end: second.end, anchoredHighWater: best.anchoredHighWater,
                     bottleneckName: best.bottleneckName, waterLevelQuality: quality,
                     waterLevelDetail: Self.detail(for: quality),
                     recommendedDeparture: best.recommendedDeparture, recommendedClearanceMeters: best.recommendedClearanceMeters,
                     bottleneckArrival: best.bottleneckArrival, bottleneckDepthDetail: best.bottleneckDepthDetail)
    }

    static func worstQuality(_ first: WaterLevelCorrectionQuality, _ second: WaterLevelCorrectionQuality) -> WaterLevelCorrectionQuality {
        qualityRank(first) >= qualityRank(second) ? first : second
    }

    static func qualityRank(_ quality: WaterLevelCorrectionQuality) -> Int {
        switch quality {
        case .localOfficial: return 0
        case .manual: return 1
        case .modelForecast: return 2
        case .confirmedComparison: return 3
        case .outsideForecastHorizon: return 4
        case .estimatedTide: return 5
        case .stale: return 6
        case .unavailable: return 7
        case .unverifiedDepth: return 8
        }
    }

    static func detail(for quality: WaterLevelCorrectionQuality) -> String? {
        switch quality {
        case .localOfficial: return "Mit lokaler Wasserstandsprognose."
        case .manual: return "Manuelle Wasserstandskorrektur."
        case .modelForecast: return "Vorläufig: automatische Wasserstandsprognose, ohne gesicherte Untergrenze."
        case .confirmedComparison: return "Vorläufig: bestätigter Vergleichspegel."
        case .outsideForecastHorizon: return "Vorläufig: nur astronomisch, Windstau noch nicht vorhergesagt."
        case .estimatedTide: return "Vorläufig: örtliche HW/NW-Zeiten mit mittleren Tidehöhen."
        case .stale: return "Vorläufig: Prognose veraltet, Berechnung ohne Windstau."
        case .unavailable: return "Vorläufig: keine lokale Wasserstandsprognose, Berechnung ohne Windstau."
        case .unverifiedDepth: return "Vorläufig: unbestätigte Katalogtiefen auf der Strecke. Aktuelle Lotungen prüfen."
        }
    }
}
