import Foundation
import CoreLocation
import Observation
import SwiftData

// MARK: - Verwaltung des aktiven Törns
//
// Verwaltet die Aufzeichnung eines laufenden Törns:
//
//   • `startVoyage(route:userWaypointIDs:plannedSpeedKnots:)`
//        Startet GPS mit Hintergrundbetrieb, verbindet die Navigation
//        mit der geplanten Route und setzt die Summen zurück.
//   • Verarbeitung jeder Positionsmessung
//        Filtert GPS-Schwankungen im Stillstand, speichert den Fahrtverlauf
//        und berechnet Strecke sowie höchste und mittlere Fahrt über Grund.
//   • `stopVoyageAndSaveLogbook(...)`
//        Speichert einen `CalculationRecord` mit `isActualVoyage = true`,
//        GPS-Strecke, Geschwindigkeiten, Dauer und Fahrtverlauf als JSON.
//        Beendet anschließend die aktive Sitzung.
//
// `elapsedTime` wird aus `voyageStartTime` und `Date()` berechnet.
// So bleibt die Dauer nach einer Unterbrechung im Hintergrund korrekt,
// auch wenn der Timer währenddessen nicht läuft. Die Oberfläche liest
// den Wert über `TimelineView` einmal pro Sekunde neu.

@Observable
@MainActor
final class ActiveVoyageManager {

    // MARK: - Zustand

    private(set) var isVoyageActive: Bool = false
    private(set) var voyageStartTime: Date?
    private(set) var voyageEndTime: Date?

    /// Gesamte per GPS gemessene Strecke in Seemeilen.
    private(set) var totalDistanceNm: Double = 0
    private(set) var maxSOGKnots: Double = 0
    private(set) var averageSOGKnots: Double = 0
    private(set) var sampleCount: Int = 0

    /// Fahrtverlauf aus gültigen GPS-Messungen. Die Karte kann ihn
    /// über der geplanten Route darstellen.
    private(set) var breadcrumbs: [CLLocation] = []

    /// Geplante Route des Törns für die Oberfläche und den Logbucheintrag.
    private(set) var activeRoute: RoutePlan?
    private(set) var userWaypointIDs: [UUID] = []
    private(set) var latestWeatherSnapshot: MaritimeWeatherSnapshot?

