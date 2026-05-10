import Foundation

// MARK: - Boat Settings

/// Boat configuration used in all water-clearance calculations.
/// Values are read from `@AppStorage` in the view layer.
struct BoatSettings {
    /// Boat draft in meters. Must be > 0.
    var draftMeters: Double
    /// Minimum clearance under keel required. Default 0.0 m (matching Excel).
    /// The UI should recommend a positive value (e.g. 0.30 m).
    var safetyMarginMeters: Double
}

// MARK: - Waypoint Calculation Mode

/// Determines how available water depth is calculated at a waypoint.
///
/// - `meanHighWater`: Uses MHW as the reference level. Chart depth / Peilplan value is applied.
/// - `lottiefe`: Uses Lottiefe (controlling sounding depth). Chart depth is NOT applied.
enum WaypointCalculationMode: String, Codable, CaseIterable, Identifiable {
    case meanHighWater
    case lottiefe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meanHighWater: return "MHW"
        case .lottiefe: return "Lottiefe"
        }
    }
}

// MARK: - Source Metadata

/// Tracks where a planning value originated.
/// The UI must show that catalog/default values require skipper verification.
enum ValueSource: String, Codable {
    case bsh = "bsh"
    case catalog = "catalog"
    case cache = "cache"
    case manual = "manual"
    case weatherService = "weather"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .bsh: return "BSH"
        case .catalog: return "Vorgabe"
        case .cache: return "Cache"
        case .manual: return "Manuell"
        case .weatherService: return "DWD"
        case .unknown: return "Unbekannt"
        }
    }
}

/// A numeric value paired with its source and optional notes.
struct SourcedValue<T: Codable>: Codable where T: Equatable {
    var value: T
    var source: ValueSource
    var sourceNotes: String?
}

extension SourcedValue: Equatable {}

// MARK: - Route Waypoint

/// A waypoint in a tidal route with full tidal metadata.
///
/// The calculation engine consumes this structure generically.
/// No field references a fixed waypoint name, island, or route.
struct RouteWaypoint: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double?
    var longitude: Double?

    /// BSH tidal reference station name (e.g. "Emden, Große Seeschleuse").
    var tidalReferenceStation: String
    /// BSH tidal reference station ID (e.g. "507P"). Provisional; may be unavailable.
    var tidalReferenceStationID: String

    /// Signed offset in minutes from reference station HW to waypoint HW.
    /// Positive = waypoint HW is later than reference HW.
    var highWaterOffsetMinutes: Int

    /// Mean Tidal Range in meters (Mittlerer Tidenhub).
    var meanTidalRangeMeters: SourcedValue<Double>?
    /// Mean High Water in meters. Required for `.meanHighWater` mode.
    var meanHighWaterMeters: SourcedValue<Double>?
    /// Lottiefe (controlling sounding depth) in meters. Required for `.lottiefe` mode.
    var lottiefeMeters: SourcedValue<Double>?
    /// Chart depth / Peilplan value in meters. Can be positive or negative.
    /// Required for `.meanHighWater` mode. Must NOT be applied in `.lottiefe` mode.
    var chartDepthMeters: SourcedValue<Double>?

    /// Which calculation formula to use for this waypoint.
    var calculationMode: WaypointCalculationMode

    /// Optional per-waypoint BSH water-level correction override.
    /// If nil, the route-level value is used. Prepared for future per-WP support.
    var bshWaterLevelCorrectionOverride: Double?

    /// User-entered high-water time override. If set, bypasses TideDataProvider.
    var manualHighWaterTime: Date?

    /// Free-text notes or source references.
    var notes: String

    /// Category for display (e.g. "Hafen", "Wattenhoch", "Fahrwasser").
    var category: String?
    /// Associated island name, if any (e.g. "Norderney").
    var island: String?
}

// MARK: - Route Leg

/// One leg between consecutive waypoints.
struct RouteLeg: Identifiable, Codable, Equatable {
    var id: UUID
    var fromWaypointID: UUID
    var toWaypointID: UUID
    /// Distance in nautical miles. Must be >= 0.
    var distanceNm: Double
    /// Optional course in degrees true.
    var courseDegrees: Double?
    /// Speed through water in knots. Must be > 0.
    var speedThroughWaterKnots: Double
    /// Tidal current correction in knots. Positive = favorable, negative = adverse.
    var tidalCurrentKnots: Double
}

