import Foundation

// MARK: - Gezeitenreferenzstation

/// BSH-Gezeitenreferenzstation oder Pegel.
/// Stationskennungen sind vorläufig und können von aktuellen BSH-Daten abweichen.
struct TidalReferenceStation: Identifiable, Codable, Equatable {
    /// BSH-Stationskennung, z. B. "507P". Kann fehlen oder umbenannt worden sein.
    var id: String
    /// Lesbarer Stationsname, z. B. "Emden, Große Seeschleuse".
    var name: String
    var latitude: Double?
    var longitude: Double?
    /// Bekannter Standardwert für den mittleren Tidenhub mit Quellenangabe.
    var meanTidalRangeMeters: SourcedValue<Double>?
    /// Bekannter Standardwert für das mittlere Hochwasser mit Quellenangabe.
    var meanHighWaterMeters: SourcedValue<Double>?
}

// MARK: - Wegpunktvorlage

/// Vorbereitete Wegpunktvorlage aus dem Katalog.
/// Planungswerte aus Vorlagen müssen vom Skipper geprüft werden.
struct WaypointTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double?
    var longitude: Double?
    /// Kennung der BSH-Gezeitenreferenzstation.
    var tidalReferenceStationID: String
    /// Name der BSH-Gezeitenreferenzstation.
    var tidalReferenceStationName: String
    /// Vorzeichenbehafteter Hochwasserversatz gegenüber der Referenzstation in Minuten.
    var highWaterOffsetMinutes: Int
    /// Berechnungsmodus auf Grundlage von MHW oder Lottiefe.
    var calculationMode: WaypointCalculationMode
    /// Standardwert für den mittleren Tidenhub.
    var defaultMTH: SourcedValue<Double>?
    /// Standardwert für das mittlere Hochwasser im MHW-Modus.
    var defaultMHW: SourcedValue<Double>?
    /// Standardwert für die Lottiefe im Lottiefe-Modus.
    var defaultLottiefe: SourcedValue<Double>?
    /// Standardwert für Kartentiefe oder Peilplan.
    var defaultChartDepth: SourcedValue<Double>?
    /// Zugehörige Insel, z. B. "Norderney". Bei Festland und Fahrwasser nil.
    var island: String?
    /// Kategorie: "Hafen", "Wattenhoch", "Fahrwasser", "Reede".
    var category: String
    /// Hinweise oder Quellenangabe.
    var notes: String

    /// Erstellt aus der Vorlage einen RouteWaypoint mit Katalogwerten.
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

// MARK: - Wattenmeerkatalog

/// Datenbasierter Katalog für das ostfriesische Wattenmeer.
///
/// Wird aus einer mitgelieferten JSON-Datei geladen. Neue Inseln, Häfen, Routen,
/// Wegpunkte oder Peilplanwerte werden in den Daten ergänzt, ohne den Rechencode zu ändern.
///
/// Weitere Daten können künftig auch andere Gebiete wie das nordfriesische
/// oder niederländische Wattenmeer abdecken.
struct WaddenSeaCatalog: Codable, Equatable {
    var stations: [TidalReferenceStation]
    var waypoints: [WaypointTemplate]

    // MARK: Nachschlagen

    /// Sucht eine Wegpunktvorlage zur Kennung einer HarbourOption.
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

    // MARK: Laden

    /// Lädt den Katalog aus der mitgelieferten JSON-Datei.
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
