import Foundation

enum WaterLevelCorrectionQuality: String, Codable, Equatable, Sendable {
    case localOfficial
    case modelForecast
    case estimatedTide
    case unverifiedDepth
    case confirmedComparison
    case manual
    case stale
    case outsideForecastHorizon
    case unavailable

    var allowsGreenStatus: Bool { self == .localOfficial }
    var isUsable: Bool {
        self == .localOfficial || self == .modelForecast || self == .confirmedComparison || self == .manual
    }
}

struct WaterLevelCorrectionResolution: Equatable, Sendable {
    let meters: Double
    let quality: WaterLevelCorrectionQuality
    let localStationID: String
    let sourceStationID: String?
    let sourceStationName: String?
    let issuedAt: Date?
    let detail: String

    static func unavailable(
        stationID: String,
        quality: WaterLevelCorrectionQuality = .unavailable,
        detail: String
    ) -> WaterLevelCorrectionResolution {
        WaterLevelCorrectionResolution(
            meters: 0,
            quality: quality,
            localStationID: stationID,
            sourceStationID: nil,
            sourceStationName: nil,
            issuedAt: nil,
            detail: detail
        )
    }
}

struct WaterLevelForecast: Codable, Equatable, Sendable {
    let stationID: String
    let featureID: String
    let stationName: String
    let issuedAt: Date
    let curveIssuedAt: Date?
    let fetchedAt: Date
    let pnpBelowNhnMeters: Double?
    let sknAbovePnpMeters: Double?
    let mhwAbovePnpMeters: Double?
    let mnwAbovePnpMeters: Double?
    let events: [WaterLevelEvent]
    let curve: [WaterLevelCurvePoint]
    let mhwAboveSknMeters: Double?
    let mnwAboveSknMeters: Double?
    let officialWarningLevel: String?
    let informationText: String?
    let sourcePage: URL?

    var isStale: Bool {
        Date().timeIntervalSince(issuedAt) > 8 * 3_600
    }
}

struct WaterLevelCurvePoint: Identifiable, Codable, Equatable, Sendable {
    let time: Date
    let astroMetersSkn: Double?
    let forecastMetersSkn: Double?
    let measurementMetersSkn: Double?

    var id: Date { time }
}

struct WaterLevelEvent: Identifiable, Codable, Equatable, Sendable {
    let time: Date
    let type: String
    let tidalPredictionCmAbovePnp: Double?
    let forecastCmAbovePnp: Double?
    let uncertaintyCentimeters: Double?
    let tidalPredictionMetersAboveSkn: Double?
    let forecastMetersAboveSkn: Double?
    let forecastText: String
    let warning: String?

    var id: String { "\(time.timeIntervalSince1970)-\(type)" }
    var symbol: String { type == "HW" ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }

    var conservativeCorrectionMeters: Double? {
        guard let forecastCmAbovePnp,
              let tidalPredictionCmAbovePnp,
              let uncertaintyCentimeters else { return nil }
        return (forecastCmAbovePnp - uncertaintyCentimeters - tidalPredictionCmAbovePnp) / 100
    }

    var sknHeightText: String {
        guard let forecastMetersAboveSkn else { return "SKN nicht verfügbar" }
        return String(format: "%.2f m SKN", forecastMetersAboveSkn)
    }
}

enum BSHWaterLevelForecastError: LocalizedError {
    case invalidURL
    case notAvailable
    case badResponse
    case emptyPayload
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Die BSH-Wasserstands-URL ist ungültig."
        case .notAvailable: return "Für diesen Pegel veröffentlicht das BSH keine lokale Wasserstandsvorhersage."
        case .badResponse: return "Die BSH-Wasserstandsvorhersage konnte nicht gelesen werden."
        case .emptyPayload: return "Der BSH-Datensatz enthält keine Wasserstandsvorhersage."
        case .network(let message): return "Die BSH-Wasserstandsvorhersage ist nicht erreichbar: \(message)"
        }
    }
}

