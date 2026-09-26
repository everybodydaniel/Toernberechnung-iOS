import Foundation
import Observation

// MARK: - Modell für Zwischenstopps
//
// Ein vom Nutzer ergänzter Zwischenstopp mit stabiler `id`. So kann SwiftUI
// die Liste auch bei schnellen Änderungen sicher abgleichen. Eine veränderbare
// Hafenkennung als Identität könnte während einer Aktualisierung zu einem
// ungültigen Index und einem Absturz führen.

struct IntermediateStop: Identifiable, Equatable {
    let id: UUID
    var harbourID: String

    init(id: UUID = UUID(), harbourID: String) {
        self.id = id
        self.harbourID = harbourID
    }
}

// MARK: - ViewModel der Routenplanung

/// Beobachtbares ViewModel für die Routenberechnung mit mehreren Wegpunkten im Kartenbereich.
///
/// Nach Auswahl von Start, Ziel und Abfahrt wird die Route automatisch aufgebaut
/// und mit `RouteCalculationService` berechnet.
@Observable
final class RoutePlannerViewModel {
    // MARK: - Eingabezustand

    var startHarbourID: String = "" {
        didSet {
            guard oldValue != startHarbourID else { return }
            if !removeIntermediateStopsMatchingEndpoints() {
                onRouteChanged()
            }
        }
    }
    var destinationHarbourID: String = "" {
        didSet {
            guard oldValue != destinationHarbourID else { return }
            if !removeIntermediateStopsMatchingEndpoints() {
                onRouteChanged()
            }
        }
    }
    /// Geordnete Zwischenstopps mit jeweils stabiler UUID für den Listenabgleich
    /// in SwiftUI. Hafenkennungen eignen sich nicht als Identität, da zwei Stopps
    /// denselben Hafen verwenden können. Eine stabile UUID verhindert ungültige
    /// Indizes, wenn während einer Aktualisierung ein Eintrag gelöscht wird.
    var intermediateStops: [IntermediateStop] = [] {
        didSet {
            let sanitized = sanitizedIntermediateStops(intermediateStops)
            if sanitized != intermediateStops {
                intermediateStops = sanitized
                return
            }
            if oldValue != intermediateStops { onRouteChanged() }
        }
    }
    var departure: Date = Date() {
        didSet { if !isApplyingDeparture { scheduleRecalculation() } }
    }
    private var isApplyingDeparture = false
    var planningDay: Date {
        get { AppDateFormatters.berlinCalendar.startOfDay(for: departure) }
        set { departure = AppDateFormatters.berlinCalendar.startOfDay(for: newValue) }
    }
    var speedKnots: Double = RoutePlannerViewModel.loadSpeedFromSettings() {
        didSet {
            let formatted = String(format: "%.1f", speedKnots)
            if UserDefaults.standard.string(forKey: "boatSpeed") != formatted {
                UserDefaults.standard.set(formatted, forKey: "boatSpeed")
            }
            scheduleRecalculation()
        }
    }
    /// Excel `$AD$13`. Der Standardwert `nil` verwendet die BSH-Vorhersage.
    /// Ein gesetzter Wert, einschließlich `0`, ersetzt sie für den gesamten Törn.
    var bshWaterLevelCorrection: Double? {
        didSet { scheduleRecalculation() }
    }
    private(set) var confirmedComparisonGaugeIDs: [String: String] = [:]

    // MARK: - Berechnungszustand

    var routePlan: RoutePlan?
    var calculationResult: RouteCalculationResult?
    /// Zusammenfassung nach Streckenabschnitten für die Oberfläche; zeigt nur gewählte Häfen.
    var routeSummary: RouteSummary?
    /// Kennungen der gewählten Wegpunkte im erweiterten `routePlan`.
    /// Die Zusammenfassung kann damit zusätzliche Dijkstra-Fahrwasserpunkte auslassen.
    private(set) var userWaypointIDs: [UUID] = []
    var isCalculating: Bool = false
    var calculationError: String?

    // MARK: - Passagefenster

