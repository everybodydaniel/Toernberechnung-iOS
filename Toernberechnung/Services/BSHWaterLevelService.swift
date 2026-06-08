import Foundation

// MARK: - BSH Wasserstand Service
//
// Fetches live water-level deviation ("BSH-Wasserstand") from the BSH
// "Wasserstandsvorhersagen Nordsee" portal.
//
// Source: https://wasserstand-nordsee.bsh.de
// The site publishes per-station JSON time series under `/data/<gauge>.json`
// containing live measurements plus astronomical reference. The deviation
// (measured − astronomical) is exactly the +/- value that the calculation engine
// uses for the BSH water-level correction ("BSH-Wasserstand:  (+/- m)").
//
// The service is best-effort: if the BSH portal is unreachable or returns
// an unfamiliar payload, the call resolves to `nil` (so the route engine
// falls back to the user-set correction or 0.0).

actor BSHWaterLevelService {

    static let shared = BSHWaterLevelService()

    private let baseURL = "https://wasserstand.bsh.de/data"
    private var cache: [String: (value: Double, fetchedAt: Date)] = [:]
    private let cacheLifetime: TimeInterval = 30 * 60  // 30 minutes

    // MARK: - Public API

    /// Fetch the current water-level deviation (m) for the given gauge,
    /// closest to `referenceTime`. Returns nil on any failure.
    func deviation(
        forGaugeID gaugeID: String,
        at referenceTime: Date = .now,
        force: Bool = false
    ) async -> Double? {
        let key = "\(gaugeID)-\(Int(referenceTime.timeIntervalSince1970) / 3600)"
        if !force, let cached = cache[key],
           Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.value
        }

        guard let bshNr = bshNr(forGaugeID: gaugeID) else {
            return nil
        }

        let urls = [
            URL(string: "\(baseURL)/nordsee/DE__\(bshNr).json")!,
            URL(string: "\(baseURL)/ostsee/DE__\(bshNr).json")!
        ]

        for url in urls {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continue
                }

                let payload = try JSONDecoder().decode(BSHLivePayload.self, from: data)
                guard let points = payload.curveForecast?.data, !points.isEmpty else {
                    continue
                }

                var bestPoint: BSHLiveCurvePoint?
                var minDiff: TimeInterval = .greatestFiniteMagnitude

                for point in points {
                    guard let date = Self.parseDate(point.timestamp),
                          let val = point.deviationMeters else { continue }
                    let diff = abs(date.timeIntervalSince(referenceTime))
                    if diff < minDiff {
                        minDiff = diff
                        bestPoint = point
                    }
                }

                if let val = bestPoint?.deviationMeters {
                    cache[key] = (val, Date())
                    return val
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private func bshNr(forGaugeID gaugeID: String) -> String? {
        switch gaugeID {
        case "borkum":        return "101P"
        case "emden":         return "507P"
        case "norderney":     return "111P"
        case "helgoland":     return "509A"
        case "wilhelmshaven": return "512P"
        default:              return nil
        }
    }

    // MARK: - Date helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let bshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
        return formatter
    }()

    private static func parseDate(_ raw: String) -> Date? {
        if let d = bshFormatter.date(from: raw) { return d }
        return isoFormatter.date(from: raw.replacingOccurrences(of: " ", with: "T"))
    }
}

// MARK: - Decoding structs

private struct BSHLivePayload: Decodable {
    let curveForecast: BSHLiveCurveForecast?

    enum CodingKeys: String, CodingKey {
        case curveForecast = "curve_forecast"
    }
}

private struct BSHLiveCurveForecast: Decodable {
    let data: [BSHLiveCurvePoint]
}

private struct BSHLiveCurvePoint: Decodable {
    let timestamp: String
    let astro: Int?
    let curveforecast: Int?
    let measurement: Int?

    var deviationMeters: Double? {
        guard let astro = astro else { return nil }
        if let measurement = measurement {
            return Double(measurement - astro) / 100.0
        } else if let curveforecast = curveforecast {
            return Double(curveforecast - astro) / 100.0
        }
        return nil
    }
}

// MARK: - Default gauge mapping for catalog harbours.
//
// Used by the RoutePlannerViewModel to pick a sensible default gauge when
// the user has not entered a manual BSH-Wasserstand value.

enum BSHGauge: String {
    case borkum    = "borkum"
    case emden     = "emden"
    case norderney = "norderney"
    case helgoland = "helgoland"
    case wilhelmshaven = "wilhelmshaven"

    static func defaultGauge(forHarbourID harbourID: String) -> BSHGauge {
        switch harbourID {
        case "borkum_harbor":     return .borkum
        case "emden_harbor":      return .emden
        case "juist_harbor":      return .norderney
        case "norderney_harbor":  return .norderney
        case "baltrum_harbor":    return .norderney
        case "langeoog_harbor":   return .helgoland
        case "spiekeroog_harbor": return .helgoland
        case "wangerooge_harbor": return .wilhelmshaven
        default:                  return .norderney
        }
    }
}
