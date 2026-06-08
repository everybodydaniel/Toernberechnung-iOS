import Foundation
import CoreLocation
import Observation
import SwiftData

// MARK: - Active Voyage Manager
//
// Owns the lifecycle of a live tracked voyage:
//
//   • `startVoyage(route:userWaypointIDs:plannedSpeedKnots:)`
//        Switches on background-capable GPS, binds the navigation tracker
//        to the planned route, resets all running totals.
//   • Per-fix processing
//        Filters out idle GPS noise, accumulates the breadcrumb trail,
//        sums actual distance sailed in nautical miles, tracks max and
//        average SOG.
//   • `stopVoyageAndSaveLogbook(...)`
//        Persists a `CalculationRecord` flagged as `isActualVoyage = true`
//        with the GPS-measured distance, average / max SOG, duration, and
//        a JSON-encoded breadcrumb trail.  Then clears the active session.
//
// `elapsedTime` is intentionally **computed** from `voyageStartTime` so
// the value stays correct after the app is backgrounded — `Timer` won't
// fire while suspended, but `Date()` always works.  Views animate the
// clock via a `TimelineView` that re-reads `elapsedTime` once per second.

@Observable
@MainActor
final class ActiveVoyageManager {

    // MARK: - State

    private(set) var isVoyageActive: Bool = false
    private(set) var voyageStartTime: Date?
    private(set) var voyageEndTime: Date?

    /// Cumulative GPS-measured distance in nautical miles.
    private(set) var totalDistanceNm: Double = 0
    private(set) var maxSOGKnots: Double = 0
    private(set) var averageSOGKnots: Double = 0
    private(set) var sampleCount: Int = 0

    /// Breadcrumb trail of accepted GPS samples.  Exposed so the map can
    /// draw the actual sailed path on top of the planned route polyline.
    private(set) var breadcrumbs: [CLLocation] = []

    /// Planned route the voyage is anchored to (for UI + logbook output).
    private(set) var activeRoute: RoutePlan?
    private(set) var userWaypointIDs: [UUID] = []

