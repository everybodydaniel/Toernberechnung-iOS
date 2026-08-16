import Foundation
import XCTest
@testable import Toernberechnung

/// `RuleOfTwelfths.continuousWaterLevel` is the smooth counterpart to the
/// stepped Excel rule. It is **not** part of the Törn calculation — its only
/// consumer is the map depth shading in `NauticalRouteService.calculateTideOffset`.
///
/// These tests pin that boundary: the stepped rule stays canonical for planning,
/// this one stays continuous for rendering.
final class RuleOfTwelfthsInterpolationTests: XCTestCase {

    private let accuracy = 1e-9
    private let start = Date(timeIntervalSince1970: 1_768_500_000)
    private var end: Date { start.addingTimeInterval(6 * 3_600) }

    private func level(atPhase phase: Double) -> Double {
        RuleOfTwelfths.continuousWaterLevel(
            timeStart: start, heightStart: 0.5,
            timeEnd: end, heightEnd: 3.5,
            targetTime: start.addingTimeInterval(phase * 6 * 3_600)
        )
    }

    func testEndpointsReturnTheKnownHeights() {
        XCTAssertEqual(level(atPhase: 0), 0.5, accuracy: accuracy)
        XCTAssertEqual(level(atPhase: 1), 3.5, accuracy: accuracy)
        // Outside the bracket the nearest known height is held.
        XCTAssertEqual(level(atPhase: -0.5), 0.5, accuracy: accuracy)
        XCTAssertEqual(level(atPhase: 1.5), 3.5, accuracy: accuracy)
    }

    /// Half way through, the 1/2/3 + 3/2/1 split has accumulated exactly 6 of
    /// 12 twelfths, so the level sits precisely in the middle.
    func testMidpointIsTheExactMiddleOfTheRange() {
        XCTAssertEqual(level(atPhase: 0.5), 2.0, accuracy: accuracy)
    }

    /// After the first sixth: 1/12 of the range.
    /// After the third sixth: (1+2+3)/12 = one half.
    func testSegmentBoundariesFollowTheTwelfthsDistribution() {
        XCTAssertEqual(level(atPhase: 1.0 / 6.0), 0.5 + 3.0 * (1.0 / 12.0), accuracy: accuracy)
        XCTAssertEqual(level(atPhase: 3.0 / 6.0), 0.5 + 3.0 * (6.0 / 12.0), accuracy: accuracy)
        XCTAssertEqual(level(atPhase: 5.0 / 6.0), 0.5 + 3.0 * (11.0 / 12.0), accuracy: accuracy)
    }

    func testIsStrictlyMonotonicUnlikeTheSteppedRule() {
        var previous = -Double.infinity
        for step in 0 ... 60 {
            let value = level(atPhase: Double(step) / 60.0)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    /// A degenerate bracket must not divide by zero.
    func testZeroLengthBracketReturnsTheEndHeightWithoutDividingByZero() {
        let value = RuleOfTwelfths.continuousWaterLevel(
            timeStart: start, heightStart: 0.5,
            timeEnd: start, heightEnd: 3.5,
            targetTime: start
        )
        XCTAssertTrue(value.isFinite)
        XCTAssertEqual(value, 0.5, accuracy: accuracy)
    }
}
