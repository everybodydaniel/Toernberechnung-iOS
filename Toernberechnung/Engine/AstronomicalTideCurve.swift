import Foundation

/// Port of TideStationExtensions.tideHeightAt and RuleOfTwelfths.
/// No extrapolation or replacement of missing event heights.
struct AstronomicalTideCurve: Equatable {
    struct Point: Equatable {
        let time: Date
        let height: Double
    }
    private let events: [TideEvent]
    let points: [Point]
    let estimatedHeights: Bool = false

    init(events: [TideEvent], meanHighWater: Double, meanRange: Double, offset: TimeInterval) {
        self.events = events.map {
            var shifted = TideEvent(time: $0.time.addingTimeInterval(offset), heightMeters: $0.heightMeters,
                                    type: $0.type, phase: $0.phase)
            shifted.usesAstronomicalPrediction = $0.usesAstronomicalPrediction
            return shifted
        }.sorted { $0.time < $1.time }
        points = self.events.compactMap { event in
            event.heightMeters.map { Point(time: event.time, height: $0) }
        }
    }

    func height(at time: Date) -> Double? {
        guard let next = events.firstIndex(where: { $0.time >= time }) else { return nil }
        if events[next].time == time { return events[next].heightMeters }
        guard next > 0,
              let firstHeight = events[next - 1].heightMeters,
              let lastHeight = events[next].heightMeters,
              firstHeight.isFinite, lastHeight.isFinite else { return nil }
        return Self.waterLevel(start: events[next - 1].time, heightStart: firstHeight,
                               end: events[next].time, heightEnd: lastHeight, target: time)
    }

    func usesAstronomicalPrediction(at time: Date) -> Bool {
        guard let next = events.firstIndex(where: { $0.time >= time }) else { return false }
        return events[next].usesAstronomicalPrediction
            || (next > 0 && events[next - 1].usesAstronomicalPrediction)
    }

    /// Android deliberately interpolates LocalDateTime in Europe/Berlin.
    /// Retain that wall-clock arithmetic, including across a DST transition.
    static func waterLevel(start: Date, heightStart: Double, end: Date,
                           heightEnd: Double, target: Date) -> Double {
        let zone = AppDateFormatters.berlinTimeZone
        func localMillis(_ date: Date) -> Double {
            (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
                + Double(zone.secondsFromGMT(for: date)) * 1_000
        }
        let first = localMillis(start), last = localMillis(end), current = localMillis(target)
        if current < first { return heightStart }
        if current > last { return heightEnd }
        let duration = last - first
        if duration <= 0 { return heightEnd }
        let phase = (current - first) / duration
        let weights = [1.0, 2, 3, 3, 2, 1]
        let segmentLength = 1.0 / 6.0
        let index = min(max(Int(phase / segmentLength), 0), 5)
        let fraction = (phase - Double(index) * segmentLength) / segmentLength
        var accumulated = 0.0
        for i in 0 ..< index { accumulated += weights[i] }
        accumulated += weights[index] * fraction
        return heightStart + (heightEnd - heightStart) * (accumulated / 12)
    }
}

/// Used only when a manual HW or a provider without NW events is supplied.
/// No fictitious next tide is extrapolated beyond six hours from that HW.
struct ContinuousTwelfthsStrategy: TidalHeightStrategy {
    func missingWater(deviationHours: Double, meanTidalRangeMeters: Double) -> TidalHeightResult {
        let hours = abs(deviationHours)
        guard hours.isFinite, meanTidalRangeMeters.isFinite, meanTidalRangeMeters >= 0, hours <= 6 else {
            return TidalHeightResult(fmwMeters: 0, oneTwelfthMeters: meanTidalRangeMeters / 12,
                                     isValid: false, messages: ["Angrenzende Gezeitendaten fehlen."])
        }
        let effectiveHours = hours
        let values = [0.0, 1, 3, 6, 9, 11, 12]
        let lower = min(Int(effectiveHours), 5)
        let amount = values[lower] + (values[lower + 1] - values[lower]) * (effectiveHours - Double(lower))
        return TidalHeightResult(fmwMeters: amount * meanTidalRangeMeters / 12,
                                 oneTwelfthMeters: meanTidalRangeMeters / 12, isValid: true, messages: [])
    }

    func maxDeviationHours(forMaxMissingWaterMeters budget: Double, meanTidalRangeMeters range: Double) -> Double? {
        guard budget.isFinite, range.isFinite, budget >= 0, range > 0 else { return nil }
        let values = [0.0, 1, 3, 6, 9, 11, 12].map { $0 * range / 12 }
        for index in 0 ..< 6 where budget < values[index + 1] {
            return Double(index) + (budget - values[index]) / (values[index + 1] - values[index])
        }
        return 6
    }
}

/// Port of SimpleTidalCurrentProvider and VectorMath for a single route leg.
/// The 2.5 kn / east-west axis is the Android reference's simplified model.
struct AndroidPassageLeg: Equatable {
    let distanceNm: Double
    let speedKnots: Double
    let courseDegrees: Double
    let events: [TideEvent]

    func speedOverGround(at time: Date) -> Double {
        guard let next = events.firstIndex(where: { $0.androidCurrentTimestampIsISO8601 && $0.time > time }), next > 0 else { return speedKnots }
        let before = events[next - 1], after = events[next]
        guard before.androidCurrentTimestampIsISO8601 else { return speedKnots }
        let durationMinutes = after.time.timeIntervalSince(before.time) / 60
        let elapsedMinutes = time.timeIntervalSince(before.time) / 60
        let total = durationMinutes.rounded(.towardZero)
        guard total > 0 else { return speedKnots }
        let phase = elapsedMinutes.rounded(.towardZero) / total
        let drift = 2.5 * sin(phase * .pi)
        let direction: Double = after.type.localizedCaseInsensitiveContains("HW") ? 90 : 270
        let radians = Double.pi / 180
        let curX = drift * cos(direction * radians), curY = drift * sin(direction * radians)
        let coefficient = -2 * (cos(courseDegrees * radians) * curX + sin(courseDegrees * radians) * curY)
        let constant = drift * drift - speedKnots * speedKnots
        let discriminant = coefficient * coefficient - 4 * constant
        guard discriminant >= 0 else { return 0 }
        return max(0, (-coefficient + sqrt(discriminant)) / 2)
    }

    func arrival(after departure: Date) -> Date {
        let seconds = distanceNm / max(speedOverGround(at: departure), 0.1) * 3_600
        return departure.addingTimeInterval(seconds.rounded(.towardZero))
    }

    static func course(from first: RouteWaypoint, to second: RouteWaypoint) -> Double {
        let radians = Double.pi / 180
        let lat1 = (first.latitude ?? 0) * radians, lat2 = (second.latitude ?? 0) * radians
        let delta = ((second.longitude ?? 0) - (first.longitude ?? 0)) * radians
        let y = sin(delta) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(delta)
        return (atan2(y, x) / radians + 360).truncatingRemainder(dividingBy: 360)
    }
}