    var passageWindow: PassageWindowScanner.Window?
    var passageWindows: [PassageWindowScanner.Window] = []
    var isSearchingWindow: Bool = false
    var passageWindowMessage: String?

    // MARK: - Wetterstatus

    var weatherStatus: WeatherStatus = .incomplete
    var routeWeatherValidationState: RouteWeatherValidationState = .idle
    private(set) var routeWeatherValidationID: UUID?

    // MARK: - Berechnete Eigenschaften

    var selectedStartHarbour: HarbourOption? { HarbourOption.optionalByID(startHarbourID) }
    var selectedDestinationHarbour: HarbourOption? { HarbourOption.optionalByID(destinationHarbourID) }

    var hasCompleteRouteInput: Bool {
        selectedStartHarbour != nil
            && selectedDestinationHarbour != nil
            && startHarbourID != destinationHarbourID
    }

    // Kompatible Zugriffe für Abläufe, die bereits durch `hasCompleteRouteInput`
    // oder eine vorhandene Route abgesichert sind.
    var startHarbour: HarbourOption { selectedStartHarbour ?? HarbourOption.options[0] }
    var destinationHarbour: HarbourOption { selectedDestinationHarbour ?? HarbourOption.options[0] }

    var routeTitle: String {
        guard let start = selectedStartHarbour, let destination = selectedDestinationHarbour else {
            return "Törn noch nicht geplant"
        }
        return "\(start.name) → \(destination.name)"
    }

    var combinedStatus: CombinedRouteStatus? {
        guard let result = calculationResult else { return nil }
        return CombinedRouteStatus.combine(tidal: result.tidalStatus, weather: weatherStatus)
    }

    var hasIncompleteWeatherCoverage: Bool {
        switch routeWeatherValidationState {
        case .ready(_, let batch):
            return !batch.hasCompleteCoverage
        case .unavailable:
            return true
        case .idle, .loading:
            return weatherStatus == .incomplete
        }
    }

    var statusText: String {
        switch routeWeatherValidationState {
        case .loading(let completed, let total):
            return total > 0 ? "Wetterprüfung \(completed)/\(total)" : "Wetter wird geprüft…"
        case .idle, .ready, .unavailable:
            break
        }
        guard let status = combinedStatus else { return "Berechnung läuft…" }
        switch status {
        case .go: return "Befahrbar"
        case .warning: return "Befahrbar mit Einschränkungen"
        case .noGo: return "Nicht befahrbar"
        case .incomplete: return "Unvollständig"
        }
    }

    var statusDetailText: String? {
        guard let status = combinedStatus else { return nil }
        switch status {
        case .go:
            if hasIncompleteWeatherCoverage {
                return "Wassertiefe ausreichend; Wetterdaten fehlen – vor Abfahrt aktuell prüfen."
            }
            if calculationResult?.waypointResults.contains(where: {
                $0.waterLevelCorrectionQuality != .localOfficial
            }) == true {
                return "Kernkriterien erfüllt; Hinweise zur Datenqualität vor Abfahrt prüfen."
            }
            return "Ausreichend Wassertiefe und sichere Wetterbedingungen."
        case .warning:
            if weatherStatus == .warning {
                return hasIncompleteWeatherCoverage
                    ? "Wetter erfordert Aufmerksamkeit; die Routenabdeckung ist teilweise unvollständig."
                    : "Wetterbedingungen erfordern erhöhte Aufmerksamkeit (Wind/Böen)."
            }
            guard let result = calculationResult else { return nil }
            if let worst = result.worstClearanceUnderKeel, worst < boatSettings.safetyMarginMeters {
                let bn = result.waypointResults.min(by: { ($0.clearanceUnderKeelWuKMeters ?? .infinity) < ($1.clearanceUnderKeelWuKMeters ?? .infinity) })?.waypoint.name ?? "Engstelle"
                return String(format: "Reserve unterschritten: %.2f m WuK an %@", worst, SurveyedDepthCatalog.displayName(for: bn))
            }
            if result.waypointResults.contains(where: { $0.waterLevelCorrectionQuality == .unverifiedDepth }) {
                return "Vorläufig: Unbestätigte Katalogtiefen, aktuelle Lotungen prüfen."
            }
            return "Erhöhte navigatorische Aufmerksamkeit auf der Strecke empfohlen."
        case .noGo:
            if let result = calculationResult, let worst = result.worstClearanceUnderKeel, worst < 0 {
                let bn = result.waypointResults.min(by: { ($0.clearanceUnderKeelWuKMeters ?? .infinity) < ($1.clearanceUnderKeelWuKMeters ?? .infinity) })?.waypoint.name ?? "Engstelle"
                return String(format: "Untiefe: %.2f m WuK an %@", worst, SurveyedDepthCatalog.displayName(for: bn))
            }
            if weatherStatus == .noGo {
                return "Starkwind oder Sturm auf der Route."
            }
            return "Unzureichende Wassertiefe oder unpassierbare Bedingungen."
        case .incomplete:
            return "Gezeiten-, Pegel- oder Wetterdaten noch nicht vollständig."
        }
    }

