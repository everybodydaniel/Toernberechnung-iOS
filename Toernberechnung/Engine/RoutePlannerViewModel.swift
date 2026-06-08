import Foundation
import SwiftUI

// MARK: - Intermediate Stop Model
//
// A user-added Zwischenstopp. Has a stable `id` so SwiftUI's diffing
// stays safe even when stops are added, reordered, or deleted in quick
// succession — using the raw harbour id (which the user can change)
// would let SwiftUI reference a stale slot mid-update and crash with
// "Index out of range".

struct IntermediateStop: Identifiable, Equatable {
    let id: UUID
    var harbourID: String

    init(id: UUID = UUID(), harbourID: String) {
        self.id = id
        self.harbourID = harbourID
    }
}

// MARK: - Route Planner View Model

/// Observable view model for the Map tab's multi-waypoint route calculation.
///
/// Replaces the former inline `ManualPassageCalculator` usage in `ContentView+MapTab`.
/// When the user selects start, destination, and departure time, this view model
/// automatically resolves a multi-waypoint route and runs `RouteCalculationService`.
@Observable
final class RoutePlannerViewModel {
    // MARK: - Input State

    var startHarbourID: String = HarbourOption.options[0].id {
        didSet { if oldValue != startHarbourID { onRouteChanged() } }
    }
    var destinationHarbourID: String = HarbourOption.options[3].id {
        didSet { if oldValue != destinationHarbourID { onRouteChanged() } }
    }
    /// Ordered list of intermediate stops (Zwischenstopps). Each stop has a
    /// stable UUID so SwiftUI can safely diff the list — using the raw
    /// harbour id as the SwiftUI id is unsafe because two stops MAY share
    /// the same harbour id, and SwiftUI's index-based diff can produce
    /// "Index out of range" crashes when an item is deleted mid-update.
    var intermediateStops: [IntermediateStop] = [] {
        didSet { if oldValue != intermediateStops { onRouteChanged() } }
    }
    var departure: Date = Date() {
        didSet { scheduleRecalculation() }
    }
    var speedKnots: Double = 6.0 {
        didSet { scheduleRecalculation() }
    }
    var bshWaterLevelCorrection: Double = 0.3 {
        didSet { scheduleRecalculation() }
    }

    // MARK: - Route Template Selection

    var availableTemplates: [RouteTemplate] = []
    var selectedTemplateID: UUID?
    var showTemplateSelector: Bool = false

    // MARK: - Calculation State

    var routePlan: RoutePlan?
    var calculationResult: RouteCalculationResult?
    /// Leg-based summary suitable for the UI (only user-selected harbours).
    var routeSummary: RouteSummary?
    /// IDs of the user-selected waypoints inside the expanded `routePlan`.
    /// Used by the summary builder to skip Dijkstra fairway WPs.
    private(set) var userWaypointIDs: [UUID] = []
    var isCalculating: Bool = false
    var calculationError: String?

    // MARK: - Passage Window

    var passageWindow: PassageWindowScanner.Window?
    var isSearchingWindow: Bool = false
    var passageWindowMessage: String?

    // MARK: - Weather Status

    var weatherStatus: WeatherStatus = .incomplete

    // MARK: - Computed Properties

    var startHarbour: HarbourOption { HarbourOption.byID(startHarbourID) }
    var destinationHarbour: HarbourOption { HarbourOption.byID(destinationHarbourID) }

    var routeTitle: String {
        "\(startHarbour.name) → \(destinationHarbour.name)"
    }

    var isMultiWaypoint: Bool {
        (routePlan?.waypoints.count ?? 0) > 2
    }

    var combinedStatus: CombinedRouteStatus? {
        guard let result = calculationResult else { return nil }
        return CombinedRouteStatus.combine(tidal: result.tidalStatus, weather: weatherStatus)
    }

