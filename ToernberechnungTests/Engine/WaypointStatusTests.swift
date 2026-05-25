import XCTest
@testable import Toernberechnung

/// Black-Box-Tests für `RouteCalculationService.determineWaypointStatus`.
/// Klassisches XCTest (deterministisches Input → Output, keine Logik im Test).
final class WaypointStatusTests: XCTestCase {

    // EKW1: WuK < 0 → noGo

    func test_EKW1_wukNegative_returnsNoGo() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: -0.01,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .noGo)
    }

    func test_EKW1_wukDeeplyNegative_returnsNoGo() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: -5.0,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .noGo)
    }

    // EKW2: 0 ≤ WuK < safetyMargin → warning

    func test_EKW2_wukZero_returnsWarning_whenMarginPositive() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: 0.0,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .warning, "WuK=0 ist nicht im Defizit, aber unter der Marge → warning")
    }

    func test_EKW2_wukJustBelowMargin_returnsWarning() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: 0.299,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .warning)
    }

    // EKW3: WuK ≥ safetyMargin → go

    func test_EKW3_wukExactlyAtMargin_returnsGo() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: 0.3,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .go, "WuK == Marge ist gemäß Vertrag bereits go")
    }

    func test_EKW3_wukWellAboveMargin_returnsGo() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: 5.0,
            safetyMargin: 0.3
        )
        XCTAssertEqual(status, .go)
    }

    // Robustheit: Marge = 0

    func test_marginZero_wukZero_isGo() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: 0.0,
            safetyMargin: 0.0
        )
        XCTAssertEqual(status, .go,
                       "Bei Marge=0 ist WuK=0 noch im grünen Bereich – entspricht Excel-Default")
    }

    func test_marginZero_wukNegative_isNoGo() {
        let status = RouteCalculationService.determineWaypointStatus(
            clearanceUnderKeel: -0.01,
            safetyMargin: 0.0
        )
        XCTAssertEqual(status, .noGo)
    }
}
