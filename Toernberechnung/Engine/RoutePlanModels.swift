import Foundation

// MARK: - Bootseinstellungen

/// Bootseinstellungen für alle Berechnungen des Wassers unter Kiel.
/// Die Oberfläche liest die Werte aus `@AppStorage`.
struct BoatSettings {
    /// Tiefgang des Boots in Metern. Muss größer als 0 sein.
    var draftMeters: Double
    /// Erforderlicher Mindestabstand unter Kiel. Standard: 0,0 m.
    /// Die Oberfläche sollte einen positiven Wert empfehlen, z. B. 0,30 m.
    var safetyMarginMeters: Double
}

// MARK: - Berechnungsmodus des Wegpunkts

/// Legt fest, wie die verfügbare Wassertiefe am Wegpunkt berechnet wird.
///
/// - `meanHighWater`: MHW als Bezugshöhe mit Kartentiefe oder Peilplanwert.
/// - `lottiefe`: Maßgebliche Lottiefe; die Kartentiefe wird nicht zusätzlich angewendet.
enum WaypointCalculationMode: String, Codable, CaseIterable, Identifiable {
    case meanHighWater
    case lottiefe

    var id: String { rawValue }


}

// MARK: - Angaben zur Datenherkunft

/// Hält fest, woher ein Planungswert stammt.
/// Die Oberfläche muss auf die nötige Prüfung von Katalog- und Standardwerten durch den Skipper hinweisen.
enum ValueSource: String, Codable {
    case bsh = "bsh"
    case catalog = "catalog"
    case cache = "cache"
    case manual = "manual"
    case weatherService = "weather"
    case unknown = "unknown"


}

/// Zahlenwert mit Quelle und optionalen Hinweisen.
struct SourcedValue<T: Codable>: Codable where T: Equatable {
    var value: T
    var source: ValueSource
    var sourceNotes: String?
    /// Datum der Lotung. Ältere Katalogwerte ohne Datum bleiben vorläufig.
    var surveyedAt: Date? = nil
    var sourceURL: String? = nil
}

extension SourcedValue: Equatable {}

// MARK: - Routenwegpunkt

/// Wegpunkt einer gezeitenabhängigen Route mit allen Gezeitenangaben.
///
/// Die Berechnung verarbeitet diese Struktur allgemein. Kein Feld
/// setzt einen festen Wegpunktnamen, eine Insel oder eine bestimmte Route voraus.
struct RouteWaypoint: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double?
    var longitude: Double?

    /// Name der BSH-Gezeitenreferenzstation (z. B. "Emden, Große Seeschleuse").
    var tidalReferenceStation: String
    /// Kennung der BSH-Gezeitenreferenzstation (z. B. "507P"). Vorläufig; kann fehlen.
    var tidalReferenceStationID: String

    /// Vorzeichenbehafteter Versatz in Minuten zwischen Referenz- und Wegpunkthochwasser.
    /// Positiv bedeutet, dass das Hochwasser am Wegpunkt später eintritt.
    var highWaterOffsetMinutes: Int

    /// Mittlerer Tidenhub in Metern.
    var meanTidalRangeMeters: SourcedValue<Double>?
    /// Mittleres Hochwasser in Metern. Erforderlich für `.meanHighWater`.
    var meanHighWaterMeters: SourcedValue<Double>?
    /// Maßgebliche Lottiefe in Metern. Erforderlich für `.lottiefe`.
    var lottiefeMeters: SourcedValue<Double>?
    /// Kartentiefe oder Peilplanwert in Metern; kann positiv oder negativ sein.
    /// Für `.meanHighWater` erforderlich, bei `.lottiefe` nicht zusätzlich anzuwenden.
    var chartDepthMeters: SourcedValue<Double>?

    /// Berechnungsformel für diesen Wegpunkt.
    var calculationMode: WaypointCalculationMode

    /// Optionaler eigener BSH-Wasserstandskorrekturwert für diesen Wegpunkt.
    /// Bei nil gilt der Routenwert. Für spätere Unterstützung einzelner Wegpunkte vorbereitet.
    var bshWaterLevelCorrectionOverride: Double?

    /// Manuell eingegebene Hochwasserzeit. Umgeht bei gesetztem Wert den TideDataProvider.
    var manualHighWaterTime: Date?

    /// Freie Hinweise oder Quellenangaben.
    var notes: String

    /// Kategorie für die Anzeige (z. B. "Hafen", "Wattenhoch", "Fahrwasser").
    var category: String?
    /// Zugehörige Insel, falls vorhanden (z. B. "Norderney").
    var island: String?
}

// MARK: - Streckenabschnitt

/// Abschnitt zwischen zwei aufeinanderfolgenden Wegpunkten.
struct RouteLeg: Identifiable, Codable, Equatable {
    var id: UUID
    var fromWaypointID: UUID
    var toWaypointID: UUID
    /// Entfernung in Seemeilen. Muss mindestens 0 sein.
    var distanceNm: Double
    /// Optionaler rechtweisender Kurs in Grad.
    var courseDegrees: Double?
    /// Fahrt durchs Wasser in Knoten. Muss größer als 0 sein.
    var speedThroughWaterKnots: Double
    /// Gezeitenströmung in Knoten. Positiv = mitlaufend, negativ = gegenlaufend.
    var tidalCurrentKnots: Double
}

// MARK: - Routenplan

