import Foundation
import ZIPFoundation

// MARK: - DWD-Wetter- und Hafen-Auswahl mit fest hinterlegten Inseln

struct HarbourOption: Identifiable, Hashable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let chartDepth: Double
    let weatherStationID: String
    let weatherStationName: String
    let tideStationID: String
    let tideStationName: String

    static let options: [HarbourOption] = [
        .init(
            id: "borkum_harbor", name: "Borkum, Fischerbalje",
            latitude: 53.5606, longitude: 6.7502, chartDepth: 3.0,
            weatherStationID: "K1083", weatherStationName: "BORKUM",
            tideStationID: "101P", tideStationName: "Borkum, Fischerbalje"
        ),
        .init(
            id: "emden_harbor", name: "Emden, Hafen",
            latitude: 53.3421, longitude: 7.1852, chartDepth: 5.0,
            weatherStationID: "10203", weatherStationName: "EMDEN",
            tideStationID: "507P", tideStationName: "Emden, Große Seeschleuse"
        ),
        .init(
            id: "juist_harbor", name: "Juist, Hafen",
            latitude: 53.6722, longitude: 6.9982, chartDepth: 1.8,
            weatherStationID: "E5307", weatherStationName: "OSTFR. KUESTE",
            tideStationID: "794P", tideStationName: "Juist, Hafen"
        ),
        .init(
            id: "norderney_harbor", name: "Norderney, Hafen",
            latitude: 53.7024, longitude: 7.1637, chartDepth: 2.5,
            weatherStationID: "10113", weatherStationName: "NORDERNEY",
            tideStationID: "111P", tideStationName: "Norderney, Riffgat"
        ),
        .init(
            id: "baltrum_harbor", name: "Baltrum, Hafen",
            latitude: 53.7229, longitude: 7.3669, chartDepth: 1.2,
            weatherStationID: "E5344", weatherStationName: "BALTRUM",
            tideStationID: "784P", tideStationName: "Baltrum, Westende"
        ),
        .init(
            id: "langeoog_harbor", name: "Langeoog, Hafen",
            latitude: 53.7263, longitude: 7.4968, chartDepth: 1.5,
            weatherStationID: "E025", weatherStationName: "DORNUM",
            tideStationID: "781P", tideStationName: "Langeoog, Hafeneinfahrt"
        ),
        .init(
            id: "spiekeroog_harbor", name: "Spiekeroog, Hafen",
            latitude: 53.7632, longitude: 7.6955, chartDepth: 1.0,
            weatherStationID: "E031", weatherStationName: "SPIEKEROOG (SWN)",
            tideStationID: "779P", tideStationName: "Spiekeroog"
        ),
        .init(
            id: "wangerooge_harbor", name: "Wangerooge, Hafen",
            latitude: 53.7755, longitude: 7.8683, chartDepth: 1.4,
            weatherStationID: "E5408", weatherStationName: "WANGEROOGE",
            tideStationID: "777P", tideStationName: "Wangerooge, Hafen"
        )
    ]

    static func byID(_ id: String) -> HarbourOption {
        options.first(where: { $0.id == id }) ?? options[0]
    }

    var coordinate: (latitude: Double, longitude: Double) { (latitude, longitude) }

    func distanceNM(to other: HarbourOption) -> Double {
        let earthRadiusNM = 3440.065
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusNM * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

struct WeatherReading: Equatable {
    let regionName: String
    let stationID: String
    let stationName: String
    let issuedAt: Date?
    let sourceUpdatedAt: Date?
    let fetchedAt: Date
    let current: WeatherSlot
    let upcoming: [WeatherSlot]
    let daily: [DailyWeatherSummary]

    var dataTimestamp: Date {
        sourceUpdatedAt ?? issuedAt ?? fetchedAt
    }

    var dataAge: TimeInterval {
        Date().timeIntervalSince(dataTimestamp)
    }

    var isFresh: Bool {
        dataAge < 8 * 60 * 60
    }
}

struct WeatherSlot: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let temperatureC: Double
    let feelsLikeC: Double
    let dewPointC: Double?
    let windKnots: Double
    let windGustKnots: Double?
    let windDirection: Int
    let precipitationChance: Int
    let precipitationMM: Double
    let humidityPercent: Int?
    let pressureHPA: Double?
    let visibilityKM: Double?
    let cloudCoverPercent: Int?
    let condition: String
    let icon: String
}