    /// Berechnet die bisherige Dauer mit `Date()`. Der Wert bleibt auch
    /// nach längeren Unterbrechungen der App korrekt.
    var elapsedTime: TimeInterval {
        guard let start = voyageStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Abhängigkeiten

    private let locationService: LocationService
    private let tracker: NavigationTracker
    private let weatherService: MaritimeWeatherService
    /// Mindestabstand in Metern zwischen gespeicherten Positionen.
    /// Filtert GPS-Schwankungen bei einem festliegenden Boot.
    private let minBreadcrumbMeters: Double = 5
    /// Größte zulässige horizontale Messungenauigkeit in Metern für den Fahrtverlauf.
    private let maxAccuracyMeters: Double = 30

    init(
        locationService: LocationService,
        tracker: NavigationTracker,
        weatherService: MaritimeWeatherService = .shared
    ) {
        self.locationService = locationService
        self.tracker = tracker
        self.weatherService = weatherService
    }

    // MARK: - Öffentliche Schnittstelle

    /// Startet die Törnaufzeichnung. Fordert dauerhaften Standortzugriff an,
    /// aktiviert Hintergrundmessungen, verbindet die Navigation und setzt die Summen zurück.
    func startVoyage(
        route: RoutePlan,
        userWaypointIDs: [UUID],
        plannedSpeedKnots: Double
    ) {
        guard !isVoyageActive else { return }

        // Sitzungszustand zurücksetzen.
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
        latestWeatherSnapshot = nil
        currentWeatherArea = nil
        pendingWeatherArea = nil
        pendingWeatherAreaSince = nil
        nextWeatherCheckAt = UserDefaults.standard.object(
            forKey: Self.navigationWeatherNextCheckKey
        ) as? Date
        weatherTask?.cancel()
        weatherTask = nil

        tracker.setRoute(route, userWaypointIDs: userWaypointIDs, plannedSpeedKnots: plannedSpeedKnots)

        // Rückruffunktion vor dem Start der Messungen registrieren,
        // damit die erste Position erfasst wird.
        locationService.onLocationUpdate = { [weak self] location in
            // Der Aufruf erfolgt derzeit über den Core-Location-Delegate auf dem MainActor.
            // Der ausdrückliche Wechsel zum MainActor sichert den Zugriff auch dann ab,
            // wenn der Delegate später auf einem anderen Ausführungskontext läuft.
            Task { @MainActor [weak self] in
                self?.processLocation(location)
            }
        }
        locationService.requestAuthorization()
        locationService.startUpdates()

        isVoyageActive = true
    }

    /// Beendet den Törn, speichert einen Logbucheintrag und setzt die Sitzung zurück.
    /// Gibt den gespeicherten Eintrag für eine Bestätigung in der Oberfläche zurück.
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

    // MARK: - Verarbeitung der Positionsmessungen

    private var lastLocation: CLLocation?
    private var sogSum: Double = 0
    private var currentWeatherArea: WeatherAreaKey?
    private var pendingWeatherArea: WeatherAreaKey?
    private var pendingWeatherAreaSince: Date?
    private var nextWeatherCheckAt: Date?
    private var weatherTask: Task<Void, Never>?
    private static let navigationWeatherNextCheckKey = "navigationWeatherNextCheckAt"
    private static let stableWeatherAreaDuration: TimeInterval = 20

    private func processLocation(_ location: CLLocation) {
        guard isVoyageActive else { return }
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maxAccuracyMeters else { return }

        // Geschwindigkeit von m/s in Knoten umrechnen.
        let sogKnots = max(0, location.speed) * 1.94384

        // Navigation mit jeder gültigen Positionsmessung aktualisieren.
        tracker.update(location: location, speedKnots: sogKnots)
        refreshWeatherIfNeeded(for: location)

        // Positionsschwankungen im Stillstand beim Speichern des Fahrtverlaufs verwerfen.
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

    private func refreshWeatherIfNeeded(for location: CLLocation) {
        guard let area = location.coordinate.maritimeWeatherArea() else { return }
        let now = Date()
        let changedArea: Bool
        if let currentWeatherArea, area != currentWeatherArea {
            if pendingWeatherArea != area {
                pendingWeatherArea = area
                pendingWeatherAreaSince = now
                return
            }
            guard let pendingWeatherAreaSince,
                  now.timeIntervalSince(pendingWeatherAreaSince) >= Self.stableWeatherAreaDuration else {
                return
            }
            changedArea = true
        } else {
            changedArea = currentWeatherArea == nil
            pendingWeatherArea = nil
            pendingWeatherAreaSince = nil
        }
        let ttlExpired = nextWeatherCheckAt.map { now >= $0 } ?? true
        guard changedArea || ttlExpired else { return }

        if weatherTask != nil {
            guard changedArea else { return }
            weatherTask?.cancel()
        }

        currentWeatherArea = area
        pendingWeatherArea = nil
        pendingWeatherAreaSince = nil
        setNextWeatherCheck(now.addingTimeInterval(60))
        let weatherService = self.weatherService
        weatherTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.weatherTask = nil }
            do {
                let snapshot = try await weatherService.weather(
                    at: location.coordinate,
                    datasets: [.current],
                    policy: .revalidateExpired
                )
                guard !Task.isCancelled, self.currentWeatherArea == area else { return }
                self.latestWeatherSnapshot = snapshot
                self.setNextWeatherCheck(
                    snapshot.productStates[.current]?.validUntil
                        ?? now.addingTimeInterval(40 * 60)
                )
            } catch {
                guard !Task.isCancelled, self.currentWeatherArea == area else { return }
                self.setNextWeatherCheck(Date().addingTimeInterval(5 * 60))
            }
        }
    }

    private func setNextWeatherCheck(_ date: Date) {
        nextWeatherCheckAt = date
        UserDefaults.standard.set(date, forKey: Self.navigationWeatherNextCheckKey)
    }

    // MARK: - Aufräumen und Kodieren

    private func cleanup() {
        locationService.onLocationUpdate = nil
        locationService.stopUpdates()
        tracker.reset()
        isVoyageActive = false
        voyageStartTime = nil
        activeRoute = nil
        userWaypointIDs.removeAll()
        lastLocation = nil
        latestWeatherSnapshot = nil
        currentWeatherArea = nil
        pendingWeatherArea = nil
        pendingWeatherAreaSince = nil
        nextWeatherCheckAt = nil
        weatherTask?.cancel()
        weatherTask = nil
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
            let ts: Double   // Sekunden seit Beginn der Unix-Zeitrechnung
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
