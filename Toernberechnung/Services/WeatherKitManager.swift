import CoreLocation
import Foundation
import Network
import WeatherKit

// This file contains the shared cache, WeatherKit adapter, and route batching actor.
// swiftlint:disable file_length

protocol MarineWeatherClient: Sendable {
    func fetch(
        at location: CLLocation,
        datasets: Set<MarineWeatherDataset>,
        now: Date
    ) async throws -> WeatherFetchPayload
    func attribution() async throws -> MarineWeatherAttribution
}

struct WeatherFetchedValue<Value: Sendable>: Sendable {
    let value: Value
    let fetchedAt: Date
    let sourceUpdatedAt: Date
    let sourceExpiresAt: Date
}

struct WeatherFetchedHourlyValue: Sendable {
    let value: [MarineHourlyForecast]
    let interval: DateInterval
    let fetchedAt: Date
    let sourceUpdatedAt: Date
    let sourceExpiresAt: Date
}

struct WeatherFetchPayload: Sendable {
    var current: WeatherFetchedValue<MarineCurrentWeather>?
    var hourly: WeatherFetchedHourlyValue?
    var daily: WeatherFetchedValue<[MarineDailyForecast]>?

    static let empty = WeatherFetchPayload(current: nil, hourly: nil, daily: nil)
}

struct AppleWeatherClient: MarineWeatherClient {
    private let service = WeatherService.shared

    func fetch(
        at location: CLLocation,
        datasets: Set<MarineWeatherDataset>,
        now: Date
    ) async throws -> WeatherFetchPayload {
        let calendar = AppDateFormatters.berlinCalendar
        let hourlyInterval = datasets.compactMap { dataset -> DateInterval? in
            guard case .hourly(let interval) = dataset else { return nil }
            return interval
        }.first
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 8, to: dayStart)
            ?? dayStart.addingTimeInterval(8 * 86_400)
        let wantsCurrent = datasets.contains(where: { $0.kind == .current })
        let wantsHourly = hourlyInterval != nil
        let wantsDaily = datasets.contains(where: { $0.kind == .daily })

