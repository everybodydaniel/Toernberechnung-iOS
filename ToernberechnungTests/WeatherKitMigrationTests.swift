import CoreLocation
import XCTest
@testable import Toernberechnung

final class WeatherKitMigrationTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_725_000_000)

    func testNauticalUnitConversions() {
        XCTAssertEqual(MarineWeatherUnits.knots(fromMetersPerSecond: 10), 19.4384, accuracy: 0.001)
        XCTAssertEqual(MarineWeatherUnits.millimeters(fromMeters: 0.012), 12, accuracy: 0.001)
        XCTAssertEqual(MarineWeatherUnits.kilometers(fromMeters: 8_500), 8.5, accuracy: 0.001)
        XCTAssertEqual(MarineWeatherUnits.hectopascals(fromPascals: 101_325), 1_013.25, accuracy: 0.001)
    }

    func testWeatherAtmosphereUsesWeatherKitSymbolsAndDaylight() {
        XCTAssertEqual(
            WeatherAtmosphereKind(current: WeatherSamples.current(
                date: referenceDate,
                condition: "Bewölkt",
                symbolName: "cloud.bolt.rain.fill"
            )),
            .thunder
        )
        XCTAssertEqual(
            WeatherAtmosphereKind(current: WeatherSamples.current(
                date: referenceDate,
                condition: "Schauer",
                symbolName: "cloud.rain.fill"
            )),
            .rain
        )
        XCTAssertEqual(
            WeatherAtmosphereKind(current: WeatherSamples.current(
                date: referenceDate,
                condition: "Klar",
                symbolName: "moon.stars.fill",
                isDaylight: false
            )),
            .night
        )
        XCTAssertEqual(
            WeatherAtmosphereKind(current: WeatherSamples.current(
                date: referenceDate,
                condition: "Klar",
                symbolName: "sun.max.fill",
                cloudCoverPercent: 5
            )),
            .clear
        )
    }

    func testGermanCompassDirectionsAndFlowRotation() {
        XCTAssertEqual(AppleWeatherClient.normalizedDegrees(360), 0)
        XCTAssertEqual(AppleWeatherClient.normalizedDegrees(-10), 350)
        XCTAssertEqual(AppleWeatherClient.compassAbbreviation(for: 45), "NO")
        XCTAssertEqual(AppleWeatherClient.compassAbbreviation(for: 270), "W")
        XCTAssertEqual(WeatherSamples.wind(direction: 225).flowArrowRotationDegrees, 225)
    }

    func testTenKilometerGridHasStableCellsAndCenters() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 53.6722, longitude: 6.9982)
        let first = try XCTUnwrap(coordinate.maritimeWeatherArea())
        let nearby = CLLocationCoordinate2D(
            latitude: first.centerCoordinate.latitude + 0.005,
            longitude: first.centerCoordinate.longitude + 0.005
        )

        XCTAssertEqual(nearby.maritimeWeatherArea(), first)
        XCTAssertEqual(first.centerCoordinate.maritimeWeatherArea(), first)
        XCTAssertNil(CLLocationCoordinate2D(latitude: 190, longitude: 7).maritimeWeatherArea())
    }

    func testForecastWindowsAreLimitedAndSorted() {
        let unsortedHours = (0..<60).reversed().map {
            WeatherSamples.hour(date: referenceDate.addingTimeInterval(Double($0) * 3_600))
        }
        let selectedHours = MarineWeatherSelection.hourlyWindow(unsortedHours, startingAt: referenceDate)
        XCTAssertEqual(selectedHours.count, 48)
        XCTAssertEqual(selectedHours.first?.date, referenceDate)
        XCTAssertEqual(selectedHours.last?.date, referenceDate.addingTimeInterval(47 * 3_600))

        let unsortedDays = (0..<10).reversed().map {
            WeatherSamples.day(date: referenceDate.addingTimeInterval(Double($0) * 86_400))
        }
        let selectedDays = MarineWeatherSelection.dailyWindow(unsortedDays, startingAt: referenceDate)
        XCTAssertEqual(selectedDays.count, 7)
        XCTAssertTrue(zip(selectedDays, selectedDays.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    func testTodayDetailLoadsRollingTwentyFourHourWindForecast() async throws {
        let setup = makeService()
        let harbour = try XCTUnwrap(HarbourOption.options.first)
        let calendar = AppDateFormatters.berlinCalendar
        let expectedStart = try XCTUnwrap(calendar.dateInterval(of: .hour, for: referenceDate)?.start)

        let hours = try await setup.service.hourlyWeather(for: harbour, on: referenceDate)

        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours.first?.date, expectedStart)
        XCTAssertEqual(hours.last?.date, expectedStart.addingTimeInterval(23 * 3_600))
    }

    func testFutureDayDetailLoadsCompleteCalendarDayWindForecast() async throws {
        let setup = makeService()
        let harbour = try XCTUnwrap(HarbourOption.options.first)
        let calendar = AppDateFormatters.berlinCalendar
        let futureDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: referenceDate))
        let expectedStart = calendar.startOfDay(for: futureDate)

        let hours = try await setup.service.hourlyWeather(for: harbour, on: futureDate)

        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours.first?.date, expectedStart)
        XCTAssertEqual(hours.last?.date, expectedStart.addingTimeInterval(23 * 3_600))
    }

    func testFiveWaypointsInOneCellCreateOneClientCall() async throws {
        let setup = makeService()
        let key = try XCTUnwrap(CLLocationCoordinate2D(latitude: 53.67, longitude: 7).maritimeWeatherArea())
        let center = key.centerCoordinate
        let waypoints = (0..<5).map { index in
            CLLocationCoordinate2D(
                latitude: center.latitude + Double(index) * 0.001,
                longitude: center.longitude + Double(index) * 0.001
            )
        }

        let batch = try await setup.service.weatherForRoute(
            waypoints: waypoints,
            departure: referenceDate,
            progress: { _ in }
        )

        XCTAssertEqual(batch.snapshotsByArea.count, 1)
        XCTAssertEqual(batch.areaKeysByWaypoint.count, 5)
        let callCount = await setup.client.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testRouteWeatherRequestsFortyEightHoursStartingOneWeekAhead() async throws {
        let setup = makeService()
        let calendar = AppDateFormatters.berlinCalendar
        let departure = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: referenceDate))
        let expectedStart = try XCTUnwrap(calendar.dateInterval(of: .hour, for: departure)?.start)
        let coordinate = CLLocationCoordinate2D(latitude: 53.67, longitude: 7.0)

        let batch = try await setup.service.weatherForRoute(
            waypoints: [coordinate],
            departure: departure,
            progress: { _ in }
        )

        let requestedInterval = await setup.client.lastHourlyInterval
        let requestedKinds = await setup.client.lastRequestedKinds
        let snapshot = try XCTUnwrap(batch.snapshotsByArea.values.first)
        XCTAssertEqual(batch.departure, departure)
        XCTAssertEqual(requestedInterval?.start, expectedStart)
        XCTAssertGreaterThanOrEqual(
            requestedInterval?.end ?? .distantPast,
            expectedStart.addingTimeInterval(48 * 3_600)
        )
        XCTAssertEqual(requestedKinds, [.hourly])
        XCTAssertEqual(snapshot.hourly.count, 48)
        XCTAssertEqual(snapshot.hourly.first?.date, expectedStart)
        XCTAssertEqual(snapshot.hourly.last?.date, expectedStart.addingTimeInterval(47 * 3_600))
    }

    func testMixedProductTTLOnlyReloadsExpiredCurrentWeather() async throws {
        let clock = TestWeatherClock(referenceDate)
        let configuration = WeatherCacheConfiguration(
            currentTTL: 40,
            hourlyTTL: 150,
            dailyTTL: 300,
            currentMaximumAge: 500,
            hourlyMaximumAge: 500,
            dailyMaximumAge: 500,
            maximumAreas: 128
        )
        let setup = makeService(clock: clock, configuration: configuration)
        let coordinate = CLLocationCoordinate2D(latitude: 53.67, longitude: 7)
        let interval = DateInterval(start: referenceDate, duration: 48 * 3_600)
        let datasets: Set<MarineWeatherDataset> = [.current, .hourly(interval), .daily]

        _ = try await setup.service.weather(at: coordinate, datasets: datasets, policy: .revalidateExpired)
        clock.advance(by: 60)
        _ = try await setup.service.weather(at: coordinate, datasets: datasets, policy: .revalidateExpired)

        let callCount = await setup.client.callCount
        let requestedKinds = await setup.client.lastRequestedKinds
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(requestedKinds, [.current])
    }

    func testFreshDiskCacheSurvivesServiceRestart() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("weather-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let clock = TestWeatherClock(referenceDate)
        let first = makeService(clock: clock, fileURL: fileURL)
        let coordinate = CLLocationCoordinate2D(latitude: 53.67, longitude: 7)

        _ = try await first.service.weather(at: coordinate, datasets: [.current], policy: .revalidateExpired)
        let firstCallCount = await first.client.callCount
        XCTAssertEqual(firstCallCount, 1)

        let second = makeService(clock: clock, fileURL: fileURL)
        _ = try await second.service.weather(at: coordinate, datasets: [.current], policy: .revalidateExpired)
        let secondCallCount = await second.client.callCount
        XCTAssertEqual(secondCallCount, 0)
    }

    func testConcurrentConsumersShareOneInFlightRequest() async throws {
        let setup = makeService(clientDelay: 80_000_000)
        let coordinate = CLLocationCoordinate2D(latitude: 53.67, longitude: 7)

        try await withThrowingTaskGroup(of: MaritimeWeatherSnapshot.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await setup.service.weather(
                        at: coordinate,
                        datasets: [.current],
                        policy: .revalidateExpired
                    )
                }
            }
            for try await _ in group { }
        }

        let callCount = await setup.client.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testConcurrentDifferentProductsAreCombinedIntoOneRequest() async throws {
        let setup = makeService(clientDelay: 80_000_000)
        let coordinate = CLLocationCoordinate2D(latitude: 53.67, longitude: 7)
        let interval = DateInterval(start: referenceDate, duration: 24 * 3_600)

        async let current = setup.service.weather(
            at: coordinate,
            datasets: [.current],
            policy: .revalidateExpired
        )
        async let hourly = setup.service.weather(
            at: coordinate,
            datasets: [.hourly(interval)],
            policy: .revalidateExpired
        )
        _ = try await (current, hourly)

        let callCount = await setup.client.callCount
        let requestedKinds = await setup.client.lastRequestedKinds
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(requestedKinds, [.current, .hourly])
    }

    func testCorruptDiskCacheIsPreservedAsBackup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("weather-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("weather-cache-v1.json")
        try Data("not-json".utf8).write(to: fileURL)
        let setup = makeService(fileURL: fileURL)

        _ = try await setup.service.weather(
            at: CLLocationCoordinate2D(latitude: 53.67, longitude: 7),
            datasets: [.current],
            policy: .revalidateExpired
        )

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains(where: { $0.hasPrefix("weather-cache-v1.corrupt-") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testLRUEvictsLeastRecentlyUsedArea() async throws {
        var configuration = WeatherCacheConfiguration.maritime
        configuration.maximumAreas = 2
        let setup = makeService(configuration: configuration)
        let coordinates = [
            CLLocationCoordinate2D(latitude: 53.5, longitude: 6),
            CLLocationCoordinate2D(latitude: 53.5, longitude: 7),
            CLLocationCoordinate2D(latitude: 53.5, longitude: 8)
        ]

        for coordinate in coordinates {
            _ = try await setup.service.weather(at: coordinate, datasets: [.current], policy: .revalidateExpired)
        }
        _ = try await setup.service.weather(at: coordinates[0], datasets: [.current], policy: .revalidateExpired)

        let callCount = await setup.client.callCount
        XCTAssertEqual(callCount, 4)
    }

    func testOfflineGraceIsVisibleButHardExpiredDataIsRejected() async throws {
        let clock = TestWeatherClock(referenceDate)
        let monitor = FakeNetworkPathMonitor(.wifi(generation: 1))
        var configuration = WeatherCacheConfiguration.maritime
        configuration.currentTTL = 40
        configuration.currentMaximumAge = 120
        let setup = makeService(clock: clock, configuration: configuration, networkMonitor: monitor)
        let coordinate = CLLocationCoordinate2D(latitude: 53.67, longitude: 7)

        _ = try await setup.service.weather(at: coordinate, datasets: [.current], policy: .revalidateExpired)
        clock.advance(by: 60)
        await monitor.set(.offline(generation: 2))
        let stale = try await setup.service.weather(
            at: coordinate,
            datasets: [.current],
            policy: .revalidateExpired
        )
        XCTAssertEqual(stale.productStates[.current]?.isStale, true)
        guard case .retryBlocked = stale.refreshOutcome else {
            return XCTFail("Offline grace must expose the retry cooldown")
        }

        clock.advance(by: 61)
        do {
            _ = try await setup.service.weather(at: coordinate, datasets: [.current], policy: .revalidateExpired)
            XCTFail("Hard-expired data must not be returned")
        } catch let error as MarineWeatherError {
            guard case .retryBlocked = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testManualRetryOverridesCooldownAfterNetworkImproves() async throws {
        let monitor = FakeNetworkPathMonitor(.offline(generation: 1))
        let setup = makeService(networkMonitor: monitor)
        let coordinate = CLLocationCoordinate2D(latitude: 53.67, longitude: 7)

        do {
            _ = try await setup.service.weather(at: coordinate, datasets: [.current], policy: .revalidateExpired)
            XCTFail("Offline request must fail")
        } catch let error as MarineWeatherError {
            XCTAssertEqual(error, .networkUnavailable)
        }

        await monitor.set(.cellular(generation: 2))
        _ = try await setup.service.weather(at: coordinate, datasets: [.current], policy: .manualRetry)
        let callCount = await setup.client.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testUnchangedNetworkKeepsRetryCooldownBlocked() async throws {
        let monitor = FakeNetworkPathMonitor(.cellular(generation: 1))
        let setup = makeService(networkMonitor: monitor)
        await setup.client.setFailure(.unavailable("Testausfall"))
        let coordinate = CLLocationCoordinate2D(latitude: 53.67, longitude: 7)

        do {
            _ = try await setup.service.weather(at: coordinate, datasets: [.current], policy: .revalidateExpired)
            XCTFail("Initial failure expected")
        } catch { }

        await setup.client.setFailure(nil)
        do {
            _ = try await setup.service.weather(at: coordinate, datasets: [.current], policy: .manualRetry)
            XCTFail("Unchanged cellular path must stay blocked")
        } catch let error as MarineWeatherError {
            guard case .retryBlocked = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let callCount = await setup.client.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testIncompleteWeatherIsAdvisoryWhenCoreTidalResultExists() {
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .go, weather: .incomplete), .go)
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .warning, weather: .incomplete), .warning)
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .incomplete, weather: .go), .incomplete)
        XCTAssertEqual(CombinedRouteStatus.combine(tidal: .go, weather: .noGo), .noGo)
    }

    func testMissingWeatherDoesNotMaskKnownWeatherHazards() {
        let safe = WeatherSamples.assessment(wind: 12, gust: 18)
        let storm = WeatherSamples.assessment(wind: 30, gust: 38)

        XCTAssertEqual(RoutePlannerViewModel.assessRouteWeather([safe, nil]), .incomplete)
        XCTAssertEqual(RoutePlannerViewModel.assessRouteWeather([safe, nil, storm]), .noGo)
    }

    func testExistingWeatherSafetyThresholdsRemainStable() {
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: WeatherSamples.assessment(wind: 12, gust: 18)), .go)
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: WeatherSamples.assessment(wind: 20, gust: 25)), .warning)
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: WeatherSamples.assessment(wind: 12, gust: 34)), .noGo)
    }

    private func makeService(
        clock: TestWeatherClock? = nil,
        configuration: WeatherCacheConfiguration = .maritime,
        fileURL: URL? = nil,
        networkMonitor: FakeNetworkPathMonitor? = nil,
        clientDelay: UInt64 = 0
    ) -> (service: MaritimeWeatherService, client: FakeMarineWeatherClient) {
        let clock = clock ?? TestWeatherClock(referenceDate)
        let client = FakeMarineWeatherClient(delayNanoseconds: clientDelay)
        let monitor = networkMonitor ?? FakeNetworkPathMonitor(.wifi(generation: 1))
        let cache = WeatherCacheManager(configuration: configuration, fileURL: fileURL)
        let service = MaritimeWeatherService(
            client: client,
            cache: cache,
            networkMonitor: monitor,
            retryCooldown: 5 * 60,
            now: { clock.now() }
        )
        return (service, client)
    }
}

