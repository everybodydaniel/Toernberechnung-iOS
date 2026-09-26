import Foundation
import CoreLocation
import Observation

// MARK: - Navigation während des Törns
//
// Berechnet Navigationswerte für jede Positionsmessung:
//
//   • activeWaypointName   — nächster vom Nutzer gewählter Hafen
//   • distanceToWaypointNm — Strecke entlang der Route bis zu diesem Hafen
//   • distanceToFinalNm    — Strecke entlang der Route bis zum Ziel
//   • dynamicETA           — Ankunftszeit aus der aktuellen Fahrt über Grund;
//                            unter 1 kn wird die geplante Geschwindigkeit verwendet
//   • crossTrackError      — senkrechter Abstand zur aktiven Routenlinie
//   • isOffCourse          — Routenabweichung über 150 m
//   • bearingToWaypoint    — rechtweisende Peilung in Grad
//
// Abgesehen von der aktiven Route wird kein Verlauf gespeichert. Jede Messung
// sucht den nächsten Streckenabschnitt neu. So bleibt die Berechnung nachvollziehbar
// und kann eine während des Törns geänderte Route direkt berücksichtigen.

@Observable
@MainActor
final class NavigationTracker {

    // MARK: - Konfiguration

    /// Grenze der Routenabweichung in Metern, ab der `isOffCourse` true wird.
    var offCourseThresholdMeters: Double = 150

    /// Geplante Geschwindigkeit in Knoten. Wird für die Ankunftszeit verwendet,
    /// wenn die aktuelle Fahrt über Grund unter `minimumSOGKnots` liegt.
    var plannedSpeedKnots: Double = 6

    /// Unterhalb dieser Fahrt über Grund gilt das Boot als treibend oder festliegend.
    /// `plannedSpeedKnots` verhindert dann eine unendliche berechnete Fahrtdauer.
    private let minimumSOGKnots: Double = 1.0

    // MARK: - Zuordnung der aktiven Route

    private(set) var activeRoute: RoutePlan?
    /// Stabile Kennungen der vom Nutzer gewählten Wegpunkte in der erweiterten Route.
    /// Beim Anzeigen des nächsten Hafens werden zusätzliche Fahrwasserpunkte übersprungen.
    private var userWaypointIDs: Set<UUID> = []

    // MARK: - Werte für die Oberfläche

    private(set) var activeWaypointName: String?
    private(set) var activeWaypointIndex: Int?
    private(set) var distanceToWaypointNm: Double?
    private(set) var distanceToFinalNm: Double?
    private(set) var dynamicETA: Date?
    private(set) var crossTrackErrorMeters: Double?
    private(set) var bearingToWaypointDegrees: Double?
    private(set) var isOffCourse: Bool = false
    /// Die Route gilt als beendet, sobald das Boot höchstens 50 m vom Zielwegpunkt entfernt ist.
    private(set) var hasArrived: Bool = false

    // MARK: - Routenzuordnung

    /// Ordnet einen neuen Routenplan zu und setzt alle Ausgabewerte zurück.
    func setRoute(_ route: RoutePlan, userWaypointIDs: [UUID], plannedSpeedKnots: Double) {
        self.activeRoute = route
        self.userWaypointIDs = Set(userWaypointIDs)
        self.plannedSpeedKnots = max(0.5, plannedSpeedKnots)
        reset()
    }

    func reset() {
        activeWaypointName = nil
        activeWaypointIndex = nil
        distanceToWaypointNm = nil
        distanceToFinalNm = nil
        dynamicETA = nil
        crossTrackErrorMeters = nil
        bearingToWaypointDegrees = nil
        isOffCourse = false
        hasArrived = false
    }

    // MARK: - Aktualisierung je Positionsmessung

