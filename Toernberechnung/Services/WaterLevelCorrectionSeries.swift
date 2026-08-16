import Foundation

// MARK: - Time-dependent water level correction

/// The BSH meteorological correction (Windstau) sampled over time instead of
/// pinned to the high-water peak.
///
/// The Excel reference tool has a single global cell `$AD$13` for the whole
/// Törn. The app can do better: the BSH publishes a full forecast curve, so a
/// waypoint passed four hours after high water gets the surge that is actually
/// predicted for that moment rather than the peak value.
///
/// A `fallback` — exactly the previous peak scalar — is always carried. When no
/// curve covers a time, the series returns it unchanged, so behaviour degrades
/// to the old one instead of failing.
///
/// **Invariant:** the correction *quality* depends only on the source gauge,
/// never on the sample time; `resolution(at:).quality == fallback.quality` for
/// every input. That is what keeps `allowsGreenStatus` and every downgrade rule
/// in `RouteCalculationService.applyCorrectionQuality` intact — a curve may
/// change the number of metres, never how much the number can be trusted.
struct WaterLevelCorrectionSeries: Equatable, Sendable {

    struct Sample: Equatable, Sendable {
        let time: Date
        /// Already conservative: the forecast uncertainty has been subtracted.
        let meters: Double
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

    /// Linear interpolation between the two bracketing samples.
    /// Outside the covered span, or with fewer than two samples, the peak
    /// scalar is returned unchanged.
    func resolution(at time: Date) -> WaterLevelCorrectionResolution {
        guard let meters = interpolatedMeters(at: time) else { return fallback }
        return WaterLevelCorrectionResolution(
            meters: meters,
            quality: fallback.quality,
            localStationID: fallback.localStationID,
            sourceStationID: fallback.sourceStationID,
            sourceStationName: fallback.sourceStationName,
            issuedAt: fallback.issuedAt,
            detail: fallback.detail
        )
    }

    private func interpolatedMeters(at time: Date) -> Double? {
        guard samples.count >= 2, let span = coveredSpan, span.contains(time) else { return nil }

        // The curve is short (a few dozen points per waypoint), so a linear
        // scan is cheaper than the bookkeeping of a binary search.
        for (earlier, later) in zip(samples, samples.dropFirst()) where time <= later.time {
            let total = later.time.timeIntervalSince(earlier.time)
            guard total > 0 else { return earlier.meters }
            let fraction = time.timeIntervalSince(earlier.time) / total
            return earlier.meters + (later.meters - earlier.meters) * fraction
        }
        return samples.last?.meters
    }
}

// MARK: - Curve point correction

extension WaterLevelCurvePoint {
    /// Model forecast minus astronomical prediction, in metres.
    ///
    /// Both values are already referenced to chart datum, so the datum cancels
    /// in the difference — this is the same quantity that
    /// `WaterLevelEvent.centralCorrectionMeters` derives from the raw
    /// centimetre values above gauge zero.
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
        let peak = await correction(
            for: localStationID,
            at: anchorHighWaterTime,
            comparisonStationID: comparisonStationID,
            force: force
        )
        // An unusable peak means there is no trustworthy source at all; a curve
        // from the same source would not be any better.
        guard peak.quality.isUsable, let sourceID = peak.sourceStationID,
              let source = BSHTideStationCatalog.station(id: sourceID) else {
            return .constant(peak)
        }

        guard let forecast = try? await fetch(station: source, force: force) else {
            return .constant(peak)
        }

        // The uncertainty is published per tidal event, not per curve point, so
        // the band of the anchoring high water is applied across the series.
        guard let uncertaintyMeters = forecast.events
            .filter({ $0.type == "HW" })
            .min(by: {
                abs($0.time.timeIntervalSince(anchorHighWaterTime))
                    < abs($1.time.timeIntervalSince(anchorHighWaterTime))
            })?
            .uncertaintyCentimeters
            .map({ $0 / 100 })
        else {
            return .constant(peak)
        }

        let padded = span.lowerBound.addingTimeInterval(-3_600)
            ... span.upperBound.addingTimeInterval(3_600)
        let samples = forecast.curve
            .filter { padded.contains($0.time) }
            .compactMap { point -> WaterLevelCorrectionSeries.Sample? in
                guard let central = point.centralCorrectionMeters else { return nil }
                return WaterLevelCorrectionSeries.Sample(
                    time: point.time,
                    meters: central - uncertaintyMeters
                )
            }
            .sorted { $0.time < $1.time }

        guard samples.count >= 2 else { return .constant(peak) }
        return WaterLevelCorrectionSeries(samples: samples, fallback: peak)
    }
}
