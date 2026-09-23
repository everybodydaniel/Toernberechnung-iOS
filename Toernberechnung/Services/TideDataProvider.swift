import Foundation

// MARK: - Tide Data Provider Protocol

/// Abstraction for obtaining tidal event data for a BSH reference station.
///
/// Supports multiple backends:
/// - Online BSH API (`BSHTideDataProvider`)
/// - Mock data for unit tests (`MockTideDataProvider`)
/// - Manual user entry fallback
///
/// The provider must fail gracefully if a station ID is unknown, unavailable,
/// renamed, or not supported by BSH. Never crash on missing data.
protocol TideDataProvider {
    var usesAndroidForecastLevels: Bool { get }
    func routeEvents(for waypoint: RouteWaypoint, covering span: ClosedRange<Date>) async throws -> [TideEvent]
    /// Full HW/NW coverage, including adjacent events outside the requested interval.
    func tidalEvents(for stationID: String, covering span: ClosedRange<Date>) async throws -> [TideEvent]

    /// Fetch high-water events for a reference station around a date.
    ///
    /// - Parameters:
    ///   - stationID: BSH station ID (e.g. "507P"). May be provisional or incorrect.
    ///   - date: The approximate date to search around.
    /// - Returns: Array of `TideEvent` sorted by time, or empty if station is unknown.
    /// - Throws: Network errors, parse errors. Unknown station should return empty, not throw.
    func highWaters(
        for stationID: String,
        around date: Date
    ) async throws -> [TideEvent]

    /// Fetch mean tidal range for a station, if available from the data source.
    /// Returns nil if the provider does not supply this value.
    func meanTidalRange(for stationID: String) async throws -> Double?

    /// Fetch mean high water for a station, if available from the data source.
    /// Returns nil if the provider does not supply this value.
    func meanHighWater(for stationID: String) async throws -> Double?

    /// Current-year BSH reference values and station capability metadata.
    func stationReference(
        for stationID: String,
        around date: Date
    ) async throws -> TideStationReference?

    /// Conservative meteorological correction for the relevant HW cycle.
    /// A comparison station is only considered when explicitly supplied.
    func waterLevelCorrection(
        for stationID: String,
        at highWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionResolution

    /// Time-dependent correction over `span`, so a waypoint reached hours away
    /// from high water is not charged the peak surge.
    ///
    /// `anchorHighWaterTime` selects the gauge's HW cycle (and its uncertainty
    /// band); the caller samples the result at the actual arrival time.
    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries
}

extension TideDataProvider {
    var usesAndroidForecastLevels: Bool { false }
    func routeEvents(for waypoint: RouteWaypoint, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        try await tidalEvents(for: waypoint.tidalReferenceStationID, covering: span)
    }
    func tidalEvents(for stationID: String, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        // Compatibility for manual/test providers that only supply HW.
        let middle = span.lowerBound.addingTimeInterval(span.upperBound.timeIntervalSince(span.lowerBound) / 2)
        return try await highWaters(for: stationID, around: middle)
    }

    /// Providers without a forecast curve keep the previous behaviour: one
    /// scalar sampled at the high-water peak, applied flat.
    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries {
        .constant(await waterLevelCorrection(
            for: stationID,
            at: anchorHighWaterTime,
            confirmedComparisonStationID: confirmedComparisonStationID
        ))
    }
}

// MARK: - BSH Tide Data Provider

/// Wraps the existing `BSHTideService` to conform to `TideDataProvider`.
///
/// Maps station IDs to `HarbourOption` for the BSH fetch call.
/// If a station ID is not found in the known harbour list, returns empty results
/// rather than throwing, so the calculation engine marks the waypoint as incomplete.
final class BSHTideDataProvider: TideDataProvider {
    var usesAndroidForecastLevels: Bool { true }
    func routeEvents(for waypoint: RouteWaypoint, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        guard let latitude = waypoint.latitude, let longitude = waypoint.longitude else { return [] }
        return try await AndroidPassageForecastStore.shared.events(
            latitude: latitude, longitude: longitude, covering: span
        )
    }
    func tidalEvents(for stationID: String, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        try await BSHTideService.shared.tidalEvents(for: stationID, covering: span)
    }


