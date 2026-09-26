import Foundation
import CoreLocation
import Observation

// MARK: - Standortdienst
//
// Zentraler Zugriff auf GPS für die Aufzeichnung eines Törns,
// auch während die App im Hintergrund läuft:
//
//   • `requestAlwaysAuthorization()` — fordert dauerhaften Standortzugriff an.
//   • `allowsBackgroundLocationUpdates = true` — bei dauerhaftem Zugriff.
//   • `showsBackgroundLocationIndicator = true` — sichtbarer Hinweis auf Hintergrundmessungen.
//   • `desiredAccuracy = kCLLocationAccuracyBestForNavigation` — hohe Genauigkeit
//      für die Navigation.
//   • `pausesLocationUpdatesAutomatically = false` — keine automatische Pause,
//      da auch ein langsam treibendes Boot aktuelle Positionen benötigt.
//   • `activityType = .otherNavigation` — Standortverarbeitung für Navigation
//      außerhalb des Straßenverkehrs.
//
// Geschwindigkeit wird von m/s in Knoten umgerechnet, Kurs rechtweisend in Grad
// angegeben. Die Kompassrichtung aus dem Magnetometer dreht die Karte.
//
// `onLocationUpdate` meldet jede Position direkt aus dem Core-Location-Delegate
// an die Empfänger. `ActiveVoyageManager` kann den Fahrtverlauf so auch bei
// unterbrochener SwiftUI-Oberfläche im Hintergrund weiter erfassen.

@Observable
@MainActor
final class LocationService: NSObject {

    // MARK: - Veröffentlichter Zustand

    /// Neueste gültige CLLocation. Bis zur ersten Messung `nil`.
    private(set) var currentLocation: CLLocation?
    /// Fahrt über Grund in Knoten (1 m/s ≈ 1,94384 kn), auf mindestens 0 begrenzt.
    private(set) var speedKnots: Double = 0
    /// Rechtweisender Kurs über Grund in Grad. Im Stillstand `nil`,
    /// da CLLocation dann `course = -1` liefert.
    private(set) var courseDegrees: Double?
    /// Rechtweisende Kompassrichtung für die Kartendrehung.
    /// Falls sie fehlt, wird die magnetische Richtung verwendet.
    private(set) var headingDegrees: Double?
    /// Aktueller Berechtigungsstatus. Die Oberfläche zeigt einen Hinweis,
    /// wenn weder `.authorizedAlways` noch `.authorizedWhenInUse` vorliegt.
    private(set) var authorizationStatus: CLAuthorizationStatus
    /// `true`, solange CLLocationManager aktiv Positionsmessungen liefert.
    private(set) var isTracking: Bool = false

    // MARK: - Weitergabe an Empfänger
    //
    // `ActiveVoyageManager` registriert hier eine Rückruffunktion für jede
    // Standortmeldung. Der direkte Aufruf aus dem Core-Location-Delegate
    // funktioniert auch bei unterbrochener Oberfläche im Hintergrund.

    var onLocationUpdate: ((CLLocation) -> Void)?

    // MARK: - Initialisierung

    private let manager: CLLocationManager

    override init() {
        let mgr = CLLocationManager()
        self.manager = mgr
        self.authorizationStatus = mgr.authorizationStatus
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        mgr.distanceFilter = 5.0      // Meter; Kompromiss zwischen Stromverbrauch und Messdichte
        mgr.activityType = .otherNavigation
        mgr.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Berechtigungen

    /// Fordert dauerhaften Standortzugriff für die Hintergrundaufzeichnung an.
    /// Wenn zuvor nur Zugriff während der Nutzung erlaubt war, kann iOS zunächst
    /// diese Berechtigung beibehalten und die weitere Abfrage später anzeigen.
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

    // MARK: - Start und Ende der Messungen

    /// Startet Positions- und Richtungsmessungen. Wiederholte Aufrufe sind möglich,
    /// da CoreLocation doppelte Startaufrufe auslässt.
    func startUpdates() {
        // Hintergrundmessungen nur bei dauerhaftem Standortzugriff aktivieren.
        // Für `allowsBackgroundLocationUpdates = true` muss die passende
        // Berechtigung vorliegen.
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

    /// Beendet GPS- und Richtungsmessungen und deaktiviert den Hintergrundbetrieb.
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
        // Ungültige Messungen mit negativer Genauigkeit oder mehr als 100 m
        // horizontaler Unsicherheit verwerfen.
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
            // Wird während eines Törns dauerhafter Standortzugriff gewährt,
            // Hintergrundmessungen sofort einschalten.
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
        // Wiederholte CoreLocation-Fehler bei verweigertem GPS-Zugriff nicht einzeln
        // anzeigen. Die Oberfläche prüft stattdessen `authorizationStatus`,
        // um häufig wiederkehrende Fehlermeldungen zu vermeiden.
    }
}
