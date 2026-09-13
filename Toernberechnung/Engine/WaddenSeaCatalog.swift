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

    // MARK: Lookup

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

    // MARK: Loading

    /// Load the catalog from the bundled JSON resource.
    static func loadBundled() -> WaddenSeaCatalog {
        guard let url = Bundle.main.url(forResource: "wadden_sea_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return WaddenSeaCatalog(stations: [], waypoints: [])
        }

        let decoder = JSONDecoder()
        return (try? decoder.decode(WaddenSeaCatalog.self, from: data))
            ?? WaddenSeaCatalog(stations: [], waypoints: [])
    }
}