        switch (wantsCurrent, wantsHourly, wantsDaily) {
        case (true, true, true):
            guard let hourlyInterval else { throw MarineWeatherError.noData }
            let (current, hourly, daily) = try await service.weather(
                for: location,
                including: .current,
                .hourly(startDate: hourlyInterval.start, endDate: hourlyInterval.end),
                .daily(startDate: dayStart, endDate: dayEnd)
            )
            return WeatherFetchPayload(
                current: currentPayload(current, now: now),
                hourly: hourlyPayload(hourly, interval: hourlyInterval, now: now),
                daily: dailyPayload(daily, now: now)
            )
        case (true, true, false):
            guard let hourlyInterval else { throw MarineWeatherError.noData }
            let (current, hourly) = try await service.weather(
                for: location,
                including: .current,
                .hourly(startDate: hourlyInterval.start, endDate: hourlyInterval.end)
            )
            return WeatherFetchPayload(
                current: currentPayload(current, now: now),
                hourly: hourlyPayload(hourly, interval: hourlyInterval, now: now),
                daily: nil
            )
        case (true, false, true):
            let (current, daily) = try await service.weather(
                for: location,
                including: .current,
                .daily(startDate: dayStart, endDate: dayEnd)
            )
            return WeatherFetchPayload(
                current: currentPayload(current, now: now),
                hourly: nil,
                daily: dailyPayload(daily, now: now)
            )
        case (false, true, true):
            guard let hourlyInterval else { throw MarineWeatherError.noData }
            let (hourly, daily) = try await service.weather(
                for: location,
                including: .hourly(startDate: hourlyInterval.start, endDate: hourlyInterval.end),
                .daily(startDate: dayStart, endDate: dayEnd)
            )
            return WeatherFetchPayload(
                current: nil,
                hourly: hourlyPayload(hourly, interval: hourlyInterval, now: now),
                daily: dailyPayload(daily, now: now)
            )
        case (true, false, false):
            let current = try await service.weather(for: location, including: .current)
            return WeatherFetchPayload(current: currentPayload(current, now: now), hourly: nil, daily: nil)
        case (false, true, false):
            guard let hourlyInterval else { throw MarineWeatherError.noData }
            let hourly = try await service.weather(
                for: location,
                including: .hourly(startDate: hourlyInterval.start, endDate: hourlyInterval.end)
            )
            return WeatherFetchPayload(
                current: nil,
                hourly: hourlyPayload(hourly, interval: hourlyInterval, now: now),
                daily: nil
            )
        case (false, false, true):
            let daily = try await service.weather(
                for: location,
                including: .daily(startDate: dayStart, endDate: dayEnd)
            )
            return WeatherFetchPayload(current: nil, hourly: nil, daily: dailyPayload(daily, now: now))
        case (false, false, false):
            return .empty
        }
    }

    func attribution() async throws -> MarineWeatherAttribution {
        let attribution = try await service.attribution
        return MarineWeatherAttribution(
            serviceName: attribution.serviceName,
            legalPageURL: attribution.legalPageURL,
            combinedMarkDarkURL: attribution.combinedMarkDarkURL,
            combinedMarkLightURL: attribution.combinedMarkLightURL
        )
    }

    private func currentPayload(_ weather: CurrentWeather, now: Date) -> WeatherFetchedValue<MarineCurrentWeather> {
        WeatherFetchedValue(
            value: Self.makeCurrent(weather),
            fetchedAt: now,
            sourceUpdatedAt: weather.metadata.date,
            sourceExpiresAt: weather.metadata.expirationDate
        )
    }

    private func hourlyPayload(
        _ weather: Forecast<HourWeather>,
        interval: DateInterval,
        now: Date
    ) -> WeatherFetchedHourlyValue {
        WeatherFetchedHourlyValue(
            value: weather.forecast.map(Self.makeHourly),
            interval: interval,
            fetchedAt: now,
            sourceUpdatedAt: weather.metadata.date,
            sourceExpiresAt: weather.metadata.expirationDate
        )
    }

    private func dailyPayload(
        _ weather: Forecast<DayWeather>,
        now: Date
    ) -> WeatherFetchedValue<[MarineDailyForecast]> {
        WeatherFetchedValue(
            value: weather.forecast.map(Self.makeDaily),
            fetchedAt: now,
            sourceUpdatedAt: weather.metadata.date,
            sourceExpiresAt: weather.metadata.expirationDate
        )
    }

    private static func makeCurrent(_ weather: CurrentWeather) -> MarineCurrentWeather {
        MarineCurrentWeather(
            date: weather.date,
            temperatureC: celsius(weather.temperature),
            apparentTemperatureC: celsius(weather.apparentTemperature),
            dewPointC: celsius(weather.dewPoint),
            condition: conditionText(weather.condition),
            symbolName: weather.symbolName,
            humidityPercent: percent(weather.humidity),
            pressureHPA: MarineWeatherUnits.hectopascals(
                fromPascals: weather.pressure.converted(to: .newtonsPerMetersSquared).value
            ),
            pressureTrend: pressureTrendText(weather.pressureTrend),
            visibilityKM: MarineWeatherUnits.kilometers(fromMeters: weather.visibility.converted(to: .meters).value),
            cloudCoverPercent: percent(weather.cloudCover),
            uvIndex: weather.uvIndex.value,
            uvCategory: uvText(weather.uvIndex.category),
            isDaylight: weather.isDaylight,
            precipitationIntensityMMPerHour: weather.precipitationIntensity.converted(to: .metersPerSecond).value * 3_600_000,
            wind: makeWind(weather.wind)
        )
    }

    private static func makeHourly(_ weather: HourWeather) -> MarineHourlyForecast {
        MarineHourlyForecast(
            date: weather.date,
            temperatureC: celsius(weather.temperature),
            apparentTemperatureC: celsius(weather.apparentTemperature),
            dewPointC: celsius(weather.dewPoint),
            condition: conditionText(weather.condition),
            symbolName: weather.symbolName,
            humidityPercent: percent(weather.humidity),
            pressureHPA: MarineWeatherUnits.hectopascals(
                fromPascals: weather.pressure.converted(to: .newtonsPerMetersSquared).value
            ),
            pressureTrend: pressureTrendText(weather.pressureTrend),
            visibilityKM: MarineWeatherUnits.kilometers(fromMeters: weather.visibility.converted(to: .meters).value),
            cloudCoverPercent: percent(weather.cloudCover),
            uvIndex: weather.uvIndex.value,
            isDaylight: weather.isDaylight,
            precipitationType: precipitationText(weather.precipitation),
            precipitationChance: percent(weather.precipitationChance),
            precipitationMM: MarineWeatherUnits.millimeters(fromMeters: weather.precipitationAmount.converted(to: .meters).value),
            wind: makeWind(weather.wind)
        )
    }

    private static func makeDaily(_ weather: DayWeather) -> MarineDailyForecast {
        let amounts = weather.precipitationAmountByType
        return MarineDailyForecast(
            date: weather.date,
            condition: conditionText(weather.condition),
            symbolName: weather.symbolName,
            highTemperatureC: celsius(weather.highTemperature),
            highTemperatureTime: weather.highTemperatureTime,
            lowTemperatureC: celsius(weather.lowTemperature),
            lowTemperatureTime: weather.lowTemperatureTime,
            daytimeCondition: conditionText(weather.daytimeForecast.condition),
            overnightCondition: conditionText(weather.overnightForecast.condition),
            daytimeWind: makeWind(weather.daytimeForecast.wind),
            overnightWind: makeWind(weather.overnightForecast.wind),
            highWindKnots: weather.highWindSpeed?.converted(to: .knots).value,
            precipitationType: precipitationText(weather.precipitation),
            precipitationChance: percent(weather.precipitationChance),
            precipitation: MarinePrecipitationAmounts(
                totalMM: MarineWeatherUnits.millimeters(fromMeters: amounts.precipitation.converted(to: .meters).value),
                rainMM: MarineWeatherUnits.millimeters(fromMeters: amounts.rainfall.converted(to: .meters).value),
                snowMM: MarineWeatherUnits.millimeters(fromMeters: amounts.snowfallAmount.amountLiquidEquivalent.converted(to: .meters).value),
                sleetMM: MarineWeatherUnits.millimeters(fromMeters: amounts.sleet.converted(to: .meters).value),
                hailMM: MarineWeatherUnits.millimeters(fromMeters: amounts.hail.converted(to: .meters).value),
                mixedMM: MarineWeatherUnits.millimeters(fromMeters: amounts.mixed.converted(to: .meters).value)
            ),
            minimumHumidityPercent: percent(weather.minimumHumidity),
            maximumHumidityPercent: percent(weather.maximumHumidity),
            minimumVisibilityKM: weather.minimumVisibility / 1_000,
            maximumVisibilityKM: weather.maximumVisibility / 1_000,
            uvIndex: weather.uvIndex.value,
            uvCategory: uvText(weather.uvIndex.category),
            sunrise: weather.sun.sunrise,
            sunset: weather.sun.sunset,
            moonrise: weather.moon.moonrise,
            moonset: weather.moon.moonset,
            moonPhase: moonText(weather.moon.phase),
            moonSymbolName: weather.moon.phase.symbolName
        )
    }

    static func makeWind(_ wind: Wind) -> MarineWind {
        let degrees = normalizedDegrees(wind.direction.converted(to: .degrees).value)
        return MarineWind(
            speedKnots: MarineWeatherUnits.knots(fromMetersPerSecond: wind.speed.converted(to: .metersPerSecond).value),
            gustKnots: wind.gust.map {
                MarineWeatherUnits.knots(fromMetersPerSecond: $0.converted(to: .metersPerSecond).value)
            },
            directionDegrees: degrees,
            compassDirection: compassAbbreviation(for: degrees),
            compassDescription: compassDescription(for: degrees)
        )
    }

    static func normalizedDegrees(_ value: Double) -> Int {
        let rounded = Int(value.rounded()) % 360
        return rounded >= 0 ? rounded : rounded + 360
    }

    static func compassAbbreviation(for degrees: Int) -> String {
        let labels = [
            "N", "NNO", "NO", "ONO", "O", "OSO", "SO", "SSO",
            "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
        ]
        let normalized = ((degrees % 360) + 360) % 360
        return labels[Int((Double(normalized) / 22.5).rounded()) % 16]
    }

    static func compassDescription(for degrees: Int) -> String {
        let descriptions = [
            "Nord", "Nordnordost", "Nordost", "Ostnordost",
            "Ost", "Ostsüdost", "Südost", "Südsüdost",
            "Süd", "Südsüdwest", "Südwest", "Westsüdwest",
            "West", "Westnordwest", "Nordwest", "Nordnordwest"
        ]
        let normalized = ((degrees % 360) + 360) % 360
        return descriptions[Int((Double(normalized) / 22.5).rounded()) % 16]
    }

    private static func celsius(_ value: Measurement<UnitTemperature>) -> Double {
        value.converted(to: .celsius).value
    }

    private static func percent(_ value: Double) -> Int {
        min(max(Int((value * 100).rounded()), 0), 100)
    }

    private static func conditionText(_ condition: WeatherCondition) -> String {
        conditionNames[condition] ?? condition.description
    }

    private static let conditionNames: [WeatherCondition: String] = [
        .blizzard: "Schneesturm",
        .blowingDust: "Staub",
        .blowingSnow: "Schneetreiben",
        .breezy: "Windig",
        .clear: "Klar",
        .cloudy: "Bewölkt",
        .drizzle: "Nieselregen",
        .flurries: "Schneeschauer",
        .foggy: "Nebel",
        .freezingDrizzle: "Gefrierender Nieselregen",
        .freezingRain: "Gefrierender Regen",
        .frigid: "Sehr kalt",
        .hail: "Hagel",
        .haze: "Dunst",
        .heavyRain: "Starker Regen",
        .heavySnow: "Starker Schneefall",
        .hot: "Heiß",
        .hurricane: "Orkan",
        .isolatedThunderstorms: "Einzelne Gewitter",
        .mostlyClear: "Überwiegend klar",
        .mostlyCloudy: "Überwiegend bewölkt",
        .partlyCloudy: "Teilweise bewölkt",
        .rain: "Regen",
        .scatteredThunderstorms: "Örtliche Gewitter",
        .sleet: "Schneeregen",
        .smoky: "Rauchig",
        .snow: "Schnee",
        .strongStorms: "Starke Gewitter",
        .sunFlurries: "Sonnige Schneeschauer",
        .sunShowers: "Sonnige Regenschauer",
        .thunderstorms: "Gewitter",
        .tropicalStorm: "Tropischer Sturm",
        .windy: "Stürmisch",
        .wintryMix: "Winterlicher Mix"
    ]

    private static func precipitationText(_ precipitation: Precipitation) -> String {
        switch precipitation {
        case .none: return "Kein Niederschlag"
        case .hail: return "Hagel"
        case .mixed: return "Gemischt"
        case .rain: return "Regen"
        case .sleet: return "Schneeregen"
        case .snow: return "Schnee"
        @unknown default: return precipitation.description
        }
    }

    private static func pressureTrendText(_ trend: PressureTrend) -> String {
        switch trend {
        case .rising: return "steigend"
        case .falling: return "fallend"
        case .steady: return "gleichbleibend"
        @unknown default: return trend.description
        }
    }

    private static func uvText(_ category: UVIndex.ExposureCategory) -> String {
        switch category {
        case .low: return "Niedrig"
        case .moderate: return "Mäßig"
        case .high: return "Hoch"
        case .veryHigh: return "Sehr hoch"
        case .extreme: return "Extrem"
        @unknown default: return category.description
        }
    }

    private static func moonText(_ phase: MoonPhase) -> String {
        switch phase {
        case .new: return "Neumond"
        case .waxingCrescent: return "Zunehmende Sichel"
        case .firstQuarter: return "Erstes Viertel"
        case .waxingGibbous: return "Zunehmender Mond"
        case .full: return "Vollmond"
        case .waningGibbous: return "Abnehmender Mond"
        case .lastQuarter: return "Letztes Viertel"
        case .waningCrescent: return "Abnehmende Sichel"
        @unknown default: return phase.description
        }
    }
}

