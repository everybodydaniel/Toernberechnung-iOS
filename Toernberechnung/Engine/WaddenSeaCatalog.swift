import Foundation

// MARK: - Tidal Reference Station

/// A BSH tidal reference station / gauge.
/// Station IDs are provisional and may not match BSH's current online data.
struct TidalReferenceStation: Identifiable, Codable, Equatable {
    /// BSH station ID (e.g. "507P"). May be unavailable or renamed.
    var id: String
    /// Human-readable station name (e.g. "Emden, Große Seeschleuse").
    var name: String
    var latitude: Double?
    var longitude: Double?
    /// Default Mean Tidal Range if known. Source metadata attached.
    var meanTidalRangeMeters: SourcedValue<Double>?
    /// Default Mean High Water if known. Source metadata attached.
    var meanHighWaterMeters: SourcedValue<Double>?
}

// MARK: - Waypoint Template

/// A pre-configured waypoint template from the catalog.
/// Templates provide planning defaults that require skipper verification.
struct WaypointTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double?
    var longitude: Double?
    /// BSH tidal reference station ID.
    var tidalReferenceStationID: String
    /// BSH tidal reference station name.
    var tidalReferenceStationName: String
    /// Signed HW offset from reference station in minutes.
    var highWaterOffsetMinutes: Int
    /// Calculation mode: MHW-based or Lottiefe-based.
    var calculationMode: WaypointCalculationMode
    /// Default Mean Tidal Range.
    var defaultMTH: SourcedValue<Double>?
    /// Default Mean High Water (for MHW mode).
    var defaultMHW: SourcedValue<Double>?
    /// Default Lottiefe (for Lottiefe mode).
    var defaultLottiefe: SourcedValue<Double>?
    /// Default chart depth / Peilplan value.
    var defaultChartDepth: SourcedValue<Double>?
    /// Associated island (e.g. "Norderney"). Nil for mainland/fairway.
    var island: String?
    /// Category: "Hafen", "Wattenhoch", "Fahrwasser", "Reede".
    var category: String
    /// Notes or source reference.
    var notes: String

    /// Convert this template into a RouteWaypoint with catalog defaults.
    func toRouteWaypoint() -> RouteWaypoint {
        RouteWaypoint(
            id: UUID(),
            name: name,
            latitude: latitude,
            longitude: longitude,
            tidalReferenceStation: tidalReferenceStationName,
            tidalReferenceStationID: tidalReferenceStationID,
            highWaterOffsetMinutes: highWaterOffsetMinutes,
            meanTidalRangeMeters: defaultMTH,
            meanHighWaterMeters: defaultMHW,
            lottiefeMeters: defaultLottiefe,
            chartDepthMeters: defaultChartDepth,
            calculationMode: calculationMode,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: nil,
            notes: notes,
            category: category,
            island: island
        )
    }
}

// MARK: - Route Template

/// An optional convenience template linking waypoints with default distances.
/// Route templates are not required — users can build fully custom routes.
struct RouteTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var description: String
    /// Ordered waypoint template IDs: [start, ...intermediates..., destination].
    var waypointTemplateIDs: [UUID]
    /// Default leg distances in NM. Count must be waypointTemplateIDs.count - 1.
    var defaultLegDistancesNm: [Double]
    /// Default tidal current per leg in knots. Count must match legs.
    var defaultTidalCurrentsKnots: [Double]
    /// Default speed through water in knots.
    var defaultSpeedKnots: Double
    /// Start waypoint template ID (convenience).
    var startWaypointID: UUID { waypointTemplateIDs.first ?? UUID() }
    /// Destination waypoint template ID (convenience).
    var destinationWaypointID: UUID { waypointTemplateIDs.last ?? UUID() }
}

// MARK: - Wadden Sea Catalog

/// Data-driven catalog for the East Frisian Wadden Sea.
///
/// Loaded from a bundled JSON file. Adding a new island, harbour, route, waypoint,
/// or Peilplan value only requires modifying the JSON data, not the calculation code.
///
/// The catalog is designed so future areas (North Frisian, Dutch Wadden Sea)
/// can be supported by adding more data.
struct WaddenSeaCatalog: Codable, Equatable {
    var stations: [TidalReferenceStation]
    var waypoints: [WaypointTemplate]
    var routeTemplates: [RouteTemplate]

    // MARK: Lookup

    func station(byID id: String) -> TidalReferenceStation? {
        stations.first { $0.id == id }
    }

    func waypointTemplate(byID id: UUID) -> WaypointTemplate? {
        waypoints.first { $0.id == id }
    }

    /// Find route templates that connect the given start and destination waypoint templates.
    func routeTemplates(from startID: UUID, to destinationID: UUID) -> [RouteTemplate] {
        routeTemplates.filter {
            $0.startWaypointID == startID && $0.destinationWaypointID == destinationID
        }
    }

    /// Find route templates that connect harbours matching the given HarbourOption IDs.
    /// Maps HarbourOption IDs to WaypointTemplate names for matching.
    func routeTemplates(fromHarbourID startHarbourID: String, toHarbourID destHarbourID: String) -> [RouteTemplate] {
        // Find waypoint templates that match the harbour IDs by name prefix.
        let startTemplates = waypoints.filter { wp in
            harbourIDMatches(harbourID: startHarbourID, waypointName: wp.name)
        }
        let destTemplates = waypoints.filter { wp in
            harbourIDMatches(harbourID: destHarbourID, waypointName: wp.name)
        }

        var matches: [RouteTemplate] = []
        for st in startTemplates {
            for dt in destTemplates {
                matches.append(contentsOf: routeTemplates(from: st.id, to: dt.id))
            }
        }
        return matches
    }

