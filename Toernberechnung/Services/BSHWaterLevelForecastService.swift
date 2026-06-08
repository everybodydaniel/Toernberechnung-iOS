import Foundation

// MARK: - BSH Wasserstandsvorhersage (Scheitelwert)
//
// Pulls the per-gauge JSON published by the BSH at
// `https://wasserstand-nordsee.bsh.de/data/DE__{bshnr}.json`.
//
// The payload contains the manually-checked peak forecast (`hwnw_forecast`)
// for HW/NW events plus the station's reference levels (`PNP (unter NHN)`
// and `SKN (ueber PNP)`) so we can convert the published cm-above-PNP
// values into metres above Seekartennull (SKN) — the chart datum the
// skipper actually cares about.
//
// Cache: 15 minutes. The BSH refreshes the manual forecast roughly every
// six hours; polling on top of that is throttled both by the cache and by
// the `creation_forecast` timestamp echoed in `WaterLevelForecast`.

struct WaterLevelForecast: Equatable, Sendable {
    let stationName: String
    let bshNr: String
    /// When the BSH issued this forecast (its own `creation_forecast`).
    let issuedAt: Date
    /// When we received it.
    let fetchedAt: Date
    /// Pegelnullpunkt below NHN, in metres (negative = below NHN).
    let pnpBelowNhnMeters: Double
    /// Seekartennull above PNP, in metres.
    let sknAbovePnpMeters: Double
    /// Mean high water above PNP in metres (long-term).
    let mhwMeters: Double?
    /// Mean low water above PNP in metres (long-term).
    let mnwMeters: Double?
    let events: [WaterLevelEvent]
    /// Continuous curve (astronomical + forecast + measurement) in
    /// metres above SKN. Empty for Group-4 gauges that publish peak
    /// values only — UI shows a hint in that case.
    let curve: [WaterLevelCurvePoint]
    /// Mean high water in metres above SKN — used by the chart as a
    /// horizontal reference line.
    let mhwAboveSknMeters: Double?
    let mnwAboveSknMeters: Double?
    /// Was this forecast taken from a substitute station (Juist→Norderney
    /// etc.)? Tells the UI to show a hint.
    let substituteForHarbour: String?
}

/// Single sample on the continuous curve. Any of the three values may
/// be `nil` (BSH only ships measurements for past times and forecast
/// for future times).
struct WaterLevelCurvePoint: Identifiable, Equatable, Sendable {
    let id = UUID()
    let time: Date
    let astroMetersSkn: Double?
    let forecastMetersSkn: Double?
    let measurementMetersSkn: Double?
}

struct WaterLevelEvent: Identifiable, Equatable, Sendable {
    let id = UUID()
    let time: Date
    let type: String         // "HW" or "NW"
    /// Raw published value in cm above the local Pegelnullpunkt.
    let cmAbovePnp: Int
    /// Same value converted to metres above Seekartennull (SKN).
    let metersAboveSkn: Double
    /// Deviation from the astronomical mean, in dm (BSH convention).
    let deviationDm: Double
    /// Human-readable text from BSH, e.g. "+0,2 m".
    let forecastText: String
    let warning: String?

    var symbol: String { type == "HW" ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }

    /// "3.18 m über SKN" — the value skippers expect on the card.
    var sknHeightText: String {
        String(format: "%.2f m SKN", metersAboveSkn)
    }
}

enum BSHWaterLevelForecastError: LocalizedError {
    case invalidURL
    case notAvailable    // 404 — no forecast for this gauge
    case badResponse
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case .invalidURL:    return "Die BSH-Vorhersage-URL ist ungültig."
        case .notAvailable:  return "Für diesen Pegel gibt es keine BSH-Wasserstandsvorhersage."
        case .badResponse:   return "Die BSH-Vorhersage konnte nicht geladen werden."
        case .emptyPayload:  return "Der BSH-Datensatz enthält keine Scheitelwerte."
        }
    }
}

