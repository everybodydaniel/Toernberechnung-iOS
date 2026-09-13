import CoreLocation
import Foundation

struct WeatherAreaKey: Hashable, Codable, Sendable, Identifiable {
    static let gridVersion = 1
    static let cellSizeMeters = 10_000.0
    static let referenceLatitude = 54.0
    private static let metersPerDegreeLatitude = 111_320.0
    private static let metersPerDegreeLongitude = metersPerDegreeLatitude
        * cos(referenceLatitude * .pi / 180)

    let version: Int
    let x: Int
    let y: Int

    init(version: Int = WeatherAreaKey.gridVersion, x: Int, y: Int) {
        self.version = version
        self.x = x
        self.y = y
    }

    var id: String { "v\(version):\(x):\(y)" }

    var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (Double(y) + 0.5) * Self.cellSizeMeters / Self.metersPerDegreeLatitude,
            longitude: (Double(x) + 0.5) * Self.cellSizeMeters / Self.metersPerDegreeLongitude
        )
    }

    static func make(for coordinate: CLLocationCoordinate2D) -> WeatherAreaKey? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let xMeters = coordinate.longitude * metersPerDegreeLongitude
        let yMeters = coordinate.latitude * metersPerDegreeLatitude
        return WeatherAreaKey(
            x: Int(floor(xMeters / cellSizeMeters)),
            y: Int(floor(yMeters / cellSizeMeters))
        )
    }
}

extension CLLocationCoordinate2D {
    func maritimeWeatherArea() -> WeatherAreaKey? {
        WeatherAreaKey.make(for: self)
    }
}

enum MarineWeatherDataset: Hashable, Sendable {
    case current
    case hourly(DateInterval)
    case daily

    var kind: MarineWeatherProductKind {
        switch self {
        case .current: return .current
        case .hourly: return .hourly
        case .daily: return .daily
        }
    }
}

enum MarineWeatherProductKind: String, Codable, Hashable, Sendable {
    case current
    case hourly
    case daily
}

enum WeatherReadPolicy: Sendable {
    case cacheFirst
    case revalidateExpired
    case manualRetry
}

enum WeatherRefreshOutcome: Equatable, Sendable {
    case cacheHit(validUntil: Date)
    case refreshed(Set<MarineWeatherDataset>)
    case retryBlocked(until: Date)
}

struct MarineWeatherProductState: Equatable, Codable, Sendable {
    let fetchedAt: Date
    let validUntil: Date
    let isStale: Bool
}

enum MarineWeatherUnits {
    static func knots(fromMetersPerSecond value: Double) -> Double {
        Measurement(value: value, unit: UnitSpeed.metersPerSecond).converted(to: .knots).value
    }

    static func millimeters(fromMeters value: Double) -> Double {
        Measurement(value: value, unit: UnitLength.meters).converted(to: .millimeters).value
    }

    static func kilometers(fromMeters value: Double) -> Double {
        Measurement(value: value, unit: UnitLength.meters).converted(to: .kilometers).value
    }

    static func hectopascals(fromPascals value: Double) -> Double {
        Measurement(value: value, unit: UnitPressure.newtonsPerMetersSquared).converted(to: .hectopascals).value
    }
}

enum MarineWeatherSelection {
    static func hourlyWindow(
        _ forecasts: [MarineHourlyForecast],
        startingAt start: Date,
        count: Int = 48
    ) -> [MarineHourlyForecast] {
        Array(forecasts.filter { $0.date >= start }.sorted { $0.date < $1.date }.prefix(count))
    }

    static func dailyWindow(
        _ forecasts: [MarineDailyForecast],
        startingAt start: Date,
        count: Int = 7,
        calendar: Calendar = AppDateFormatters.berlinCalendar
    ) -> [MarineDailyForecast] {
        let dayStart = calendar.startOfDay(for: start)
        return Array(forecasts.filter { $0.date >= dayStart }.sorted { $0.date < $1.date }.prefix(count))
    }
}

