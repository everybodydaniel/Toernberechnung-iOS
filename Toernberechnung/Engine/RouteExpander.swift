import Foundation
import CoreLocation

// MARK: - Route Expander
//
// Inserts NauticalRouter fairway waypoints between user-selected waypoints so
// the RouteCalculationService evaluates WuK at the actual shallow Watt-segments
// (the bottlenecks), not just at the user's named harbours.
//
// Tide-station references (MHW, MTH, BSH gauge) for the inserted fairway
// waypoints inherit from the *nearest* user waypoint. This is the correct
// behaviour because the calculation engine treats Anschlussorte the same way —
// it inherits the reference station and applies an HW offset (`hwOffsetMinutes`)
// for points that lie between two reference gauges.

enum RouteExpander {

    /// Expand the user-supplied route by inserting Dijkstra-routed fairway
    /// waypoints between every pair of consecutive user waypoints. The
    /// resulting RoutePlan keeps the user's original waypoints (start, stops,
    /// destination) and interleaves the fairway segments between them.
    static func expandWithFairwayWaypoints(_ plan: RoutePlan) -> RoutePlan {
        guard plan.waypoints.count >= 2 else { return plan }

        var newWaypoints: [RouteWaypoint] = []
        var newLegs: [RouteLeg] = []
        let defaultSpeed: Double = plan.legs.first?.speedThroughWaterKnots ?? 6.0

        for i in 0 ..< plan.waypoints.count - 1 {
            let fromWP = plan.waypoints[i]
            let toWP   = plan.waypoints[i + 1]
            let originalLeg = i < plan.legs.count ? plan.legs[i] : nil

            // Append "from" only once (start of first leg or already trailed
            // by previous segment).
            if newWaypoints.isEmpty { newWaypoints.append(fromWP) }

            // Resolve coordinates.
            let fromCoord = coordinate(for: fromWP)
            let toCoord   = coordinate(for: toWP)

            // Dijkstra fairway path between the two harbours.
            let fairwayPath = NauticalRouter.route(from: fromCoord, to: toCoord)

            // Drop bookend fairway WPs that are essentially identical to the
            // user-supplied endpoints (avoid doubling start/end markers).
            let interiorFairway = fairwayPath.filter { wp in
                let coord = CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lon)
                return !isClose(coord, fromCoord) && !isClose(coord, toCoord)
            }

            // Build cumulative leg list:
            //   from → fairway[0] → fairway[1] → … → to
            var legPath: [RouteWaypoint] = []
            for fw in interiorFairway {
                let fairwayWP = synthesizeFairwayWaypoint(
                    fairway: fw,
                    inheritFrom: nearestUserWaypoint(to: fw, candidates: [fromWP, toWP]),
                    bshCorrectionOverride: nil
                )
                legPath.append(fairwayWP)
            }
            legPath.append(toWP)

            // Emit waypoints + legs.
            var previousWP = fromWP
            var previousCoord = fromCoord
            let tidalCurrent = originalLeg?.tidalCurrentKnots ?? 0
            let speed = originalLeg?.speedThroughWaterKnots ?? defaultSpeed

            for wp in legPath {
                let coord = coordinate(for: wp)
                let distNm = NauticalRouter.haversineNm(previousCoord, coord)
                newWaypoints.append(wp)
                newLegs.append(RouteLeg(
                    id: UUID(),
                    fromWaypointID: previousWP.id,
                    toWaypointID: wp.id,
                    distanceNm: distNm,
                    courseDegrees: nil,
                    speedThroughWaterKnots: speed,
                    tidalCurrentKnots: tidalCurrent
                ))
                previousWP = wp
                previousCoord = coord
            }
        }

        var expanded = plan
        expanded.waypoints = newWaypoints
        expanded.legs = newLegs
        return expanded
    }

    // MARK: - Helpers

    private static func coordinate(for wp: RouteWaypoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: wp.latitude ?? 0, longitude: wp.longitude ?? 0)
    }

    private static func isClose(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 0.005 && abs(a.longitude - b.longitude) < 0.008
    }

    private static func nearestUserWaypoint(
        to fw: NauticalRouter.Waypoint,
        candidates: [RouteWaypoint]
    ) -> RouteWaypoint {
        let target = CLLocationCoordinate2D(latitude: fw.lat, longitude: fw.lon)
        return candidates.min { lhs, rhs in
            NauticalRouter.haversineNm(coordinate(for: lhs), target)
                < NauticalRouter.haversineNm(coordinate(for: rhs), target)
        } ?? candidates[0]
    }

    /// Convert a fairway waypoint into a fully-formed RouteWaypoint suitable
    /// for the calculation engine. MHW / MTH are inherited from the nearest
    /// user waypoint so the same BSH gauge governs the calculation.
    private static func synthesizeFairwayWaypoint(
        fairway: NauticalRouter.Waypoint,
        inheritFrom anchor: RouteWaypoint,
        bshCorrectionOverride: Double?
    ) -> RouteWaypoint {
        // Apply HW offset (minutes) on top of the anchor's offset.
        let totalOffset = anchor.highWaterOffsetMinutes + fairway.hwOffsetMinutes

        return RouteWaypoint(
            id: UUID(),
            name: fairway.id,
            latitude: fairway.lat,
            longitude: fairway.lon,
            tidalReferenceStation: anchor.tidalReferenceStation,
            tidalReferenceStationID: fairway.tideStationID ?? anchor.tidalReferenceStationID,
            highWaterOffsetMinutes: totalOffset,
            meanTidalRangeMeters: anchor.meanTidalRangeMeters,
            meanHighWaterMeters: anchor.meanHighWaterMeters,
            lottiefeMeters: nil,
            chartDepthMeters: SourcedValue(
                value: fairway.chartDepth,
                source: .catalog,
                sourceNotes: "NauticalRouter Fahrwasser-Knoten"
            ),
            calculationMode: .meanHighWater,
            bshWaterLevelCorrectionOverride: bshCorrectionOverride,
            manualHighWaterTime: nil,
            notes: "Automatisch eingefügter Fahrwasser-Punkt (Dijkstra)",
            category: "Fahrwasser",
            island: nil
        )
    }
}
