import Foundation

// MARK: - Routenzusammenfassung
//
// Zusammenfassung eines `RouteCalculationResult` für die Oberfläche.
// Zusätzliche Dijkstra-Fahrwasserpunkte werden nicht einzeln angezeigt.
// Ihre Tiefenwerte fließen in den jeweiligen Streckenabschnitt ein.
//
// Ein Abschnitt verbindet zwei gewählte Häfen: Start, Zwischenstopps oder Ziel.
// Für jeden Abschnitt werden ausgegeben:
//   - Abfahrtshafen
//   - Ankunftshafen
//   - Ankunftszeit am Ankunftshafen
//   - kleinstes Wasser unter Kiel an den Fahrwasserpunkten des Abschnitts
//   - Status: .go / .warning / .noGo / .incomplete
//   - Name des Wegpunkts, der eine Einschränkung verursacht, damit die Oberfläche
//     die betroffene Passage und die unterschrittene Sicherheitsgrenze nennen kann.

struct RouteSummary: Equatable {

    struct Leg: Equatable, Identifiable {
        /// Aus den Endpunktkennungen abgeleitet, nicht neu erzeugt. So bleiben
        /// SwiftUI-Zustände eines Abschnitts, etwa eine geöffnete Berechnungstabelle,
        /// bei einer Neuberechnung erhalten.
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



    // MARK: - Aufbau

    /// Erstellt aus dem Berechnungsergebnis eine Zusammenfassung nach Streckenabschnitten.
    ///
    /// - Parameters:
    ///   - result: Berechnungsergebnis für jeden Wegpunkt.
    ///   - userWaypointIDs: Geordnete Kennungen der gewählten Häfen
    ///     (Start, Zwischenstopps, Ziel). Diese Punkte gelten als Nutzerhäfen.
    ///     Alle übrigen Punkte gelten als Dijkstra-Fahrwasserpunkte und
    ///     fließen nur in den zugehörigen Abschnitt ein.
    static func build(
        from result: RouteCalculationResult,
        userWaypointIDs: [UUID]
    ) -> RouteSummary {
        let userIDSet = Set(userWaypointIDs)
        let wpResults = result.waypointResults

        // Indizes der gewählten Wegpunkte in wpResults, in ihrer Reihenfolge.
        let userIndices = wpResults.enumerated()
            .filter { userIDSet.contains($0.element.waypoint.id) }
            .map(\.offset)

        var legs: [Leg] = []
        for pair in zip(userIndices, userIndices.dropFirst()) {
            let (fromIdx, toIdx) = pair
            let fromWP = wpResults[fromIdx]
            let toWP   = wpResults[toIdx]

            // Kleinstes Wasser unter Kiel an allen Punkten dieses Abschnitts, einschließlich `to`.
            let inLeg = Array(wpResults[(fromIdx + 1) ... toIdx])
            let valid = inLeg.compactMap { wp -> (WaypointCalculationResult, Double)? in
                guard let v = wp.clearanceUnderKeelWuKMeters else { return nil }
                return (wp, v)
            }
            let worst = valid.min { $0.1 < $1.1 }
            let worstWuK = worst?.1
            let worstWP  = worst?.0.waypoint.name

            // Strecke und Fahrtdauer des Abschnitts aus den enthaltenen Teilabschnitten summieren.
            let underlyingLegs = result.legResults.filter { leg in
                let fromIDs = (fromIdx ..< toIdx).map { wpResults[$0].waypoint.id }
                let toIDs   = ((fromIdx + 1) ... toIdx).map { wpResults[$0].waypoint.id }
                return fromIDs.contains(leg.leg.fromWaypointID)
                    && toIDs.contains(leg.leg.toWaypointID)
            }
            let distance = underlyingLegs.reduce(0) { $0 + $1.leg.distanceNm }
            let travelHours = underlyingLegs.reduce(0) { $0 + $1.travelTimeHours }

            // Abschnittsstatus aus dem ungünstigsten Wegpunktstatus bestimmen.
            // Der Startpunkt zählt zum vorherigen Abschnitt und wird hier ausgelassen.
            let legStatus = legStatusFrom(inLeg.map(\.status))

            // Angabe zur Ursache der Einschränkung.
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
