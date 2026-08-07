import Foundation

enum TideMovement: String, Codable, Sendable {
    case rising
    case falling
    case unknown

    var label: String {
        switch self {
        case .rising: return "Steigendes Wasser"
        case .falling: return "Fallendes Wasser"
        case .unknown: return "Tidenphase nicht bestimmt"
        }
    }

    var symbol: String {
        switch self {
        case .rising: return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .unknown: return "water.waves"
        }
    }
}

struct TideStationReference: Equatable, Sendable {
    let stationID: String
    let stationName: String
    let year: Int
    let kind: BSHTideStationKind
    let hasEventHeights: Bool
    let hasCurve: Bool
    let notices: [String]
    let chartDatumAboveGaugeZeroMeters: Double?
    let meanHighWaterAboveSknMeters: Double?
    let meanLowWaterAboveSknMeters: Double?
    let meanTidalRangeMeters: Double?
}

struct TideReading: Equatable, Sendable {
    let stationName: String
    let stationID: String
    let fetchedAt: Date
    let reference: TideStationReference
    let previousEvent: TideEvent?
    let events: [TideEvent]

    var nextEvent: TideEvent? { events.first }

    var summary: String {
        events.prefix(4).map { "\($0.type) \(Self.timeFormatter.string(from: $0.time)) \($0.heightText)" }
            .joined(separator: " | ")
    }

    func movement(at date: Date) -> TideMovement {
        guard let previousEvent, let nextEvent else { return .unknown }
        if previousEvent.type == "NW" && nextEvent.type == "HW" { return .rising }
        if previousEvent.type == "HW" && nextEvent.type == "NW" { return .falling }
        return .unknown
    }