    var isPassable: Bool {
        combinedStatus == .go || combinedStatus == .warning
    }

    var routeWind: MarineWind? {
        if case .ready(_, let batch) = routeWeatherValidationState {
            return batch.primaryWind
        }
        return nil
    }

    var routeWindSummaryText: String? {
        guard let wind = routeWind else { return nil }
        if let gust = wind.gustKnots, gust > wind.speedKnots + 3 {
            return String(format: "%@ %d° · %.0f kn (Böen %.0f kn)", wind.compassDirection, wind.directionDegrees, wind.speedKnots, gust)
        } else {
            return String(format: "%@ %d° · %.0f kn", wind.compassDirection, wind.directionDegrees, wind.speedKnots)
        }
    }

    var routeWindDirectionBadge: String? {
        guard let wind = routeWind else { return nil }
        return String(format: "%@ %d°", wind.compassDirection, wind.directionDegrees)
    }

    var totalDistanceText: String {
        guard let result = calculationResult else { return "–" }
        return String(format: "%.1f nm", result.totalDistanceNm)
    }

    var totalTravelTimeText: String {
        guard let result = calculationResult else { return "–" }
        let totalMinutes = max(Int((result.totalTravelTimeHours * 60).rounded()), 0)
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    var arrivalTimeText: String {
        guard let result = calculationResult,
              let lastWP = result.waypointResults.last else { return "–" }
        return AppDateFormatters.hourMinute.string(from: lastWP.arrivalTime)
    }

    var worstWuKText: String {
        guard let result = calculationResult,
              let worst = result.worstClearanceUnderKeel else { return "–" }
        return String(format: "%.2f m", worst)
    }

    // MARK: - Abhängigkeiten

    private let catalog: WaddenSeaCatalog
    private let calculationService: RouteCalculationService
    private let tideDataProvider: TideDataProvider
    private let passageScanner: PassageWindowScanner
    private var calculationTask: Task<Void, Never>?
    private var passageWindowTask: Task<Void, Never>?

    // MARK: - Initialisierung

    init(
        catalog: WaddenSeaCatalog? = nil,
        calculationService: RouteCalculationService = RouteCalculationService(),
        tideDataProvider: TideDataProvider = BSHTideDataProvider()
    ) {
        self.catalog = catalog ?? WaddenSeaCatalog.loadBundled()
        self.calculationService = calculationService
        self.tideDataProvider = tideDataProvider
        var scanner = PassageWindowScanner()
        scanner.scanSelectedDay = true
        self.passageScanner = scanner
    }

    // MARK: - Ermittlung der Route

    /// Lädt Bootseinstellungen (Geschwindigkeit, Tiefgang, Sicherheitsabstand)
    /// aus UserDefaults neu und berechnet einen vorhandenen Routenplan erneut.
    func reloadBoatSettings() {
        let loadedSpeed = Self.loadSpeedFromSettings()
        if abs(speedKnots - loadedSpeed) > 0.05 {
            speedKnots = loadedSpeed
        } else if let plan = routePlan {
            runCalculation(plan: plan)
        }
    }

    /// Wird bei Änderungen von Start, Ziel oder Zwischenstopps aufgerufen.
    func onRouteChanged() {
        confirmedComparisonGaugeIDs.removeAll()

        guard hasCompleteRouteInput else {
            clearCalculatedRoute()
            return
        }

        buildHarbourChainAndCalculate()
    }

    /// Fügt mehrere ausdrücklich gewählte Zwischenhäfen gemeinsam hinzu.
    /// Unbekannte Kennungen, Start und Ziel sowie bereits verwendete Häfen werden
    /// ausgelassen. Die Reihenfolge der übrigen Auswahl bleibt erhalten.
    /// Stopps können schon vor vollständiger Start- und Zielauswahl vorbereitet werden;
    /// die Berechnung beginnt erst, wenn `hasCompleteRouteInput` true ist.
    @discardableResult
    func addIntermediateStops(harbourIDs: [String]) -> Int {
        let knownHarbourIDs = Set(HarbourOption.options.map(\.id))
        var unavailableIDs = Set(intermediateStops.map(\.harbourID))
        if !startHarbourID.isEmpty { unavailableIDs.insert(startHarbourID) }
        if !destinationHarbourID.isEmpty { unavailableIDs.insert(destinationHarbourID) }

        var additions: [IntermediateStop] = []
        additions.reserveCapacity(harbourIDs.count)

        for rawID in harbourIDs {
            let harbourID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownHarbourIDs.contains(harbourID),
                  unavailableIDs.insert(harbourID).inserted else {
                continue
            }
            additions.append(IntermediateStop(harbourID: harbourID))
        }

        guard !additions.isEmpty else { return 0 }
        intermediateStops.append(contentsOf: additions)
        return additions.count
    }

    /// Entfernt den Zwischenstopp mit der angegebenen stabilen UUID.
    /// `removeAll(where:)` vermeidet Indexzugriffe auf eine veraltete Liste
    /// und verhindert Abstürze beim Löschen während eines SwiftUI-Abgleichs.
    func removeIntermediateStop(id stopID: IntermediateStop.ID) {
        intermediateStops.removeAll(where: { $0.id == stopID })
    }

    /// Ändert den Hafen des Stopps mit der angegebenen UUID. Es gelten dieselben
    /// Eindeutigkeitsregeln wie in der Auswahl. Auch andere Aufrufer können keine
    /// unbekannten, doppelten oder mit Start und Ziel identischen Wegpunkte einfügen.
    @discardableResult
    func updateIntermediateStop(id stopID: IntermediateStop.ID, to rawHarbourID: String) -> Bool {
        let harbourID = rawHarbourID.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownHarbourIDs = Set(HarbourOption.options.map(\.id))
        let endpointIDs = endpointHarbourIDs

        guard knownHarbourIDs.contains(harbourID),
              !endpointIDs.contains(harbourID),
              !intermediateStops.contains(where: { $0.id != stopID && $0.harbourID == harbourID }),
              let index = intermediateStops.firstIndex(where: { $0.id == stopID }) else {
            return false
        }

        guard intermediateStops[index].harbourID != harbourID else { return true }
        intermediateStops[index].harbourID = harbourID
        return true
    }

    private var endpointHarbourIDs: Set<String> {
        Set([startHarbourID, destinationHarbourID].filter { !$0.isEmpty })
    }

    /// Entfernt nach Änderungen von Start oder Ziel übereinstimmende Zwischenstopps.
    /// Die Zuweisung an `intermediateStops` löst über den Beobachter genau eine Aktualisierung aus.
    @discardableResult
    private func removeIntermediateStopsMatchingEndpoints() -> Bool {
        let endpoints = endpointHarbourIDs
        guard !endpoints.isEmpty else { return false }
        let filtered = intermediateStops.filter { !endpoints.contains($0.harbourID) }
        guard filtered != intermediateStops else { return false }
        intermediateStops = filtered
        return true
    }

    /// Erhält bei jeder Zuweisung eine eindeutige Route aus Katalogeinträgen,
    /// auch bei Assistentenaktionen und künftigen Aufrufern außerhalb der Oberfläche.
    private func sanitizedIntermediateStops(_ candidates: [IntermediateStop]) -> [IntermediateStop] {
        let knownHarbourIDs = Set(HarbourOption.options.map(\.id))
        var unavailable = endpointHarbourIDs

        return candidates.filter { stop in
            let harbourID = stop.harbourID.trimmingCharacters(in: .whitespacesAndNewlines)
            return harbourID == stop.harbourID
                && knownHarbourIDs.contains(harbourID)
                && unavailable.insert(harbourID).inserted
        }
    }

    // MARK: - Routenaufbau (Start → Stopp 1 → Stopp 2 → … → Ziel)

    private func buildHarbourChainAndCalculate() {
        guard hasCompleteRouteInput else {
            clearCalculatedRoute()
            return
        }

        let harbourIDs = [startHarbourID]
            + intermediateStops.map(\.harbourID)
            + [destinationHarbourID]

        // Erstellt gewählte Wegpunkte aus Katalogvorlagen oder ersatzweise Hafendaten.
        // Jeder Punkt behält eine stabile UUID, damit RouteSummary ihn nach dem
        // Einfügen zusätzlicher Fahrwasserpunkte durch RouteExpander wiedererkennt.
        var userWPs: [RouteWaypoint] = []
        for id in harbourIDs {
            if let template = catalog.waypointTemplate(forHarbourID: id) {
                var wp = template.toRouteWaypoint()
                if wp.latitude == nil || wp.longitude == nil {
                    let h = HarbourOption.byID(id)
                    wp.latitude = h.latitude
                    wp.longitude = h.longitude
                }
                userWPs.append(wp)
            } else {
                let h = HarbourOption.byID(id)
                userWPs.append(RouteWaypoint(
                    id: UUID(),
                    name: h.name,
                    latitude: h.latitude,
                    longitude: h.longitude,
                    tidalReferenceStation: h.tideStationName,
                    tidalReferenceStationID: h.tideStationID,
                    highWaterOffsetMinutes: 0,
                    meanTidalRangeMeters: nil,
                    meanHighWaterMeters: nil,
                    lottiefeMeters: nil,
                    chartDepthMeters: SourcedValue(value: h.chartDepth, source: .catalog, sourceNotes: "HarbourOption Fallback"),
                    calculationMode: .meanHighWater,
                    bshWaterLevelCorrectionOverride: nil,
                    manualHighWaterTime: nil,
                    notes: "Hafen (Fallback)",
                    category: "Hafen",
                    island: nil
                ))
            }
        }

        for index in userWPs.indices {
            userWPs[index] = SurveyedDepthCatalog.applying(to: userWPs[index], harbourID: harbourIDs[index])
        }

        // Erstellt vorläufige Streckenabschnitte mit Entfernung 0. Nach dem Einfügen
        // der Fahrwasserpunkte berechnet RouteExpander die tatsächlichen Haversine-Entfernungen.
        let placeholderLegs: [RouteLeg] = zip(userWPs, userWPs.dropFirst()).map { from, to in
            RouteLeg(
                id: UUID(),
                fromWaypointID: from.id,
                toWaypointID: to.id,
                distanceNm: 0,
                courseDegrees: nil,
                speedThroughWaterKnots: speedKnots,
                tidalCurrentKnots: 0
            )
        }

        let basePlan = RoutePlan(
            id: UUID(),
            date: departure,
            routeName: userWPs.map(\.name).joined(separator: " → "),
            plannedStartTime: departure,
            waypoints: userWPs,
            legs: placeholderLegs,
            bshWaterLevelCorrectionMeters: bshWaterLevelCorrection,
            tidalStateLabel: "BSH-Gezeiten am Reisetag"
        )

        // Kennungen der gewählten Wegpunkte für die Zusammenfassung speichern.
        userWaypointIDs = userWPs.map(\.id)

        // Dijkstra-Fahrwasserpunkte einfügen, damit die Berechnung
        // auch flache Wattabschnitte und Engstellen prüft.
        let plan = RouteExpander.expandWithFairwayWaypoints(basePlan)
        routePlan = plan
        for stationID in Set(plan.waypoints.map(\.tidalReferenceStationID)) {
            if confirmedComparisonGaugeIDs[stationID] == nil,
               let comparison = BSHTideStationCatalog.requiredComparisonStation(for: stationID)
                ?? BSHTideStationCatalog.nearestComparisonStation(for: stationID) {
                confirmedComparisonGaugeIDs[stationID] = comparison.id
            }
        }
        invalidateRouteWeatherValidation()
        runCalculation(plan: plan)
    }

    private func clearCalculatedRoute() {
        calculationTask?.cancel()
        passageWindowTask?.cancel()
        calculationTask = nil
        passageWindowTask = nil
        routePlan = nil
        calculationResult = nil
        routeSummary = nil
        userWaypointIDs = []
        isCalculating = false
        calculationError = nil
        passageWindow = nil
        passageWindows = []
        passageWindowMessage = nil
        isSearchingWindow = false
        invalidateRouteWeatherValidation()
    }

    // MARK: - Berechnung

    private func scheduleRecalculation() {
        guard let plan = routePlan else {
            onRouteChanged()
            return
        }

        // Plan mit aktualisierten Parametern neu erstellen.
        var updatedPlan = plan
        updatedPlan.plannedStartTime = departure
        updatedPlan.date = planningDay
        updatedPlan.bshWaterLevelCorrectionMeters = bshWaterLevelCorrection

        // Geschwindigkeiten der Streckenabschnitte aktualisieren.
        for i in updatedPlan.legs.indices {
            updatedPlan.legs[i].speedThroughWaterKnots = speedKnots
        }

        routePlan = updatedPlan
        invalidateRouteWeatherValidation()
        runCalculation(plan: updatedPlan)
    }

    func runCalculation(plan: RoutePlan) {
        calculationTask?.cancel()
        passageWindowTask?.cancel()
        isCalculating = true
        calculationResult = nil
        routeSummary = nil
        calculationError = nil
        passageWindow = nil
        passageWindows = []
        passageWindowMessage = nil
        isSearchingWindow = true
        invalidateRouteWeatherValidation()
        calculationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let solution = await self.passageScanner.solve(
                route: plan, boatSettings: self.boatSettings, tideDataProvider: self.tideDataProvider,
                confirmedComparisonGaugeIDs: self.confirmedComparisonGaugeIDs
            )
            guard !Task.isCancelled else { return }
            self.passageWindows = solution.routeWindows.filter(\.hasUsableDuration)
            self.passageWindow = self.passageWindows.first { $0.contains(plan.plannedStartTime) }
                ?? self.passageWindows.first { $0.start > plan.plannedStartTime }
                ?? self.passageWindows.last
            if !solution.missingWaypointNames.isEmpty {
                self.passageWindowMessage = "Daten fehlen: " + solution.missingWaypointNames
                    .map(SurveyedDepthCatalog.displayName(for:)).joined(separator: ", ")
            } else if solution.hasInvalidLeg {
                self.passageWindowMessage = "Fahrtzeit nicht berechenbar: Geschwindigkeit, Strom oder Strecke prüfen."
            } else if self.passageWindows.isEmpty && !solution.routeWindows.isEmpty {
                self.passageWindowMessage = "Nur einzelne Prüfzeitpunkte erfüllen die Reserve; kein nutzbares Abfahrtsfenster."
            } else if solution.routeWindows.isEmpty {
                self.passageWindowMessage = solution.hasCoverageGaps
                    ? "Gezeitendaten unvollständig. Kein Abfahrtsfenster ableitbar."
                    : solution.bottlenecks.allSatisfy({ $0.departureWindow != nil })
                        ? String(format: "Die Gezeitenfenster der Engstellen überschneiden sich bei %.1f kn nicht. Zwischenstopp oder andere Route prüfen.", self.speedKnots)
                        : String(format: "Mindestens eine Engstelle ist an diesem Tag bei %.1f kn nicht sicher passierbar. Zwischenstopp oder andere Route prüfen.", self.speedKnots)
            } else if solution.hasCoverageGaps {
                self.passageWindowMessage = "Das Fenster gilt für den Abschnitt mit verfügbaren Gezeitendaten."
            }
            self.isSearchingWindow = false
            var selectedPlan = plan
            if let window = self.passageWindow {
                selectedPlan.plannedStartTime = window.recommendedDeparture
                self.isApplyingDeparture = true
                self.departure = window.recommendedDeparture
                self.isApplyingDeparture = false
            }
            self.routePlan = selectedPlan
            await self.calculateSelectedDeparture(selectedPlan)
        }
    }