struct ResilientMarineWeatherClient: MarineWeatherClient {
    private let primary: any MarineWeatherClient
    private let fallback: any MarineWeatherClient

    init(
        primary: any MarineWeatherClient = AppleWeatherClient(),
        fallback: any MarineWeatherClient = BrightSkyWeatherClient()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    func fetch(
        at location: CLLocation,
        datasets: Set<MarineWeatherDataset>,
        now: Date
    ) async throws -> WeatherFetchPayload {
        do {
            let result = try await primary.fetch(at: location, datasets: datasets, now: now)
            let wantsCurrent = datasets.contains(where: { $0.kind == .current })
            let wantsHourly = datasets.contains(where: { $0.kind == .hourly })
            if (wantsCurrent && result.current == nil) || (wantsHourly && result.hourly == nil) {
                return try await fallback.fetch(at: location, datasets: datasets, now: now)
            }
            return result
        } catch {
            return try await fallback.fetch(at: location, datasets: datasets, now: now)
        }
    }

    func attribution() async throws -> MarineWeatherAttribution {
        if let attr = try? await primary.attribution() {
            return attr
        }
        return try await fallback.attribution()
    }
}

/// BrightSky weather service for open DWD (Deutscher Wetterdienst) weather data.
/// Provides reliable marine forecasts, wind speed, gusts, and wind direction without requiring WeatherKit entitlements.
struct BrightSkyWeatherClient: MarineWeatherClient {
    private let session: URLSession
    private static let baseURL = "https://api.brightsky.dev"
    private static let kmhPerKnot = 1.852

    init(session: URLSession = .shared) {
        self.session = session
    }

    func attribution() async throws -> MarineWeatherAttribution {
        MarineWeatherAttribution(
            serviceName: "DWD via Bright Sky",
            legalPageURL: URL(string: "https://brightsky.dev")!,
            combinedMarkDarkURL: nil,
            combinedMarkLightURL: nil
        )
    }

    func fetch(
        at location: CLLocation,
        datasets: Set<MarineWeatherDataset>,
        now: Date
    ) async throws -> WeatherFetchPayload {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        let calendar = AppDateFormatters.berlinCalendar
        let hourlyInterval = datasets.compactMap { dataset -> DateInterval? in
            guard case .hourly(let interval) = dataset else { return nil }
            return interval
        }.first

        let wantsCurrent = datasets.contains(where: { $0.kind == .current })
        let wantsHourly = hourlyInterval != nil
        let wantsDaily = datasets.contains(where: { $0.kind == .daily })

        var currentWeather: WeatherFetchedValue<MarineCurrentWeather>?
        var hourlyWeather: WeatherFetchedHourlyValue?
        var dailyWeather: WeatherFetchedValue<[MarineDailyForecast]>?

        // 1. Fetch current weather if needed
        if wantsCurrent {
            if let current = try? await fetchCurrent(lat: lat, lon: lon, now: now) {
                currentWeather = current
            }
        }

        // 2. Fetch forecast if hourly or daily needed
        if wantsHourly || wantsDaily {
            let start = hourlyInterval?.start ?? now
            let end = hourlyInterval?.end ?? calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86400)
            let (hourlyList, dailyList) = try await fetchForecast(lat: lat, lon: lon, start: start, end: end, now: now)

            if wantsHourly, let interval = hourlyInterval {
                hourlyWeather = WeatherFetchedHourlyValue(
                    value: hourlyList,
                    interval: interval,
                    fetchedAt: now,
                    sourceUpdatedAt: now,
                    sourceExpiresAt: now.addingTimeInterval(3600)
                )
            }

            if wantsDaily {
                dailyWeather = WeatherFetchedValue(
                    value: dailyList,
                    fetchedAt: now,
                    sourceUpdatedAt: now,
                    sourceExpiresAt: now.addingTimeInterval(7200)
                )
            }

            // If current was requested but direct call had failed, derive from nearest hourly
            if wantsCurrent && currentWeather == nil, let first = hourlyList.first {
                currentWeather = WeatherFetchedValue(
                    value: currentFromHourly(first),
                    fetchedAt: now,
                    sourceUpdatedAt: now,
                    sourceExpiresAt: now.addingTimeInterval(1800)
                )
            }
        }

        guard currentWeather != nil || hourlyWeather != nil || dailyWeather != nil else {
            throw MarineWeatherError.noData
        }

        return WeatherFetchPayload(
            current: currentWeather,
            hourly: hourlyWeather,
            daily: dailyWeather
        )
    }

    // MARK: - API Calls

    private func fetchCurrent(lat: Double, lon: Double, now: Date) async throws -> WeatherFetchedValue<MarineCurrentWeather> {
        let urlString = String(format: "%@/current_weather?lat=%.4f&lon=%.4f", locale: Locale(identifier: "en_US_POSIX"), Self.baseURL, lat, lon)
        guard let url = URL(string: urlString) else { throw MarineWeatherError.invalidCoordinate }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw MarineWeatherError.noData
        }

        let dto = try JSONDecoder().decode(BrightSkyCurrentResponse.self, from: data)
        guard let item = dto.weather else { throw MarineWeatherError.noData }

        let parsedDate = ISO8601DateFormatter().date(from: item.timestamp ?? "") ?? now
        let current = makeMarineCurrentWeather(from: item, date: parsedDate)