    func progressToNextEvent(at date: Date) -> Double {
        guard let previousEvent, let nextEvent,
              nextEvent.time > previousEvent.time else { return 0.5 }
        let elapsed = date.timeIntervalSince(previousEvent.time)
        let duration = nextEvent.time.timeIntervalSince(previousEvent.time)
        return min(max(elapsed / duration, 0), 1)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppDateFormatters.germanLocale
        formatter.timeZone = AppDateFormatters.berlinTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct TideEvent: Identifiable, Equatable, Sendable {
    let time: Date
    /// Event-specific astronomical height above chart datum (SKN).
    /// Interpolated stations such as Juist and Baltrum intentionally return nil.
    let heightMeters: Double?
    let type: String
    let phase: String?

    var id: String { "\(time.timeIntervalSince1970)-\(type)" }
    var symbol: String { type == "HW" ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
    var heightText: String {
        guard let heightMeters else { return "Höhe nicht verfügbar" }
        return String(format: "%.2f m SKN", heightMeters)
    }
}

enum BSHTideError: LocalizedError {
    case invalidURL
    case unknownStation
    case badResponse
    case emptyPayload
    case yearUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Die BSH-Gezeiten-URL ist ungültig."
        case .unknownStation: return "Der gewählte BSH-Pegel ist nicht im Stationskatalog enthalten."
        case .badResponse: return "Das BSH hat keine gültigen Gezeitendaten zurückgegeben."
        case .emptyPayload: return "Für diesen Zeitraum wurden keine Gezeiten gefunden."
        case .yearUnavailable: return "Für das gewählte Kalenderjahr liegen noch keine BSH-Gezeiten vor."
        }
    }
}

actor BSHTideService {
    static let shared = BSHTideService()

    private struct CachedPayload {
        let payload: BSHTidePayload
        let fetchedAt: Date
    }

    private let baseURL = "https://gezeiten.bsh.de/data"
    private var cache: [String: CachedPayload] = [:]
    private let cacheLifetime: TimeInterval = 12 * 3_600

    func fetch(
        for harbour: HarbourOption,
        around date: Date = .now,
        force: Bool = false
    ) async throws -> TideReading {
        try await fetch(stationID: harbour.tideStationID, around: date, force: force)
    }

    func fetch(
        stationID: String,
        around date: Date = .now,
        force: Bool = false
    ) async throws -> TideReading {
        guard let station = BSHTideStationCatalog.station(id: stationID) else {
            throw BSHTideError.unknownStation
        }
        let payload = try await payload(for: stationID, force: force)
        return try Self.makeReading(
            payload: payload,
            station: station,
            around: date,
            fetchedAt: .now
        )
    }

    static func decodeReading(
        data: Data,
        stationID: String,
        around date: Date,
        fetchedAt: Date = .now
    ) throws -> TideReading {
        guard let station = BSHTideStationCatalog.station(id: stationID) else {
            throw BSHTideError.unknownStation
        }
        let payload: BSHTidePayload
        do {
            payload = try JSONDecoder().decode(BSHTidePayload.self, from: data)
        } catch {
            throw BSHTideError.badResponse
        }
        return try makeReading(
            payload: payload,
            station: station,
            around: date,
            fetchedAt: fetchedAt
        )
    }

    private static func makeReading(
        payload: BSHTidePayload,
        station: BSHTideStation,
        around date: Date,
        fetchedAt: Date
    ) throws -> TideReading {
        guard let reference = payload.reference(for: station, around: date) else {
            throw BSHTideError.yearUnavailable
        }

        let allEvents = payload.events(around: date)
        let previous = allEvents.last { $0.time < date }
        let upcoming = Array(allEvents.filter { $0.time >= date }.prefix(8))
        guard !upcoming.isEmpty else { throw BSHTideError.emptyPayload }

        return TideReading(
            stationName: payload.stationName ?? station.name,
            stationID: station.id,
            fetchedAt: fetchedAt,
            reference: reference,
            previousEvent: previous,
            events: upcoming
        )
    }

    func reference(
        for stationID: String,
        around date: Date,
        force: Bool = false
    ) async throws -> TideStationReference? {
        guard let station = BSHTideStationCatalog.station(id: stationID) else { return nil }
        let payload = try await payload(for: stationID, force: force)
        return payload.reference(for: station, around: date)
    }

    func highWaters(
        for stationID: String,
        around date: Date,
        force: Bool = false
    ) async throws -> [TideEvent] {
        let allEvents = try await payload(for: stationID, force: force).events(around: date)
        let windowStart = date.addingTimeInterval(-14 * 3_600)
        let windowEnd = date.addingTimeInterval(14 * 3_600)
        return allEvents.filter {
            $0.type == "HW" && $0.time >= windowStart && $0.time <= windowEnd
        }
    }

    private func payload(for stationID: String, force: Bool) async throws -> BSHTidePayload {
        if !force, let cached = cache[stationID],
           Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.payload
        }

        let paddedID = stationID.leftPadding(toLength: 5, withPad: "_")
        guard let url = URL(string: "\(baseURL)/DE_\(paddedID)_tides.json") else {
            throw BSHTideError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw BSHTideError.badResponse
        }

        let decoded: BSHTidePayload
        do {
            decoded = try JSONDecoder().decode(BSHTidePayload.self, from: data)
        } catch {
            throw BSHTideError.badResponse
        }
        cache[stationID] = CachedPayload(payload: decoded, fetchedAt: .now)
        return decoded
    }
}

private struct BSHTidePayload: Decodable {
    let bshNumber: String?
    let stationName: String?
    let years: [String: BSHTideYear]

    enum CodingKeys: String, CodingKey {
        case bshNumber = "bshnr"
        case stationName = "station_name"
        case years
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bshNumber = try container.decodeIfPresent(String.self, forKey: .bshNumber)
        stationName = try container.decodeIfPresent(String.self, forKey: .stationName)
        if let dictionary = try? container.decode([String: BSHTideYear].self, forKey: .years) {
            years = dictionary
        } else {
            let dictionaries = try container.decode([[String: BSHTideYear]].self, forKey: .years)
            years = dictionaries.reduce(into: [:]) { result, dictionary in
                result.merge(dictionary) { current, _ in current }
            }
        }
    }

    func reference(for station: BSHTideStation, around date: Date) -> TideStationReference? {
        let year = AppDateFormatters.berlinCalendar.component(.year, from: date)
        guard let values = years[String(year)] else { return nil }
        return values.reference(for: station, year: year)
    }

    func events(around date: Date) -> [TideEvent] {
        let calendar = AppDateFormatters.berlinCalendar
        let year = calendar.component(.year, from: date)
        return [year - 1, year, year + 1]
            .compactMap { years[String($0)] }
            .flatMap(\.events)
            .sorted { $0.time < $1.time }
    }
}

