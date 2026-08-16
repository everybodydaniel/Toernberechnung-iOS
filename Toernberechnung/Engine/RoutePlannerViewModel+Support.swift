import Foundation

// MARK: - Weather assessment and display formatting
//
// Extracted from `RoutePlannerViewModel` to keep that type within the
// 450-line limit. Everything here is either a pure static helper or a derived
// display string with no state of its own, so the move is behaviour-neutral;
// `WeatherKitMigrationTests` covers the weather thresholds.

extension RoutePlannerViewModel {

    static func assessRouteWeather(
        batch: RouteWeatherBatch,
        calculationResult: RouteCalculationResult?
    ) -> WeatherStatus {
        guard let calculationResult,
              calculationResult.waypointResults.count == batch.areaKeysByWaypoint.count else {
            return .incomplete
        }

        var result: WeatherStatus = .go
        for (index, waypointResult) in calculationResult.waypointResults.enumerated() {
            let area = batch.areaKeysByWaypoint[index]
            guard let snapshot = batch.snapshotsByArea[area],
                  let hour = snapshot.hourly.min(by: {
                      abs($0.date.timeIntervalSince(waypointResult.arrivalTime))
                          < abs($1.date.timeIntervalSince(waypointResult.arrivalTime))
                  }),
                  abs(hour.date.timeIntervalSince(waypointResult.arrivalTime)) <= 90 * 60 else {
                return .incomplete
            }

            let status = assessWeatherStatus(
                for: MarineWeatherAssessment(
                    windKnots: hour.wind.speedKnots,
                    gustKnots: hour.wind.effectiveGustKnots,
                    visibilityKM: hour.visibilityKM,
                    precipitationChance: hour.precipitationChance,
                    precipitationMM: hour.precipitationMM
                )
            )
            if status == .noGo { return .noGo }
            if status == .warning { result = .warning }
        }
        return result
    }

    static func assessWeatherStatus(
        for report: MarineWeatherReport?,
        departure: Date
    ) -> WeatherStatus {
        guard let report else { return .incomplete }
        return assessWeatherStatus(for: report.weatherForRiskAssessment(at: departure))
    }

    static func assessWeatherStatus(for assessment: MarineWeatherAssessment) -> WeatherStatus {
        if assessment.windKnots >= 28 || assessment.gustKnots >= 34 || assessment.visibilityKM < 1 {
            return .noGo
        }

        if assessment.windKnots >= 20
            || assessment.gustKnots >= 27
            || assessment.visibilityKM < 5
            || assessment.precipitationChance >= 60
            || assessment.precipitationMM >= 3 {
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
}