private final class TestWeatherClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor FakeNetworkPathMonitor: NetworkPathMonitoring {
    private var value: NetworkPathSnapshot

    init(_ value: NetworkPathSnapshot) {
        self.value = value
    }

    func set(_ value: NetworkPathSnapshot) {
        self.value = value
    }

    func snapshot() -> NetworkPathSnapshot { value }
}

private extension NetworkPathSnapshot {
    static func offline(generation: UInt64) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            availability: .unavailable,
            interface: .none,
            isExpensive: false,
            isConstrained: false,
            generation: generation
        )
    }

    static func cellular(generation: UInt64) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            availability: .available,
            interface: .cellular,
            isExpensive: true,
            isConstrained: false,
            generation: generation
        )
    }

    static func wifi(generation: UInt64) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            availability: .available,
            interface: .wifi,
            isExpensive: false,
            isConstrained: false,
            generation: generation
        )
    }
}

private actor FakeMarineWeatherClient: MarineWeatherClient {
    private(set) var callCount = 0
    private(set) var lastRequestedKinds: Set<MarineWeatherProductKind> = []
    private(set) var lastHourlyInterval: DateInterval?
    private var failure: MarineWeatherError?
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func setFailure(_ failure: MarineWeatherError?) {
        self.failure = failure
    }

    func fetch(
        at location: CLLocation,
        datasets: Set<MarineWeatherDataset>,
        now: Date
    ) async throws -> WeatherFetchPayload {
        callCount += 1
        lastRequestedKinds = Set(datasets.map(\.kind))
        lastHourlyInterval = datasets.compactMap { dataset -> DateInterval? in
            guard case .hourly(let interval) = dataset else { return nil }
            return interval
        }.first
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let failure { throw failure }

        let expiry = now.addingTimeInterval(24 * 3_600)
        var payload = WeatherFetchPayload.empty
        if datasets.contains(where: { $0.kind == .current }) {
            payload.current = WeatherFetchedValue(
                value: WeatherSamples.current(date: now),
                fetchedAt: now,
                sourceUpdatedAt: now,
                sourceExpiresAt: expiry
            )
        }
        if let interval = datasets.compactMap({ dataset -> DateInterval? in
            guard case .hourly(let interval) = dataset else { return nil }
            return interval
        }).first {
            var date = interval.start
            var hours: [MarineHourlyForecast] = []
            while date < interval.end {
                hours.append(WeatherSamples.hour(date: date))
                date = date.addingTimeInterval(3_600)
            }
            payload.hourly = WeatherFetchedHourlyValue(
                value: hours,
                interval: interval,
                fetchedAt: now,
                sourceUpdatedAt: now,
                sourceExpiresAt: expiry
            )
        }
        if datasets.contains(where: { $0.kind == .daily }) {
            let start = AppDateFormatters.berlinCalendar.startOfDay(for: now)
            payload.daily = WeatherFetchedValue(
                value: (0..<8).map {
                    WeatherSamples.day(date: start.addingTimeInterval(Double($0) * 86_400))
                },
                fetchedAt: now,
                sourceUpdatedAt: now,
                sourceExpiresAt: expiry
            )
        }
        return payload
    }

    func attribution() async throws -> MarineWeatherAttribution { .fallback }
}

