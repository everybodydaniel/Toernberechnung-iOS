import Foundation

// MARK: - Rule of Twelfths — smooth interpolation
//
// The canonical, Excel-compatible Zwölftelregel lives in
// `TwelfthsRuleStrategy` (see `TidalHeightStrategy.swift`) and is the only
// implementation the Törn calculation uses. Keeping a second stepped variant
// here once caused the two to disagree at exact high water, so it was removed.
//
// What remains is the *continuous* interpolation, which the map depth shading
// needs: it distributes the tidal range as 1/2/3/3/2/1 twelfths across six
// equal slices between two known tide events and interpolates linearly inside
// each slice. Unlike the stepped rule it consumes real HW/LW heights.

enum RuleOfTwelfths {

    // MARK: - Continuous Interpolation

    /// Predict water level at `targetTime` given a bracketing pair of tide
    /// events (typically NW → HW or HW → NW). Uses the 12/1 distribution.
    static func continuousWaterLevel(
        timeStart: Date, heightStart: Double,
        timeEnd: Date, heightEnd: Double,
        targetTime: Date
    ) -> Double {
        if targetTime <= timeStart { return heightStart }
        if targetTime >= timeEnd { return heightEnd }

        let total = timeEnd.timeIntervalSince(timeStart)
        guard total > 0 else { return heightEnd }
        let phase = targetTime.timeIntervalSince(timeStart) / total

        let twelfthsPerSegment: [Double] = [1, 2, 3, 3, 2, 1]
        let segmentLength = 1.0 / 6.0
        let segmentIndex = max(0, min(5, Int(phase / segmentLength)))
        let fractionInSegment = (phase - Double(segmentIndex) * segmentLength) / segmentLength

        var accumulated: Double = 0
        for i in 0 ..< segmentIndex { accumulated += twelfthsPerSegment[i] }
        accumulated += twelfthsPerSegment[segmentIndex] * fractionInSegment

        return heightStart + (heightEnd - heightStart) * (accumulated / 12.0)
    }
}