    func highWaters(
        for stationID: String,
        around date: Date
    ) async throws -> [TideEvent] {
        do {
            return try await BSHTideService.shared.highWaters(for: stationID, around: date)
        } catch {
            // BSH fetch failed — return empty so the waypoint is marked incomplete.
            return []
        }
    }

    func meanTidalRange(for stationID: String) async throws -> Double? {
        try await BSHTideService.shared.reference(for: stationID, around: .now)?.meanTidalRangeMeters
    }

    func meanHighWater(for stationID: String) async throws -> Double? {
        try await BSHTideService.shared.reference(for: stationID, around: .now)?.meanHighWaterAboveSknMeters
    }

    func stationReference(
        for stationID: String,
        around date: Date
    ) async throws -> TideStationReference? {
        try await BSHTideService.shared.reference(for: stationID, around: date)
    }

    func waterLevelCorrection(
        for stationID: String,
        at highWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionResolution {
        await BSHWaterLevelForecastService.shared.correction(
            for: stationID,
            at: highWaterTime,
            comparisonStationID: confirmedComparisonStationID
        )
    }

    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries {
        await BSHWaterLevelForecastService.shared.correctionSeries(
            for: stationID,
            covering: span,
            anchorHighWaterTime: anchorHighWaterTime,
            comparisonStationID: confirmedComparisonStationID
        )
    }
}

// MARK: - Mock Tide Data Provider

/// Mock provider for unit tests. Returns configurable tide events.
final class MockTideDataProvider: TideDataProvider {
    var tidalEventsByStation: [String: [TideEvent]] = [:]
    func tidalEvents(for stationID: String, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        if shouldThrow { throw BSHTideError.badResponse }
        if let events = tidalEventsByStation[stationID] { return events }
        return try await highWaters(for: stationID, around: span.lowerBound)
    }

    /// Pre-configured high water events keyed by station ID.
    var highWatersByStation: [String: [TideEvent]] = [:]
    /// Pre-configured mean tidal ranges keyed by station ID.
    var meanTidalRanges: [String: Double] = [:]
    /// Pre-configured mean high water values keyed by station ID.
    var meanHighWaters: [String: Double] = [:]
    var referencesByStation: [String: TideStationReference] = [:]
    var correctionsByStation: [String: WaterLevelCorrectionResolution] = [:]
    /// Optional time-dependent corrections. When a station is absent here, the
    /// protocol's default kicks in and the scalar from `correctionsByStation`
    /// is used — so tests written before the curve existed keep working.
    var correctionSeriesByStation: [String: WaterLevelCorrectionSeries] = [:]
    /// If true, throws an error on fetch to simulate network failure.
    var shouldThrow: Bool = false
    /// Counts `highWaters(for:around:)` calls so tests can prove the passage
    /// window search resolves tide data once per waypoint instead of once per
    /// candidate departure time.
    ///
    /// Lock-protected: `PassageWindowSolver` resolves its waypoints
    /// concurrently, so an unsynchronised dictionary would race.
    var highWatersCallCount: [String: Int] {
        callCountLock.withLock {
            storedHighWatersCallCount
        }
    }

    private let callCountLock = NSLock()
    private var storedHighWatersCallCount: [String: Int] = [:]

    func highWaters(for stationID: String, around date: Date) async throws -> [TideEvent] {
        callCountLock.withLock {
            storedHighWatersCallCount[stationID, default: 0] += 1
        }
        if shouldThrow {
            throw BSHTideError.badResponse
        }
        return highWatersByStation[stationID] ?? []
    }

    func meanTidalRange(for stationID: String) async throws -> Double? {
        meanTidalRanges[stationID]
    }