    func update(location: CLLocation, speedKnots: Double) {
        guard let route = activeRoute, route.waypoints.count >= 2 else { return }

        let coords: [CLLocationCoordinate2D] = route.waypoints.compactMap { wp in
            guard let lat = wp.latitude, let lon = wp.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard coords.count >= 2 else { return }

        // 1. Streckenabschnitt mit dem kleinsten senkrechten Abstand suchen.
        let user = location.coordinate
        var bestSegment = 0
        var bestXTE = Double.infinity
        for i in 0 ..< coords.count - 1 {
            let dist = Self.perpendicularDistance(point: user, segA: coords[i], segB: coords[i + 1])
            if dist < bestXTE {
                bestXTE = dist
                bestSegment = i
            }
        }
        let segmentEndIndex = bestSegment + 1
        let endWP = route.waypoints[segmentEndIndex]
        activeWaypointIndex = segmentEndIndex

        // 2. Nächsten vom Nutzer gewählten Hafen ab segmentEndIndex ermitteln.
        let nextHarbourIndex = (segmentEndIndex ..< route.waypoints.count).first { idx in
            userWaypointIDs.contains(route.waypoints[idx].id)
        } ?? (route.waypoints.count - 1)
        activeWaypointName = route.waypoints[nextHarbourIndex].name

        // 3. Strecke entlang der Route zum nächsten Hafen berechnen.
        let toHarbourMeters = Self.alongRouteDistanceMeters(
            from: location,
            startIndex: segmentEndIndex,
            endIndex: nextHarbourIndex,
            coords: coords
        )
        distanceToWaypointNm = toHarbourMeters / 1852.0

        // 4. Strecke entlang der Route zum Ziel berechnen.
        let lastIndex = coords.count - 1
        let toFinalMeters = Self.alongRouteDistanceMeters(
            from: location,
            startIndex: segmentEndIndex,
            endIndex: lastIndex,
            coords: coords
        )
        distanceToFinalNm = toFinalMeters / 1852.0

        // 5. Ankunftszeit mit Ersatzwert bei geringer Fahrt über Grund berechnen.
        let effectiveSpeedKnots = speedKnots >= minimumSOGKnots
            ? speedKnots
            : plannedSpeedKnots
        if effectiveSpeedKnots > 0 {
            let hours = (toFinalMeters / 1852.0) / effectiveSpeedKnots
            dynamicETA = Date().addingTimeInterval(hours * 3600)
        } else {
            dynamicETA = nil
        }

        // 6. Routenabweichung und Überschreitung der Grenze bestimmen.
        crossTrackErrorMeters = bestXTE
        isOffCourse = bestXTE > offCourseThresholdMeters

        // 7. Rechtweisende Peilung zum nächsten Dijkstra-Wegpunkt bestimmen.
        bearingToWaypointDegrees = Self.bearing(from: user, to: coords[segmentEndIndex])

        // 8. Ankunft dauerhaft vormerken.
        let finalLoc = CLLocation(latitude: coords[lastIndex].latitude,
                                  longitude: coords[lastIndex].longitude)
        hasArrived = location.distance(from: finalLoc) <= 50
        _ = endWP   // Warnung für ungenutzten Wert vermeiden; für spätere Verwendung vorgesehen
    }

    // MARK: - Geometrische Hilfsfunktionen ohne Zustandsänderung

    /// Gesamte Großkreisentfernung ab `from` über alle Koordinaten
    /// von `startIndex` bis einschließlich `endIndex`.
    nonisolated static func alongRouteDistanceMeters(
        from origin: CLLocation,
        startIndex: Int,
        endIndex: Int,
        coords: [CLLocationCoordinate2D]
    ) -> Double {
        guard startIndex < coords.count else { return 0 }
        let firstLoc = CLLocation(
            latitude: coords[startIndex].latitude,
            longitude: coords[startIndex].longitude
        )
        var total = origin.distance(from: firstLoc)
        if endIndex <= startIndex { return total }
        for i in startIndex ..< endIndex {
            let a = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            let b = CLLocation(latitude: coords[i + 1].latitude, longitude: coords[i + 1].longitude)
            total += a.distance(from: b)
        }
        return total
    }

    /// Senkrechter Abstand von `point` zum Abschnitt a→b in einer Ebene.
    /// Verwendet eine lokale Näherung mit Skalierung über den Kosinus der mittleren Breite.
    /// So ist keine vollständige Kugelprojektion für jede Positionsmessung nötig.
    nonisolated static func perpendicularDistance(
        point p: CLLocationCoordinate2D,
        segA a: CLLocationCoordinate2D,
        segB b: CLLocationCoordinate2D
    ) -> Double {
        let metresPerDegLat = 111_320.0
        let midLat = (a.latitude + b.latitude) / 2.0
        let metresPerDegLon = 111_320.0 * cos(midLat * .pi / 180)

        let ax = a.longitude * metresPerDegLon
        let ay = a.latitude  * metresPerDegLat
        let bx = b.longitude * metresPerDegLon
        let by = b.latitude  * metresPerDegLat
        let px = p.longitude * metresPerDegLon
        let py = p.latitude  * metresPerDegLat

        let dx = bx - ax
        let dy = by - ay
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            let dpx = px - ax
            let dpy = py - ay
            return (dpx * dpx + dpy * dpy).squareRoot()
        }
        let t = ((px - ax) * dx + (py - ay) * dy) / lenSq
        let clampedT = max(0, min(1, t))
        let fx = ax + clampedT * dx
        let fy = ay + clampedT * dy
        let ex = px - fx
        let ey = py - fy
        return (ex * ex + ey * ey).squareRoot()
    }

    /// Rechtweisende Anfangspeilung in Grad von `a` nach `b` (0…360).
    nonisolated static func bearing(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }
}