private struct BSHTideYear: Decodable {
    let prediction: BSHTidePrediction?
    let levelTidalValues: String?
    let meanHighWaterCentimeters: Double?
    let meanLowWaterCentimeters: Double?
    let meanTidalRangeCentimeters: Double?
    let chartDatumAboveGaugeZeroCentimeters: Double?
    let chartDatumBelowNHNCentimeters: Double?
    let notices: [String]
    let hasHeight: Bool
    let hasCurve: Bool

    enum CodingKeys: String, CodingKey {
        case prediction = "hwnw_prediction"
        case levelTidalValues = "level_tidalvalues"
        case meanHighWaterCentimeters = "MHW"
        case meanLowWaterCentimeters = "MNW"
        case meanTidalRangeCentimeters = "MTH"
        case chartDatumAboveGaugeZeroCentimeters = "SKN (ueber PNP)"
        case chartDatumBelowNHNCentimeters = "SKN (unter NHN)"
        case notices = "notice"
        case hasHeight = "has_height"
        case hasCurve = "has_curve"
    }

    var events: [TideEvent] {
        (prediction?.data ?? []).compactMap { rawEvent in
            rawEvent.event(
                level: prediction?.level,
                chartDatumAboveGaugeZeroCentimeters: chartDatumAboveGaugeZeroCentimeters,
                chartDatumBelowNHNCentimeters: chartDatumBelowNHNCentimeters
            )
        }
    }

    func reference(for station: BSHTideStation, year: Int) -> TideStationReference {
        TideStationReference(
            stationID: station.id,
            stationName: station.name,
            year: year,
            kind: station.kind,
            hasEventHeights: hasHeight,
            hasCurve: hasCurve,
            notices: notices,
            chartDatumAboveGaugeZeroMeters: chartDatumAboveGaugeZeroCentimeters.map { $0 / 100 },
            meanHighWaterAboveSknMeters: heightAboveSkn(meanHighWaterCentimeters, level: levelTidalValues),
            meanLowWaterAboveSknMeters: heightAboveSkn(meanLowWaterCentimeters, level: levelTidalValues),
            meanTidalRangeMeters: meanTidalRangeCentimeters.map { $0 / 100 }
        )
    }

    private func heightAboveSkn(_ value: Double?, level: String?) -> Double? {
        guard let value else { return nil }
        switch level?.uppercased() {
        case "SKN":
            return value / 100
        case "NHN":
            guard let chartDatumBelowNHNCentimeters else { return nil }
            return (value - chartDatumBelowNHNCentimeters) / 100
        default:
            guard let chartDatumAboveGaugeZeroCentimeters else { return nil }
            return (value - chartDatumAboveGaugeZeroCentimeters) / 100
        }
    }
}

private struct BSHTidePrediction: Decodable {
    let level: String?
    let data: [BSHTideRawEvent]
}

private struct BSHTideRawEvent: Decodable {
    let timestamp: String
    let height: Double?
    let type: String
    let phase: String?

    func event(
        level: String?,
        chartDatumAboveGaugeZeroCentimeters: Double?,
        chartDatumBelowNHNCentimeters: Double?
    ) -> TideEvent? {
        guard let date = BSHDateParser.date(from: timestamp) else { return nil }

        let heightMeters: Double?
        if let height {
            switch level?.uppercased() {
            case "SKN":
                heightMeters = height / 100
            case "NHN":
                heightMeters = chartDatumBelowNHNCentimeters.map { (height - $0) / 100 }
            default:
                heightMeters = chartDatumAboveGaugeZeroCentimeters.map { (height - $0) / 100 }
            }
        } else {
            heightMeters = nil
        }

        return TideEvent(time: date, heightMeters: heightMeters, type: type, phase: phase)
    }
}

enum BSHDateParser {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(from raw: String) -> Date? {
        if let value = formatter.date(from: raw) { return value }
        if let value = isoFormatter.date(from: raw.replacingOccurrences(of: " ", with: "T")) { return value }
        let fallback = ISO8601DateFormatter()
        return fallback.date(from: raw.replacingOccurrences(of: " ", with: "T"))
    }
}

private extension String {
    func leftPadding(toLength: Int, withPad character: Character) -> String {
        guard count < toLength else { return self }
        return String(repeating: String(character), count: toLength - count) + self
    }
}
