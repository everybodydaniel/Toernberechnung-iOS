import Foundation

/// Abstraktion zum Abrufen von Wettervorhersagen für einen Hafen.
///
/// Trennt die Geschäftslogik (ViewModel/Views) von der konkreten Datenquelle
/// (DWD MOSMIX) und ermöglicht damit:
/// - isolierte Unit-Tests ohne Netzwerk- oder KMZ-Abhängigkeit,
/// - späteres Austauschen der Datenquelle (z. B. alternative Wettermodelle),
/// - deterministisches Verhalten in der CI-Pipeline.
///
/// Implementierungen müssen sauber scheitern, wenn der DWD-Endpunkt nicht
/// erreichbar oder das KMZ unlesbar ist – ein Crash ist hier nicht akzeptabel.
protocol WeatherDataProvider {
    /// Holt eine aktuelle `WeatherReading` für den angegebenen Hafen.
    ///
    /// - Parameters:
    ///   - harbour: Zielhafen inklusive DWD-Stations-ID.
    ///   - force: Wenn `true`, wird der Cache umgangen und neu geladen.
    /// - Throws: `DWDCompactError` bei Netzwerk- oder Parserfehlern.
    func fetchWeather(for harbour: HarbourOption, force: Bool) async throws -> WeatherReading
}

/// Produktiver Adapter, der den bestehenden `DWDCompactService` als
/// `WeatherDataProvider` bereitstellt.
final class DWDWeatherDataProvider: WeatherDataProvider {
    func fetchWeather(for harbour: HarbourOption, force: Bool) async throws -> WeatherReading {
        try await DWDCompactService.shared.fetch(for: harbour, force: force)
    }
}

/// Mock-Provider für Unit-Tests. Liefert konfigurierbare `WeatherReading`-Stubs,
/// ohne den DWD-Server zu kontaktieren.
///
/// Verwendung:
/// ```swift
/// let mock = MockWeatherDataProvider()
/// mock.stubbedReadings["norderney_harbor"] = makeFixture(...)
/// let vm = RoutePlannerViewModel(weatherDataProvider: mock)
/// ```
final class MockWeatherDataProvider: WeatherDataProvider {
    /// Vorkonfigurierte Wettermessungen, indiziert nach `HarbourOption.id`.
    var stubbedReadings: [String: WeatherReading] = [:]
    /// Wenn gesetzt, wird dieser Fehler statt einer Messung geworfen.
    var stubbedError: Error?
    /// Anzahl der Aufrufe – nützlich, um Cache-/Aufruflogik in Tests zu prüfen.
    private(set) var callCount: Int = 0
    /// Zuletzt angefragter Hafen – nützlich für Assertion-Checks.
    private(set) var lastRequestedHarbour: HarbourOption?

    func fetchWeather(for harbour: HarbourOption, force: Bool) async throws -> WeatherReading {
        callCount += 1
        lastRequestedHarbour = harbour
        if let stubbedError {
            throw stubbedError
        }
        guard let reading = stubbedReadings[harbour.id] else {
            throw DWDCompactError.emptyPayload
        }
        return reading
    }
}