struct MarineWind: Codable, Equatable, Sendable {
    let speedKnots: Double
    let gustKnots: Double?
    let directionDegrees: Int
    let compassDirection: String
    let compassDescription: String

    var effectiveGustKnots: Double { gustKnots ?? speedKnots }

    /// `arrow.down` rotated by this angle shows where the wind travels to.
    var flowArrowRotationDegrees: Double { Double(directionDegrees) }
}

struct MarineCurrentWeather: Codable, Equatable, Sendable {
    let date: Date
    let temperatureC: Double
    let apparentTemperatureC: Double
    let dewPointC: Double
    let condition: String
    let symbolName: String
    let humidityPercent: Int
    let pressureHPA: Double
    let pressureTrend: String
    let visibilityKM: Double
    let cloudCoverPercent: Int
    let uvIndex: Int
    let uvCategory: String
    let isDaylight: Bool
    let precipitationIntensityMMPerHour: Double
    let wind: MarineWind
}

struct MarineHourlyForecast: Identifiable, Codable, Equatable, Sendable {
    var id: Date { date }

    let date: Date
    let temperatureC: Double
    let apparentTemperatureC: Double
    let dewPointC: Double
    let condition: String
    let symbolName: String
    let humidityPercent: Int
    let pressureHPA: Double
    let pressureTrend: String
    let visibilityKM: Double
    let cloudCoverPercent: Int
    let uvIndex: Int
    let isDaylight: Bool
    let precipitationType: String
    let precipitationChance: Int
    let precipitationMM: Double
    let wind: MarineWind
}

struct MarinePrecipitationAmounts: Codable, Equatable, Sendable {
    let totalMM: Double
    let rainMM: Double
    let snowMM: Double
    let sleetMM: Double
    let hailMM: Double
    let mixedMM: Double
}

struct MarineDailyForecast: Identifiable, Codable, Equatable, Sendable {
    var id: Date { date }

    let date: Date
    let condition: String
    let symbolName: String
    let highTemperatureC: Double
    let highTemperatureTime: Date?
    let lowTemperatureC: Double
    let lowTemperatureTime: Date?
    let daytimeCondition: String
    let overnightCondition: String
    let daytimeWind: MarineWind
    let overnightWind: MarineWind
    let highWindKnots: Double?
    let precipitationType: String
    let precipitationChance: Int
    let precipitation: MarinePrecipitationAmounts
    let minimumHumidityPercent: Int
    let maximumHumidityPercent: Int
    let minimumVisibilityKM: Double
    let maximumVisibilityKM: Double
    let uvIndex: Int
    let uvCategory: String
    let sunrise: Date?
    let sunset: Date?
    let moonrise: Date?
    let moonset: Date?
    let moonPhase: String
    let moonSymbolName: String
}

struct MarineWeatherReport: Codable, Equatable, Sendable {
    let regionID: String
    let regionName: String
    let latitude: Double
    let longitude: Double
    let current: MarineCurrentWeather
    let hourly: [MarineHourlyForecast]
    let daily: [MarineDailyForecast]
    let fetchedAt: Date
    let sourceUpdatedAt: Date
    let isStale: Bool

    func hourlyForecast(nearest date: Date, tolerance: TimeInterval = 90 * 60) -> MarineHourlyForecast? {
        guard let closest = hourly.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }), abs(closest.date.timeIntervalSince(date)) <= tolerance else {
            return nil
        }
        return closest
    }

    func weatherForRiskAssessment(at departure: Date) -> MarineWeatherAssessment {
        if let hour = hourlyForecast(nearest: departure) {
            return MarineWeatherAssessment(
                windKnots: hour.wind.speedKnots,
                gustKnots: hour.wind.effectiveGustKnots,
                visibilityKM: hour.visibilityKM,
                precipitationChance: hour.precipitationChance,
                precipitationMM: hour.precipitationMM
            )
        }

        return MarineWeatherAssessment(
            windKnots: current.wind.speedKnots,
            gustKnots: current.wind.effectiveGustKnots,
            visibilityKM: current.visibilityKM,
            precipitationChance: 0,
            precipitationMM: current.precipitationIntensityMMPerHour
        )
    }
}

