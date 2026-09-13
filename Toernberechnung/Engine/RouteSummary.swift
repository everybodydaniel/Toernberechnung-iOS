import Foundation

// MARK: - Route Summary
//
// User-facing condensation of a `RouteCalculationResult`. The Dijkstra
// fairway WPs (NauticalRouter) are *not* displayed individually — they
// only contribute their depth values to the leg they belong to.
//
// A leg connects two **user-selected** harbours (start, intermediate
// stops, destination). For each leg we report:
//   - the departure harbour
//   - the arrival harbour
//   - cumulative ETA at the arrival harbour
//   - the worst (smallest) WuK observed across the leg's fairway WPs
//   - leg status: .go / .warning / .noGo / .incomplete
//   - the WP name that triggered a failure (so the UI can say
//     "Passage von Norderney nach Juist nicht möglich – Knoten
//     `watt_nesskana` < Sicherheitsmarge").

struct RouteSummary: Equatable {

    struct Leg: Equatable, Identifiable {
        /// Derived from the endpoint waypoints, not freshly generated, so a
        /// recalculation keeps SwiftUI's per-leg state (e.g. an expanded
        /// calculation table) instead of resetting it.
        var id: String { "\(fromWaypointID.uuidString)-\(toWaypointID.uuidString)" }
        let fromWaypointID: UUID
        let toWaypointID: UUID
        let fromName: String
        let toName: String
        let departureTime: Date
        let arrivalTime: Date
        let distanceNm: Double
        let travelTimeHours: Double
        let worstWuKMeters: Double?
        let bottleneckName: String?
        let status: WaypointStatus
        let failureReason: String?
    }

    let legs: [Leg]
    let overallStatus: RouteStatus



    // MARK: - Build

    /// Build a leg-based summary from a calculation result.
    ///
    /// - Parameters:
    ///   - result: the engine's per-WP calculation result.
    ///   - userWaypointIDs: ordered IDs of the user-selected harbours
    ///     (start, intermediate stops, destination).  Every WP whose ID
    ///     is in this set is treated as a user harbour; everything else
    ///     is a Dijkstra fairway WP and only contributes to the leg.
    static func build(
        from result: RouteCalculationResult,
        userWaypointIDs: [UUID]
    ) -> RouteSummary {
        let userIDSet = Set(userWaypointIDs)
        let wpResults = result.waypointResults

        // Indices of user WPs inside wpResults, in order.
        let userIndices = wpResults.enumerated()
            .filter { userIDSet.contains($0.element.waypoint.id) }
            .map(\.offset)

        var legs: [Leg] = []
        for pair in zip(userIndices, userIndices.dropFirst()) {
            let (fromIdx, toIdx) = pair
            let fromWP = wpResults[fromIdx]
            let toWP   = wpResults[toIdx]

            // Worst WuK across all WPs in this leg (inclusive of `to`).
            let inLeg = Array(wpResults[(fromIdx + 1) ... toIdx])
            let valid = inLeg.compactMap { wp -> (WaypointCalculationResult, Double)? in
                guard let v = wp.clearanceUnderKeelWuKMeters else { return nil }
                return (wp, v)
            }
            let worst = valid.min { $0.1 < $1.1 }
            let worstWuK = worst?.1
            let worstWP  = worst?.0.waypoint.name

            // Leg distance / travel time = sum over the underlying legs.
            let underlyingLegs = result.legResults.filter { leg in
                let fromIDs = (fromIdx ..< toIdx).map { wpResults[$0].waypoint.id }
                let toIDs   = ((fromIdx + 1) ... toIdx).map { wpResults[$0].waypoint.id }
                return fromIDs.contains(leg.leg.fromWaypointID)
                    && toIDs.contains(leg.leg.toWaypointID)
            }
            let distance = underlyingLegs.reduce(0) { $0 + $1.leg.distanceNm }
            let travelHours = underlyingLegs.reduce(0) { $0 + $1.travelTimeHours }

            // Leg status = worst status among the WPs in this leg (excluding
            // the leg's departure WP which was scored by the previous leg).
            let legStatus = legStatusFrom(inLeg.map(\.status))

            // Failure detail.
            var failureReason: String?
            if legStatus == .noGo || legStatus == .invalid {
                if let trigger = inLeg.first(where: { $0.status == .noGo || $0.status == .invalid }) {
                    failureReason = "WuK \(trigger.clearanceUnderKeelWuKMeters.map { String(format: "%.2f m", $0) } ?? "ungültig") an \(trigger.waypoint.name)"
                }
            } else if legStatus == .incomplete {
                failureReason = "Gezeiten- oder Kartendaten fehlen"
            }

            legs.append(Leg(
                fromWaypointID: fromWP.waypoint.id,
                toWaypointID: toWP.waypoint.id,
                fromName: fromWP.waypoint.name,
                toName: toWP.waypoint.name,
                departureTime: fromWP.arrivalTime,
                arrivalTime: toWP.arrivalTime,
                distanceNm: distance,
                travelTimeHours: travelHours,
                worstWuKMeters: worstWuK,
                bottleneckName: worstWP,
                status: legStatus,
                failureReason: failureReason
            ))
        }

        return RouteSummary(legs: legs, overallStatus: result.tidalStatus)
    }

    private static func legStatusFrom(_ statuses: [WaypointStatus]) -> WaypointStatus {
        if statuses.contains(.invalid) { return .invalid }
        if statuses.contains(.noGo) { return .noGo }
        if statuses.contains(.incomplete) { return .incomplete }
        if statuses.contains(.warning) { return .warning }
        return .go
    }
}
