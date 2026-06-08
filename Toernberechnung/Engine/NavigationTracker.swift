import Foundation
import CoreLocation
import Observation

// MARK: - Navigation Tracker
//
// Computes per-fix navigation derivatives for the active voyage:
//
//   • activeWaypointName   — next USER harbour we are heading to
//   • distanceToWaypointNm — along-route distance to that harbour
//   • distanceToFinalNm    — along-route distance to the destination
//   • dynamicETA           — ETA at the destination based on current SOG;
//                            falls back to the planned speed when SOG < 1 kn
//   • crossTrackError      — perpendicular distance to the active route line
//   • isOffCourse          — XTE > 150 m  (skipper-defined threshold)
//   • bearingToWaypoint    — true bearing in degrees
//
// The tracker is deliberately stateless beyond the active route — every
// update finds the closest segment from scratch. That keeps the maths
// transparent and avoids state-machine bugs when the user manually
// re-routes mid-voyage.

@Observable
@MainActor
final class NavigationTracker {

    // MARK: - Configuration

    /// XTE threshold in metres beyond which `isOffCourse` flips to true.
    var offCourseThresholdMeters: Double = 150

    /// Planned speed in knots (skipper's cruising speed). Used as the ETA
    /// denominator when the live SOG is below `minimumSOGKnots`.
    var plannedSpeedKnots: Double = 6

    /// Below this SOG the boat is considered drifting / moored and we
    /// substitute `plannedSpeedKnots` to avoid an "infinite ETA" display.
    private let minimumSOGKnots: Double = 1.0

    // MARK: - Active route binding

    private(set) var activeRoute: RoutePlan?
    /// Stable IDs of the USER waypoints inside the expanded route. Used to
    /// skip Dijkstra fairway nodes when reporting the "next harbour".
    private var userWaypointIDs: Set<UUID> = []

    // MARK: - Outputs (read by UI)

    private(set) var activeWaypointName: String?
    private(set) var activeWaypointIndex: Int?
    private(set) var distanceToWaypointNm: Double?
    private(set) var distanceToFinalNm: Double?
    private(set) var dynamicETA: Date?
    private(set) var crossTrackErrorMeters: Double?
    private(set) var bearingToWaypointDegrees: Double?
    private(set) var isOffCourse: Bool = false
    /// The route is "complete" once we are within 50 m of the final WP.
    private(set) var hasArrived: Bool = false

    // MARK: - Bindings

    /// Bind a new route plan. Resets all outputs.
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

    // MARK: - Per-fix update

    func update(location: CLLocation, speedKnots: Double) {
        guard let route = activeRoute, route.waypoints.count >= 2 else { return }

        let coords: [CLLocationCoordinate2D] = route.waypoints.compactMap { wp in
            guard let lat = wp.latitude, let lon = wp.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard coords.count >= 2 else { return }

        // 1. Find the closest segment (smallest perpendicular distance).
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

        // 2. Project to the next USER harbour at or after segmentEndIndex.
        let nextHarbourIndex = (segmentEndIndex ..< route.waypoints.count).first { idx in
            userWaypointIDs.contains(route.waypoints[idx].id)
        } ?? (route.waypoints.count - 1)
        activeWaypointName = route.waypoints[nextHarbourIndex].name

        // 3. Along-route distance to active harbour.
        let toHarbourMeters = Self.alongRouteDistanceMeters(
            from: location,
            startIndex: segmentEndIndex,
            endIndex: nextHarbourIndex,
            coords: coords
        )
        distanceToWaypointNm = toHarbourMeters / 1852.0

        // 4. Along-route distance to destination.
        let lastIndex = coords.count - 1
        let toFinalMeters = Self.alongRouteDistanceMeters(
            from: location,
            startIndex: segmentEndIndex,
            endIndex: lastIndex,
            coords: coords
        )
        distanceToFinalNm = toFinalMeters / 1852.0

        // 5. Dynamic ETA with SOG fallback.
        let effectiveSpeedKnots = speedKnots >= minimumSOGKnots
            ? speedKnots
            : plannedSpeedKnots
        if effectiveSpeedKnots > 0 {
            let hours = (toFinalMeters / 1852.0) / effectiveSpeedKnots
            dynamicETA = Date().addingTimeInterval(hours * 3600)
        } else {
            dynamicETA = nil
        }

        // 6. XTE + off-course flag.
        crossTrackErrorMeters = bestXTE
        isOffCourse = bestXTE > offCourseThresholdMeters

        // 7. True bearing to the next Dijkstra waypoint.
        bearingToWaypointDegrees = Self.bearing(from: user, to: coords[segmentEndIndex])

        // 8. Arrival latch.
        let finalLoc = CLLocation(latitude: coords[lastIndex].latitude,
                                  longitude: coords[lastIndex].longitude)
        hasArrived = location.distance(from: finalLoc) <= 50
        _ = endWP   // silence unused warning; reserved for future use
    }

    // MARK: - Geometry helpers (static / pure)

    /// Cumulative great-circle distance starting at `from`, hitting every
    /// coord from `startIndex` through `endIndex`.
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

    /// Planar perpendicular distance from `point` to the segment a→b.
    /// Uses a local equirectangular approximation (cos-of-midlatitude
    /// scaling) which is accurate to a few cm at marine speeds and
    /// avoids the cost of full spherical projection per fix.
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

    /// True initial bearing in degrees from `a` to `b` (0…360).
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
