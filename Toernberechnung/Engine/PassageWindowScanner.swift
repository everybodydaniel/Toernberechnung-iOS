import Foundation

// MARK: - Passage Window Scanner (HW-anchored, bottleneck-driven)
//
// Implements the exact algorithm specified by the skipper:
//
//   1. Identify the single shallowest point ("Nadelöhr") of the entire
//      expanded route, including auto-inserted Dijkstra fairway WPs.
//   2. Find the BSH HW (at that bottleneck's tide station) closest to the
//      user's planned arrival there.
//   3. Iterate BACKWARDS from HW in 15-minute steps until
//      `Wassertiefe(t) − Tiefgang < Sicherheitsmarge`.
//      The last successful step is the OPENING of the bottleneck window.
//   4. Iterate FORWARDS from HW in 15-minute steps until the equation
//      fails again.  The last successful step is the CLOSING.
//   5. Translate the bottleneck-arrival window into a DEPARTURE window
//      by subtracting the cumulative travel time to the bottleneck.
//
// All formatting is forced to `Europe/Berlin` time and `de_DE` locale.

struct PassageWindowScanner {

    // MARK: - Public types

    struct Window: Equatable {
        let start: Date
        let end: Date
        /// BSH HW used as anchor (for display).
        let anchoredHighWater: Date?
        /// Bottleneck waypoint name (for display).
        let bottleneckName: String?

        func contains(_ date: Date) -> Bool { date >= start && date <= end }

        var displayString: String {
            "\(AppDateFormatters.hourMinute.string(from: start))" +
            " – \(AppDateFormatters.hourMinute.string(from: end)) Uhr"
        }
    }

    // MARK: - Config

    /// Iteration step. 15 minutes per the skipper's spec.
    let stepSeconds: TimeInterval = 15 * 60
    /// Hard limit: ±12 h from HW.
    let maxOffsetHours: Double = 12

    init() {}

    // MARK: - Entry point

    func findSafeWindow(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider
    ) async -> Window? {
        // 1. Identify the bottleneck waypoint and its position in the route.
        guard let bottleneck = bottleneck(in: route, boat: boatSettings) else { return nil }

        // 2. Travel time from start to the bottleneck.
        let travelToBottleneck = travelTime(
            toWaypointIndex: bottleneck.index,
            in: route
        )
        let plannedArrival = route.plannedStartTime.addingTimeInterval(travelToBottleneck)

        // 3. BSH HW at the bottleneck's tide station closest to planned arrival.
        let hwEvents = (try? await tideDataProvider.highWaters(
            for: bottleneck.waypoint.tidalReferenceStationID,
            around: plannedArrival
        )) ?? []
        guard let bshHW = hwEvents
            .map(\.time)
            .min(by: { abs($0.timeIntervalSince(plannedArrival))
                     < abs($1.timeIntervalSince(plannedArrival)) })
        else { return nil }

        // 4. Local HW at the bottleneck = BSH HW + waypoint HW offset.
        let localHW = bshHW.addingTimeInterval(
            Double(bottleneck.waypoint.highWaterOffsetMinutes) * 60
        )

        // 5. Quick sanity check: must be safe AT HW or the cycle has no window.
        guard let centralWuK = wuk(
            at: localHW,
            waypoint: bottleneck.waypoint,
            localHW: localHW,
            bshCorrection: bshCorrectionFor(waypoint: bottleneck.waypoint, route: route),
            draft: boatSettings.draftMeters
        ), centralWuK >= boatSettings.safetyMarginMeters else {
            return nil
        }

        // 6. Sweep BACKWARDS from HW until WuK < margin.
        var opening = localHW
        var elapsed: Double = 0
        while elapsed < maxOffsetHours * 3600 {
            let candidate = opening.addingTimeInterval(-stepSeconds)
            guard let wukVal = wuk(
                at: candidate, waypoint: bottleneck.waypoint, localHW: localHW,
                bshCorrection: bshCorrectionFor(waypoint: bottleneck.waypoint, route: route),
                draft: boatSettings.draftMeters
            ), wukVal >= boatSettings.safetyMarginMeters else { break }
            opening = candidate
            elapsed += stepSeconds
        }

        // 7. Sweep FORWARDS from HW until WuK < margin.
        var closing = localHW
        elapsed = 0
        while elapsed < maxOffsetHours * 3600 {
            let candidate = closing.addingTimeInterval(stepSeconds)
            guard let wukVal = wuk(
                at: candidate, waypoint: bottleneck.waypoint, localHW: localHW,
                bshCorrection: bshCorrectionFor(waypoint: bottleneck.waypoint, route: route),
                draft: boatSettings.draftMeters
            ), wukVal >= boatSettings.safetyMarginMeters else { break }
            closing = candidate
            elapsed += stepSeconds
        }

        // 8. Translate to DEPARTURE window by subtracting travel time.
        let departureStart = opening.addingTimeInterval(-travelToBottleneck)
        let departureEnd   = closing.addingTimeInterval(-travelToBottleneck)

        return Window(
            start: departureStart,
            end: departureEnd,
            anchoredHighWater: bshHW,
            bottleneckName: bottleneck.waypoint.name
        )
    }