private enum WeatherSamples {
    static func wind(speed: Double = 12, gust: Double = 18, direction: Int = 225) -> MarineWind {
        MarineWind(
            speedKnots: speed,
            gustKnots: gust,
            directionDegrees: direction,
            compassDirection: AppleWeatherClient.compassAbbreviation(for: direction),
            compassDescription: AppleWeatherClient.compassDescription(for: direction)
        )
    }

    static func current(
        date: Date,
        condition: String = "Teilweise bewölkt",
        symbolName: String = "cloud.sun.fill",
        cloudCoverPercent: Int = 40,
        isDaylight: Bool = true
    ) -> MarineCurrentWeather {
        MarineCurrentWeather(
            date: date,
            temperatureC: 18,
            apparentTemperatureC: 17,
            dewPointC: 12,
            condition: condition,
            symbolName: symbolName,
            humidityPercent: 72,
            pressureHPA: 1_013,
            pressureTrend: "gleichbleibend",
            visibilityKM: 18,
            cloudCoverPercent: cloudCoverPercent,
            uvIndex: 3,
            uvCategory: "Mäßig",
            isDaylight: isDaylight,
            precipitationIntensityMMPerHour: 0,
            wind: wind()
        )
    }

    static func hour(date: Date) -> MarineHourlyForecast {
        MarineHourlyForecast(
            date: date,
            temperatureC: 18,
            apparentTemperatureC: 17,
            dewPointC: 12,
            condition: "Teilweise bewölkt",
            symbolName: "cloud.sun.fill",
            humidityPercent: 72,
            pressureHPA: 1_013,
            pressureTrend: "gleichbleibend",
            visibilityKM: 18,
            cloudCoverPercent: 40,
            uvIndex: 3,
            isDaylight: true,
            precipitationType: "Kein Niederschlag",
            precipitationChance: 10,
            precipitationMM: 0,
            wind: wind()
        )
    }

