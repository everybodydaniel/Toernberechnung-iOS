import Foundation

struct TideReading: Equatable {
    let stationName: String
    let stationID: String
    let fetchedAt: Date
    let events: [TideEvent]

    var summary: String {
        events.prefix(4).map { "\($0.type) \(Self.timeFormatter.string(from: $0.time)) \($0.heightText)" }
            .joined(separator: " | ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct TideEvent: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let heightMeters: Double?
    let type: String
    let phase: String?

    var symbol: String { type == "HW" ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
    var heightText: String {
        guard let heightMeters else { return "ohne Höhe" }
        return String(format: "%.2f m", heightMeters)
    }
}

enum BSHTideError: LocalizedError {
    case invalidURL
    case badResponse
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Die BSH-URL ist ungültig."
        case .badResponse: return "Das BSH hat keine Gezeitendaten zurückgegeben."
        case .emptyPayload: return "Für diesen Zeitraum wurden keine Gezeiten gefunden."
        }
    }
}

actor BSHTideService {
    static let shared = BSHTideService()

    private let baseURL = "https://gezeiten.bsh.de/data"
    private var cache: [String: (TideReading, Date)] = [:]
    private var eventCache: [String: ([TideEvent], Date)] = [:]
    private let cacheLifetime: TimeInterval = 12 * 3600

    func fetch(for harbour: HarbourOption, around date: Date = .now, force: Bool = false) async throws -> TideReading {
        let cacheKey = "\(harbour.tideStationID)-\(Calendar.current.component(.year, from: date))"
        if !force, let cached = cache[cacheKey], Date().timeIntervalSince(cached.1) < cacheLifetime {
            return cached.0
        }

        guard let url = URL(string: "\(baseURL)/DE_\(harbour.tideStationID.leftPadding(toLength: 5, withPad: "_"))_tides.json") else {
            throw BSHTideError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BSHTideError.badResponse
        }

        let payload = try JSONDecoder().decode(BSHTidePayload.self, from: data)
        let events = payload.events(around: date).filter { $0.time >= date }.prefix(8)
        guard !events.isEmpty else { throw BSHTideError.emptyPayload }

        let reading = TideReading(
            stationName: harbour.tideStationName,
            stationID: harbour.tideStationID,
            fetchedAt: .now,
            events: Array(events)
        )
        cache[cacheKey] = (reading, .now)
        return reading
    }

    func highWaters(for stationID: String, around date: Date, force: Bool = false) async throws -> [TideEvent] {
        let allEvents = try await yearlyEvents(for: stationID, around: date, force: force)
        let windowStart = date.addingTimeInterval(-14 * 3600)
        let windowEnd = date.addingTimeInterval(14 * 3600)

        return allEvents.filter {
            $0.type == "HW" && $0.time >= windowStart && $0.time <= windowEnd
        }
    }

    private func yearlyEvents(for stationID: String, around date: Date, force: Bool) async throws -> [TideEvent] {
        let cacheKey = "\(stationID)-\(Calendar.current.component(.year, from: date))"
        if !force, let cached = eventCache[cacheKey], Date().timeIntervalSince(cached.1) < cacheLifetime {
            return cached.0
        }

        guard let url = URL(string: "\(baseURL)/DE_\(stationID.leftPadding(toLength: 5, withPad: "_"))_tides.json") else {
            throw BSHTideError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BSHTideError.badResponse
        }

        let payload = try JSONDecoder().decode(BSHTidePayload.self, from: data)
        let events = payload.events(around: date)
        guard !events.isEmpty else { throw BSHTideError.emptyPayload }
        eventCache[cacheKey] = (events, .now)
        return events
    }
}

private struct BSHTidePayload: Decodable {
    let years: [String: BSHTideYear]

    enum CodingKeys: String, CodingKey {
        case years
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let dictionary = try? container.decode([String: BSHTideYear].self, forKey: .years) {
            years = dictionary
            return
        }

        // Manche BSH-Dateien liefern die Jahre als Array von Dictionaries; hier wird beides auf dieselbe Struktur normalisiert.
        let yearDictionaries = try container.decode([[String: BSHTideYear]].self, forKey: .years)
        years = yearDictionaries.reduce(into: [:]) { partialResult, yearDictionary in
            partialResult.merge(yearDictionary) { current, _ in current }
        }
    }

    func events(around date: Date) -> [TideEvent] {
        let targetYears = [Calendar.current.component(.year, from: date), Calendar.current.component(.year, from: date.addingTimeInterval(370 * 86400))]
        return targetYears
            .compactMap { years[String($0)] }
            .flatMap { $0.events }
            .sorted { $0.time < $1.time }
    }
}

private struct BSHTideYear: Decodable {
    let hwnwPrediction: BSHTidePrediction?
    let meanHighWaterCentimeters: Double?
    let meanLowWaterCentimeters: Double?

    enum CodingKeys: String, CodingKey {
        case hwnwPrediction = "hwnw_prediction"
        case meanHighWaterCentimeters = "MHW"
        case meanLowWaterCentimeters = "MNW"
    }

    var events: [TideEvent] {
        (hwnwPrediction?.data ?? [])
            .compactMap { rawEvent in
                rawEvent.event(
                    fallbackHighWaterCentimeters: meanHighWaterCentimeters,
                    fallbackLowWaterCentimeters: meanLowWaterCentimeters
                )
            }
    }
}

private struct BSHTidePrediction: Decodable {
    let data: [BSHTideRawEvent]
}

private struct BSHTideRawEvent: Decodable {
    let timestamp: String
    let height: Double?
    let type: String
    let phase: String?

    func event(fallbackHighWaterCentimeters: Double?, fallbackLowWaterCentimeters: Double?) -> TideEvent? {
        guard let date = Self.formatter.date(from: timestamp) else { return nil }
        let fallbackHeight = type == "HW" ? fallbackHighWaterCentimeters : fallbackLowWaterCentimeters
        let heightMeters = (height ?? fallbackHeight).map { $0 / 100 }
        return TideEvent(time: date, heightMeters: heightMeters, type: type, phase: phase)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
        return formatter
    }()
}

private extension String {
    func leftPadding(toLength: Int, withPad character: Character) -> String {
        if count >= toLength { return self }
        return String(repeating: String(character), count: toLength - count) + self
    }
}