struct MarineWeatherAssessment: Codable, Equatable, Sendable {
    let windKnots: Double
    let gustKnots: Double
    let visibilityKM: Double
    let precipitationChance: Int
    let precipitationMM: Double
}

struct MarineWeatherAttribution: Codable, Equatable, Sendable {
    let serviceName: String
    let legalPageURL: URL
    let combinedMarkDarkURL: URL?
    let combinedMarkLightURL: URL?

    static let fallback = MarineWeatherAttribution(
        serviceName: "Apple Weather",
        legalPageURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
        combinedMarkDarkURL: nil,
        combinedMarkLightURL: nil
    )
}

enum MarineWeatherError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case noData
    case cancelled
    case invalidCoordinate
    case networkUnavailable
    case retryBlocked(Date)
    case incompleteRouteWeather
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "WeatherKit ist für diese App noch nicht freigeschaltet. Prüfe Capability, App ID und Provisioning Profile."
        case .noData:
            return "Apple Weather hat für diesen Ort gerade keine Vorhersagedaten geliefert."
        case .cancelled:
            return "Der Wetterabruf wurde abgebrochen."
        case .invalidCoordinate:
            return "Für diese Position können keine Wetterdaten geladen werden."
        case .networkUnavailable:
            return "Keine Netzwerkverbindung. Vorhandene Wetterdaten werden weiterhin offline angezeigt."
        case .retryBlocked(let date):
            return "Der nächste Wetterabruf ist ab \(AppDateFormatters.hourMinute.string(from: date)) möglich."
        case .incompleteRouteWeather:
            return "Nicht alle Seegebiete der Route konnten mit aktuellen Wetterdaten geprüft werden."
        case .unavailable:
            return "Apple Weather ist gerade nicht erreichbar. Bitte prüfe deine Verbindung und versuche es erneut."
        }
    }
}

struct MaritimeWeatherSnapshot: Equatable, Sendable {
    let areaKey: WeatherAreaKey
    let queryLatitude: Double
    let queryLongitude: Double
    let current: MarineCurrentWeather?
    let hourly: [MarineHourlyForecast]
    let daily: [MarineDailyForecast]
    let productStates: [MarineWeatherProductKind: MarineWeatherProductState]
    let refreshOutcome: WeatherRefreshOutcome

    var isStale: Bool {
        productStates.values.contains(where: \.isStale)
    }

    func report(for harbour: HarbourOption, startingAt start: Date = Date()) throws -> MarineWeatherReport {
        guard let current, !hourly.isEmpty, !daily.isEmpty else {
            throw MarineWeatherError.noData
        }
        return MarineWeatherReport(
            regionID: harbour.id,
            regionName: harbour.name,
            latitude: harbour.latitude,
            longitude: harbour.longitude,
            current: current,
            hourly: MarineWeatherSelection.hourlyWindow(hourly, startingAt: start),
            daily: MarineWeatherSelection.dailyWindow(daily, startingAt: start),
            fetchedAt: productStates.values.map(\.fetchedAt).max() ?? start,
            sourceUpdatedAt: current.date,
            isStale: isStale
        )
    }
}

struct MarineWeatherReportResult: Equatable, Sendable {
    let report: MarineWeatherReport
    let outcome: WeatherRefreshOutcome
}

struct RouteWeatherProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
}

struct RouteWeatherBatch: Equatable, Sendable {
    let departure: Date
    let snapshotsByArea: [WeatherAreaKey: MaritimeWeatherSnapshot]
    let areaKeysByWaypoint: [WeatherAreaKey]
}

enum RouteWeatherValidationState: Equatable, Sendable {
    case idle
    case loading(completed: Int, total: Int)
    case ready(status: WeatherStatus, batch: RouteWeatherBatch)
    case unavailable(message: String)
}
