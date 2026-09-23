import Foundation

/// Time-bounded meteorological corrections. Outside sampled coverage the
/// calculation returns an explicitly provisional astronomical scenario (zero surge).
struct WaterLevelCorrectionSeries: Equatable, Sendable {

    struct Sample: Equatable, Sendable {
        let time: Date
        /// Correction applied by the planner. Model samples are capped at zero
        /// when no pointwise lower confidence bound is available.
        let meters: Double
        var quality: WaterLevelCorrectionQuality? = nil
    }

    /// Ascending by time. May be empty, in which case only `fallback` applies.
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

// MARK: - Curve point correction

extension WaterLevelCurvePoint {
    /// Model forecast minus astronomical prediction, in metres.
    ///
    /// Both values are already referenced to chart datum, so the datum cancels
    /// in the difference, just as it does for a tidal event's raw forecast
    /// and astronomical centimetre values above gauge zero.
    var centralCorrectionMeters: Double? {
        guard let forecastMetersSkn, let astroMetersSkn else { return nil }
        return forecastMetersSkn - astroMetersSkn
    }
}

// MARK: - Building a series from the BSH forecast

extension BSHWaterLevelForecastService {

    /// Builds a time-dependent correction for one gauge.
    ///
    /// - Parameters:
    ///   - anchorHighWaterTime: selects the **gauge's** high-water cycle and
    ///     therefore the uncertainty band that applies. This is deliberately a
    ///     different quantity from the sampling time: it is gauge-local,
    ///     whereas the sampling time is the arrival time at a waypoint that may
    ///     sit an offset away from the gauge.
    ///   - span: the time range the caller will sample. Padded by an hour so
    ///     interpolation still has bracketing points at the edges.
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
            // The automated curve is a central model estimate without a pointwise
            // lower confidence bound. Positive setup must therefore not create
            // additional calculated clearance. Negative setdown is retained.
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