    func meanHighWater(for stationID: String) async throws -> Double? {
        meanHighWaters[stationID]
    }

    func stationReference(
        for stationID: String,
        around date: Date
    ) async throws -> TideStationReference? {
        referencesByStation[stationID]
    }

    func waterLevelCorrection(
        for stationID: String,
        at highWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionResolution {
        correctionsByStation[stationID] ?? .unavailable(
            stationID: stationID,
            detail: "Mock enthält keine Wasserstandskorrektur."
        )
    }

    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries {
        if let series = correctionSeriesByStation[stationID] { return series }
        return .constant(await waterLevelCorrection(
            for: stationID,
            at: anchorHighWaterTime,
            confirmedComparisonStationID: confirmedComparisonStationID
        ))
    }
}

/// The Android map planner enriches its local harbours with the nearest BSH
/// forecast station within 20 km, then uses the nearest local harbour per sample.
/// This snapshot preserves that two-stage lookup and centimetre/SKN conversion.
actor AndroidPassageForecastStore {
    static let shared = AndroidPassageForecastStore()

    struct Station: Sendable {
        let name: String
        let gaugeName: String
        let latitude: Double
        let longitude: Double
        let events: [TideEvent]
        let chartDatumAboveGaugeZeroMeters: Double?
    }

    static let localHarbours: [(String, Double, Double)] = [
        ("Borkum", 53.5572, 6.7525), ("Juist", 53.6732, 7.0015),
        ("Norderney", 53.7012, 7.1585), ("Baltrum", 53.7215, 7.3715),
        ("Langeoog", 53.7285, 7.5095), ("Spiekeroog", 53.7645, 7.6955),
        ("Wangerooge", 53.7852, 7.8965), ("Emden", 53.3382, 7.1945),
        ("Norddeich", 53.6265, 7.1615), ("Nessmersiel", 53.6865, 7.3615),
        ("Dornumersiel", 53.6865, 7.4785), ("Bensersiel", 53.6785, 7.5705),
        ("Neuharlingersiel", 53.7015, 7.7055), ("Harlesiel", 53.7125, 7.8105),
        ("Horumersiel", 53.6862, 8.0195), ("Hooksiel", 53.6425, 8.0825),
        ("Dangast", 53.4472, 8.1175), ("Wilhelmshaven", 53.5142, 8.1465),
        ("Delfzijl", 53.3305, 6.9335), ("Termunterzijl", 53.3032, 7.0405),
        ("Eemshaven", 53.4445, 6.8365)
    ]
    private var cached: (Date, [Station])?
    private var pending: Task<[Station], Error>?

    func events(latitude: Double, longitude: Double, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        let stations = try await snapshot()
        guard let station = stations.min(by: {
            Self.distance(latitude, longitude, $0.latitude, $0.longitude)
                < Self.distance(latitude, longitude, $1.latitude, $1.longitude)
        }) else { return [] }
        let gauge = BSHTideStationCatalog.stations.first(where: {
            $0.name.localizedCaseInsensitiveCompare(station.gaugeName) == .orderedSame
        })
        let reference = if let gauge {
            try? await BSHTideService.shared.reference(for: gauge.id, around: span.lowerBound)
        } else {
            nil as TideStationReference?
        }
        guard let datum = station.chartDatumAboveGaugeZeroMeters
            ?? reference?.chartDatumAboveGaugeZeroMeters else { return [] }
        let forecast = station.events.map { event in
            var converted = event
            if station.chartDatumAboveGaugeZeroMeters == nil, let height = event.heightMeters {
                converted = TideEvent(time: event.time, heightMeters: height - datum,
                                      type: event.type, phase: event.phase)
                converted.androidCurrentTimestampIsISO8601 = event.androidCurrentTimestampIsISO8601
                converted.usesAstronomicalPrediction = event.usesAstronomicalPrediction
            }
            return converted
        }
        guard let gauge, !forecast.isEmpty else { return forecast }
        let calendar = (try? await BSHTideService.shared.tidalEvents(for: gauge.id, covering: span)) ?? []
        return Self.combined(forecast: forecast, calendar: calendar)
    }

    static func combined(forecast: [TideEvent], calendar: [TideEvent]) -> [TideEvent] {
        guard let first = forecast.first?.time, let last = forecast.last?.time else { return forecast }
        let adjacent = calendar.filter { $0.heightMeters != nil && ($0.time < first || $0.time > last) }
            .map { event -> TideEvent in
                var predicted = event
                predicted.usesAstronomicalPrediction = true
                predicted.androidCurrentTimestampIsISO8601 = false
                return predicted
            }
        return (forecast + adjacent).sorted { $0.time < $1.time }
    }

    private func snapshot() async throws -> [Station] {
        if let (date, stations) = cached, Date().timeIntervalSince(date) < 600 { return stations }
        if let pending { return try await pending.value }
        let task = Task { () throws -> [Station] in
            let endpoint = "https://gdi.bsh.de/ldproxy/rest/services/WaterLevelForecast/collections/waterlevelforecastdata/items?limit=100&region=north_sea&f=json"
            var request = URLRequest(url: URL(string: endpoint)!)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BSHTideError.badResponse }
            return try Self.decode(data)
        }
        pending = task
        defer { pending = nil }
        let stations = try await task.value
        cached = (Date(), stations)
        return stations
    }

