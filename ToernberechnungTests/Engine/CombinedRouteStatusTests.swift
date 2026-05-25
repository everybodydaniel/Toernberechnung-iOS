import Testing
@testable import Toernberechnung

/// Parametrisierte Black-Box-Tests für `CombinedRouteStatus.combine(tidal:weather:)`.
@Suite("CombinedRouteStatus.combine – vollständige Wahrheitstabelle")
struct CombinedRouteStatusTests {

    @Test(
        "Wahrheitstabelle (tidal × weather) → combined",
        arguments: [
            // tidal = .go
            (RouteStatus.go,         WeatherStatus.go,          CombinedRouteStatus.go),
            (RouteStatus.go,         WeatherStatus.warning,     CombinedRouteStatus.warning),
            (RouteStatus.go,         WeatherStatus.noGo,        CombinedRouteStatus.noGo),
            (RouteStatus.go,         WeatherStatus.incomplete,  CombinedRouteStatus.go),

            // tidal = .warning
            (RouteStatus.warning,    WeatherStatus.go,          CombinedRouteStatus.warning),
            (RouteStatus.warning,    WeatherStatus.warning,     CombinedRouteStatus.warning),
            (RouteStatus.warning,    WeatherStatus.noGo,        CombinedRouteStatus.noGo),
            (RouteStatus.warning,    WeatherStatus.incomplete,  CombinedRouteStatus.warning),

            // tidal = .noGo
            (RouteStatus.noGo,       WeatherStatus.go,          CombinedRouteStatus.noGo),
            (RouteStatus.noGo,       WeatherStatus.warning,     CombinedRouteStatus.noGo),
            (RouteStatus.noGo,       WeatherStatus.noGo,        CombinedRouteStatus.noGo),
            (RouteStatus.noGo,       WeatherStatus.incomplete,  CombinedRouteStatus.noGo),

            // tidal = .incomplete
            (RouteStatus.incomplete, WeatherStatus.go,          CombinedRouteStatus.incomplete),
            (RouteStatus.incomplete, WeatherStatus.warning,     CombinedRouteStatus.incomplete),
            (RouteStatus.incomplete, WeatherStatus.noGo,        CombinedRouteStatus.noGo),
            (RouteStatus.incomplete, WeatherStatus.incomplete,  CombinedRouteStatus.incomplete)
        ]
    )
    func truthTable(tidal: RouteStatus, weather: WeatherStatus, expected: CombinedRouteStatus) {
        let actual = CombinedRouteStatus.combine(tidal: tidal, weather: weather)
        #expect(actual == expected,
                "combine(.\(tidal), .\(weather)) sollte .\(expected) sein, war .\(actual)")
    }
}
