import Foundation

// MARK: - Passage Window Solver

/// Answers the question the Excel tool cannot: **when is a passage open?**
///
/// For every waypoint it derives the time span in which the boat still floats,
/// converts it into a departure span, and intersects all of them into one
/// route-wide window. The per-waypoint spans survive as `BottleneckWindow`s, so
/// the UI can name the constriction that closes the route and say by how many
/// centimetres it misses.
///
/// ## Why this is not a scan
///
/// The previous implementation shifted the departure time in ten-minute steps
/// and recalculated the whole route for each candidate — up to 217 full
/// recalculations, each awaiting the tide provider per waypoint. The expensive
/// part was never the arithmetic; it was resolving the same tide data over and
/// over.
///
/// Here the tide data is resolved **once per waypoint**, and the passable span
/// then follows from `TidalHeightStrategy.maxDeviationHours` in closed form.
/// Only when the water level correction actually varies over time does the
/// solver fall back to sampling — and even then it samples synchronously,
/// without touching the network.
struct PassageWindowSolver {

    // MARK: - Types

    /// One waypoint's passability, expressed both as arrival and as departure
    /// times so the UI can show either.
    struct BottleneckWindow: Identifiable, Equatable {
        let id: UUID
        let waypointName: String
        /// "Wattenhoch", "Hafen", "Fahrwasser" — nil when the catalog has none.
        let category: String?
        /// When the boat may **arrive** here. Nil when never passable in range.
        let arrivalWindow: ClosedRange<Date>?
        /// The same span shifted back by the travel time, i.e. when the boat
        /// must **leave the start** for this waypoint to be passable.
        let departureWindow: ClosedRange<Date>?
        /// Cumulative travel time from the start to this waypoint.
        let travelOffsetHours: Double
        let plannedArrivalTime: Date
        let plannedClearanceMeters: Double?
        /// How much water is missing at the planned time. Zero when passable.
        let shortfallMeters: Double
        let quality: WaterLevelCorrectionQuality

        var isPassableAtPlannedTime: Bool { shortfallMeters <= 0 }
    }

    struct Solution: Equatable {
        /// Route-wide departure window — the intersection of all bottlenecks.
        let routeWindow: PassageWindowScanner.Window?
        /// Every evaluated waypoint, in route order.
        let bottlenecks: [BottleneckWindow]
        /// True when a leg has SOG ≤ 0, which makes timing meaningless.
        let hasInvalidLeg: Bool

        /// The waypoint with the least water at the planned time — the one that
        /// decides whether the route goes.
        var limiting: BottleneckWindow? {
            bottlenecks.min { lhs, rhs in
                let left = lhs.plannedClearanceMeters ?? .greatestFiniteMagnitude
                let right = rhs.plannedClearanceMeters ?? .greatestFiniteMagnitude
                return left < right
            }
        }
    }

    struct Configuration: Equatable {
        var searchBackwardHours: Double = 12
        var searchForwardHours: Double = 24
        /// Only used when the correction varies over time.
        var sweepIncrementSeconds: TimeInterval = 60
        var boundaryToleranceSeconds: TimeInterval = 30
    }

    // MARK: - Init

    var configuration: Configuration
    private let tidalHeightStrategy: TidalHeightStrategy

    init(
        configuration: Configuration = Configuration(),
        tidalHeightStrategy: TidalHeightStrategy = TwelfthsRuleStrategy()
    ) {
        self.configuration = configuration
        self.tidalHeightStrategy = tidalHeightStrategy
    }

    // MARK: - Entry point

    func solve(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider,
        confirmedComparisonGaugeIDs: [String: String] = [:]
    ) async -> Solution {
        guard route.waypoints.count >= 2,
              route.legs.count == route.waypoints.count - 1,
              boatSettings.draftMeters > 0 else {
            return Solution(routeWindow: nil, bottlenecks: [], hasInvalidLeg: false)
        }

        // The travel times are independent of the departure time, because
        // SOG = speed + current has no time dependency. That is what allows the
        // arrival spans to be shifted into departure spans further down.
        let legResults = RouteCalculationService.calculateLegResults(
            startTime: route.plannedStartTime,
            legs: route.legs
        )
        guard legResults.allSatisfy(\.isValid) else {
            return Solution(routeWindow: nil, bottlenecks: [], hasInvalidLeg: true)
        }

        var travelOffsets: [Double] = [0]
        for leg in legResults { travelOffsets.append(leg.cumulativeTravelTimeHours) }

        let searchSpan = route.plannedStartTime
            .addingTimeInterval(-configuration.searchBackwardHours * 3_600)
            ... route.plannedStartTime
            .addingTimeInterval(configuration.searchForwardHours * 3_600)

        let contexts = await resolveContexts(
            route: route,
            boatSettings: boatSettings,
            travelOffsets: travelOffsets,
            searchSpan: searchSpan,
            tideDataProvider: tideDataProvider,
            confirmedComparisonGaugeIDs: confirmedComparisonGaugeIDs
        )
        guard !contexts.isEmpty else {
            return Solution(routeWindow: nil, bottlenecks: [], hasInvalidLeg: false)
        }

        let bottlenecks = contexts.map { context in
            makeBottleneck(
                context: context,
                searchSpan: searchSpan,
                safetyMarginMeters: boatSettings.safetyMarginMeters
            )
        }

        return Solution(
            routeWindow: routeWindow(
                from: bottlenecks,
                plannedStart: route.plannedStartTime,
                contexts: contexts
            ),
            bottlenecks: bottlenecks,
            hasInvalidLeg: false
        )
    }

