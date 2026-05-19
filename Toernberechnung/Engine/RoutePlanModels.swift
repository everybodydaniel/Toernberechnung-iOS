import Foundation

/// Bootskonfiguration für alle Berechnungen zum Wasser unter dem Kiel.
/// Werte werden im View-Layer aus `@AppStorage` gelesen.
struct BoatSettings {
    /// Tiefgang in Metern. Muss > 0 sein.
    var draftMeters: Double
    /// Mindest-Wasser unter dem Kiel. Standard: 0,0 m (wie in Excel).
    /// Die UI sollte einen positiven Wert empfehlen (z. B. 0,30 m).
    var safetyMarginMeters: Double
}

/// Legt fest, wie die verfügbare Wassertiefe an einem Wegpunkt berechnet wird.
///
/// - `meanHighWater`: MHW als Bezugsniveau. Kartentiefe/Peilplanwert wird angewendet.
/// - `lottiefe`: Lottiefe (maßgebliche Peiltiefe). Kartentiefe wird NICHT angewendet.
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

/// Hält fest, woher ein Planungswert stammt.
/// Die UI muss anzeigen, dass Katalog-/Standardwerte vom Skipper geprüft werden müssen.
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

/// Ein numerischer Wert zusammen mit Quelle und optionalen Notizen.
struct SourcedValue<T: Codable>: Codable where T: Equatable {
    var value: T
    var source: ValueSource
    var sourceNotes: String?
}

extension SourcedValue: Equatable {}

/// Ein Wegpunkt einer Tidenroute mit vollständigen Tiden-Metadaten.
///
/// Die Berechnungsengine verarbeitet diese Struktur generisch.
/// Kein Feld verweist auf einen festen Wegpunktnamen, eine Insel oder eine Route.
struct RouteWaypoint: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double?
    var longitude: Double?

    /// Name der BSH-Tidenreferenzstation (z. B. „Emden, Große Seeschleuse“).
    var tidalReferenceStation: String
    /// BSH-Stations-ID (z. B. „507P“). Vorläufig; ggf. nicht verfügbar.
    var tidalReferenceStationID: String

    /// Vorzeichenbehafteter HW-Offset in Minuten von der Referenzstation zum Wegpunkt.
    /// Positiv = HW am Wegpunkt liegt nach dem HW der Referenzstation.
    var highWaterOffsetMinutes: Int

    /// Mittlerer Tidenhub (MTH) in Metern.
    var meanTidalRangeMeters: SourcedValue<Double>?
    /// Mittleres Hochwasser (MHW) in Metern. Erforderlich für `.meanHighWater`-Modus.
    var meanHighWaterMeters: SourcedValue<Double>?
    /// Lottiefe (maßgebliche Peiltiefe) in Metern. Erforderlich für `.lottiefe`-Modus.
    var lottiefeMeters: SourcedValue<Double>?
    /// Kartentiefe / Peilplanwert in Metern. Kann positiv oder negativ sein.
    /// Erforderlich für `.meanHighWater`-Modus. Im `.lottiefe`-Modus NICHT anwenden.
    var chartDepthMeters: SourcedValue<Double>?

    /// Welche Berechnungsformel an diesem Wegpunkt verwendet wird.
    var calculationMode: WaypointCalculationMode

    /// Optionaler BSH-Wasserstandskorrektur-Override pro Wegpunkt.
    /// Wenn nil, wird der Routenwert verwendet. Vorbereitung für künftige Per-WP-Unterstützung.
    var bshWaterLevelCorrectionOverride: Double?

    /// Manuell eingegebene Hochwasserzeit. Wenn gesetzt, wird der TideDataProvider umgangen.
    var manualHighWaterTime: Date?

    /// Freitext-Notizen oder Quellenangaben.
    var notes: String

    /// Anzeigekategorie (z. B. „Hafen“, „Wattenhoch“, „Fahrwasser“).
    var category: String?
    /// Zugehöriger Inselname, falls vorhanden (z. B. „Norderney“).
    var island: String?
}

