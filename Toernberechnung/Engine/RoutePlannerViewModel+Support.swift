import Foundation

// MARK: - Wetterbewertung und Anzeigeformate

extension RoutePlannerViewModel {

    static func assessRouteWeather(
        batch: RouteWeatherBatch,
        calculationResult: RouteCalculationResult?
    ) -> WeatherStatus {
        guard let calculationResult,
              calculationResult.waypointResults.count == batch.areaKeysByWaypoint.count else {
            return .incomplete
        }

        var assessments: [MarineWeatherAssessment?] = []
        for (index, waypointResult) in calculationResult.waypointResults.enumerated() {
            let area = batch.areaKeysByWaypoint[index]
            let hour = batch.snapshotsByArea[area]?.hourly.min(by: {
                abs($0.date.timeIntervalSince(waypointResult.arrivalTime))
                    < abs($1.date.timeIntervalSince(waypointResult.arrivalTime))
            })
            guard let hour,
                  abs(hour.date.timeIntervalSince(waypointResult.arrivalTime)) <= 90 * 60 else {
                assessments.append(nil)
                continue
            }
            assessments.append(
                MarineWeatherAssessment(
                    windKnots: hour.wind.speedKnots,
                    gustKnots: hour.wind.effectiveGustKnots,
                    visibilityKM: hour.visibilityKM,
                    precipitationChance: hour.precipitationChance,
                    precipitationMM: hour.precipitationMM
                )
            )
        }
        return assessRouteWeather(assessments)
    }

    /// Fasst alle verfügbaren Wetterwerte zusammen. Ein fehlender weiterer Messwert
    /// darf eine bekannte Sturm- oder Sichtgefahr nicht verdecken.
    static func assessRouteWeather(_ assessments: [MarineWeatherAssessment?]) -> WeatherStatus {
        guard !assessments.isEmpty else { return .incomplete }
        var result: WeatherStatus = .go
        var hasMissingSample = false
        for assessment in assessments {
            guard let assessment else {
                hasMissingSample = true
                continue
            }
            let status = assessWeatherStatus(for: assessment)
            if status == .noGo { return .noGo }
            if status == .warning { result = .warning }
        }
        if result == .warning { return .warning }
        return hasMissingSample ? .incomplete : .go
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

    // MARK: - Bootseinstellungen

    static func parseDecimalString(_ raw: String?, default fallback: Double) -> Double {
        guard let raw, !raw.isEmpty else { return fallback }
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? fallback
    }

    static func loadSpeedFromSettings() -> Double {
        let speed = parseDecimalString(UserDefaults.standard.string(forKey: "boatSpeed"), default: 6.0)
        return max(0.5, min(speed, 50.0))
    }

    var boatSettings: BoatSettings {
        let draft = Self.parseDecimalString(UserDefaults.standard.string(forKey: "boatDraft"), default: 1.1)
        let margin = Self.parseDecimalString(UserDefaults.standard.string(forKey: "safetyMargin"), default: 0.0)
        return BoatSettings(draftMeters: draft, safetyMarginMeters: margin)
    }
}