struct DailyWeatherSummary: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let minTemperatureC: Double
    let maxTemperatureC: Double
    let precipitationMM: Double
    let precipitationChance: Int
    let condition: String
    let icon: String
}

enum DWDCompactError: LocalizedError {
    case invalidURL
    case badResponse
    case emptyPayload
    case unreadableArchive
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Die DWD-URL ist ungültig."
        case .badResponse: return "Der Deutsche Wetterdienst hat keine Daten zurückgegeben."
        case .emptyPayload: return "Es wurden keine kompakten Wetterwerte gefunden."
        case .unreadableArchive: return "Das DWD-KMZ konnte nicht gelesen werden."
        case .parseFailed(let detail): return "Die DWD-Antwort konnte nicht verarbeitet werden: \(detail)"
        }
    }
}

actor DWDCompactService {
    static let shared = DWDCompactService()

    private let baseURL = "https://opendata.dwd.de/weather/local_forecasts/mos/MOSMIX_L/single_stations"
    private var cache: [String: (WeatherReading, Date)] = [:]
    private let cacheLifetime: TimeInterval = 1800

    func fetch(for harbour: HarbourOption, force: Bool = false) async throws -> WeatherReading {
        if !force, let cached = cache[harbour.id], Date().timeIntervalSince(cached.1) < cacheLifetime {
            return cached.0
        }

        let source = try await fetchKMZ(stationID: harbour.weatherStationID)
        let payload = try parseKMZ(source.data, regionID: harbour.id)
        let reading = try makeReading(from: payload, harbour: harbour, sourceUpdatedAt: source.lastModified)
        cache[harbour.id] = (reading, .now)
        return reading
    }

    private func fetchKMZ(stationID: String) async throws -> (data: Data, lastModified: Date?) {
        let fileName = "MOSMIX_L_LATEST_\(stationID).kmz"
        guard let url = URL(string: "\(baseURL)/\(stationID)/kml/\(fileName)") else {
            throw DWDCompactError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DWDCompactError.badResponse
        }
        return (data, httpResponse.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDateFormatter.date(from:)))
    }

    private func parseKMZ(_ kmz: Data, regionID: String) throws -> Payload {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("dwd-\(regionID)-\(UUID().uuidString).kmz")
        try kmz.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read, pathEncoding: nil)
        } catch {
            throw DWDCompactError.unreadableArchive
        }
        guard let entry = archive.first(where: { $0.path.hasSuffix(".kml") }) else {
            throw DWDCompactError.unreadableArchive
        }

        var xmlData = Data()
        _ = try archive.extract(entry) { xmlData.append($0) }

        let parser = MOSMIXParser()
        let xmlParser = XMLParser(data: xmlData)
        xmlParser.delegate = parser
        guard xmlParser.parse() else {
            throw DWDCompactError.parseFailed(xmlParser.parserError?.localizedDescription ?? "Unbekannter Parserfehler")
        }
        guard !parser.payload.timeSteps.isEmpty else {
            throw DWDCompactError.emptyPayload
        }
        return parser.payload
    }

    private func makeReading(from payload: Payload, harbour: HarbourOption, sourceUpdatedAt: Date?) throws -> WeatherReading {
        let slots = payload.timeSteps.enumerated().compactMap { index, time -> WeatherSlot? in
            guard let tempKelvin = payload.value(named: "TTT", at: index),
                  let windMS = payload.value(named: "FF", at: index) else { return nil }
            let tempC = tempKelvin - 273.15
            let dewPointC = payload.value(named: "Td", at: index).map { $0 - 273.15 }
            let windKnots = windMS * 1.943844
            let gustKnots = payload.value(named: "FX1", at: index).map { $0 * 1.943844 }
            let direction = Int((payload.value(named: "DD", at: index) ?? 0).rounded())
            let precipitationChance = probability(payload.value(named: "R101", at: index))
            let precipitationMM = max(payload.value(named: "RR1c", at: index) ?? 0, 0)
            let humidity = dewPointC.map { relativeHumidity(temperatureC: tempC, dewPointC: $0) }
            let pressure = pressureHPA(payload.value(named: "PPPP", at: index))
            let visibility = visibilityKM(payload.value(named: "VV", at: index))
            let cloudCover = cloudCoverPercent(payload.value(named: "N", at: index) ?? payload.value(named: "Neff", at: index))
            let code = Int((payload.value(named: "ww", at: index) ?? 0).rounded())
            let condition = conditionName(code: code, cloudCoverPercent: cloudCover, precipitationMM: precipitationMM)
            return WeatherSlot(
                time: time,
                temperatureC: tempC,
                feelsLikeC: feelsLike(temperatureC: tempC, windMS: windMS),
                dewPointC: dewPointC,
                windKnots: windKnots,
                windGustKnots: gustKnots,
                windDirection: direction,
                precipitationChance: precipitationChance,
                precipitationMM: precipitationMM,
                humidityPercent: humidity,
                pressureHPA: pressure,
                visibilityKM: visibility,
                cloudCoverPercent: cloudCover,
                condition: condition,
                icon: conditionIcon(code: code, tempC: tempC, cloudCoverPercent: cloudCover, precipitationMM: precipitationMM)
            )
        }

        guard let current = slots.min(by: { abs($0.time.timeIntervalSinceNow) < abs($1.time.timeIntervalSinceNow) }) else {
            throw DWDCompactError.emptyPayload
        }
        let upcoming = slots.filter { $0.time >= current.time }.prefix(12)
        return WeatherReading(
            regionName: harbour.name,
            stationID: harbour.weatherStationID,
            stationName: harbour.weatherStationName,
            issuedAt: payload.issueTime,
            sourceUpdatedAt: sourceUpdatedAt,
            fetchedAt: .now,
            current: current,
            upcoming: Array(upcoming),
            daily: dailySummaries(from: slots)
        )
    }

    private func dailySummaries(from slots: [WeatherSlot]) -> [DailyWeatherSummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: slots.filter { $0.time >= calendar.startOfDay(for: .now) }) {
            calendar.startOfDay(for: $0.time)
        }

        return grouped.keys.sorted().prefix(7).compactMap { day in
            guard let daySlots = grouped[day], !daySlots.isEmpty else { return nil }
            let dominant = daySlots.max { lhs, rhs in
                score(lhs) < score(rhs)
            } ?? daySlots[0]

            return DailyWeatherSummary(
                date: day,
                minTemperatureC: daySlots.map(\.temperatureC).min() ?? dominant.temperatureC,
                maxTemperatureC: daySlots.map(\.temperatureC).max() ?? dominant.temperatureC,
                precipitationMM: daySlots.map(\.precipitationMM).reduce(0, +),
                precipitationChance: daySlots.map(\.precipitationChance).max() ?? 0,
                condition: dominant.condition,
                icon: dominant.icon
            )
        }
    }

    private func score(_ slot: WeatherSlot) -> Double {
        Double(slot.precipitationChance) + slot.precipitationMM * 20 + Double(slot.cloudCoverPercent ?? 0) * 0.2
    }

    private func conditionName(code: Int, cloudCoverPercent: Int?, precipitationMM: Double) -> String {
        switch code {
        case 45, 48: return "Nebel"
        case 51...67, 80...82: return "Regen"
        case 71...77, 85, 86: return "Schnee"
        case 95...99: return "Gewitter"
        case 1...3: return "Wolkig"
        default:
            if precipitationMM >= 0.2 { return "Regen" }
            if let cloudCoverPercent, cloudCoverPercent >= 75 { return "Bedeckt" }
            if let cloudCoverPercent, cloudCoverPercent >= 35 { return "Wolkig" }
            return "Sonnig"
        }
    }

    private func conditionIcon(code: Int, tempC: Double, cloudCoverPercent: Int?, precipitationMM: Double) -> String {
        switch code {
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        case 1...3: return "cloud.sun.fill"
        default:
            if precipitationMM >= 0.2 { return "cloud.rain.fill" }
            if let cloudCoverPercent, cloudCoverPercent >= 75 { return "cloud.fill" }
            if let cloudCoverPercent, cloudCoverPercent >= 35 { return "cloud.sun.fill" }
            return tempC > 0 ? "sun.max.fill" : "cloud.sun.fill"
        }
    }

    private func probability(_ value: Double?) -> Int {
        guard let value else { return 0 }
        return min(max(Int(value.rounded()), 0), 100)
    }

    private func pressureHPA(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return value > 2_000 ? value / 100 : value
    }

    private func visibilityKM(_ value: Double?) -> Double? {
        guard let value, value >= 0 else { return nil }
        return value > 100 ? value / 1_000 : value
    }

    private func cloudCoverPercent(_ value: Double?) -> Int? {
        guard let value else { return nil }
        let percent = value <= 8 ? value * 12.5 : value
        return min(max(Int(percent.rounded()), 0), 100)
    }

    private func relativeHumidity(temperatureC: Double, dewPointC: Double) -> Int {
        let saturation = exp((17.625 * temperatureC) / (243.04 + temperatureC))
        let actual = exp((17.625 * dewPointC) / (243.04 + dewPointC))
        return min(max(Int(((actual / saturation) * 100).rounded()), 0), 100)
    }

    private func feelsLike(temperatureC: Double, windMS: Double) -> Double {
        let windKPH = windMS * 3.6
        guard temperatureC <= 10, windKPH > 4.8 else { return temperatureC }
        return 13.12 + 0.6215 * temperatureC - 11.37 * pow(windKPH, 0.16) + 0.3965 * temperatureC * pow(windKPH, 0.16)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}