actor BSHWaterLevelForecastService {
    static let shared = BSHWaterLevelForecastService()

    private let baseURL = "https://wasserstand.bsh.de/data"
    private var cache: [String: WaterLevelForecast] = [:]
    private let cacheLifetime: TimeInterval = 15 * 60

    // MARK: - Public API

    /// Fetch the manually-verified peak forecast for the given gauge number.
    /// `substituteForHarbour` is purely metadata so the UI can hint that the
    /// forecast was taken from a neighbouring station.
    func fetch(bshNr: String, substituteForHarbour: String? = nil, force: Bool = false) async throws -> WaterLevelForecast {
        if !force, let cached = cache[bshNr],
           Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return WaterLevelForecast(
                stationName: cached.stationName,
                bshNr: cached.bshNr,
                issuedAt: cached.issuedAt,
                fetchedAt: cached.fetchedAt,
                pnpBelowNhnMeters: cached.pnpBelowNhnMeters,
                sknAbovePnpMeters: cached.sknAbovePnpMeters,
                mhwMeters: cached.mhwMeters,
                mnwMeters: cached.mnwMeters,
                events: cached.events,
                curve: cached.curve,
                mhwAboveSknMeters: cached.mhwAboveSknMeters,
                mnwAboveSknMeters: cached.mnwAboveSknMeters,
                substituteForHarbour: substituteForHarbour
            )
        }

        let urls = [
            URL(string: "\(baseURL)/nordsee/DE__\(bshNr).json")!,
            URL(string: "\(baseURL)/ostsee/DE__\(bshNr).json")!
        ]

        var lastError: Error?
        var data: Data?
        var httpResponse: HTTPURLResponse?

        for url in urls {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (d, r) = try await URLSession.shared.data(for: request)
                if let http = r as? HTTPURLResponse {
                    if http.statusCode == 200 {
                        data = d
                        httpResponse = http
                        break
                    } else if http.statusCode == 404 {
                        httpResponse = http
                    }
                }
            } catch {
                lastError = error
            }
        }

        if data == nil {
            if let http = httpResponse, http.statusCode == 404 {
                throw BSHWaterLevelForecastError.notAvailable
            }
            if let err = lastError {
                throw err
            }
            throw BSHWaterLevelForecastError.badResponse
        }

        let payload: BSHStationPayload
        do {
            payload = try JSONDecoder().decode(BSHStationPayload.self, from: data!)
        } catch {
            throw BSHWaterLevelForecastError.badResponse
        }

        let sknAbovePnpMeters = (payload.sknAbovePnpCm.flatMap(Double.init) ?? 0) / 100
        let pnpBelowNhnMeters = (payload.pnpBelowNhnCm.flatMap(Double.init) ?? 0) / 100

        // Sort chronologically and trim past events older than one hour
        // so the UI starts on the next upcoming HW/NW.
        let cutoff = Date().addingTimeInterval(-3600)
        let events: [WaterLevelEvent] = (payload.hwnwForecast?.data ?? [])
            .compactMap { raw in raw.event(sknAbovePnpMeters: sknAbovePnpMeters) }
            .filter { $0.time >= cutoff }
            .sorted { $0.time < $1.time }

        guard !events.isEmpty else { throw BSHWaterLevelForecastError.emptyPayload }

        // Continuous curve. BSH ships ~920 points at 10-minute resolution
        // over 6 days. Thin to 30-minute steps for chart performance
        // (still 300+ samples → smooth tide sinus).
        let rawCurve = (payload.curveForecast?.data ?? [])
            .compactMap { $0.point(sknAbovePnpMeters: sknAbovePnpMeters) }
            .sorted { $0.time < $1.time }
        let curve = Self.thin(rawCurve, every: 3)

        let forecast = WaterLevelForecast(
            stationName: payload.stationName ?? bshNr,
            bshNr: bshNr,
            issuedAt: payload.creationForecast.flatMap(Self.parseDate(_:)) ?? Date(),
            fetchedAt: Date(),
            pnpBelowNhnMeters: pnpBelowNhnMeters,
            sknAbovePnpMeters: sknAbovePnpMeters,
            mhwMeters: payload.mhwCm.map { Double($0) / 100 },
            mnwMeters: payload.mnwCm.map { Double($0) / 100 },
            events: events,
            curve: curve,
            mhwAboveSknMeters: payload.mhwCm.map { Double($0) / 100 - sknAbovePnpMeters },
            mnwAboveSknMeters: payload.mnwCm.map { Double($0) / 100 - sknAbovePnpMeters },
            substituteForHarbour: substituteForHarbour
        )
        cache[bshNr] = forecast
        return forecast
    }

    /// Keep every Nth element. Preserves first/last so the chart
    /// reaches the chart edges.
    private static func thin(_ curve: [WaterLevelCurvePoint], every n: Int) -> [WaterLevelCurvePoint] {
        guard n > 1, curve.count > 2 else { return curve }
        var out: [WaterLevelCurvePoint] = []
        out.reserveCapacity(curve.count / n + 2)
        for (i, point) in curve.enumerated() {
            if i == 0 || i == curve.count - 1 || i.isMultiple(of: n) {
                out.append(point)
            }
        }
        return out
    }

    // MARK: - Date helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let bshFormatter: DateFormatter = {
        // BSH uses "yyyy-MM-dd HH:mm:ssXXXXX" with a space, not "T".
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
        return formatter
    }()

    fileprivate static func parseDate(_ raw: String) -> Date? {
        if let d = bshFormatter.date(from: raw) { return d }
        // Defensive: tolerate ISO-T variant if BSH ever switches.
        return isoFormatter.date(from: raw.replacingOccurrences(of: " ", with: "T"))
    }
}