    @MainActor
    private func calculateSelectedDeparture(_ plan: RoutePlan) async {
        let result = await calculationService.calculate(
            route: plan, boatSettings: boatSettings, tideDataProvider: tideDataProvider,
            confirmedComparisonGaugeIDs: confirmedComparisonGaugeIDs
        )
        guard !Task.isCancelled else { return }
        calculationResult = result
        routeSummary = RouteSummary.build(from: result, userWaypointIDs: userWaypointIDs)
        calculationError = result.messages.isEmpty ? nil : result.messages.joined(separator: "\n")
        isCalculating = false
    }

    func selectDepartureWindow(_ window: PassageWindowScanner.Window) {
        guard passageWindows.contains(window), var plan = routePlan else { return }
        calculationTask?.cancel()
        isApplyingDeparture = true
        departure = window.recommendedDeparture
        isApplyingDeparture = false
        passageWindow = window
        plan.plannedStartTime = departure
        routePlan = plan
        isCalculating = true
        calculationResult = nil
        invalidateRouteWeatherValidation()
        calculationTask = Task { @MainActor [weak self] in await self?.calculateSelectedDeparture(plan) }
    }

    func refreshPassageWindow() {
        guard let plan = routePlan else { return }
        runCalculation(plan: plan)
    }

    func confirmComparisonGauge(localStationID: String, comparisonStationID: String) {
        guard localStationID != comparisonStationID,
              BSHTideStationCatalog.station(id: localStationID) != nil,
              BSHTideStationCatalog.station(id: comparisonStationID)?.hasLocalWaterLevelForecast == true else {
            return
        }
        confirmedComparisonGaugeIDs[localStationID] = comparisonStationID
        if let routePlan {
            runCalculation(plan: routePlan)
        }
    }