        return WeatherFetchedValue(
            value: current,
            fetchedAt: now,
            sourceUpdatedAt: parsedDate,
            sourceExpiresAt: now.addingTimeInterval(1800)
        )
    }

    private func fetchForecast(
        lat: Double, lon: Double, start: Date, end: Date, now: Date
    ) async throws -> ([MarineHourlyForecast], [MarineDailyForecast]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = AppDateFormatters.berlinTimeZone

        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)

        let urlString = String(format: "%@/weather?lat=%.4f&lon=%.4f&date=%@&last_date=%@", locale: Locale(identifier: "en_US_POSIX"), Self.baseURL, lat, lon, startStr, endStr)
        guard let url = URL(string: urlString) else { throw MarineWeatherError.invalidCoordinate }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw MarineWeatherError.noData
        }

        let dto = try JSONDecoder().decode(BrightSkyForecastResponse.self, from: data)
        guard let items = dto.weather, !items.isEmpty else {
            throw MarineWeatherError.noData
        }

        let isoFormatter = ISO8601DateFormatter()
        var hourly: [MarineHourlyForecast] = []
        for item in items {
            guard let ts = item.timestamp, let date = isoFormatter.date(from: ts) else { continue }
            hourly.append(makeMarineHourlyForecast(from: item, date: date))
        }

        let daily = makeDailyForecasts(from: hourly)
        return (hourly, daily)
    }

    // MARK: - Mapping Helpers

    private func makeMarineWind(speedKmh: Double?, gustKmh: Double?, directionDegrees: Int?) -> MarineWind {
        let speedKnots = (speedKmh ?? 0.0) / Self.kmhPerKnot
        let gustKnots = gustKmh.map { $0 / Self.kmhPerKnot }
        let degrees = directionDegrees ?? 0
        let normalized = ((degrees % 360) + 360) % 360

        return MarineWind(
            speedKnots: speedKnots,
            gustKnots: gustKnots,
            directionDegrees: normalized,
            compassDirection: AppleWeatherClient.compassAbbreviation(for: normalized),
            compassDescription: AppleWeatherClient.compassDescription(for: normalized)
        )
    }

    private func makeMarineCurrentWeather(from item: BrightSkyWeatherItem, date: Date) -> MarineCurrentWeather {
        let wind = makeMarineWind(
            speedKmh: item.windSpeed10 ?? item.windSpeed,
            gustKmh: item.windGustSpeed10 ?? item.windGustSpeed,
            directionDegrees: item.windDirection10 ?? item.windDirection
        )
        let temp = item.temperature ?? 15.0
        let hour = AppDateFormatters.berlinCalendar.component(.hour, from: date)
        let isDaylight = hour >= 6 && hour <= 21

        return MarineCurrentWeather(
            date: date,
            temperatureC: temp,
            apparentTemperatureC: temp,
            dewPointC: item.dewPoint ?? (temp - 4.0),
            condition: conditionName(for: item.condition, icon: item.icon),
            symbolName: symbolName(for: item.icon, isDaylight: isDaylight),
            humidityPercent: item.relativeHumidity ?? 75,
            pressureHPA: item.pressureMsl ?? 1013.25,
            pressureTrend: "Gleichbleibend",
            visibilityKM: Double(item.visibility ?? 10000) / 1000.0,
            cloudCoverPercent: item.cloudCover ?? 50,
            uvIndex: isDaylight ? 3 : 0,
            uvCategory: "Mittel",
            isDaylight: isDaylight,
            precipitationIntensityMMPerHour: item.precipitation ?? 0.0,
            wind: wind
        )
    }

    private func makeMarineHourlyForecast(from item: BrightSkyWeatherItem, date: Date) -> MarineHourlyForecast {
        let wind = makeMarineWind(
            speedKmh: item.windSpeed,
            gustKmh: item.windGustSpeed,
            directionDegrees: item.windDirection
        )
        let temp = item.temperature ?? 15.0
        let hour = AppDateFormatters.berlinCalendar.component(.hour, from: date)
        let isDaylight = hour >= 6 && hour <= 21
        let precipMM = item.precipitation ?? 0.0

        return MarineHourlyForecast(
            date: date,
            temperatureC: temp,
            apparentTemperatureC: temp,
            dewPointC: item.dewPoint ?? (temp - 4.0),
            condition: conditionName(for: item.condition, icon: item.icon),
            symbolName: symbolName(for: item.icon, isDaylight: isDaylight),
            humidityPercent: item.relativeHumidity ?? 75,
            pressureHPA: item.pressureMsl ?? 1013.25,
            pressureTrend: "Gleichbleibend",
            visibilityKM: Double(item.visibility ?? 10000) / 1000.0,
            cloudCoverPercent: item.cloudCover ?? 50,
            uvIndex: isDaylight ? 3 : 0,
            isDaylight: isDaylight,
            precipitationType: precipMM > 0 ? "Regen" : "Keiner",
            precipitationChance: item.precipitationProbability ?? (precipMM > 0 ? 80 : 10),
            precipitationMM: precipMM,
            wind: wind
        )
    }

    private func currentFromHourly(_ hourly: MarineHourlyForecast) -> MarineCurrentWeather {
        MarineCurrentWeather(
            date: hourly.date,
            temperatureC: hourly.temperatureC,
            apparentTemperatureC: hourly.apparentTemperatureC,
            dewPointC: hourly.dewPointC,
            condition: hourly.condition,
            symbolName: hourly.symbolName,
            humidityPercent: hourly.humidityPercent,
            pressureHPA: hourly.pressureHPA,
            pressureTrend: hourly.pressureTrend,
            visibilityKM: hourly.visibilityKM,
            cloudCoverPercent: hourly.cloudCoverPercent,
            uvIndex: hourly.uvIndex,
            uvCategory: "Mittel",
            isDaylight: hourly.isDaylight,
            precipitationIntensityMMPerHour: hourly.precipitationMM,
            wind: hourly.wind
        )
    }

    private func makeDailyForecasts(from hourly: [MarineHourlyForecast]) -> [MarineDailyForecast] {
        let calendar = AppDateFormatters.berlinCalendar
        let grouped = Dictionary(grouping: hourly) { calendar.startOfDay(for: $0.date) }

        return grouped.keys.sorted().map { dayStart in
            let dayHours = grouped[dayStart] ?? []
            let temps = dayHours.map(\.temperatureC)
            let high = temps.max() ?? 15.0
            let low = temps.min() ?? 10.0
            let middayHour = dayHours.min(by: { abs(calendar.component(.hour, from: $0.date) - 13) < abs(calendar.component(.hour, from: $1.date) - 13) })
            let midnightHour = dayHours.min(by: { abs(calendar.component(.hour, from: $0.date) - 1) < abs(calendar.component(.hour, from: $1.date) - 1) })

            let rep = middayHour ?? dayHours.first!
            let totalPrecip = dayHours.reduce(0.0) { $0 + $1.precipitationMM }
            let maxWind = dayHours.map(\.wind.speedKnots).max()

            return MarineDailyForecast(
                date: dayStart,
                condition: rep.condition,
                symbolName: rep.symbolName,
                highTemperatureC: high,
                highTemperatureTime: dayHours.first(where: { $0.temperatureC == high })?.date,
                lowTemperatureC: low,
                lowTemperatureTime: dayHours.first(where: { $0.temperatureC == low })?.date,
                daytimeCondition: rep.condition,
                overnightCondition: midnightHour?.condition ?? rep.condition,
                daytimeWind: rep.wind,
                overnightWind: midnightHour?.wind ?? rep.wind,
                highWindKnots: maxWind,
                precipitationType: totalPrecip > 0 ? "Regen" : "Keiner",
                precipitationChance: dayHours.map(\.precipitationChance).max() ?? 0,
                precipitation: MarinePrecipitationAmounts(
                    totalMM: totalPrecip,
                    rainMM: totalPrecip,
                    snowMM: 0,
                    sleetMM: 0,
                    hailMM: 0,
                    mixedMM: 0
                ),
                minimumHumidityPercent: dayHours.map(\.humidityPercent).min() ?? 60,
                maximumHumidityPercent: dayHours.map(\.humidityPercent).max() ?? 90,
                minimumVisibilityKM: dayHours.map(\.visibilityKM).min() ?? 10.0,
                maximumVisibilityKM: dayHours.map(\.visibilityKM).max() ?? 25.0,
                uvIndex: 3,
                uvCategory: "Mittel",
                sunrise: calendar.date(bySettingHour: 6, minute: 30, second: 0, of: dayStart),
                sunset: calendar.date(bySettingHour: 19, minute: 45, second: 0, of: dayStart),
                moonrise: nil,
                moonset: nil,
                moonPhase: "Zunehmend",
                moonSymbolName: "moonphase.waxing.crescent"
            )
        }
    }

    private func conditionName(for condition: String?, icon: String?) -> String {
        switch icon {
        case "clear-day", "clear-night": return "Klar"
        case "partly-cloudy-day", "partly-cloudy-night": return "Leicht bewölkt"
        case "cloudy": return "Bewölkt"
        case "fog": return "Nebel"
        case "wind": return "Windig"
        case "rain": return "Regen"
        case "sleet": return "Schneeregen"
        case "snow": return "Schnee"
        case "hail": return "Hagel"
        case "thunderstorm": return "Gewitter"
        default:
            switch condition {
            case "dry": return "Trocken"
            case "rain": return "Regen"
            case "fog": return "Nebel"
            case "snow": return "Schnee"
            default: return "Heiter"
            }
        }
    }

    private func symbolName(for icon: String?, isDaylight: Bool) -> String {
        switch icon {
        case "clear-day": return "sun.max.fill"
        case "clear-night": return "moon.stars.fill"
        case "partly-cloudy-day": return "cloud.sun.fill"
        case "partly-cloudy-night": return "cloud.moon.fill"
        case "cloudy": return "cloud.fill"
        case "fog": return "cloud.fog.fill"
        case "wind": return "wind"
        case "rain": return "cloud.rain.fill"
        case "sleet": return "cloud.sleet.fill"
        case "snow": return "cloud.snow.fill"
        case "hail": return "cloud.hail.fill"
        case "thunderstorm": return "cloud.bolt.rain.fill"
        default: return isDaylight ? "sun.max.fill" : "moon.fill"
        }
    }
}