actor BSHWaterLevelForecastService {
    static let shared = BSHWaterLevelForecastService()

    private let baseURL = "https://gdi.bsh.de/ldproxy/rest/services/WaterLevelForecast/collections/waterlevelforecastdata/items"
    private let cacheLifetime: TimeInterval = 15 * 60
    private var cache: [String: WaterLevelForecast] = [:]
    private var didLoadPersistentCache = false

    func fetch(stationID: String, force: Bool = false) async throws -> WaterLevelForecast {
        guard let station = BSHTideStationCatalog.station(id: stationID) else {
            throw BSHWaterLevelForecastError.notAvailable
        }
        return try await fetch(station: station, force: force)
    }

    func fetch(station: BSHTideStation, force: Bool = false) async throws -> WaterLevelForecast {
        guard let featureID = station.forecastFeatureID else {
            throw BSHWaterLevelForecastError.notAvailable
        }

        loadPersistentCacheIfNeeded()
        if !force, let cached = cache[featureID],
           Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached
        }

        guard let url = URL(string: "\(baseURL)/\(featureID)?f=json") else {
            throw BSHWaterLevelForecastError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BSHWaterLevelForecastError.badResponse
            }
            if http.statusCode == 404 { throw BSHWaterLevelForecastError.notAvailable }
            guard http.statusCode == 200 else { throw BSHWaterLevelForecastError.badResponse }

            let reference = try? await BSHTideService.shared.reference(
                for: station.id,
                around: .now
            )
            let forecast = try Self.decodeForecast(
                data: data,
                station: station,
                chartDatumFallbackMeters: reference?.chartDatumAboveGaugeZeroMeters
            )
            cache[featureID] = forecast
            persistCache()
            return forecast
        } catch let error as BSHWaterLevelForecastError {
            if let cached = cache[featureID] { return cached }
            throw error
        } catch {
            if let cached = cache[featureID] { return cached }
            throw BSHWaterLevelForecastError.network(error.localizedDescription)
        }
    }

    static func decodeForecast(
        data: Data,
        station: BSHTideStation,
        chartDatumFallbackMeters: Double? = nil
    ) throws -> WaterLevelForecast {
        let feature: BSHForecastFeature
        do {
            feature = try JSONDecoder().decode(BSHForecastFeature.self, from: data)
        } catch {
            throw BSHWaterLevelForecastError.badResponse
        }
        return try makeForecast(
            feature: feature,
            station: station,
            chartDatumFallbackMeters: chartDatumFallbackMeters
        )
    }

    func correction(
        for localStationID: String,
        at highWaterTime: Date,
        comparisonStationID: String? = nil,
        force: Bool = false
    ) async -> WaterLevelCorrectionResolution {
        guard let local = BSHTideStationCatalog.station(id: localStationID) else {
            return .unavailable(stationID: localStationID, detail: "Unbekannter BSH-Referenzpegel.")
        }

        let effectiveComparisonID = comparisonStationID
            ?? BSHTideStationCatalog.requiredComparisonStation(for: localStationID)?.id
            ?? BSHTideStationCatalog.nearestComparisonStation(for: localStationID)?.id
        let source: BSHTideStation
        let quality: WaterLevelCorrectionQuality
        if let effectiveComparisonID,
                  let comparison = BSHTideStationCatalog.station(id: effectiveComparisonID),
                  comparison.hasLocalWaterLevelForecast {
            source = comparison
            quality = .confirmedComparison
        } else if local.hasLocalWaterLevelForecast {
            source = local
            quality = .localOfficial
        } else {
            return .unavailable(
                stationID: localStationID,
                detail: "Für \(local.name) ist keine BSH-Wasserstandsvorhersage verfügbar."
            )
        }

        do {
            let forecast = try await fetch(station: source, force: force)
            if forecast.isStale {
                return .unavailable(
                    stationID: localStationID,
                    quality: .stale,
                    detail: "Die BSH-Wasserstandsvorhersage ist älter als acht Stunden."
                )
            }

            guard let event = forecast.events
                .filter({ $0.type == "HW" })
                .min(by: {
                    abs($0.time.timeIntervalSince(highWaterTime))
                        < abs($1.time.timeIntervalSince(highWaterTime))
                }),
                abs(event.time.timeIntervalSince(highWaterTime)) <= 8 * 3_600
            else {
                return .unavailable(
                    stationID: localStationID,
                    quality: .outsideForecastHorizon,
                    detail: "Das Hochwasser liegt außerhalb des aktuellen BSH-Prognosezeitraums."
                )
            }

            guard let correction = event.conservativeCorrectionMeters else {
                return .unavailable(
                    stationID: localStationID,
                    detail: "Der BSH-Scheitelwert enthält keine vollständige Unsicherheitsangabe."
                )
            }

            let comparisonText: String
            if quality == .confirmedComparison {
                let distance = local.distanceKilometers(to: source)
                comparisonText = "Bestätigter Vergleichspegel \(source.name), Entfernung \(String(format: "%.1f", distance)) km."
            } else {
                comparisonText = "Lokale amtliche Scheitelwertvorhersage."
            }

            return WaterLevelCorrectionResolution(
                meters: correction,
                quality: quality,
                localStationID: localStationID,
                sourceStationID: source.id,
                sourceStationName: source.name,
                issuedAt: forecast.issuedAt,
                detail: comparisonText
            )
        } catch {
            return .unavailable(stationID: localStationID, detail: error.localizedDescription)
        }
    }

    private static func makeForecast(
        feature: BSHForecastFeature,
        station: BSHTideStation,
        chartDatumFallbackMeters: Double?
    ) throws -> WaterLevelForecast {
        let properties = feature.properties
        let chartDatumMeters = properties.chartDatumRelativeToGaugeZero?.value.map { $0 / 100 }
            ?? chartDatumFallbackMeters

        let events = (properties.highWaterLowWater ?? [])
            .compactMap { raw -> WaterLevelEvent? in
                guard let date = BSHDateParser.date(from: raw.eventTimestamp),
                      let type = raw.event else { return nil }
                let tidalPnp = raw.tidalPredictionValue?.value
                let forecastPnp = raw.forecastValue?.value
                return WaterLevelEvent(
                    time: date,
                    type: type,
                    tidalPredictionCmAbovePnp: tidalPnp,
                    forecastCmAbovePnp: forecastPnp,
                    uncertaintyCentimeters: raw.forecastUncertainty?.value,
                    tidalPredictionMetersAboveSkn: metersAboveSkn(tidalPnp, chartDatumMeters: chartDatumMeters),
                    forecastMetersAboveSkn: metersAboveSkn(forecastPnp, chartDatumMeters: chartDatumMeters),
                    forecastText: raw.forecastDeviation ?? correctionText(forecast: forecastPnp, tide: tidalPnp),
                    warning: raw.automatedWarning
                )
            }
            .sorted { $0.time < $1.time }

        let rawCurve = (properties.curve ?? [])
            .compactMap { raw -> WaterLevelCurvePoint? in
                guard let date = BSHDateParser.date(from: raw.timestamp) else { return nil }
                return WaterLevelCurvePoint(
                    time: date,
                    astroMetersSkn: metersAboveSkn(raw.tidalPrediction?.value, chartDatumMeters: chartDatumMeters),
                    forecastMetersSkn: metersAboveSkn(raw.automatedForecast?.value, chartDatumMeters: chartDatumMeters),
                    measurementMetersSkn: metersAboveSkn(raw.measurement?.value, chartDatumMeters: chartDatumMeters)
                )
            }
            .sorted { $0.time < $1.time }

        guard !events.isEmpty || !rawCurve.isEmpty else {
            throw BSHWaterLevelForecastError.emptyPayload
        }

        let issuedAt = properties.forecastTimestamp.flatMap(BSHDateParser.date(from:))
            ?? properties.curveForecastTimestamp.flatMap(BSHDateParser.date(from:))
            ?? .now
        let mhwPnp = properties.meanHighWater?.value.map { $0 / 100 }
        let mnwPnp = properties.meanLowWater?.value.map { $0 / 100 }

        return WaterLevelForecast(
            stationID: station.id,
            featureID: feature.id ?? station.forecastFeatureID ?? station.seoID,
            stationName: properties.gaugeLabel ?? station.name,
            issuedAt: issuedAt,
            curveIssuedAt: properties.curveForecastTimestamp.flatMap(BSHDateParser.date(from:)),
            fetchedAt: .now,
            pnpBelowNhnMeters: properties.gaugeZeroRelativeToNHN?.value.map { $0 / 100 },
            sknAbovePnpMeters: chartDatumMeters,
            mhwAbovePnpMeters: mhwPnp,
            mnwAbovePnpMeters: mnwPnp,
            events: events,
            curve: thin(rawCurve, every: 3),
            mhwAboveSknMeters: subtractDatum(mhwPnp, chartDatumMeters),
            mnwAboveSknMeters: subtractDatum(mnwPnp, chartDatumMeters),
            officialWarningLevel: properties.officialWarningLevel,
            informationText: properties.informationText?.german,
            sourcePage: properties.sourcePage.flatMap(URL.init(string:))
        )
    }

    private static func metersAboveSkn(_ centimeters: Double?, chartDatumMeters: Double?) -> Double? {
        guard let centimeters, let chartDatumMeters else { return nil }
        return centimeters / 100 - chartDatumMeters
    }

    private static func subtractDatum(_ metersAbovePnp: Double?, _ chartDatumMeters: Double?) -> Double? {
        guard let metersAbovePnp, let chartDatumMeters else { return nil }
        return metersAbovePnp - chartDatumMeters
    }

    private static func correctionText(forecast: Double?, tide: Double?) -> String {
        guard let forecast, let tide else { return "" }
        return String(format: "%+.1f m", (forecast - tide) / 100)
    }

    private static func thin(_ curve: [WaterLevelCurvePoint], every step: Int) -> [WaterLevelCurvePoint] {
        guard step > 1, curve.count > 2 else { return curve }
        return curve.enumerated().compactMap { index, point in
            index == 0 || index == curve.count - 1 || index.isMultiple(of: step) ? point : nil
        }
    }

    private func loadPersistentCacheIfNeeded() {
        guard !didLoadPersistentCache else { return }
        didLoadPersistentCache = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let stored = try? JSONDecoder().decode([String: WaterLevelForecast].self, from: data) else { return }
        cache.merge(stored) { current, stored in
            current.fetchedAt >= stored.fetchedAt ? current : stored
        }
    }

    private func persistCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let directory = Self.cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TideNode/BSHWaterLevelCache.json", isDirectory: false)
    }
}