// MARK: - Route Plan

/// A complete route definition with all waypoints, legs, and route-level parameters.
///
/// `waypoints[0]` is the start, `waypoints[last]` is the destination.
/// `legs.count == waypoints.count - 1`.
struct RoutePlan: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var routeName: String
    var plannedStartTime: Date
    /// Ordered waypoints: [start, ...intermediates..., destination].
    var waypoints: [RouteWaypoint]
    /// Legs connecting consecutive waypoints.
    var legs: [RouteLeg]
    /// Route-level BSH water-level correction in meters. Can be positive, zero, or negative.
    var bshWaterLevelCorrectionMeters: Double
    /// Display label for tidal state (e.g. "Springtide", "Mitteltide", "Nipptide").
    var tidalStateLabel: String
}

// MARK: - Calculation Results

/// Status of a single waypoint's tidal calculation.
enum WaypointStatus: String, Codable, Equatable {
    /// Clearance under keel >= safety margin.
    case go
    /// Clearance under keel >= 0 but < safety margin.
    case warning
    /// Clearance under keel < 0 (valid calculation, insufficient depth).
    case noGo
    /// Required input data is missing.
    case incomplete
    /// Calculation error (e.g. deviation > 12h, SOG <= 0).
    case invalid
}

/// Overall route tidal status.
enum RouteStatus: String, Codable, Equatable {
    case go
    case warning
    case noGo
    case incomplete
}

/// Result for a single leg.
struct LegCalculationResult: Equatable {
    var leg: RouteLeg
    var speedOverGroundKnots: Double
    var travelTimeHours: Double
    var departureTime: Date
    var arrivalTime: Date
    var cumulativeDistanceNm: Double
    var cumulativeTravelTimeHours: Double
    var isValid: Bool
    var messages: [String]
}

/// Full result for a single waypoint's tidal calculation.
struct WaypointCalculationResult: Identifiable, Equatable {
    var id: UUID { waypoint.id }
    var waypoint: RouteWaypoint
    var arrivalTime: Date
    var relevantHighWaterTime: Date?
    var deviationHours: Double?
    var oneTwelfthMeters: Double?
    /// "Fehlmenge Wasser" — water deficit relative to HW.
    var missingWaterFmWMeters: Double?
    var baseWaterAtTideMeters: Double?
    var bshWaterLevelCorrectionMeters: Double
    /// Chart depth applied. Nil for Lottiefe mode.
    var chartDepthMetersApplied: Double?
    /// Tide height (HG). Nil for Lottiefe mode ("leer" in Excel).
    var tideHeightHGMeters: Double?
    /// Available water depth (WT).
    var availableWaterDepthWTMeters: Double?
    var boatDraftMeters: Double
    /// Clearance under keel (WuK).
    var clearanceUnderKeelWuKMeters: Double?
    var status: WaypointStatus
    var messages: [String]
}

/// Weather assessment for route safety.
enum WeatherStatus: String, Codable, Equatable {
    case go
    case warning
    case noGo
    case incomplete
}

/// Combined final route decision.
///
/// Final status = combine(tidalStatus, weatherStatus):
/// - No-Go if either is No-Go
/// - Warning if either is Warning and neither is No-Go
/// - If weather is not available yet, the tidal decision remains visible
/// - Incomplete if critical tidal data is missing
enum CombinedRouteStatus: String, Equatable {
    case go
    case warning
    case noGo
    case incomplete

    static func combine(tidal: RouteStatus, weather: WeatherStatus) -> CombinedRouteStatus {
        if tidal == .noGo || weather == .noGo { return .noGo }
        if tidal == .incomplete { return .incomplete }
        if tidal == .warning || weather == .warning { return .warning }
        return .go
    }
}

/// Complete route calculation result.
struct RouteCalculationResult: Equatable {
    var waypointResults: [WaypointCalculationResult]
    var legResults: [LegCalculationResult]
    var totalDistanceNm: Double
    var totalTravelTimeHours: Double
    var worstClearanceUnderKeel: Double?
    var tidalStatus: RouteStatus
    var weatherStatus: WeatherStatus
    var combinedStatus: CombinedRouteStatus
    var messages: [String]
}