    static func decode(_ data: Data) throws -> [Station] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw BSHTideError.badResponse }
        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? String { return Double(value) }
            return nil
        }
        let forecasts = features.compactMap { feature -> Station? in
            guard let properties = feature["properties"] as? [String: Any],
                  let lat = number(properties["latitude"]), let lon = number(properties["longitude"]) else { return nil }
            let datum = number(properties["chartdatum_relative_to_gaugezero"]).map { $0 / 100 }
            let events = (properties["high_water_low_water"] as? [[String: Any]] ?? []).compactMap { raw -> TideEvent? in
                let forecast = number(raw["forecast_value"])
                guard let height = forecast ?? number(raw["tidal_prediction_value"]), height.isFinite,
                      let timestamp = raw["event_timestamp"] as? String,
                      let time = BSHDateParser.date(from: timestamp),
                      let type = raw["event"] as? String else { return nil }
                var event = TideEvent(time: time, heightMeters: height / 100 - (datum ?? 0), type: type, phase: nil)
                event.usesAstronomicalPrediction = forecast == nil
                // SimpleTidalCurrentProvider uses ZonedDateTime.parse directly,
                // unlike TideTimes: space-separated BSH timestamps disable current.
                event.androidCurrentTimestampIsISO8601 = timestamp.contains("T") &&
                    (timestamp.hasSuffix("Z") || timestamp.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil)
                return event
            }.sorted { $0.time < $1.time }
            return Station(name: properties["gauge_label"] as? String ?? "BSH",
                           gaugeName: properties["gauge_label"] as? String ?? "BSH", latitude: lat, longitude: lon,
                           events: events, chartDatumAboveGaugeZeroMeters: datum)
        }
        return localHarbours.map { name, lat, lon in
            let nearest = forecasts.min { distance(lat, lon, $0.latitude, $0.longitude) < distance(lat, lon, $1.latitude, $1.longitude) }
            let events = nearest.flatMap { distance(lat, lon, $0.latitude, $0.longitude) < 20 ? $0.events : nil } ?? []
            return Station(name: name, gaugeName: nearest?.gaugeName ?? "BSH", latitude: lat, longitude: lon,
                           events: events, chartDatumAboveGaugeZeroMeters: nearest?.chartDatumAboveGaugeZeroMeters)
        }
    }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let value = pow(sin((lat2 - lat1) * rad / 2), 2)
            + cos(lat1 * rad) * cos(lat2 * rad) * pow(sin((lon2 - lon1) * rad / 2), 2)
        return 6_371 * 2 * atan2(sqrt(value), sqrt(1 - value))
    }
}