private struct BSHForecastFeature: Decodable {
    let id: String?
    let properties: BSHForecastProperties
}

private struct BSHForecastProperties: Decodable {
    let gaugeLabel: String?
    let officialWarningLevel: String?
    let informationText: BSHLocalizedText?
    let gaugeZeroRelativeToNHN: BSHFlexibleNumber?
    let chartDatumRelativeToGaugeZero: BSHFlexibleNumber?
    let meanHighWater: BSHFlexibleNumber?
    let meanLowWater: BSHFlexibleNumber?
    let forecastTimestamp: String?
    let curveForecastTimestamp: String?
    let sourcePage: String?
    let highWaterLowWater: [BSHRawForecastEvent]?
    let curve: [BSHRawCurvePoint]?

    enum CodingKeys: String, CodingKey {
        case gaugeLabel = "gauge_label"
        case officialWarningLevel = "official_warning_level_region"
        case informationText = "information_text"
        case gaugeZeroRelativeToNHN = "gaugezero_relative_to_nhn"
        case chartDatumRelativeToGaugeZero = "chartdatum_relative_to_gaugezero"
        case meanHighWater = "mean_high_water"
        case meanLowWater = "mean_low_water"
        case forecastTimestamp = "forecast_timestamp"
        case curveForecastTimestamp = "automated_curveforecast_timestamp"
        case sourcePage = "bsh_url_waterlevel"
        case highWaterLowWater = "high_water_low_water"
        case curve
    }
}