    /// Find a waypoint template matching a HarbourOption ID.
    func waypointTemplate(forHarbourID harbourID: String) -> WaypointTemplate? {
        waypoints.first { wp in
            harbourIDMatches(harbourID: harbourID, waypointName: wp.name)
        }
    }

    private func harbourIDMatches(harbourID: String, waypointName: String) -> Bool {
        let normalized = harbourID.replacingOccurrences(of: "_harbor", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        return waypointName.lowercased().contains(normalized)
    }

    /// All waypoint templates of category "Hafen".
    var harbourWaypoints: [WaypointTemplate] {
        waypoints.filter { $0.category == "Hafen" }
    }

    // MARK: Loading

    /// Load the catalog from the bundled JSON resource.
    static func loadBundled() -> WaddenSeaCatalog {
        guard let url = Bundle.main.url(forResource: "wadden_sea_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return WaddenSeaCatalog(stations: [], waypoints: [], routeTemplates: [])
        }

        let decoder = JSONDecoder()
        return (try? decoder.decode(WaddenSeaCatalog.self, from: data))
            ?? WaddenSeaCatalog(stations: [], waypoints: [], routeTemplates: [])
    }

    /// Build a RoutePlan from a route template with user parameters.
    func buildRoutePlan(
        from template: RouteTemplate,
        date: Date,
        startTime: Date,
        speedKnots: Double? = nil,
        bshCorrectionMeters: Double = 0,
        tidalStateLabel: String = "Mitteltide"
    ) -> RoutePlan? {
        let waypointTemplates = template.waypointTemplateIDs.compactMap { waypointTemplate(byID: $0) }
        guard waypointTemplates.count == template.waypointTemplateIDs.count else { return nil }

        let routeWaypoints = waypointTemplates.map { $0.toRouteWaypoint() }
        let speed = speedKnots ?? template.defaultSpeedKnots

        var legs: [RouteLeg] = []
        for i in 0 ..< routeWaypoints.count - 1 {
            let distance = i < template.defaultLegDistancesNm.count
                ? template.defaultLegDistancesNm[i] : 0
            let current = i < template.defaultTidalCurrentsKnots.count
                ? template.defaultTidalCurrentsKnots[i] : 0

            legs.append(RouteLeg(
                id: UUID(),
                fromWaypointID: routeWaypoints[i].id,
                toWaypointID: routeWaypoints[i + 1].id,
                distanceNm: distance,
                courseDegrees: nil,
                speedThroughWaterKnots: speed,
                tidalCurrentKnots: current
            ))
        }

        return RoutePlan(
            id: UUID(),
            date: date,
            routeName: template.name,
            plannedStartTime: startTime,
            waypoints: routeWaypoints,
            legs: legs,
            bshWaterLevelCorrectionMeters: bshCorrectionMeters,
            tidalStateLabel: tidalStateLabel
        )
    }

    /// Build a direct (2-waypoint) fallback route from harbour options.
    func buildDirectRoute(
        startHarbourID: String,
        destinationHarbourID: String,
        date: Date,
        startTime: Date,
        distanceNm: Double,
        speedKnots: Double,
        bshCorrectionMeters: Double = 0
    ) -> RoutePlan {
        let startWP: RouteWaypoint
        if let template = waypointTemplate(forHarbourID: startHarbourID) {
            startWP = template.toRouteWaypoint()
        } else {
            let harbour = HarbourOption.byID(startHarbourID)
            startWP = RouteWaypoint(
                id: UUID(), name: harbour.name,
                latitude: harbour.latitude, longitude: harbour.longitude,
                tidalReferenceStation: harbour.tideStationName,
                tidalReferenceStationID: harbour.tideStationID,
                highWaterOffsetMinutes: 0,
                calculationMode: .meanHighWater,
                notes: "Direkte Route ohne Zwischenpunkte",
                category: "Hafen"
            )
        }

        let destWP: RouteWaypoint
        if let template = waypointTemplate(forHarbourID: destinationHarbourID) {
            destWP = template.toRouteWaypoint()
        } else {
            let harbour = HarbourOption.byID(destinationHarbourID)
            destWP = RouteWaypoint(
                id: UUID(), name: harbour.name,
                latitude: harbour.latitude, longitude: harbour.longitude,
                tidalReferenceStation: harbour.tideStationName,
                tidalReferenceStationID: harbour.tideStationID,
                highWaterOffsetMinutes: 0,
                calculationMode: .meanHighWater,
                notes: "Direkte Route ohne Zwischenpunkte",
                category: "Hafen"
            )
        }

        let leg = RouteLeg(
            id: UUID(),
            fromWaypointID: startWP.id,
            toWaypointID: destWP.id,
            distanceNm: distanceNm,
            speedThroughWaterKnots: speedKnots,
            tidalCurrentKnots: 0
        )

        return RoutePlan(
            id: UUID(),
            date: date,
            routeName: "\(startWP.name) → \(destWP.name)",
            plannedStartTime: startTime,
            waypoints: [startWP, destWP],
            legs: [leg],
            bshWaterLevelCorrectionMeters: bshCorrectionMeters,
            tidalStateLabel: "Mitteltide"
        )
    }
}