    func clearComparisonGauge(localStationID: String) {
        confirmedComparisonGaugeIDs.removeValue(forKey: localStationID)
        if let routePlan {
            runCalculation(plan: routePlan)
        }
    }

    @discardableResult
    func beginRouteWeatherValidation(total: Int) -> UUID {
        let id = UUID()
        routeWeatherValidationID = id
        routeWeatherValidationState = .loading(completed: 0, total: total)
        weatherStatus = .incomplete
        return id
    }

    func updateRouteWeatherProgress(_ progress: RouteWeatherProgress, id: UUID) {
        guard routeWeatherValidationID == id else { return }
        routeWeatherValidationState = .loading(completed: progress.completed, total: progress.total)
    }

    func finishRouteWeatherValidation(_ batch: RouteWeatherBatch, id: UUID) {
        guard routeWeatherValidationID == id else { return }
        let status = Self.assessRouteWeather(batch: batch, calculationResult: calculationResult)
        guard status != .incomplete else {
            weatherStatus = .incomplete
            routeWeatherValidationState = .unavailable(
                message: MarineWeatherError.incompleteRouteWeather.localizedDescription
            )
            return
        }
        weatherStatus = status
        routeWeatherValidationState = .ready(status: status, batch: batch)
    }

    func failRouteWeatherValidation(_ message: String, id: UUID) {
        guard routeWeatherValidationID == id else { return }
        weatherStatus = .incomplete
        routeWeatherValidationState = .unavailable(message: message)
    }

    func invalidateRouteWeatherValidation() {
        routeWeatherValidationID = nil
        routeWeatherValidationState = .idle
        weatherStatus = .incomplete
    }

}
