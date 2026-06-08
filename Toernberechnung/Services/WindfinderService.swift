import Foundation

// MARK: - Wind Forecast Service
//
// Wind forecast for the harbour spots, sourced from the free, key-less
// Open-Meteo API (https://open-meteo.com). It returns hourly wind speed,
// gusts and direction as JSON — far more robust than the previous
// windfinder.com HTML scrape, which broke when Windfinder moved its data
// behind a client-side, authenticated API.
//
// The public type stays `WindfinderService` with the same `Reading` /
// `ForecastSlot` shape so the existing card + wiring are unchanged; only
// the data source switched.

actor WindfinderService {

    static let shared = WindfinderService()

    struct ForecastSlot: Equatable, Identifiable {
        let id = UUID()
        let time: Date
        let windKnots: Double
        let gustKnots: Double?
        let directionDegrees: Int?
    }

    struct Reading: Equatable {
        let spotID: String
        let fetchedAt: Date
        let slots: [ForecastSlot]
    }

    private var cache: [String: (Reading, Date)] = [:]
    private let cacheLifetime: TimeInterval = 60 * 60  // 1 hour

    // MARK: - Windfinder spot slugs (still used for the "open in Safari" link)

    static let defaultSpot: [String: String] = [
        "borkum_harbor":    "borkum",
        "emden_harbor":     "emden",
        "juist_harbor":     "juist",
        "norderney_harbor": "norderney",
        "baltrum_harbor":   "baltrum",
        "langeoog_harbor":  "langeoog",
        "spiekeroog_harbor":"spiekeroog",
        "wangerooge_harbor":"wangerooge"
    ]

    // MARK: - Public

    /// Hourly wind forecast for a coordinate. `spotID` is only a cache key.
    func forecast(latitude: Double, longitude: Double, spotID: String, force: Bool = false) async -> Reading? {
        if !force, let cached = cache[spotID],
           Date().timeIntervalSince(cached.1) < cacheLifetime {
            return cached.0
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            URLQueryItem(name: "wind_speed_unit", value: "kn"),
            URLQueryItem(name: "timezone", value: "Europe/Berlin"),
            URLQueryItem(name: "forecast_days", value: "3")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let slots = Self.parseSlots(data: data)
            guard !slots.isEmpty else { return nil }
            let reading = Reading(spotID: spotID, fetchedAt: Date(), slots: slots)
            cache[spotID] = (reading, Date())
            return reading
        } catch {
            return nil
        }
    }

    // MARK: - JSON parsing

    static func parseSlots(data: Data) -> [ForecastSlot] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String]
        else { return [] }

        let speeds = hourly["wind_speed_10m"] as? [Any] ?? []
        let gusts = hourly["wind_gusts_10m"] as? [Any] ?? []
        let directions = hourly["wind_direction_10m"] as? [Any] ?? []

        // Open-Meteo emits local times (timezone=Europe/Berlin) like
        // "2026-06-08T15:00" — no seconds, no offset.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        func number(_ array: [Any], _ index: Int) -> Double? {
            guard index < array.count else { return nil }
            return (array[index] as? NSNumber)?.doubleValue
        }

        let cutoff = Date().addingTimeInterval(-3600)
        var slots: [ForecastSlot] = []
        // Every 3rd hour keeps the horizontal card readable across 3 days.
        for index in stride(from: 0, to: times.count, by: 3) {
            guard let time = formatter.date(from: times[index]), time >= cutoff else { continue }
            slots.append(ForecastSlot(
                time: time,
                windKnots: number(speeds, index) ?? 0,
                gustKnots: number(gusts, index),
                directionDegrees: number(directions, index).map { Int($0.rounded()) }
            ))
        }
        return Array(slots.prefix(24))
    }
}
