import XCTest
@testable import Toernberechnung

/// Tests für `WeatherDataProvider`-Abstraktion und Wetterbewertung.
///
/// Demonstriert das in der Vorlesung behandelte Pattern „Isolation durch Mocking":
/// Das System Under Test (RoutePlannerViewModel/assessWeatherStatus) wird vollständig
/// von Netzwerk und DWD-KMZ-Parsing entkoppelt. Damit sind die Tests deterministisch,
/// schnell und in der CI-Pipeline zuverlässig ausführbar.
final class WeatherDataProviderTests: XCTestCase {

    // MARK: - Mock-Vertrag

    func test_mockProvider_returnsStubbedReading() async throws {
        let mock = MockWeatherDataProvider()
        let harbour = HarbourOption.byID("norderney_harbor")
        let fixture = Self.makeReading(harbour: harbour, windKnots: 10, gustKnots: 12, visibilityKM: 20, precipChance: 10, precipMM: 0)
        mock.stubbedReadings[harbour.id] = fixture

        let result = try await mock.fetchWeather(for: harbour, force: false)

        XCTAssertEqual(result, fixture)
        XCTAssertEqual(mock.callCount, 1)
        XCTAssertEqual(mock.lastRequestedHarbour?.id, harbour.id)
    }

    func test_mockProvider_throwsConfiguredError() async {
        let mock = MockWeatherDataProvider()
        mock.stubbedError = DWDCompactError.badResponse

        do {
            _ = try await mock.fetchWeather(for: HarbourOption.byID("borkum_harbor"), force: false)
            XCTFail("Erwarteter Fehler wurde nicht geworfen")
        } catch let error as DWDCompactError {
            if case .badResponse = error { return }
            XCTFail("Unerwarteter DWDCompactError: \(error)")
        } catch {
            XCTFail("Unerwarteter Fehlertyp: \(error)")
        }
    }

    func test_mockProvider_throwsEmptyPayloadWhenUnconfigured() async {
        let mock = MockWeatherDataProvider()

        do {
            _ = try await mock.fetchWeather(for: HarbourOption.byID("juist_harbor"), force: false)
            XCTFail("Erwarteter Fehler wurde nicht geworfen")
        } catch let error as DWDCompactError {
            if case .emptyPayload = error { return }
            XCTFail("Unerwarteter DWDCompactError: \(error)")
        } catch {
            XCTFail("Unerwarteter Fehlertyp: \(error)")
        }
    }

    // MARK: - Branch-Coverage für assessWeatherStatus

    func test_assessWeatherStatus_incompleteWhenNoReading() {
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: nil), .incomplete)
    }

    func test_assessWeatherStatus_goWhenCalmConditions() {
        let reading = Self.makeReading(windKnots: 10, gustKnots: 14, visibilityKM: 15, precipChance: 10, precipMM: 0)
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: reading), .go)
    }

    func test_assessWeatherStatus_warningOnElevatedWind() {
        let reading = Self.makeReading(windKnots: 22, gustKnots: 26, visibilityKM: 10, precipChance: 30, precipMM: 0.5)
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: reading), .warning)
    }

    func test_assessWeatherStatus_warningOnPoorVisibility() {
        let reading = Self.makeReading(windKnots: 12, gustKnots: 15, visibilityKM: 3, precipChance: 20, precipMM: 0)
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: reading), .warning)
    }

    func test_assessWeatherStatus_warningOnHeavyPrecipitation() {
        let reading = Self.makeReading(windKnots: 12, gustKnots: 15, visibilityKM: 12, precipChance: 70, precipMM: 4)
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: reading), .warning)
    }

    func test_assessWeatherStatus_noGoOnStormWind() {
        let reading = Self.makeReading(windKnots: 30, gustKnots: 36, visibilityKM: 12, precipChance: 50, precipMM: 1)
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: reading), .noGo)
    }

    func test_assessWeatherStatus_noGoOnDenseFog() {
        let reading = Self.makeReading(windKnots: 8, gustKnots: 10, visibilityKM: 0.5, precipChance: 20, precipMM: 0)
        XCTAssertEqual(RoutePlannerViewModel.assessWeatherStatus(for: reading), .noGo)
    }

    // MARK: - Fixture-Helfer

    private static func makeReading(
        harbour: HarbourOption = HarbourOption.byID("norderney_harbor"),
        windKnots: Double,
        gustKnots: Double,
        visibilityKM: Double,
        precipChance: Int,
        precipMM: Double
    ) -> WeatherReading {
        let slot = WeatherSlot(
            time: Date(timeIntervalSince1970: 1_700_000_000),
            temperatureC: 12,
            feelsLikeC: 10,
            dewPointC: 8,
            windKnots: windKnots,
            windGustKnots: gustKnots,
            windDirection: 220,
            precipitationChance: precipChance,
            precipitationMM: precipMM,
            humidityPercent: 75,
            pressureHPA: 1015,
            visibilityKM: visibilityKM,
            cloudCoverPercent: 40,
            condition: "Wolkig",
            icon: "cloud.sun.fill"
        )
        return WeatherReading(
            regionName: harbour.name,
            stationID: harbour.weatherStationID,
            stationName: harbour.weatherStationName,
            issuedAt: Date(timeIntervalSince1970: 1_699_999_000),
            sourceUpdatedAt: Date(timeIntervalSince1970: 1_699_999_500),
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            current: slot,
            upcoming: [slot],
            daily: []
        )
    }
}

/// Integration-style Test: das ViewModel akzeptiert den Mock per Constructor-Injection
/// und kann damit komplett isoliert betrieben werden.
final class RoutePlannerViewModelInjectionTests: XCTestCase {

    func test_viewModel_acceptsInjectedWeatherProvider() {
        let mockWeather = MockWeatherDataProvider()
        let mockTide = MockTideDataProvider()

        let vm = RoutePlannerViewModel(
            tideDataProvider: mockTide,
            weatherDataProvider: mockWeather
        )

        XCTAssertTrue(vm.weatherDataProvider is MockWeatherDataProvider)
    }
}