private struct BrightSkyCurrentResponse: Codable {
    let weather: BrightSkyWeatherItem?
}

private struct BrightSkyForecastResponse: Codable {
    let weather: [BrightSkyWeatherItem]?
}

private struct BrightSkyWeatherItem: Codable {
    let timestamp: String?
    let temperature: Double?
    let dewPoint: Double?
    let relativeHumidity: Int?
    let pressureMsl: Double?
    let visibility: Int?
    let cloudCover: Int?
    let precipitation: Double?
    let precipitationProbability: Int?
    let condition: String?
    let icon: String?
    let windSpeed: Double?
    let windDirection: Int?
    let windGustSpeed: Double?
    let windSpeed10: Double?
    let windDirection10: Int?
    let windGustSpeed10: Double?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case temperature
        case dewPoint = "dew_point"
        case relativeHumidity = "relative_humidity"
        case pressureMsl = "pressure_msl"
        case visibility
        case cloudCover = "cloud_cover"
        case precipitation
        case precipitationProbability = "precipitation_probability"
        case condition
        case icon
        case windSpeed = "wind_speed"
        case windDirection = "wind_direction"
        case windGustSpeed = "wind_gust_speed"
        case windSpeed10 = "wind_speed_10"
        case windDirection10 = "wind_direction_10"
        case windGustSpeed10 = "wind_gust_speed_10"
    }
}

struct WeatherCacheConfiguration: Equatable, Sendable {
    var currentTTL: TimeInterval = 40 * 60
    var hourlyTTL: TimeInterval = 2.5 * 3_600
    var dailyTTL: TimeInterval = 12 * 3_600
    var currentMaximumAge: TimeInterval = 2 * 3_600
    var hourlyMaximumAge: TimeInterval = 6 * 3_600
    var dailyMaximumAge: TimeInterval = 24 * 3_600
    var maximumAreas = 128

    static let maritime = WeatherCacheConfiguration()
}

private struct CachedWeatherValue<Value>: Codable, Equatable, Sendable
where Value: Codable & Equatable & Sendable {
    let value: Value
    let fetchedAt: Date
    let sourceUpdatedAt: Date
    let sourceExpiresAt: Date
}

private struct CachedHourlyWeatherValue: Codable, Equatable, Sendable {
    let value: [MarineHourlyForecast]
    let interval: DateInterval
    let fetchedAt: Date
    let sourceUpdatedAt: Date
    let sourceExpiresAt: Date

    var cacheKey: String {
        "\(Int64(interval.start.timeIntervalSince1970)):\(Int64(interval.end.timeIntervalSince1970))"
    }
}

private struct WeatherAreaCacheRecord: Codable, Equatable, Sendable {
    let areaKey: WeatherAreaKey
    var current: CachedWeatherValue<MarineCurrentWeather>?
    var hourly: [String: CachedHourlyWeatherValue]
    var daily: CachedWeatherValue<[MarineDailyForecast]>?
    var lastAccessedAt: Date
    var accessSequence: UInt64? = nil
}

private struct WeatherCacheEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let records: [WeatherAreaCacheRecord]
}

struct WeatherCacheLookup: Sendable {
    let snapshot: MaritimeWeatherSnapshot
    let staleDatasets: Set<MarineWeatherDataset>
    let missingDatasets: Set<MarineWeatherDataset>

    var datasetsNeedingRefresh: Set<MarineWeatherDataset> { staleDatasets.union(missingDatasets) }
}

