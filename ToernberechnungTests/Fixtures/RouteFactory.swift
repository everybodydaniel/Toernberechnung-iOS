import Foundation
@testable import Toernberechnung

enum RouteFactory {

    static let referenceStartTime: Date = TestFixtures.berlinDate("2026-05-25 09:00")
    static let highWaterTime: Date     = TestFixtures.berlinDate("2026-05-25 12:00")

    static func boat(draft: Double = 1.5, safetyMargin: Double = 0.3) -> BoatSettings {
        BoatSettings(draftMeters: draft, safetyMarginMeters: safetyMargin)
    }

    static func mhwWaypoint(
        name: String = "Norderney Hafen",
        offsetMinutes: Int = 0,
        mth: Double = 2.4,
        mhw: Double = 1.2,
        chartDepth: Double = 2.5,
        stationID: String = "111P",
        manualHW: Date? = nil
    ) -> RouteWaypoint {
        RouteWaypoint(
            id: UUID(),
            name: name,
            latitude: nil, longitude: nil,
            tidalReferenceStation: stationID,
            tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: offsetMinutes,
            meanTidalRangeMeters:  SourcedValue(value: mth,        source: .catalog, sourceNotes: nil),
            meanHighWaterMeters:   SourcedValue(value: mhw,        source: .catalog, sourceNotes: nil),
            lottiefeMeters:        nil,
            chartDepthMeters:      SourcedValue(value: chartDepth, source: .catalog, sourceNotes: nil),
            calculationMode: .meanHighWater,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: manualHW,
            notes: "",
            category: "Hafen",
            island: nil
        )
    }

    static func lottiefeWaypoint(
        name: String = "Watt-Hoch",
        offsetMinutes: Int = 0,
        mth: Double = 2.4,
        lottiefe: Double = 1.0,
        stationID: String = "111P",
        manualHW: Date? = nil
    ) -> RouteWaypoint {
        RouteWaypoint(
            id: UUID(),
            name: name,
            latitude: nil, longitude: nil,
            tidalReferenceStation: stationID,
            tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: offsetMinutes,
            meanTidalRangeMeters:  SourcedValue(value: mth,      source: .catalog, sourceNotes: nil),
            meanHighWaterMeters:   nil,
            lottiefeMeters:        SourcedValue(value: lottiefe, source: .catalog, sourceNotes: nil),
            chartDepthMeters:      nil,
            calculationMode: .lottiefe,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: manualHW,
            notes: "",
            category: "Wattenhoch",
            island: nil
        )
    }

    static func twoPointRoute(
        from start: RouteWaypoint,
        to end: RouteWaypoint,
        distanceNm: Double = 6.0,
        speedKnots: Double = 6.0,
        currentKnots: Double = 0,
        startTime: Date = referenceStartTime,
        bshCorrection: Double = 0
    ) -> RoutePlan {
        let leg = RouteLeg(
            id: UUID(),
            fromWaypointID: start.id,
            toWaypointID: end.id,
            distanceNm: distanceNm,
            courseDegrees: nil,
            speedThroughWaterKnots: speedKnots,
            tidalCurrentKnots: currentKnots
        )
        return RoutePlan(
            id: UUID(),
            date: startTime,
            routeName: "\(start.name) → \(end.name)",
            plannedStartTime: startTime,
            waypoints: [start, end],
            legs: [leg],
            bshWaterLevelCorrectionMeters: bshCorrection,
            tidalStateLabel: "Mitteltide"
        )
    }

    static func provider(
        stationID: String = "111P",
        highWaters: [Date] = [highWaterTime]
    ) -> MockTideDataProvider {
        let mock = MockTideDataProvider()
        let events = highWaters.map { TideEvent(time: $0, heightMeters: 3.5, type: "HW", phase: "S") }
        mock.highWatersByStation[stationID] = events
        return mock
    }
}