/// Ein Leg zwischen zwei aufeinanderfolgenden Wegpunkten.
struct RouteLeg: Identifiable, Codable, Equatable {
    var id: UUID
    var fromWaypointID: UUID
    var toWaypointID: UUID
    /// Distanz in Seemeilen. Muss >= 0 sein.
    var distanceNm: Double
    /// Optionaler Kurs in Grad rechtweisend.
    var courseDegrees: Double?
    /// Fahrt durchs Wasser in Knoten. Muss > 0 sein.
    var speedThroughWaterKnots: Double
    /// Tidenstrom-Korrektur in Knoten. Positiv = mitlaufend, negativ = gegenlaufend.
    var tidalCurrentKnots: Double
}

/// Eine vollständige Routendefinition mit allen Wegpunkten, Legs und Routenparametern.
///
/// `waypoints[0]` ist der Start, `waypoints[last]` das Ziel.
/// Es gilt: `legs.count == waypoints.count - 1`.
struct RoutePlan: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var routeName: String
    var plannedStartTime: Date
    /// Geordnete Wegpunkte: [Start, …Zwischenpunkte…, Ziel].
    var waypoints: [RouteWaypoint]
    /// Legs, die aufeinanderfolgende Wegpunkte verbinden.
    var legs: [RouteLeg]
    /// BSH-Wasserstandskorrektur auf Routenebene in Metern. Positiv, null oder negativ.
    var bshWaterLevelCorrectionMeters: Double
    /// Anzeigelabel für die Tidenlage (z. B. „Springtide“, „Mitteltide“, „Nipptide“).
    var tidalStateLabel: String
}

/// Status der Tidenberechnung für einen einzelnen Wegpunkt.
enum WaypointStatus: String, Codable, Equatable {
    /// Wasser unter Kiel >= Sicherheitsmarge.
    case go
    /// Wasser unter Kiel >= 0, aber < Sicherheitsmarge.
    case warning
    /// Wasser unter Kiel < 0 (gültige Berechnung, Tiefe nicht ausreichend).
    case noGo
    /// Erforderliche Eingabedaten fehlen.
    case incomplete
    /// Berechnungsfehler (z. B. Abweichung > 12 h, SOG <= 0).
    case invalid
}

/// Gesamt-Tidenstatus der Route.
enum RouteStatus: String, Codable, Equatable {
    case go
    case warning
    case noGo
    case incomplete
}

/// Ergebnis für ein einzelnes Leg.
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

/// Vollständiges Ergebnis der Tidenberechnung für einen einzelnen Wegpunkt.
struct WaypointCalculationResult: Identifiable, Equatable {
    var id: UUID { waypoint.id }
    var waypoint: RouteWaypoint
    var arrivalTime: Date
    var relevantHighWaterTime: Date?
    var deviationHours: Double?
    var oneTwelfthMeters: Double?
    /// „Fehlmenge Wasser“ (FmW) — Wasserdefizit gegenüber dem HW.
    var missingWaterFmWMeters: Double?
    var baseWaterAtTideMeters: Double?
    var bshWaterLevelCorrectionMeters: Double
    /// Angewendete Kartentiefe. Nil im Lottiefe-Modus.
    var chartDepthMetersApplied: Double?
    /// Tidenhöhe (HG). Nil im Lottiefe-Modus („leer“ in Excel).
    var tideHeightHGMeters: Double?
    /// Verfügbare Wassertiefe (WT).
    var availableWaterDepthWTMeters: Double?
    var boatDraftMeters: Double
    /// Wasser unter dem Kiel (WuK).
    var clearanceUnderKeelWuKMeters: Double?
    var status: WaypointStatus
    var messages: [String]
}

/// Wetterbewertung für die Routensicherheit.
enum WeatherStatus: String, Codable, Equatable {
    case go
    case warning
    case noGo
    case incomplete
}

/// Kombinierte Endentscheidung für die Route.
///
/// Endstatus = combine(tidalStatus, weatherStatus):
/// - No-Go, wenn einer der beiden No-Go ist
/// - Warning, wenn einer Warning ist und keiner No-Go
/// - Solange das Wetter noch nicht verfügbar ist, bleibt die Tidenentscheidung sichtbar
/// - Incomplete, wenn kritische Tidendaten fehlen
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

/// Vollständiges Routenberechnungsergebnis.
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