// MARK: - Gauge mapping
//
// Not every harbour in the catalog has a BSH-published peak forecast.
// Juist (794P) and Baltrum (784P) only appear in the astronomical
// gezeiten.bsh.de feed, so we substitute the nearest neighbour that does
// have a `wasserstand-nordsee` entry. The UI shows a hint in that case.

extension HarbourOption {
    /// Pegel-ID (`bshnr`) used to fetch the manual peak forecast from
    /// `wasserstand-nordsee.bsh.de`. Falls back to the nearest neighbour
    /// for stations that the BSH does not publish a forecast for.
    var forecastBshNr: String {
        switch id {
        case "juist_harbor":     return "111P"   // Norderney
        case "baltrum_harbor":   return "781P"   // Langeoog
        default:                 return tideStationID
        }
    }

    /// Display name of the substitute gauge (nil if this harbour is its own gauge).
    var forecastSubstituteName: String? {
        switch id {
        case "juist_harbor":     return "Juist, Hafen"
        case "baltrum_harbor":   return "Baltrum, Westende"
        default:                 return nil
        }
    }

    /// Pegel-ID used to fetch the CONTINUOUS curve (astro + forecast +
    /// measurement). Only Group-1/2 stations publish the curve, so the
    /// Group-4 island gauges (Langeoog/Spiekeroog/Wangerooge) and the
    /// neighbour-substituted ones (Juist/Baltrum) point at the nearest
    /// curve-publishing station.
    var curveBshNr: String {
        switch id {
        case "borkum_harbor":     return "101P"  // own
        case "emden_harbor":      return "507P"  // own
        case "juist_harbor":      return "111P"  // Norderney
        case "norderney_harbor":  return "111P"  // own
        case "baltrum_harbor":    return "111P"  // Norderney (geographically closer than Wangerooge N)
        case "langeoog_harbor":   return "754P"  // Wangerooge Nord (Group 2 with curve)
        case "spiekeroog_harbor": return "754P"  // Wangerooge Nord
        case "wangerooge_harbor": return "754P"  // Wangerooge Nord
        default:                  return tideStationID
        }
    }