/// Vollständige Route mit allen Wegpunkten, Streckenabschnitten und gemeinsamen Parametern.
///
/// `waypoints[0]` ist der Start, `waypoints[last]` das Ziel.
/// `legs.count == waypoints.count - 1`.
struct RoutePlan: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var routeName: String
    var plannedStartTime: Date
    /// Wegpunkte in Reihenfolge: Start, Zwischenstopps, Ziel.
    var waypoints: [RouteWaypoint]
    /// Streckenabschnitte zwischen aufeinanderfolgenden Wegpunkten.
    var legs: [RouteLeg]
    /// `nil` verwendet die BSH-Vorhersage; ein ausdrücklich gesetzter Wert `0`
    /// bedeutet keine wetterbedingte Wasserstandsabweichung.
    var bshWaterLevelCorrectionMeters: Double?
    /// Bezeichnung des Gezeitenzustands (z. B. "Springtide", "Mitteltide", "Nipptide").
    var tidalStateLabel: String
}

// MARK: - Berechnungsergebnisse

/// Status der Gezeitenberechnung eines einzelnen Wegpunkts.
enum WaypointStatus: String, Codable, Equatable {
    /// Wasser unter Kiel ist mindestens so groß wie der Sicherheitsabstand.
    case go
    /// Wasser unter Kiel ist mindestens 0, aber kleiner als der Sicherheitsabstand.
    case warning
    /// Wasser unter Kiel ist negativ: Berechnung gültig, Wassertiefe unzureichend.
    case noGo
    /// Erforderliche Eingabedaten fehlen.
    case incomplete
    /// Berechnungsfehler, z. B. Abweichung über 12 h oder SOG <= 0.
    case invalid
}

/// Gezeitenstatus der gesamten Route.
enum RouteStatus: String, Codable, Equatable {
    case go
    case warning
    case noGo
    case incomplete
}

/// Ergebnis eines einzelnen Streckenabschnitts.
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

/// Vollständiges Ergebnis der Gezeitenberechnung eines Wegpunkts.

struct WaypointCalculationResult: Identifiable, Equatable {
    var id: UUID { waypoint.id }
    var waypoint: RouteWaypoint
    /// Excel `L31`: Zeitpunkt am Wegpunkt.
    var arrivalTime: Date
    /// Excel `L23`: passendes Hochwasser am Referenzpegel vor Anwendung
    /// des Wegpunktversatzes. Unterscheidet sich von `relevantHighWaterTime`.
    var referenceHighWaterTime: Date?
    /// Excel `L29`: Hochwasser am Wegpunkt, also `L23 ± M25/M27`.
    var relevantHighWaterTime: Date?
    /// Excel `L37`.
    var deviationHours: Double?
    /// Excel `L33`: tatsächlich verwendeter mittlerer Tidenhub nach
    /// der Auswahl in der Reihenfolge manuelle Eingabe → BSH → Katalog.
    var meanTidalRangeMeters: Double?
    /// Excel `L41` (MHW) oder `L43` (Lottiefe), je nach Berechnungsmodus.
    var referenceLevelMeters: Double?
    /// Excel `L35`.
    var oneTwelfthMeters: Double?
    /// Excel `L39`: Fehlmenge Wasser gegenüber dem Hochwasser.
    var missingWaterFmWMeters: Double?
    /// Excel `L45`.
    var baseWaterAtTideMeters: Double?
    /// Excel `L47`.
    var bshWaterLevelCorrectionMeters: Double
    var waterLevelCorrectionQuality: WaterLevelCorrectionQuality
    /// Herkunft der Wasserstandskorrektur, angezeigt neben `L47`.
    var waterLevelCorrectionDetail: String?
    /// Excel `L51`. Im Lottiefe-Modus nil.
    var chartDepthMetersApplied: Double?
    /// Excel `L49`: Gezeitenhöhe (HG). Im Lottiefe-Modus nil ("leer").
    var tideHeightHGMeters: Double?
    /// Excel `L53`: verfügbare Wassertiefe (WT).
    var availableWaterDepthWTMeters: Double?
    /// Excel `M55`.
    var boatDraftMeters: Double
    /// Excel `L57`: Wasser unter Kiel (WuK).
    var clearanceUnderKeelWuKMeters: Double?
    var status: WaypointStatus
    var messages: [String]
}

/// Wetterbewertung für die Befahrbarkeit der Route.
enum WeatherStatus: String, Codable, Equatable {
    case go
    case warning
    case noGo
    case incomplete
}

/// Zusammengeführte Bewertung der Route.
///
/// Gesamtstatus = combine(tidalStatus, weatherStatus):
/// - No-Go, wenn einer der beiden Statuswerte No-Go ist
/// - Warnung, wenn mindestens einer Warnung ist und keiner No-Go
/// - Unvollständig, solange eine zentrale Routen-, Gezeiten- oder Tiefenberechnung fehlt
///
/// Fehlendes Wetter bleibt als Hinweis in `WeatherStatus` erhalten, verdeckt aber
/// kein gültiges Gezeitenergebnis. Eine bekannte Wettergefahr hat immer Vorrang.
enum CombinedRouteStatus: String, Equatable {
    case go
    case warning
    case noGo
    case incomplete

    static func combine(tidal: RouteStatus, weather: WeatherStatus) -> CombinedRouteStatus {
        if tidal == .noGo || weather == .noGo { return .noGo }
        if tidal == .warning || weather == .warning { return .warning }
        if tidal == .incomplete { return .incomplete }
        return .go
    }
}

/// Vollständiges Ergebnis der Routenberechnung.
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
