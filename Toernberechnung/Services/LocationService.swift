import Foundation
import CoreLocation
import Observation

// MARK: - Location Service
//
// Single source of truth for hardware GPS. Designed to support an
// active sailing voyage that keeps recording while the app is in the
// background:
//
//   • `requestAlwaysAuthorization()` — needed for background updates.
//   • `allowsBackgroundLocationUpdates = true` — when always-authorized.
//   • `showsBackgroundLocationIndicator = true` — Apple-required UI hint.
//   • `desiredAccuracy = kCLLocationAccuracyBestForNavigation` — high-rate
//      fixes appropriate for marine navigation.
//   • `pausesLocationUpdatesAutomatically = false` — never pause; a sailor
//      drifting in calm wind still needs a fix.
//   • `activityType = .otherNavigation` — Core Location heuristics that suit
//      a vessel rather than a car.
//
// Speed (m/s) is converted to knots and course is reported in degrees
// true.  Heading is taken from the magnetometer to drive map rotation.
//
// Updates are pushed to listeners via a `onLocationUpdate` closure so
// the `ActiveVoyageManager` can accumulate breadcrumbs in real time —
// background-friendly because the closure runs from the CL delegate
// even while the SwiftUI scene is suspended.

@Observable
@MainActor
final class LocationService: NSObject {

    // MARK: - Published state

    /// Most recent valid CLLocation. `nil` until the first fix.
    private(set) var currentLocation: CLLocation?
    /// Speed over Ground in knots (1 m/s ≈ 1.94384 kn). Clamped to ≥ 0.
    private(set) var speedKnots: Double = 0
    /// Course over Ground in degrees true.  `nil` while stationary
    /// because CLLocation publishes `course = -1` in that case.
    private(set) var courseDegrees: Double?
    /// True heading from the magnetometer for map rotation.  Falls back
    /// to magnetic heading when true heading is unavailable.
    private(set) var headingDegrees: Double?
    /// Current authorization status. UI shows a hint when this is
    /// anything other than `.authorizedAlways` / `.authorizedWhenInUse`.
    private(set) var authorizationStatus: CLAuthorizationStatus
    /// `true` while CLLocationManager is actively delivering fixes.
    private(set) var isTracking: Bool = false

    // MARK: - Fan-out for listeners
    //
    // `ActiveVoyageManager` installs a closure here to receive every
    // delegate update. This pattern is preferred over Combine observation
    // because it works identically when the app is suspended in the
    // background — the closure is invoked directly from the CL delegate.

    var onLocationUpdate: ((CLLocation) -> Void)?

    // MARK: - Init

    private let manager: CLLocationManager

    override init() {
        let mgr = CLLocationManager()
        self.manager = mgr
        self.authorizationStatus = mgr.authorizationStatus
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        mgr.distanceFilter = 5.0      // metres — balances battery vs. fidelity
        mgr.activityType = .otherNavigation
        mgr.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Authorization

    /// Request Always authorization so background tracking works.
    /// If the user has previously granted only When-In-Use, iOS will
    /// silently keep the current grant; the second `request…Always` call
    /// will surface the prompt.
    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: - Lifecycle

    /// Start delivering high-rate fixes plus heading. Safe to call
    /// repeatedly — CoreLocation ignores duplicate `start` calls.
    func startUpdates() {
        // Enable background updates only if we hold "Always" — iOS will
        // reject `allowsBackgroundLocationUpdates = true` with anything
        // less.
        let status = manager.authorizationStatus
        if status == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            if #available(iOS 11.0, *) {
                manager.showsBackgroundLocationIndicator = true
            }
        } else {
            manager.allowsBackgroundLocationUpdates = false
        }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
        isTracking = true
    }

    /// Stop all GPS / heading updates and disable background mode.
    func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        isTracking = false
        speedKnots = 0
        courseDegrees = nil
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        // Filter out obviously bad fixes (negative accuracy or > 100 m of
        // horizontal slop). Marine GPS is usually < 10 m.
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100 else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentLocation = location
            self.speedKnots = max(0, location.speed) * 1.94384
            self.courseDegrees = location.course >= 0 ? location.course : nil
            self.onLocationUpdate?(location)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        let value: Double?
        if newHeading.trueHeading >= 0 {
            value = newHeading.trueHeading
        } else if newHeading.magneticHeading >= 0 {
            value = newHeading.magneticHeading
        } else {
            value = nil
        }
        Task { @MainActor [weak self] in
            self?.headingDegrees = value
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            // If the user just upgraded to "Always" while a voyage is
            // in flight, switch on background updates immediately.
            if status == .authorizedAlways, self.isTracking {
                self.manager.allowsBackgroundLocationUpdates = true
                if #available(iOS 11.0, *) {
                    self.manager.showsBackgroundLocationIndicator = true
                }
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // Silent failure — CoreLocation reports the same error every few
        // seconds when GPS is denied; surfacing it would spam the UI.
        // The view layer checks `authorizationStatus` instead.
    }
}
