import XCTest
@testable import Toernberechnung

/// Tests für `applyHighWaterOffset` und `calculateDeviationHours`.
final class HighWaterOffsetTests: XCTestCase {

    // EKO1: offset = 0 → unverändert
    func test_EKO1_zeroOffset_returnsSameDate() {
        let ref = TestFixtures.berlinDate("2026-05-25 12:00")
        XCTAssertEqual(
            RouteCalculationService.applyHighWaterOffset(referenceHWTime: ref, offsetMinutes: 0),
            ref
        )
    }

    // EKO2: positiver Offset
    func test_EKO2_positiveOffset_addsMinutes() {
        let ref = TestFixtures.berlinDate("2026-05-25 12:00")
        let shifted = RouteCalculationService.applyHighWaterOffset(referenceHWTime: ref, offsetMinutes: 45)
        XCTAssertEqual(shifted.timeIntervalSince(ref), 45 * 60, accuracy: 0.5)
    }

    // EKO3: negativer Offset
    func test_EKO3_negativeOffset_subtractsMinutes() {
        let ref = TestFixtures.berlinDate("2026-05-25 12:00")
        let shifted = RouteCalculationService.applyHighWaterOffset(referenceHWTime: ref, offsetMinutes: -90)
        XCTAssertEqual(shifted.timeIntervalSince(ref), -90 * 60, accuracy: 0.5)
    }

    // EKO4: Mitternachtsübergang
    func test_EKO4_offsetCrossesMidnight() {
        let ref = TestFixtures.berlinDate("2026-05-25 23:30")
        let shifted = RouteCalculationService.applyHighWaterOffset(referenceHWTime: ref, offsetMinutes: 60)

        let cal = Calendar(identifier: .gregorian)
        var comp = cal.dateComponents(in: TimeZone(identifier: "Europe/Berlin")!, from: shifted)
        XCTAssertEqual(comp.day, 26)
        XCTAssertEqual(comp.hour, 0)
        XCTAssertEqual(comp.minute, 30)
    }

    // MARK: - calculateDeviationHours

    func test_deviation_positiveTimeDifference() {
        let arrival = TestFixtures.berlinDate("2026-05-25 14:00")
        let hw      = TestFixtures.berlinDate("2026-05-25 12:00")
        XCTAssertEqual(
            RouteCalculationService.calculateDeviationHours(arrivalTime: arrival, highWaterTime: hw),
            2.0, accuracy: 1e-9
        )
    }

    func test_deviation_isAlwaysAbsolute() {
        let arrival = TestFixtures.berlinDate("2026-05-25 10:00")
        let hw      = TestFixtures.berlinDate("2026-05-25 12:00")
        XCTAssertEqual(
            RouteCalculationService.calculateDeviationHours(arrivalTime: arrival, highWaterTime: hw),
            2.0, accuracy: 1e-9
        )
    }

    func test_deviation_zeroWhenEqual() {
        let t = TestFixtures.berlinDate("2026-05-25 12:00")
        XCTAssertEqual(
            RouteCalculationService.calculateDeviationHours(arrivalTime: t, highWaterTime: t),
            0
        )
    }
}
