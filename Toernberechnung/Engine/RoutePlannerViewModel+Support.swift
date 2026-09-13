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