private struct BSHLocalizedText: Decodable {
    let german: String?

    enum CodingKeys: String, CodingKey {
        case german = "de"
    }
}

private struct BSHRawForecastEvent: Decodable {
    let eventTimestamp: String
    let event: String?
    let tidalPredictionValue: BSHFlexibleNumber?
    let forecastValue: BSHFlexibleNumber?
    let forecastUncertainty: BSHFlexibleNumber?
    let forecastDeviation: String?
    let automatedWarning: String?

    enum CodingKeys: String, CodingKey {
        case eventTimestamp = "event_timestamp"
        case event
        case tidalPredictionValue = "tidal_prediction_value"
        case forecastValue = "forecast_value"
        case forecastUncertainty = "forecast_uncertainty"
        case forecastDeviation = "forecast_deviation"
        case automatedWarning = "forecast_automated_event_warning"
    }
}

private struct BSHRawCurvePoint: Decodable {
    let timestamp: String
    let measurement: BSHFlexibleNumber?
    let tidalPrediction: BSHFlexibleNumber?
    let automatedForecast: BSHFlexibleNumber?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case measurement
        case tidalPrediction = "tidal_prediction"
        case automatedForecast = "automated_curve_forecast"
    }
}

private struct BSHFlexibleNumber: Codable, Equatable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self) {
            value = Double(string.replacingOccurrences(of: ",", with: "."))
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}