    // MARK: - WuK at a single point in time

    /// Computes WuK at the bottleneck for a given time, anchored on `localHW`.
    /// Returns nil if required tidal inputs are missing OR deviation > 12 h.
    private func wuk(
        at time: Date,
        waypoint: RouteWaypoint,
        localHW: Date,
        bshCorrection: Double,
        draft: Double
    ) -> Double? {
        let deviationHours = abs(time.timeIntervalSince(localHW)) / 3600
        guard let mth = waypoint.meanTidalRangeMeters?.value, mth > 0 else { return nil }
        guard let fmw = RuleOfTwelfths.steppedFehlmenge(
            deviationHours: deviationHours, meanTidalRangeMeters: mth
        ) else { return nil }

        switch waypoint.calculationMode {
        case .meanHighWater:
            guard let mhw = waypoint.meanHighWaterMeters?.value,
                  let chart = waypoint.chartDepthMeters?.value else { return nil }
            let wt = (mhw - fmw) + bshCorrection + chart
            return wt - draft

        case .lottiefe:
            guard let lottiefe = waypoint.lottiefeMeters?.value else { return nil }
            let wt = (lottiefe - fmw) + bshCorrection
            return wt - draft
        }
    }

    // MARK: - Bottleneck identification

    private struct Bottleneck {
        let waypoint: RouteWaypoint
        let index: Int
        /// Static depth budget at MHW (MHW + chartDepth, or Lottiefe).
        let staticDepthBudget: Double
    }

    /// Smallest MHW-relative depth budget along the route after subtracting
    /// the boat draft. If multiple WPs share the lowest budget the FIRST
    /// occurrence is returned, so the travel-time translation is conservative.
    private func bottleneck(in route: RoutePlan, boat: BoatSettings) -> Bottleneck? {
        var best: Bottleneck?
        for (i, wp) in route.waypoints.enumerated() {
            let budget: Double
            switch wp.calculationMode {
            case .meanHighWater:
                guard let mhw = wp.meanHighWaterMeters?.value,
                      let chart = wp.chartDepthMeters?.value else { continue }
                budget = mhw + chart
            case .lottiefe:
                guard let lt = wp.lottiefeMeters?.value else { continue }
                budget = lt
            }
            if let current = best {
                if budget < current.staticDepthBudget {
                    best = Bottleneck(waypoint: wp, index: i, staticDepthBudget: budget)
                }
            } else {
                best = Bottleneck(waypoint: wp, index: i, staticDepthBudget: budget)
            }
        }
        return best
    }

    // MARK: - Travel time helpers

    /// Cumulative travel time from the start waypoint to waypoint index `target`.
    private func travelTime(toWaypointIndex target: Int, in route: RoutePlan) -> TimeInterval {
        if target <= 0 { return 0 }
        let legResults = RouteCalculationService.calculateLegResults(
            startTime: route.plannedStartTime, legs: route.legs
        )
        let legIndex = min(target - 1, legResults.count - 1)
        guard legIndex >= 0 else { return 0 }
        return legResults[legIndex].arrivalTime
            .timeIntervalSince(route.plannedStartTime)
    }

    private func bshCorrectionFor(waypoint: RouteWaypoint, route: RoutePlan) -> Double {
        waypoint.bshWaterLevelCorrectionOverride ?? route.bshWaterLevelCorrectionMeters
    }
}