    static func day(date: Date) -> MarineDailyForecast {
        MarineDailyForecast(
            date: date,
            condition: "Teilweise bewölkt",
            symbolName: "cloud.sun.fill",
            highTemperatureC: 20,
            highTemperatureTime: nil,
            lowTemperatureC: 13,
            lowTemperatureTime: nil,
            daytimeCondition: "Teilweise bewölkt",
            overnightCondition: "Klar",
            daytimeWind: wind(),
            overnightWind: wind(speed: 9, gust: 13),
            highWindKnots: 20,
            precipitationType: "Kein Niederschlag",
            precipitationChance: 10,
            precipitation: MarinePrecipitationAmounts(
                totalMM: 0,
                rainMM: 0,
                snowMM: 0,
                sleetMM: 0,
                hailMM: 0,
                mixedMM: 0
            ),
            minimumHumidityPercent: 55,
            maximumHumidityPercent: 82,
            minimumVisibilityKM: 10,
            maximumVisibilityKM: 25,
            uvIndex: 4,
            uvCategory: "Mäßig",
            sunrise: nil,
            sunset: nil,
            moonrise: nil,
            moonset: nil,
            moonPhase: "Vollmond",
            moonSymbolName: "moonphase.full.moon"
        )
    }

    static func assessment(wind: Double, gust: Double) -> MarineWeatherAssessment {
        MarineWeatherAssessment(
            windKnots: wind,
            gustKnots: gust,
            visibilityKM: 10,
            precipitationChance: 10,
            precipitationMM: 0
        )
    }
}