actor WeatherCacheManager {
    private let configuration: WeatherCacheConfiguration
    private let fileURL: URL?
    private var records: [WeatherAreaKey: WeatherAreaCacheRecord] = [:]
    private var accessCounter: UInt64 = 0
    private var didLoad = false

    init(
        configuration: WeatherCacheConfiguration = .maritime,
        fileURL: URL? = WeatherCacheManager.defaultCacheURL()
    ) {
        self.configuration = configuration
        self.fileURL = fileURL
    }

    nonisolated static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("TideNode", isDirectory: true)
            .appendingPathComponent("Weather", isDirectory: true)
            .appendingPathComponent("weather-cache-v1.json", isDirectory: false)
    }

    func prepare(now: Date = Date()) {
        ensureLoaded(now: now)
    }

    func lookup(
        areaKey: WeatherAreaKey,
        datasets: Set<MarineWeatherDataset>,
        now: Date
    ) -> WeatherCacheLookup {
        ensureLoaded(now: now)
        var record = records[areaKey] ?? WeatherAreaCacheRecord(
            areaKey: areaKey,
            current: nil,
            hourly: [:],
            daily: nil,
            lastAccessedAt: now
        )
        record.lastAccessedAt = now
        record.accessSequence = nextAccessSequence()
        records[areaKey] = record

        var current: MarineCurrentWeather?
        var hourly: [MarineHourlyForecast] = []
        var daily: [MarineDailyForecast] = []
        var states: [MarineWeatherProductKind: MarineWeatherProductState] = [:]
        var stale: Set<MarineWeatherDataset> = []
        var missing: Set<MarineWeatherDataset> = []

        for dataset in datasets {
            switch dataset {
            case .current:
                guard let cached = record.current,
                      now.timeIntervalSince(cached.fetchedAt) <= configuration.currentMaximumAge else {
                    missing.insert(dataset)
                    continue
                }
                current = cached.value
                let state = productState(
                    fetchedAt: cached.fetchedAt,
                    ttl: configuration.currentTTL,
                    now: now
                )
                states[.current] = state
                if state.isStale {
                    stale.insert(dataset)
                }

            case .hourly(let requestedInterval):
                guard let cached = bestHourlyValue(
                    in: record,
                    covering: requestedInterval,
                    now: now
                ) else {
                    missing.insert(dataset)
                    continue
                }
                hourly = cached.value.filter {
                    $0.date >= requestedInterval.start && $0.date < requestedInterval.end
                }
                guard !hourly.isEmpty else {
                    missing.insert(dataset)
                    continue
                }
                let state = productState(
                    fetchedAt: cached.fetchedAt,
                    ttl: configuration.hourlyTTL,
                    now: now
                )
                states[.hourly] = state
                if state.isStale {
                    stale.insert(dataset)
                }

            case .daily:
                guard let cached = record.daily,
                      now.timeIntervalSince(cached.fetchedAt) <= configuration.dailyMaximumAge else {
                    missing.insert(dataset)
                    continue
                }
                daily = MarineWeatherSelection.dailyWindow(cached.value, startingAt: now)
                guard !daily.isEmpty else {
                    missing.insert(dataset)
                    continue
                }
                let state = productState(
                    fetchedAt: cached.fetchedAt,
                    ttl: configuration.dailyTTL,
                    now: now
                )
                states[.daily] = state
                if state.isStale {
                    stale.insert(dataset)
                }
            }
        }

        let validUntil = states.values.map(\.validUntil).min() ?? now
        let center = areaKey.centerCoordinate
        return WeatherCacheLookup(
            snapshot: MaritimeWeatherSnapshot(
                areaKey: areaKey,
                queryLatitude: center.latitude,
                queryLongitude: center.longitude,
                current: current,
                hourly: hourly,
                daily: daily,
                productStates: states,
                refreshOutcome: .cacheHit(validUntil: validUntil)
            ),
            staleDatasets: stale,
            missingDatasets: missing
        )
    }

    func merge(areaKey: WeatherAreaKey, payload: WeatherFetchPayload, now: Date) throws {
        ensureLoaded(now: now)
        var record = records[areaKey] ?? WeatherAreaCacheRecord(
            areaKey: areaKey,
            current: nil,
            hourly: [:],
            daily: nil,
            lastAccessedAt: now
        )

        if let current = payload.current {
            record.current = CachedWeatherValue(
                value: current.value,
                fetchedAt: current.fetchedAt,
                sourceUpdatedAt: current.sourceUpdatedAt,
                sourceExpiresAt: current.sourceExpiresAt
            )
        }
        if let hourly = payload.hourly {
            let cached = CachedHourlyWeatherValue(
                value: hourly.value,
                interval: hourly.interval,
                fetchedAt: hourly.fetchedAt,
                sourceUpdatedAt: hourly.sourceUpdatedAt,
                sourceExpiresAt: hourly.sourceExpiresAt
            )
            record.hourly[cached.cacheKey] = cached
        }
        if let daily = payload.daily {
            record.daily = CachedWeatherValue(
                value: daily.value,
                fetchedAt: daily.fetchedAt,
                sourceUpdatedAt: daily.sourceUpdatedAt,
                sourceExpiresAt: daily.sourceExpiresAt
            )
        }
        record.lastAccessedAt = now
        record.accessSequence = nextAccessSequence()
        records[areaKey] = record
        prune(now: now)
        try persist()
    }

    private func productState(fetchedAt: Date, ttl: TimeInterval, now: Date) -> MarineWeatherProductState {
        let validUntil = fetchedAt.addingTimeInterval(ttl)
        return MarineWeatherProductState(
            fetchedAt: fetchedAt,
            validUntil: validUntil,
            isStale: now >= validUntil
        )
    }

    private func bestHourlyValue(
        in record: WeatherAreaCacheRecord,
        covering interval: DateInterval,
        now: Date
    ) -> CachedHourlyWeatherValue? {
        record.hourly.values
            .filter {
                $0.interval.start <= interval.start
                    && $0.interval.end >= interval.end
                    && now.timeIntervalSince($0.fetchedAt) <= configuration.hourlyMaximumAge
            }
            .max(by: { $0.fetchedAt < $1.fetchedAt })
    }

    private func ensureLoaded(now: Date) {
        guard !didLoad else { return }
        didLoad = true
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(WeatherCacheEnvelope.self, from: data)
            guard envelope.schemaVersion == 1 else { return }
            records = Dictionary(uniqueKeysWithValues: envelope.records.map { ($0.areaKey, $0) })
            accessCounter = records.values.compactMap(\.accessSequence).max() ?? 0
            prune(now: now)
        } catch {
            let backupURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            records.removeAll()
        }
    }

    private func prune(now: Date) {
        for key in Array(records.keys) {
            guard var record = records[key] else { continue }
            if let current = record.current,
               now.timeIntervalSince(current.fetchedAt) > configuration.currentMaximumAge {
                record.current = nil
            }
            record.hourly = record.hourly.filter {
                now.timeIntervalSince($0.value.fetchedAt) <= configuration.hourlyMaximumAge
            }
            if let daily = record.daily,
               now.timeIntervalSince(daily.fetchedAt) > configuration.dailyMaximumAge {
                record.daily = nil
            }
            if record.current == nil, record.hourly.isEmpty, record.daily == nil {
                records.removeValue(forKey: key)
            } else {
                records[key] = record
            }
        }

        if records.count > configuration.maximumAreas {
            let retained = records.values
                .sorted {
                    let lhsSequence = $0.accessSequence ?? 0
                    let rhsSequence = $1.accessSequence ?? 0
                    if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
                    if $0.lastAccessedAt != $1.lastAccessedAt {
                        return $0.lastAccessedAt > $1.lastAccessedAt
                    }
                    return $0.areaKey.id > $1.areaKey.id
                }
                .prefix(configuration.maximumAreas)
            records = Dictionary(uniqueKeysWithValues: retained.map { ($0.areaKey, $0) })
        }
    }

    private func nextAccessSequence() -> UInt64 {
        accessCounter &+= 1
        return accessCounter
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let envelope = WeatherCacheEnvelope(
            schemaVersion: 1,
            records: records.values.sorted { $0.areaKey.id < $1.areaKey.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(envelope).write(to: fileURL, options: .atomic)
    }
}

enum NetworkPathAvailability: String, Codable, Sendable {
    case unknown
    case unavailable
    case available
}

enum NetworkPathInterface: Int, Codable, Comparable, Sendable {
    case none = 0
    case other = 1
    case cellular = 2
    case wifi = 3
    case wired = 4

    static func < (lhs: NetworkPathInterface, rhs: NetworkPathInterface) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct NetworkPathSnapshot: Equatable, Codable, Sendable {
    let availability: NetworkPathAvailability
    let interface: NetworkPathInterface
    let isExpensive: Bool
    let isConstrained: Bool
    let generation: UInt64

    static let unknown = NetworkPathSnapshot(
        availability: .unknown,
        interface: .none,
        isExpensive: false,
        isConstrained: false,
        generation: 0
    )

    var permitsRequest: Bool { availability != .unavailable }

    func isImprovement(over previous: NetworkPathSnapshot) -> Bool {
        if previous.availability == .unavailable, availability == .available { return true }
        guard availability == .available, previous.availability == .available else { return false }
        if previous.isConstrained, !isConstrained { return true }
        return interface > previous.interface
    }
}

protocol NetworkPathMonitoring: Sendable {
    func snapshot() async -> NetworkPathSnapshot
}

private actor NetworkPathStateStore {
    private var value = NetworkPathSnapshot.unknown

    func update(_ next: NetworkPathSnapshot) {
        let changed = value.availability != next.availability
            || value.interface != next.interface
            || value.isExpensive != next.isExpensive
            || value.isConstrained != next.isConstrained
        value = NetworkPathSnapshot(
            availability: next.availability,
            interface: next.interface,
            isExpensive: next.isExpensive,
            isConstrained: next.isConstrained,
            generation: changed ? value.generation + 1 : value.generation
        )
    }

    func snapshot() -> NetworkPathSnapshot { value }
}

final class NWPathMonitorAdapter: NetworkPathMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "de.tidenode.weather.network-path")
    private let store = NetworkPathStateStore()

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [store] path in
            let availability: NetworkPathAvailability = path.status == .satisfied ? .available : .unavailable
            let interface: NetworkPathInterface
            if path.usesInterfaceType(.wiredEthernet) {
                interface = .wired
            } else if path.usesInterfaceType(.wifi) {
                interface = .wifi
            } else if path.usesInterfaceType(.cellular) {
                interface = .cellular
            } else if path.status == .satisfied {
                interface = .other
            } else {
                interface = .none
            }
            let snapshot = NetworkPathSnapshot(
                availability: availability,
                interface: interface,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                generation: 0
            )
            Task { await store.update(snapshot) }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func snapshot() async -> NetworkPathSnapshot {
        await store.snapshot()
    }
}