    /// Display name of the curve substitute (nil if this harbour's own
    /// gauge publishes a curve).
    var curveSubstituteName: String? {
        switch id {
        case "borkum_harbor", "emden_harbor", "norderney_harbor":
            return nil
        case "juist_harbor":      return "Norderney, Riffgat"
        case "baltrum_harbor":    return "Norderney, Riffgat"
        case "langeoog_harbor",
             "spiekeroog_harbor",
             "wangerooge_harbor":
            return "Wangerooge, Langes Riff (Nord)"
        default:                  return nil
        }
    }
}

// MARK: - Decoding

private struct BSHStationPayload: Decodable {
    let stationName: String?
    let bshnr: String?
    let mhwCm: Int?
    let mnwCm: Int?
    let pnpBelowNhnCm: String?    // BSH ships these as Int OR String — accept both
    let sknAbovePnpCm: String?
    let creationForecast: String?
    let hwnwForecast: BSHHwnwForecast?
    let curveForecast: BSHCurveForecast?

    enum CodingKeys: String, CodingKey {
        case stationName = "station_name"
        case bshnr
        case mhwCm = "MHW"
        case mnwCm = "MNW"
        case pnpBelowNhnCm = "PNP (unter NHN)"
        case sknAbovePnpCm = "SKN (ueber PNP)"
        case creationForecast = "creation_forecast"
        case hwnwForecast = "hwnw_forecast"
        case curveForecast = "curve_forecast"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stationName = try c.decodeIfPresent(String.self, forKey: .stationName)
        bshnr = try c.decodeIfPresent(String.self, forKey: .bshnr)
        mhwCm = try c.decodeIfPresent(Int.self, forKey: .mhwCm)
        mnwCm = try c.decodeIfPresent(Int.self, forKey: .mnwCm)
        pnpBelowNhnCm = Self.flexInt(in: c, forKey: .pnpBelowNhnCm)
        sknAbovePnpCm = Self.flexInt(in: c, forKey: .sknAbovePnpCm)
        creationForecast = try c.decodeIfPresent(String.self, forKey: .creationForecast)
        hwnwForecast = try c.decodeIfPresent(BSHHwnwForecast.self, forKey: .hwnwForecast)
        curveForecast = try c.decodeIfPresent(BSHCurveForecast.self, forKey: .curveForecast)
    }

    private static func flexInt(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let i = try? container.decode(Int.self, forKey: key) { return String(i) }
        if let d = try? container.decode(Double.self, forKey: key) { return String(Int(d)) }
        if let s = try? container.decode(String.self, forKey: key) { return s }
        return nil
    }
}

private struct BSHHwnwForecast: Decodable {
    let data: [BSHHwnwEvent]
}

private struct BSHHwnwEvent: Decodable {
    let timestamp: String
    let value: Int?
    let event: String
    let deviation: Double?
    let forecast: String?
    let warning: String?

    func event(sknAbovePnpMeters: Double) -> WaterLevelEvent? {
        guard let date = BSHWaterLevelForecastService.parseDate(timestamp),
              let value
        else { return nil }
        let cmAbovePnp = value
        let metresAboveSkn = Double(value) / 100 - sknAbovePnpMeters
        return WaterLevelEvent(
            time: date,
            type: event,
            cmAbovePnp: cmAbovePnp,
            metersAboveSkn: metresAboveSkn,
            deviationDm: deviation ?? 0,
            forecastText: forecast ?? "",
            warning: warning
        )
    }
}

private struct BSHCurveForecast: Decodable {
    let data: [BSHCurvePoint]
}

private struct BSHCurvePoint: Decodable {
    let timestamp: String
    let astro: Int?
    let forecast: Int?
    let measurement: Int?

    func point(sknAbovePnpMeters: Double) -> WaterLevelCurvePoint? {
        guard let date = BSHWaterLevelForecastService.parseDate(timestamp) else { return nil }
        return WaterLevelCurvePoint(
            time: date,
            astroMetersSkn: astro.map { Double($0) / 100 - sknAbovePnpMeters },
            forecastMetersSkn: forecast.map { Double($0) / 100 - sknAbovePnpMeters },
            measurementMetersSkn: measurement.map { Double($0) / 100 - sknAbovePnpMeters }
        )
    }
}