    var statusText: String {
        guard let status = combinedStatus else { return "Berechnung läuft…" }
        switch status {
        case .go: return "Befahrbar"
        case .warning: return "Befahrbar mit Einschränkungen"
        case .noGo: return "Nicht befahrbar"
        case .incomplete: return "Unvollständig"
        }
    }

    var isPassable: Bool {
        combinedStatus == .go || combinedStatus == .warning
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

    // MARK: - Dependencies

    private let catalog: WaddenSeaCatalog
    private let calculationService: RouteCalculationService
    private let tideDataProvider: TideDataProvider
    private let passageScanner: PassageWindowScanner
    private var calculationTask: Task<Void, Never>?
    private var passageWindowTask: Task<Void, Never>?
    private var bshWaterLevelTask: Task<Void, Never>?

    /// Source of the current `bshWaterLevelCorrection` value.
    var bshWaterLevelSource: ValueSource = .manual

    // MARK: - Init

    init(
        catalog: WaddenSeaCatalog? = nil,
        calculationService: RouteCalculationService = RouteCalculationService(),
        tideDataProvider: TideDataProvider = BSHTideDataProvider()
    ) {
        self.catalog = catalog ?? WaddenSeaCatalog.loadBundled()
        self.calculationService = calculationService
        self.tideDataProvider = tideDataProvider
        self.passageScanner = PassageWindowScanner()
    }

    // MARK: - Route Resolution

    /// Called when start / destination / intermediate stops change.
    func onRouteChanged() {
        refreshBSHWaterLevelInBackground()

        availableTemplates = []
        selectedTemplateID = nil
        showTemplateSelector = false

        buildHarbourChainAndCalculate()
    }

    /// Legacy template selector hook (no longer auto-suggests templates —
    /// kept so the existing UI button compiles).
    func selectTemplate(_ templateID: UUID) {
        // No-op: we now always build from the user's start / stops / destination.
    }

    /// Add an intermediate stop. Picks the first harbour that is not yet
    /// part of the chain so the user lands on a meaningful default.
    func addIntermediateStop() {
        let used = Set([startHarbourID, destinationHarbourID]
                       + intermediateStops.map(\.harbourID))
        guard let candidate = HarbourOption.options
            .first(where: { !used.contains($0.id) })
        else { return }
        intermediateStops.append(IntermediateStop(harbourID: candidate.id))
    }

    /// Remove the intermediate stop with the given stable UUID. Uses
    /// `removeAll(where:)` so no index is ever read against a stale list —
    /// fixes the "Index out of range" crash that occurred when the trash
    /// button was tapped mid-SwiftUI-diff.
    func removeIntermediateStop(id stopID: IntermediateStop.ID) {
        intermediateStops.removeAll(where: { $0.id == stopID })
    }

    /// Update the harbour for the stop with the given UUID.
    func updateIntermediateStop(id stopID: IntermediateStop.ID, to harbourID: String) {
        guard let idx = intermediateStops.firstIndex(where: { $0.id == stopID })
        else { return }
        intermediateStops[idx].harbourID = harbourID
    }

    // MARK: - Route Building (Start → Stop 1 → Stop 2 → … → Destination)

    private func buildHarbourChainAndCalculate() {
        let harbourIDs = [startHarbourID]
            + intermediateStops.map(\.harbourID)
            + [destinationHarbourID]

        // Build user waypoints from the catalog templates (or harbour
        // fallback). Each user WP keeps a stable UUID so the RouteSummary
        // builder can identify them after RouteExpander injects fairway WPs.
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

        // Build placeholder legs (distance 0) — RouteExpander will re-emit
        // the legs with real Haversine distances after inserting fairway WPs.
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
            tidalStateLabel: "Mitteltide"
        )

        // Remember which IDs are user-selected for the RouteSummary builder.
        userWaypointIDs = userWPs.map(\.id)

        // Inject Dijkstra fairway WPs so the engine sees the actual
        // shallow Watt-segments (bottlenecks).
        let plan = RouteExpander.expandWithFairwayWaypoints(basePlan)
        routePlan = plan
        runCalculation(plan: plan)
    }

