import Foundation
import SwiftUI

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
        return Self.timeFormatter.string(from: lastWP.arrivalTime)
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

    // MARK: - Init

    init(
        catalog: WaddenSeaCatalog? = nil,
        calculationService: RouteCalculationService = RouteCalculationService(),
        tideDataProvider: TideDataProvider = BSHTideDataProvider()
    ) {
        self.catalog = catalog ?? WaddenSeaCatalog.loadBundled()
        self.calculationService = calculationService
        self.tideDataProvider = tideDataProvider
        self.passageScanner = PassageWindowScanner(calculationService: calculationService)
    }

    // MARK: - Route Resolution

    /// Called when start or destination changes. Resolves route templates and triggers calculation.
    func onRouteChanged() {
        // Find matching route templates from the catalog.
        let templates = catalog.routeTemplates(
            fromHarbourID: startHarbourID,
            toHarbourID: destinationHarbourID
        )

        availableTemplates = templates

        if templates.count == 1 {
            // Exactly one match → auto-select.
            selectedTemplateID = templates[0].id
            showTemplateSelector = false
            buildAndCalculate(template: templates[0])
        } else if templates.count > 1 {
            // Multiple matches → let user choose.
            selectedTemplateID = templates[0].id
            showTemplateSelector = true
            buildAndCalculate(template: templates[0])
        } else {
            // No template → direct route fallback.
            selectedTemplateID = nil
            showTemplateSelector = false
            buildDirectRouteAndCalculate()
        }
    }

    /// User selected a specific route template from the picker.
    func selectTemplate(_ templateID: UUID) {
        selectedTemplateID = templateID
        if let template = availableTemplates.first(where: { $0.id == templateID }) {
            buildAndCalculate(template: template)
        }
    }

    // MARK: - Route Building

    private func buildAndCalculate(template: RouteTemplate) {
        guard let plan = catalog.buildRoutePlan(
            from: template,
            date: departure,
            startTime: departure,
            speedKnots: speedKnots,
            bshCorrectionMeters: bshWaterLevelCorrection
        ) else {
            calculationError = "Route konnte nicht aus dem Template aufgebaut werden."
            return
        }

        routePlan = plan
        runCalculation(plan: plan)
    }

    private func buildDirectRouteAndCalculate() {
        let start = HarbourOption.byID(startHarbourID)
        let dest = HarbourOption.byID(destinationHarbourID)
        let distance = SeaRoutePlanner.distanceNM(from: start, to: dest)

        let plan = catalog.buildDirectRoute(
            startHarbourID: startHarbourID,
            destinationHarbourID: destinationHarbourID,
            date: departure,
            startTime: departure,
            distanceNm: max(distance, 0.1),
            speedKnots: speedKnots,
            bshCorrectionMeters: bshWaterLevelCorrection
        )

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
        let draft = Double(UserDefaults.standard.string(forKey: "boatDraft") ?? "1.1") ?? 1.1
        let margin = Double(UserDefaults.standard.string(forKey: "safetyMargin") ?? "0.0") ?? 0.0
        return BoatSettings(draftMeters: draft, safetyMarginMeters: margin)
    }

    // MARK: - Formatting

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func durationText(_ hours: Double) -> String {
        let totalMinutes = max(Int((hours * 60).rounded()), 0)
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    func formatMeters(_ value: Double?) -> String {
        guard let v = value else { return "–" }
        return String(format: "%.2f m", v)
    }
}