    // MARK: - Context resolution (the only async part)

    private func resolveContexts(
        route: RoutePlan,
        boatSettings: BoatSettings,
        travelOffsets: [Double],
        searchSpan: ClosedRange<Date>,
        tideDataProvider: TideDataProvider,
        confirmedComparisonGaugeIDs: [String: String]
    ) async -> [WaypointTideContext] {
        await withTaskGroup(of: (Int, WaypointTideContext?).self) { group in
            for (index, waypoint) in route.waypoints.enumerated() {
                let offsetHours = travelOffsets[index]
                let plannedArrival = route.plannedStartTime
                    .addingTimeInterval(offsetHours * 3_600)
                group.addTask {
                    let context = await WaypointTideContext.resolve(
                        waypoint: waypoint,
                        plannedArrivalTime: plannedArrival,
                        travelOffsetHours: offsetHours,
                        draftMeters: boatSettings.draftMeters,
                        manualCorrectionMeters: waypoint.bshWaterLevelCorrectionOverride
                            ?? route.bshWaterLevelCorrectionMeters,
                        searchSpan: searchSpan,
                        tideDataProvider: tideDataProvider,
                        confirmedComparisonStationID:
                            confirmedComparisonGaugeIDs[waypoint.tidalReferenceStationID]
                    )
                    return (index, context)
                }
            }

            var resolved: [(Int, WaypointTideContext)] = []
            for await (index, context) in group {
                if let context { resolved.append((index, context)) }
            }
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Per-waypoint window

    private func makeBottleneck(
        context: WaypointTideContext,
        searchSpan: ClosedRange<Date>,
        safetyMarginMeters: Double
    ) -> BottleneckWindow {
        let arrivalSpan = context.searchSpanShiftedToArrival(searchSpan)
        let arrivalWindow = passableArrivalWindow(
            context: context,
            within: arrivalSpan,
            containing: context.plannedArrivalTime
        )
        let plannedClearance = context.clearance(
            atArrival: context.plannedArrivalTime,
            strategy: tidalHeightStrategy
        )
        let shortfall = plannedClearance.map { max(0, -$0) } ?? 0

        return BottleneckWindow(
            id: context.waypointID,
            waypointName: context.name,
            category: context.category,
            arrivalWindow: arrivalWindow,
            departureWindow: arrivalWindow.map { window in
                let shift = -context.travelOffsetHours * 3_600
                return window.lowerBound.addingTimeInterval(shift)
                    ... window.upperBound.addingTimeInterval(shift)
            },
            travelOffsetHours: context.travelOffsetHours,
            plannedArrivalTime: context.plannedArrivalTime,
            plannedClearanceMeters: plannedClearance,
            shortfallMeters: shortfall,
            quality: context.correction.fallback.quality
        )
    }

    /// The passable span around the high water nearest `preferred`.
    ///
    /// With a constant correction the answer is exact: the budget of spare
    /// water converts straight into a maximum deviation. With a time-varying
    /// correction the boundaries are found by sweeping and then refined by
    /// bisection — always inwards, so the reported edge is the last instant
    /// verified as passable and never an optimistic extrapolation.
    private func passableArrivalWindow(
        context: WaypointTideContext,
        within span: ClosedRange<Date>,
        containing preferred: Date
    ) -> ClosedRange<Date>? {
        guard let highWater = context.nearestWaypointHighWater(to: preferred) else { return nil }

        // Constant correction: the budget of spare water converts straight into
        // a maximum deviation, and because `clearance(atArrival:)` anchors on
        // the same high water, a passable arrival is always inside the result.
        if context.correction.samples.isEmpty {
            guard let maxDeviation = tidalHeightStrategy.maxDeviationHours(
                forMaxMissingWaterMeters: context.missingWaterBudgetMeters(
                    correctionMeters: context.correction.fallback.meters
                ),
                meanTidalRangeMeters: context.meanTidalRangeMeters
            ) else { return nil }

            let lower = highWater.addingTimeInterval(-maxDeviation * 3_600)
            let upper = highWater.addingTimeInterval(maxDeviation * 3_600)
            return clamp(lower ... upper, to: span)
        }

        // Time-varying correction: passability is no longer strictly monotonic
        // around high water, so a sweep outwards from the peak can stop at a
        // gap while the planned arrival sits in a later pocket. Growing the
        // window from the arrival itself — when that floats — keeps the
        // reported span and the reported clearance consistent.
        let sweepAnchor: Date
        if (context.clearance(atArrival: preferred, strategy: tidalHeightStrategy) ?? -1) >= 0 {
            sweepAnchor = preferred
        } else {
            sweepAnchor = highWater
        }
        return sweptWindow(context: context, within: span, around: sweepAnchor)
    }

    private func sweptWindow(
        context: WaypointTideContext,
        within span: ClosedRange<Date>,
        around highWater: Date
    ) -> ClosedRange<Date>? {
        func isPassable(_ time: Date) -> Bool {
            (context.clearance(atArrival: time, strategy: tidalHeightStrategy) ?? -1) >= 0
        }
        guard isPassable(highWater) else { return nil }

        let step = configuration.sweepIncrementSeconds
        let tolerance = configuration.boundaryToleranceSeconds

        /// Walks outwards while passable, then bisects the last passable
        /// instant. The returned edge is always verified, never extrapolated.
        func edge(direction: Double) -> Date {
            var lastPassable = highWater
            var candidate = highWater.addingTimeInterval(direction * step)
            while span.contains(candidate), isPassable(candidate) {
                lastPassable = candidate
                candidate = candidate.addingTimeInterval(direction * step)
            }
            guard span.contains(candidate) else { return lastPassable }

            var low = lastPassable
            var high = candidate
            while abs(high.timeIntervalSince(low)) > tolerance {
                let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                if isPassable(middle) { low = middle } else { high = middle }
            }
            return low
        }

        return clamp(edge(direction: -1) ... edge(direction: 1), to: span)
    }

    private func clamp(
        _ window: ClosedRange<Date>,
        to span: ClosedRange<Date>
    ) -> ClosedRange<Date>? {
        let lower = max(window.lowerBound, span.lowerBound)
        let upper = min(window.upperBound, span.upperBound)
        return lower <= upper ? lower ... upper : nil
    }

    // MARK: - Route-wide intersection

    private func routeWindow(
        from bottlenecks: [BottleneckWindow],
        plannedStart: Date,
        contexts: [WaypointTideContext]
    ) -> PassageWindowScanner.Window? {
        var intersection: ClosedRange<Date>?
        for bottleneck in bottlenecks {
            guard let window = bottleneck.departureWindow else { return nil }
            guard let current = intersection else {
                intersection = window
                continue
            }
            let lower = max(current.lowerBound, window.lowerBound)
            let upper = min(current.upperBound, window.upperBound)
            guard lower <= upper else { return nil }
            intersection = lower ... upper
        }
        guard let window = intersection else { return nil }

        let limiting = bottlenecks.min { lhs, rhs in
            let left = lhs.plannedClearanceMeters ?? .greatestFiniteMagnitude
            let right = rhs.plannedClearanceMeters ?? .greatestFiniteMagnitude
            return left < right
        }
        // The worst quality across the route governs the whole window — one
        // waypoint without a local forecast makes the entire window provisional.
        let quality = bottlenecks
            .map(\.quality)
            .max(by: { Self.qualityRank($0) < Self.qualityRank($1) })
            ?? .unavailable

        return PassageWindowScanner.Window(
            start: window.lowerBound,
            end: window.upperBound,
            anchoredHighWater: limiting.flatMap { limitingBottleneck in
                contexts
                    .first { $0.waypointID == limitingBottleneck.id }?
                    .nearestWaypointHighWater(to: limitingBottleneck.plannedArrivalTime)
            },
            bottleneckName: limiting?.waypointName,
            waterLevelQuality: quality,
            waterLevelDetail: Self.detail(for: quality)
        )
    }

    // MARK: - Quality presentation

    static func qualityRank(_ quality: WaterLevelCorrectionQuality) -> Int {
        switch quality {
        case .localOfficial: return 0
        case .manual: return 1
        case .confirmedComparison: return 2
        case .stale: return 3
        case .outsideForecastHorizon: return 4
        case .unavailable: return 5
        }
    }

    static func detail(for quality: WaterLevelCorrectionQuality) -> String? {
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
