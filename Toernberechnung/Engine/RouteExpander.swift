import Foundation
import CoreLocation

// MARK: - Erweiterung der Route
//
// Fügt Fahrwasserpunkte aus NauticalRouter zwischen den vom Nutzer gewählten
// Wegpunkten ein. So bewertet RouteCalculationService das Wasser unter Kiel
// auch an flachen Wattabschnitten und nicht nur an den ausgewählten Häfen.
//
// Die Gezeitenreferenz der zusätzlichen Punkte (MHW, MTH, BSH-Pegel) stammt
// vom nächsten gewählten Wegpunkt. Anschlussorte übernehmen entsprechend
// die Referenzstation und erhalten bei Bedarf einen Hochwasserversatz
// über `hwOffsetMinutes`.

enum RouteExpander {

    /// Erweitert die Route um Fahrwasserpunkte aus der Dijkstra-Suche zwischen
    /// je zwei gewählten Wegpunkten. Der RoutePlan behält Start, Zwischenstopps
    /// und Ziel des Nutzers und fügt die Fahrwasserpunkte dazwischen ein.
    static func expandWithFairwayWaypoints(_ plan: RoutePlan) -> RoutePlan {
        guard plan.waypoints.count >= 2 else { return plan }

        var newWaypoints: [RouteWaypoint] = []
        var newLegs: [RouteLeg] = []
        let defaultSpeed: Double = plan.legs.first?.speedThroughWaterKnots ?? 6.0

        for i in 0 ..< plan.waypoints.count - 1 {
            let fromWP = plan.waypoints[i]
            let toWP   = plan.waypoints[i + 1]
            let originalLeg = i < plan.legs.count ? plan.legs[i] : nil

            // "from" nur einmal ergänzen: am Beginn des ersten Abschnitts
            // oder bereits als Ende des vorherigen Abschnitts.
            if newWaypoints.isEmpty { newWaypoints.append(fromWP) }

            // Koordinaten ermitteln.
            let fromCoord = coordinate(for: fromWP)
            let toCoord   = coordinate(for: toWP)

            // Fahrwasserpfad zwischen den Häfen mit Dijkstra bestimmen.
            let fairwayPath = NauticalRouter.route(from: fromCoord, to: toCoord)
            guard !fairwayPath.isEmpty else {
                // Wenn das verbindende Fahrwasser fehlt, darf die Berechnung
                // nicht stillschweigend auf die beiden Häfen beschränkt werden.
                var incomplete = plan
                incomplete.legs = []
                return incomplete
            }

            // Fahrwasserpunkte entfernen, die nahezu mit den gewählten Endpunkten
            // übereinstimmen, damit Start- und Zielmarkierungen nicht doppelt erscheinen.
            let interiorFairway = fairwayPath.filter { wp in
                let coord = CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lon)
                return !isClose(coord, fromCoord) && !isClose(coord, toCoord)
            }

            // Zusammenhängende Liste der Streckenabschnitte erstellen:
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

            // Wegpunkte und Streckenabschnitte ausgeben.
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

    // MARK: - Hilfsfunktionen

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

    /// Erstellt aus einem Fahrwasserpunkt einen vollständigen RouteWaypoint für die Berechnung.
    /// Die Gezeitenreferenz stammt von der räumlich nächsten BSH-Station.
    private static func synthesizeFairwayWaypoint(
        fairway: NauticalRouter.Waypoint,
        inheritFrom anchor: RouteWaypoint,
        bshCorrectionOverride: Double?
    ) -> RouteWaypoint {
        let fwCoord = CLLocationCoordinate2D(latitude: fairway.lat, longitude: fairway.lon)
        let closestStation = BSHTideStationCatalog.stations.min { s1, s2 in
            NauticalRouter.haversineNm(fwCoord, s1.coordinate) < NauticalRouter.haversineNm(fwCoord, s2.coordinate)
        }
        let stationID = fairway.tideStationID ?? closestStation?.id ?? anchor.tidalReferenceStationID
        let stationName = closestStation?.name ?? anchor.tidalReferenceStation
        let totalOffset = fairway.hwOffsetMinutes

        return RouteWaypoint(
            id: UUID(),
            name: fairway.id,
            latitude: fairway.lat,
            longitude: fairway.lon,
            tidalReferenceStation: stationName,
            tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: totalOffset,
            meanTidalRangeMeters: anchor.meanTidalRangeMeters,
            meanHighWaterMeters: anchor.meanHighWaterMeters,
            lottiefeMeters: nil,
            chartDepthMeters: SourcedValue(
                value: fairway.chartDepth,
                source: .catalog,
                sourceNotes: "NauticalRouter LAT Kartentiefe"
            ),
            calculationMode: .meanHighWater,
            bshWaterLevelCorrectionOverride: bshCorrectionOverride,
            manualHighWaterTime: nil,
            notes: "Fahrwasser-Knoten",
            category: "Fahrwasser",
            island: nil
        )
    }
}
