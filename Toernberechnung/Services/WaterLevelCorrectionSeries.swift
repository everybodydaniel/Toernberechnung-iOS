import Foundation

/// Zeitlich begrenzte wetterbedingte Korrekturen. Außerhalb der verfügbaren Werte
/// liefert die Berechnung ein ausdrücklich vorläufiges astronomisches Szenario ohne Windstau.
struct WaterLevelCorrectionSeries: Equatable, Sendable {

    struct Sample: Equatable, Sendable {
        let time: Date
        /// Vom Planer verwendete Korrektur. Modellwerte werden höchstens mit 0 angesetzt,
        /// wenn keine untere Vertrauensgrenze für jeden Zeitpunkt vorliegt.
        let meters: Double
        var quality: WaterLevelCorrectionQuality? = nil
    }

    /// Nach Zeit aufsteigend sortiert. Bei leerer Liste gilt nur `fallback`.
    let samples: [Sample]
    let fallback: WaterLevelCorrectionResolution

    static func constant(_ resolution: WaterLevelCorrectionResolution) -> Self {
        WaterLevelCorrectionSeries(samples: [], fallback: resolution)
    }

    var coveredSpan: ClosedRange<Date>? {
        guard let first = samples.first, let last = samples.last, first.time <= last.time else {
            return nil
        }
        return first.time ... last.time
    }

    func resolution(at time: Date) -> WaterLevelCorrectionResolution {
        guard samples.count >= 2 else { return fallback }
        func outside() -> WaterLevelCorrectionResolution {
            .unavailable(stationID: fallback.localStationID, quality: .outsideForecastHorizon,
                         detail: "Nur astronomisch: Für diese Ankunft fehlt eine zeitlich passende Wasserstandsprognose.")
        }
        if let exact = samples.first(where: { $0.time == time }) {
            return resolved(exact.meters, quality: exact.quality ?? fallback.quality)
        }
        guard let upper = samples.firstIndex(where: { $0.time > time }), upper > 0 else { return outside() }
        let left = samples[upper - 1], right = samples[upper]
        let duration = right.time.timeIntervalSince(left.time)
        guard duration > 0, duration <= 30 * 60 else { return outside() }
        let fraction = time.timeIntervalSince(left.time) / duration
        let quality = PassageWindowSolver.worstQuality(left.quality ?? fallback.quality, right.quality ?? fallback.quality)
        return resolved(left.meters + (right.meters - left.meters) * fraction, quality: quality)
    }

    private func resolved(_ meters: Double, quality: WaterLevelCorrectionQuality) -> WaterLevelCorrectionResolution {
        WaterLevelCorrectionResolution(
            meters: meters, quality: quality, localStationID: fallback.localStationID,
            sourceStationID: fallback.sourceStationID, sourceStationName: fallback.sourceStationName,
            issuedAt: fallback.issuedAt,
            detail: (quality == fallback.quality ? fallback.detail : PassageWindowSolver.detail(for: quality)) ?? fallback.detail
        )
    }

}

// MARK: - Korrektur eines Kurvenpunkts

extension WaterLevelCurvePoint {
    /// Modellvorhersage minus astronomische Vorhersage in Metern.
    ///
    /// Beide Werte beziehen sich bereits auf Kartennull. Der gemeinsame Bezug
    /// fällt in der Differenz weg, ebenso wie bei den Rohwerten eines Gezeitenereignisses
    /// in Zentimetern über Pegelnull.
    var centralCorrectionMeters: Double? {
        guard let forecastMetersSkn, let astroMetersSkn else { return nil }
        return forecastMetersSkn - astroMetersSkn
    }
}

// MARK: - Zeitreihe aus der BSH-Vorhersage erstellen

extension BSHWaterLevelForecastService {

    /// Erstellt eine zeitabhängige Korrektur für einen Pegel.
    ///
    /// - Parameters:
    ///   - anchorHighWaterTime: Wählt den Hochwasserzyklus des Pegels und dessen
    ///     Unsicherheitsbereich. Unterscheidet sich von der Auswertungszeit:
    ///     Diese ist die Ankunft am Wegpunkt, dessen Hochwasser einen Versatz
    ///     gegenüber dem Pegel haben kann.
    ///   - span: Zeitbereich für die Auswertung. Wird um eine Stunde erweitert,
    ///     damit an den Grenzen umgebende Werte für die Interpolation vorliegen.
    func correctionSeries(
        for localStationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        comparisonStationID: String? = nil,
        force: Bool = false
    ) async -> WaterLevelCorrectionSeries {
        guard let local = BSHTideStationCatalog.station(id: localStationID) else {
            return .constant(.unavailable(stationID: localStationID, detail: "Unbekannter BSH-Referenzpegel."))
        }
        let effectiveComparisonID = comparisonStationID
            ?? BSHTideStationCatalog.requiredComparisonStation(for: localStationID)?.id
        let sourceStation: BSHTideStation?
        if let effectiveComparisonID,
                  let comp = BSHTideStationCatalog.station(id: effectiveComparisonID),
                  comp.hasLocalWaterLevelForecast {
            sourceStation = comp
        } else if local.hasLocalWaterLevelForecast {
            sourceStation = local
        } else {
            sourceStation = nil
        }
        guard let source = sourceStation, source.hasLocalWaterLevelForecast else {
            return .constant(.unavailable(stationID: localStationID,
                detail: "Keine BSH-Wasserstandsprognose verfügbar."))
        }
        guard let forecast = try? await fetch(station: source, force: force) else {
            return .constant(.unavailable(stationID: localStationID, detail: "Wasserstandsprognose nicht abrufbar."))
        }
        let issued = forecast.curveIssuedAt ?? forecast.issuedAt
        guard Date().timeIntervalSince(issued) <= 8 * 3_600 else {
            return .constant(.unavailable(stationID: localStationID, quality: .stale,
                detail: "Wasserstandsprognose veraltet. Nur astronomische Planung."))
        }
        let quality: WaterLevelCorrectionQuality = source.id == localStationID ? .modelForecast : .confirmedComparison
        let padded = span.lowerBound.addingTimeInterval(-3_600) ... span.upperBound.addingTimeInterval(3_600)
        let samples = forecast.curve.filter { padded.contains($0.time) }.compactMap { point -> WaterLevelCorrectionSeries.Sample? in
            guard let central = point.centralCorrectionMeters, central.isFinite else { return nil }
            // Die automatische Kurve ist eine mittlere Modellschätzung ohne untere
            // Vertrauensgrenze für jeden Zeitpunkt. Positiver Windstau darf daher kein
            // zusätzliches Wasser unter Kiel ergeben. Negative Abweichungen bleiben erhalten.
            return .init(time: point.time, meters: min(central, 0), quality: quality)
        }.sorted { $0.time < $1.time }
        let fallback = WaterLevelCorrectionResolution(
            meters: 0, quality: .outsideForecastHorizon, localStationID: localStationID,
            sourceStationID: source.id, sourceStationName: source.name, issuedAt: issued,
            detail: "Vorläufige Modellkurve: negativer Windstau wird berücksichtigt; positiver Windstau wird ohne gesicherte Untergrenze nicht gutgeschrieben."
        )
        return WaterLevelCorrectionSeries(samples: samples, fallback: fallback)
    }
}