    /// Computed live elapsed-time.  Reads `Date()` so it's correct even
    /// when the app was suspended for hours.
    var elapsedTime: TimeInterval {
        guard let start = voyageStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Dependencies

    private let locationService: LocationService
    private let tracker: NavigationTracker
    /// Minimum distance (m) between consecutive accepted breadcrumbs.
    /// Discards idle GPS jitter when the boat is moored.
    private let minBreadcrumbMeters: Double = 5
    /// Maximum acceptable horizontal accuracy (m) for breadcrumb samples.
    private let maxAccuracyMeters: Double = 30

    init(locationService: LocationService, tracker: NavigationTracker) {
        self.locationService = locationService
        self.tracker = tracker
    }

    // MARK: - Public API

    /// Start a live voyage. Requests Always-authorization, switches on
    /// background updates, binds the tracker, and resets running totals.
    func startVoyage(
        route: RoutePlan,
        userWaypointIDs: [UUID],
        plannedSpeedKnots: Double
    ) {
        guard !isVoyageActive else { return }

        // Reset session state.
        activeRoute = route
        self.userWaypointIDs = userWaypointIDs
        voyageStartTime = Date()
        voyageEndTime = nil
        totalDistanceNm = 0
        maxSOGKnots = 0
        averageSOGKnots = 0
        sampleCount = 0
        breadcrumbs.removeAll()
        sogSum = 0
        lastLocation = nil

        tracker.setRoute(route, userWaypointIDs: userWaypointIDs, plannedSpeedKnots: plannedSpeedKnots)

        // Install the fan-out callback BEFORE starting updates so we
        // don't miss the very first fix.
        locationService.onLocationUpdate = { [weak self] location in
            // The closure runs from CL's delegate (main actor); we hop to
            // the main actor explicitly to satisfy isolation when the
            // delegate eventually moves off-main on iOS 18+.
            Task { @MainActor [weak self] in
                self?.processLocation(location)
            }
        }
        locationService.requestAuthorization()
        locationService.startUpdates()

        isVoyageActive = true
    }

    /// Stop the voyage, persist a logbook entry, and clear session state.
    /// Returns the inserted record so the caller can display a confirmation.
    @discardableResult
    func stopVoyageAndSaveLogbook(
        modelContext: ModelContext,
        weatherSummary: String = "",
        tideSummary: String = "",
        crewSummary: String = ""
    ) -> CalculationRecord? {
        guard isVoyageActive,
              let route = activeRoute,
              let start = voyageStartTime
        else { return nil }
        let end = Date()
        voyageEndTime = end

        let durationSeconds = end.timeIntervalSince(start)
        let plannedDistance = route.waypoints.count >= 2
            ? plannedDistanceNm(route)
            : 0

        let record = CalculationRecord(
            routeTitle: route.routeName,
            startName: route.waypoints.first?.name ?? "",
            destinationName: route.waypoints.last?.name ?? "",
            departureAt: start,
            arrivalAt: end,
            distanceNM: plannedDistance,
            status: "Fahrt abgeschlossen",
            fmw: 0, wt: 0, wuk: 0,
            weatherSummary: weatherSummary,
            tideSummary: tideSummary,
            crewSummary: crewSummary,
            notes: voyageNotes(durationSeconds: durationSeconds),
            createdAt: Date(),
            isActualVoyage: true,
            actualDistanceNM: totalDistanceNm,
            averageSOGKnots: averageSOGKnots,
            maxSOGKnots: maxSOGKnots,
            voyageDurationSeconds: durationSeconds,
            breadcrumbJSON: encodeBreadcrumbs(breadcrumbs)
        )
        modelContext.insert(record)
        try? modelContext.save()

        cleanup()
        return record
    }

    /// Abandon the voyage without persisting anything (e.g. user cancels).
    func cancelVoyage() {
        cleanup()
    }

    // MARK: - Per-fix processing

    private var lastLocation: CLLocation?
    private var sogSum: Double = 0

    private func processLocation(_ location: CLLocation) {
        guard isVoyageActive else { return }
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maxAccuracyMeters else { return }

        // Speed normalisation (m/s → kn).
        let sogKnots = max(0, location.speed) * 1.94384

        // Update the navigation tracker on every accepted fix.
        tracker.update(location: location, speedKnots: sogKnots)

        // Discard near-stationary jitter when accumulating breadcrumbs.
        if let last = lastLocation {
            let metres = location.distance(from: last)
            guard metres >= minBreadcrumbMeters else { return }
            totalDistanceNm += metres / 1852.0
        }

        breadcrumbs.append(location)
        lastLocation = location

        if sogKnots > 0 {
            sampleCount += 1
            sogSum += sogKnots
            averageSOGKnots = sogSum / Double(sampleCount)
            maxSOGKnots = max(maxSOGKnots, sogKnots)
        }
    }

    // MARK: - Cleanup / encoding

    private func cleanup() {
        locationService.onLocationUpdate = nil
        locationService.stopUpdates()
        tracker.reset()
        isVoyageActive = false
        voyageStartTime = nil
        activeRoute = nil
        userWaypointIDs.removeAll()
        lastLocation = nil
    }

    private func voyageNotes(durationSeconds: TimeInterval) -> String {
        let dur = AppDateFormatters.duration(hours: durationSeconds / 3600)
        return [
            "Tatsächliche Fahrstrecke (GPS): \(String(format: "%.2f", totalDistanceNm)) sm",
            "Fahrtdauer (GPS):              \(dur)",
            "Ø SOG:                          \(String(format: "%.1f", averageSOGKnots)) kn",
            "Max SOG:                        \(String(format: "%.1f", maxSOGKnots)) kn",
            "Breadcrumbs:                    \(breadcrumbs.count) Punkte"
        ].joined(separator: "\n")
    }

    private func plannedDistanceNm(_ route: RoutePlan) -> Double {
        let coords = route.waypoints.compactMap { wp -> CLLocationCoordinate2D? in
            guard let lat = wp.latitude, let lon = wp.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard coords.count >= 2 else { return 0 }
        var metres: Double = 0
        for i in 0 ..< coords.count - 1 {
            let a = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            let b = CLLocation(latitude: coords[i + 1].latitude, longitude: coords[i + 1].longitude)
            metres += a.distance(from: b)
        }
        return metres / 1852.0
    }

    private func encodeBreadcrumbs(_ trail: [CLLocation]) -> String {
        struct Point: Codable {
            let lat: Double
            let lon: Double
            let ts: Double   // unix epoch seconds
        }
        let points = trail.map {
            Point(lat: $0.coordinate.latitude,
                  lon: $0.coordinate.longitude,
                  ts: $0.timestamp.timeIntervalSince1970)
        }
        guard let data = try? JSONEncoder().encode(points),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }
}