    // MARK: - Calculation

    private func scheduleRecalculation() {
        guard let plan = routePlan else {
            onRouteChanged()
            return
        }

        // Rebuild the plan with updated parameters.
        var updatedPlan = plan
        updatedPlan.plannedStartTime = departure
        updatedPlan.bshWaterLevelCorrectionMeters = bshWaterLevelCorrection

        // Update leg speeds.
        for i in updatedPlan.legs.indices {
            updatedPlan.legs[i].speedThroughWaterKnots = speedKnots
        }

        routePlan = updatedPlan
        runCalculation(plan: updatedPlan)
    }

    func runCalculation(plan: RoutePlan) {
        calculationTask?.cancel()
        passageWindowTask?.cancel()
        isCalculating = true
        calculationError = nil
        passageWindow = nil
        passageWindowMessage = nil
        isSearchingWindow = true

        calculationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let boatSettings = self.boatSettings

            let result = await self.calculationService.calculate(
                route: plan,
                boatSettings: boatSettings,
                tideDataProvider: self.tideDataProvider
            )

            guard !Task.isCancelled else { return }

            self.calculationResult = result
            self.routeSummary = RouteSummary.build(
                from: result,
                userWaypointIDs: self.userWaypointIDs
            )
            self.isCalculating = false

            if !result.messages.isEmpty {
                self.calculationError = result.messages.joined(separator: "\n")
            }

            if result.tidalStatus == .incomplete {
                self.isSearchingWindow = false
                self.passageWindowMessage = "Passagefenster erst mit vollständigen Gezeitendaten verfügbar."
            } else {
                self.startPassageWindowSearch(for: plan)
            }
        }
    }

    /// Search for safe passage windows for the current route.
    func searchPassageWindow() {
        refreshPassageWindow()
    }

    /// Refresh the safe passage window for the current route.
    func refreshPassageWindow() {
        guard let plan = routePlan else {
            passageWindow = nil
            passageWindowMessage = "Keine Route für die Fenstersuche verfügbar."
            isSearchingWindow = false
            return
        }

        startPassageWindowSearch(for: plan)
    }

    private func startPassageWindowSearch(for plan: RoutePlan) {
        passageWindowTask?.cancel()
        isSearchingWindow = true
        passageWindow = nil
        passageWindowMessage = nil

        passageWindowTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let window = await self.passageScanner.findSafeWindow(
                route: plan,
                boatSettings: self.boatSettings,
                tideDataProvider: self.tideDataProvider
            )

            guard !Task.isCancelled else { return }
            self.passageWindow = window
            self.passageWindowMessage = window == nil
                ? "Kein sicheres Abfahrtsfenster im Suchbereich gefunden."
                : nil
            self.isSearchingWindow = false
        }
    }

    /// Update weather status from the weather service assessment.
    func updateWeatherStatus(_ status: WeatherStatus) {
        weatherStatus = status
        // Recalculate combined status display — no recalculation needed,
        // just update the combined status in the existing result.
    }

    static func assessWeatherStatus(for reading: WeatherReading?) -> WeatherStatus {
        guard let reading else { return .incomplete }

        let current = reading.current
        let gustKnots = current.windGustKnots ?? current.windKnots
        let visibilityKM = current.visibilityKM ?? 99

        if current.windKnots >= 28 || gustKnots >= 34 || visibilityKM < 1 {
            return .noGo
        }

        if current.windKnots >= 20
            || gustKnots >= 27
            || visibilityKM < 5
            || current.precipitationChance >= 60
            || current.precipitationMM >= 3 {
            return .warning
        }

        return .go
    }

    func planningDepthValue(for waypointID: UUID) -> Double? {
        guard let waypoint = routePlan?.waypoints.first(where: { $0.id == waypointID }) else {
            return nil
        }

        switch waypoint.calculationMode {
        case .meanHighWater:
            return waypoint.chartDepthMeters?.value
        case .lottiefe:
            return waypoint.lottiefeMeters?.value
        }
    }

    func planningDepthSourceText(for waypointID: UUID) -> String {
        guard let waypoint = routePlan?.waypoints.first(where: { $0.id == waypointID }) else {
            return "Unbekannt"
        }

        let source: ValueSource?
        switch waypoint.calculationMode {
        case .meanHighWater:
            source = waypoint.chartDepthMeters?.source
        case .lottiefe:
            source = waypoint.lottiefeMeters?.source
        }

        return source?.displayName ?? "Fehlt"
    }

    func updatePlanningDepth(for waypointID: UUID, value: Double) {
        guard var plan = routePlan,
              let index = plan.waypoints.firstIndex(where: { $0.id == waypointID }) else {
            return
        }

        let currentValue: Double?
        switch plan.waypoints[index].calculationMode {
        case .meanHighWater:
            currentValue = plan.waypoints[index].chartDepthMeters?.value
        case .lottiefe:
            currentValue = plan.waypoints[index].lottiefeMeters?.value
        }

        if let currentValue, abs(currentValue - value) < 0.0001 {
            return
        }

        let sourcedValue = SourcedValue(
            value: value,
            source: ValueSource.manual,
            sourceNotes: "Manuelle Peilplan-Eingabe"
        )

        switch plan.waypoints[index].calculationMode {
        case .meanHighWater:
            plan.waypoints[index].chartDepthMeters = sourcedValue
        case .lottiefe:
            plan.waypoints[index].lottiefeMeters = sourcedValue
        }

        routePlan = plan
        runCalculation(plan: plan)
    }

    // MARK: - Boat Settings

    var boatSettings: BoatSettings {
        // German keyboards type "0,5"; Double(_:) only parses "0.5".
        // Accept either notation defensively so a comma never silently
        // resets the value to 0 / default.
        func parseDouble(_ raw: String?, default fallback: Double) -> Double {
            guard let raw, !raw.isEmpty else { return fallback }
            let normalized = raw.replacingOccurrences(of: ",", with: ".")
            return Double(normalized) ?? fallback
        }
        let draft = parseDouble(UserDefaults.standard.string(forKey: "boatDraft"), default: 1.1)
        let margin = parseDouble(UserDefaults.standard.string(forKey: "safetyMargin"), default: 0.0)
        return BoatSettings(draftMeters: draft, safetyMarginMeters: margin)
    }

    // MARK: - BSH Wasserstand live refresh

    /// Refresh `bshWaterLevelCorrection` from the live BSH Wasserstand service.
    /// Falls back silently if the network call fails — the existing value
    /// (manual or last-known) stays in effect.
    func refreshBSHWaterLevelInBackground() {
        bshWaterLevelTask?.cancel()
        let harbourID = destinationHarbourID
        bshWaterLevelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let gauge = BSHGauge.defaultGauge(forHarbourID: harbourID)
            let value = await BSHWaterLevelService.shared.deviation(
                forGaugeID: gauge.rawValue,
                at: self.departure
            )
            guard !Task.isCancelled else { return }
            if let value, self.bshWaterLevelSource != .manual {
                self.bshWaterLevelCorrection = value
                self.bshWaterLevelSource = .bsh
            } else if let value {
                // user has a manual value; record the fetched value for diagnostics only
                self.bshWaterLevelSource = .manual
                _ = value
            }
        }
    }

    // MARK: - Formatting

    /// Kept as a back-compat alias so the existing UI continues to compile;
    /// new code should use `AppDateFormatters.hourMinute` directly.
    static var timeFormatter: DateFormatter { AppDateFormatters.hourMinute }

    func durationText(_ hours: Double) -> String {
        AppDateFormatters.duration(hours: hours)
    }

    func formatMeters(_ value: Double?) -> String {
        guard let v = value else { return "–" }
        return String(format: "%.2f m", v)
    }
}