protocol MaritimeWeatherProviding: Sendable {
    func weather(
        at coordinate: CLLocationCoordinate2D,
        datasets: Set<MarineWeatherDataset>,
        policy: WeatherReadPolicy
    ) async throws -> MaritimeWeatherSnapshot

    func weatherForRoute(
        waypoints: [CLLocationCoordinate2D],
        departure: Date,
        progress: @escaping @Sendable (RouteWeatherProgress) async -> Void
    ) async throws -> RouteWeatherBatch
}

actor MaritimeWeatherService: MaritimeWeatherProviding {
    static let shared = MaritimeWeatherService()

    private struct RetryState: Sendable {
        let blockedUntil: Date
        let failedPath: NetworkPathSnapshot
    }

    private let client: any MarineWeatherClient
    private let cache: WeatherCacheManager
    private let networkMonitor: any NetworkPathMonitoring
    private let now: @Sendable () -> Date
    private let retryCooldown: TimeInterval
    private var inFlight: [WeatherAreaKey: Task<WeatherFetchPayload, Error>] = [:]
    private var pendingFetchDatasets: [WeatherAreaKey: Set<MarineWeatherDataset>] = [:]
    private var retries: [WeatherAreaKey: RetryState] = [:]
    private var attributionCache: MarineWeatherAttribution?

    init(
        client: any MarineWeatherClient = ResilientMarineWeatherClient(),
        cache: WeatherCacheManager = WeatherCacheManager(),
        networkMonitor: any NetworkPathMonitoring = NWPathMonitorAdapter(),
        retryCooldown: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.cache = cache
        self.networkMonitor = networkMonitor
        self.retryCooldown = retryCooldown
        self.now = now
    }

    func prepare() async {
        await cache.prepare(now: now())
    }

    func weather(
        at coordinate: CLLocationCoordinate2D,
        datasets: Set<MarineWeatherDataset>,
        policy: WeatherReadPolicy = .revalidateExpired
    ) async throws -> MaritimeWeatherSnapshot {
        guard let areaKey = coordinate.maritimeWeatherArea() else {
            throw MarineWeatherError.invalidCoordinate
        }
        let normalized = normalize(datasets)
        guard !normalized.isEmpty else { throw MarineWeatherError.noData }
        return try await resolve(areaKey: areaKey, datasets: normalized, policy: policy)
    }

    func report(
        for harbour: HarbourOption,
        policy: WeatherReadPolicy = .revalidateExpired
    ) async throws -> MarineWeatherReportResult {
        let requestDate = now()
        let calendar = AppDateFormatters.berlinCalendar
        let hourStart = calendar.dateInterval(of: .hour, for: requestDate)?.start ?? requestDate
        let hourEnd = calendar.date(byAdding: .hour, value: 48, to: hourStart)
            ?? hourStart.addingTimeInterval(48 * 3_600)
        let snapshot = try await weather(
            at: CLLocationCoordinate2D(latitude: harbour.latitude, longitude: harbour.longitude),
            datasets: [.current, .hourly(DateInterval(start: hourStart, end: hourEnd)), .daily],
            policy: policy
        )
        return MarineWeatherReportResult(
            report: try snapshot.report(for: harbour, startingAt: hourStart),
            outcome: snapshot.refreshOutcome
        )
    }

    func hourlyWeather(
        for harbour: HarbourOption,
        on date: Date,
        policy: WeatherReadPolicy = .revalidateExpired
    ) async throws -> [MarineHourlyForecast] {
        let calendar = AppDateFormatters.berlinCalendar
        let requestDate = now()
        let start: Date
        let end: Date
        if calendar.isDate(date, inSameDayAs: requestDate) {
            start = calendar.dateInterval(of: .hour, for: requestDate)?.start ?? requestDate
            end = calendar.date(byAdding: .hour, value: 24, to: start)
                ?? start.addingTimeInterval(24 * 3_600)
        } else {
            start = calendar.startOfDay(for: date)
            end = calendar.date(byAdding: .day, value: 1, to: start)
                ?? start.addingTimeInterval(86_400)
        }
        let snapshot = try await weather(
            at: CLLocationCoordinate2D(latitude: harbour.latitude, longitude: harbour.longitude),
            datasets: [.hourly(DateInterval(start: start, end: end))],
            policy: policy
        )
        guard !snapshot.hourly.isEmpty else { throw MarineWeatherError.noData }
        return snapshot.hourly
    }

    func weatherForLocations(
        _ coordinates: [CLLocationCoordinate2D],
        datasets: Set<MarineWeatherDataset>,
        policy: WeatherReadPolicy = .revalidateExpired,
        progress: (@Sendable (RouteWeatherProgress) async -> Void)? = nil
    ) async -> [WeatherAreaKey: Result<MaritimeWeatherSnapshot, MarineWeatherError>] {
        let uniqueKeys = Array(Set(coordinates.compactMap { $0.maritimeWeatherArea() }))
            .sorted { $0.id < $1.id }
        let total = uniqueKeys.count
        await progress?(RouteWeatherProgress(completed: 0, total: total))
        var completed = 0
        var output: [WeatherAreaKey: Result<MaritimeWeatherSnapshot, MarineWeatherError>] = [:]

        for offset in stride(from: 0, to: uniqueKeys.count, by: 3) {
            let end = min(offset + 3, uniqueKeys.count)
            let chunk = Array(uniqueKeys[offset..<end])
            await withTaskGroup(of: (WeatherAreaKey, Result<MaritimeWeatherSnapshot, MarineWeatherError>).self) { group in
                for key in chunk {
                    group.addTask {
                        do {
                            let snapshot = try await self.weather(
                                at: key.centerCoordinate,
                                datasets: datasets,
                                policy: policy
                            )
                            return (key, .success(snapshot))
                        } catch let error as MarineWeatherError {
                            return (key, .failure(error))
                        } catch {
                            return (key, .failure(.unavailable(error.localizedDescription)))
                        }
                    }
                }
                for await (key, result) in group {
                    output[key] = result
                    completed += 1
                    await progress?(RouteWeatherProgress(completed: completed, total: total))
                }
            }
        }
        return output
    }

    func weatherForRoute(
        waypoints: [CLLocationCoordinate2D],
        departure: Date,
        progress: @escaping @Sendable (RouteWeatherProgress) async -> Void
    ) async throws -> RouteWeatherBatch {
        let areaKeys = try waypoints.map { coordinate -> WeatherAreaKey in
            guard let key = coordinate.maritimeWeatherArea() else {
                throw MarineWeatherError.invalidCoordinate
            }
            return key
        }
        let calendar = AppDateFormatters.berlinCalendar
        let start = calendar.dateInterval(of: .hour, for: departure)?.start ?? departure
        let end = calendar.date(byAdding: .hour, value: 48, to: start)
            ?? start.addingTimeInterval(48 * 3_600)
        let hourly = MarineWeatherDataset.hourly(DateInterval(start: start, end: end))
        let results = await weatherForLocations(
            waypoints,
            datasets: [hourly],
            policy: .revalidateExpired,
            progress: progress
        )

        var snapshots: [WeatherAreaKey: MaritimeWeatherSnapshot] = [:]
        for key in Set(areaKeys) {
            guard let result = results[key] else { continue }
            switch result {
            case .success(let snapshot):
                guard snapshot.productStates[.hourly]?.isStale == false,
                      !snapshot.hourly.isEmpty else {
                    continue
                }
                snapshots[key] = snapshot
            case .failure:
                // Preserve successful areas. The decision engine evaluates all
                // known hazards and treats this missing area as an advisory gap.
                continue
            }
        }
        return RouteWeatherBatch(
            departure: departure,
            snapshotsByArea: snapshots,
            areaKeysByWaypoint: areaKeys
        )
    }

    func attribution() async throws -> MarineWeatherAttribution {
        if let attributionCache { return attributionCache }
        do {
            let attribution = try await client.attribution()
            attributionCache = attribution
            return attribution
        } catch {
            throw mapError(error)
        }
    }

    private func resolve(
        areaKey: WeatherAreaKey,
        datasets: Set<MarineWeatherDataset>,
        policy: WeatherReadPolicy
    ) async throws -> MaritimeWeatherSnapshot {
        let requestDate = now()
        let lookup = await cache.lookup(areaKey: areaKey, datasets: datasets, now: requestDate)
        let due: Set<MarineWeatherDataset>
        switch policy {
        case .cacheFirst:
            due = lookup.missingDatasets
        case .revalidateExpired, .manualRetry:
            due = lookup.datasetsNeedingRefresh
        }

        if due.isEmpty {
            return replacingOutcome(
                lookup.snapshot,
                with: .cacheHit(validUntil: earliestValidUntil(in: lookup.snapshot, fallback: requestDate))
            )
        }

        let path = await networkMonitor.snapshot()
        if let retry = retries[areaKey], requestDate < retry.blockedUntil {
            let mayOverride = policy == .manualRetry && path.isImprovement(over: retry.failedPath)
            if !mayOverride {
                if lookup.missingDatasets.isEmpty {
                    return replacingOutcome(lookup.snapshot, with: .retryBlocked(until: retry.blockedUntil))
                }
                throw MarineWeatherError.retryBlocked(retry.blockedUntil)
            }
            retries.removeValue(forKey: areaKey)
        }

        guard path.permitsRequest else {
            let blockedUntil = requestDate.addingTimeInterval(retryCooldown)
            retries[areaKey] = RetryState(blockedUntil: blockedUntil, failedPath: path)
            if lookup.missingDatasets.isEmpty {
                return replacingOutcome(lookup.snapshot, with: .retryBlocked(until: blockedUntil))
            }
            throw MarineWeatherError.networkUnavailable
        }

        if let task = inFlight[areaKey] {
            pendingFetchDatasets[areaKey, default: []].formUnion(expandedDatasetsForFetch(due))
            let payload = try await task.value
            try await cache.merge(areaKey: areaKey, payload: payload, now: requestDate)
            return try await resolve(areaKey: areaKey, datasets: datasets, policy: policy)
        }

        let fetchDatasets = expandedDatasetsForFetch(due)
        let location = CLLocation(
            latitude: areaKey.centerCoordinate.latitude,
            longitude: areaKey.centerCoordinate.longitude
        )
        let client = self.client
        pendingFetchDatasets[areaKey] = fetchDatasets
        let task = Task { [weak self] in
            try await Task.sleep(for: .milliseconds(15))
            let combinedDatasets = await self?.consumePendingDatasets(
                for: areaKey,
                fallback: fetchDatasets
            ) ?? fetchDatasets
            return try await client.fetch(at: location, datasets: combinedDatasets, now: requestDate)
        }
        inFlight[areaKey] = task

        do {
            let payload = try await task.value
            inFlight.removeValue(forKey: areaKey)
            pendingFetchDatasets.removeValue(forKey: areaKey)
            try await cache.merge(areaKey: areaKey, payload: payload, now: requestDate)
            retries.removeValue(forKey: areaKey)
            let refreshed = await cache.lookup(areaKey: areaKey, datasets: datasets, now: requestDate)
            guard refreshed.missingDatasets.isEmpty else { throw MarineWeatherError.noData }
            return replacingOutcome(refreshed.snapshot, with: .refreshed(due))
        } catch {
            inFlight.removeValue(forKey: areaKey)
            pendingFetchDatasets.removeValue(forKey: areaKey)
            let mapped = mapError(error)
            let failedPath = await networkMonitor.snapshot()
            let blockedUntil = requestDate.addingTimeInterval(retryCooldown)
            retries[areaKey] = RetryState(blockedUntil: blockedUntil, failedPath: failedPath)
            if lookup.missingDatasets.isEmpty {
                return replacingOutcome(lookup.snapshot, with: .retryBlocked(until: blockedUntil))
            }
            throw mapped
        }
    }

    private func consumePendingDatasets(
        for areaKey: WeatherAreaKey,
        fallback: Set<MarineWeatherDataset>
    ) -> Set<MarineWeatherDataset> {
        defer { pendingFetchDatasets.removeValue(forKey: areaKey) }
        return normalize(pendingFetchDatasets[areaKey] ?? fallback)
    }

    private func normalize(_ datasets: Set<MarineWeatherDataset>) -> Set<MarineWeatherDataset> {
        var output: Set<MarineWeatherDataset> = []
        var hourlyStart: Date?
        var hourlyEnd: Date?
        for dataset in datasets {
            switch dataset {
            case .current, .daily:
                output.insert(dataset)
            case .hourly(let interval):
                hourlyStart = min(hourlyStart ?? interval.start, interval.start)
                hourlyEnd = max(hourlyEnd ?? interval.end, interval.end)
            }
        }
        if let hourlyStart, let hourlyEnd, hourlyEnd > hourlyStart {
            output.insert(.hourly(DateInterval(start: hourlyStart, end: hourlyEnd)))
        }
        return output
    }

    private func expandedDatasetsForFetch(
        _ datasets: Set<MarineWeatherDataset>
    ) -> Set<MarineWeatherDataset> {
        Set(datasets.map { dataset in
            guard case .hourly(let interval) = dataset else { return dataset }
            return .hourly(DateInterval(
                start: interval.start,
                end: interval.end.addingTimeInterval(3 * 3_600)
            ))
        })
    }

    private func replacingOutcome(
        _ snapshot: MaritimeWeatherSnapshot,
        with outcome: WeatherRefreshOutcome
    ) -> MaritimeWeatherSnapshot {
        MaritimeWeatherSnapshot(
            areaKey: snapshot.areaKey,
            queryLatitude: snapshot.queryLatitude,
            queryLongitude: snapshot.queryLongitude,
            current: snapshot.current,
            hourly: snapshot.hourly,
            daily: snapshot.daily,
            productStates: snapshot.productStates,
            refreshOutcome: outcome
        )
    }

    private func earliestValidUntil(in snapshot: MaritimeWeatherSnapshot, fallback: Date) -> Date {
        snapshot.productStates.values.map(\.validUntil).min() ?? fallback
    }

    private func mapError(_ error: Error) -> MarineWeatherError {
        if error is CancellationError { return .cancelled }
        if let weatherError = error as? WeatherError {
            switch weatherError {
            case .permissionDenied: return .permissionDenied
            case .unknown: return .unavailable(weatherError.localizedDescription)
            @unknown default: return .unavailable(weatherError.localizedDescription)
            }
        }
        if let domainError = error as? MarineWeatherError { return domainError }
        return .unavailable(error.localizedDescription)
    }
}
