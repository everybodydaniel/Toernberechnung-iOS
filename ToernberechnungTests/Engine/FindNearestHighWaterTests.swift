import XCTest
@testable import Toernberechnung

/// Tests für `RouteCalculationService.findNearestHighWater`.
final class FindNearestHighWaterTests: XCTestCase {

    private func hw(_ iso: String) -> TideEvent {
        TideEvent(time: TestFixtures.berlinDate(iso), heightMeters: 3.5, type: "HW", phase: "S")
    }

    func test_emptyArray_returnsNil() {
        let nearest = RouteCalculationService.findNearestHighWater(
            to: TestFixtures.berlinDate("2026-05-25 12:00"),
            from: []
        )
        XCTAssertNil(nearest)
    }

    func test_singleEvent_returnsThatEvent() {
        let events = [hw("2026-05-25 06:42")]
        let nearest = RouteCalculationService.findNearestHighWater(
            to: TestFixtures.berlinDate("2026-05-25 09:00"),
            from: events
        )
        XCTAssertEqual(nearest, events[0].time)
    }

    func test_pickClosestOfTwo() {
        let events = [hw("2026-05-25 06:42"), hw("2026-05-25 19:21")]
        let nearestMorning = RouteCalculationService.findNearestHighWater(
            to: TestFixtures.berlinDate("2026-05-25 09:00"),
            from: events
        )
        XCTAssertEqual(nearestMorning, events[0].time)

        let nearestEvening = RouteCalculationService.findNearestHighWater(
            to: TestFixtures.berlinDate("2026-05-25 17:00"),
            from: events
        )
        XCTAssertEqual(nearestEvening, events[1].time)
    }

    func test_targetEqualsEventTime_returnsExactMatch() {
        let target = TestFixtures.berlinDate("2026-05-25 06:42")
        let events = [hw("2026-05-25 06:42"), hw("2026-05-25 19:21")]
        XCTAssertEqual(
            RouteCalculationService.findNearestHighWater(to: target, from: events),
            target
        )
    }

    func test_targetBeforeAllEvents_returnsEarliest() {
        let events = [hw("2026-05-25 06:42"), hw("2026-05-25 19:21")]
        let target = TestFixtures.berlinDate("2026-05-25 03:00")
        XCTAssertEqual(
            RouteCalculationService.findNearestHighWater(to: target, from: events),
            events[0].time
        )
    }
}