private struct Payload {
    var issueTime: Date?
    var timeSteps: [Date] = []
    var values: [String: [String]] = [:]

    func value(named parameter: String, at index: Int) -> Double? {
        guard let bucket = values[parameter], bucket.indices.contains(index) else { return nil }
        let raw = bucket[index]
        if raw == "-" { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }
}

private final class MOSMIXParser: NSObject, XMLParserDelegate {
    private let isoFormatter = ISO8601DateFormatter()
    private var activeParameter: String?
    private var buffer = ""
    private var insidePlacemark = false

    fileprivate var payload = Payload()

    override init() {
        super.init()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        buffer = ""
        if name == "kml:Placemark" { insidePlacemark = true }
        if name == "dwd:Forecast" { activeParameter = attributeDict["dwd:elementName"] ?? attributeDict["elementName"] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "dwd:IssueTime":
            payload.issueTime = parseDate(trimmed)
        case "dwd:TimeStep":
            if let date = parseDate(trimmed) { payload.timeSteps.append(date) }
        case "dwd:value":
            if let activeParameter {
                payload.values[activeParameter] = trimmed.split(separator: " ").map(String.init)
            }
        case "dwd:Forecast":
            activeParameter = nil
        case "kml:Placemark":
            insidePlacemark = false
        default:
            break
        }

        if !insidePlacemark { buffer = "" }
    }

    private func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? {
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            return fallback.date(from: string)
        }()
    }
}
