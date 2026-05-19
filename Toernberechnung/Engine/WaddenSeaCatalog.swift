import Foundation

/// Eine BSH-Tidenreferenzstation bzw. -pegel.
/// Stations-IDs sind vorläufig und können von den aktuellen Online-Daten des BSH abweichen.
struct TidalReferenceStation: Identifiable, Codable, Equatable {
    
    var id: String
    /// Menschenlesbarer Stationsname (z. B. „Emden, Große Seeschleuse“).
    var name: String
    var latitude: Double?
    var longitude: Double?
    /// Standard-Mittlerer-Tidenhub (MTH), falls bekannt. Mit Quellen-Metadaten.
    var meanTidalRangeMeters: SourcedValue<Double>?
    /// Standard-Mittleres-Hochwasser (MHW), falls bekannt. Mit Quellen-Metadaten.
    var meanHighWaterMeters: SourcedValue<Double>?
}

/// Eine vorkonfigurierte Wegpunkt-Vorlage aus dem Katalog.
/// Vorlagen liefern Planungs-Standardwerte, die der Skipper überprüfen muss.
struct WaypointTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double?
    var longitude: Double?
    /// BSH-Tidenreferenzstations-ID.
    var tidalReferenceStationID: String
    /// Name der BSH-Tidenreferenzstation.
    var tidalReferenceStationName: String
    /// Vorzeichenbehafteter HW-Offset zur Referenzstation in Minuten.
    var highWaterOffsetMinutes: Int
    /// Berechnungsmodus: MHW-basiert oder Lottiefe-basiert.
    var calculationMode: WaypointCalculationMode
    /// Standard-Mittlerer-Tidenhub.
    var defaultMTH: SourcedValue<Double>?
    /// Standard-Mittleres-Hochwasser (für MHW-Modus).
    var defaultMHW: SourcedValue<Double>?
    /// Standard-Lottiefe (für Lottiefe-Modus).
    var defaultLottiefe: SourcedValue<Double>?
    /// Standard-Kartentiefe / Peilplanwert.
    var defaultChartDepth: SourcedValue<Double>?
    /// Zugehörige Insel (z. B. „Norderney“). Nil für Festland oder Fahrwasser.
    var island: String?
    /// Kategorie: „Hafen“, „Wattenhoch“, „Fahrwasser“, „Reede“.
    var category: String
    /// Notizen oder Quellenangabe.
    var notes: String

    /// Wandelt diese Vorlage in einen RouteWaypoint mit Katalog-Standardwerten um.
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

/// Optionale Komfort-Vorlage, die Wegpunkte mit Standard-Distanzen verbindet.
/// Routenvorlagen sind nicht zwingend — Nutzer können vollständig eigene Routen bauen.
struct RouteTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var description: String
    /// Geordnete Wegpunkt-Vorlagen-IDs: [Start, …Zwischenpunkte…, Ziel].
    var waypointTemplateIDs: [UUID]
    /// Standard-Legdistanzen in NM. Anzahl muss waypointTemplateIDs.count - 1 sein.
    var defaultLegDistancesNm: [Double]
    /// Standard-Tidenstrom je Leg in Knoten. Anzahl muss zur Leg-Anzahl passen.
    var defaultTidalCurrentsKnots: [Double]
    /// Standard-Fahrt durchs Wasser in Knoten.
    var defaultSpeedKnots: Double
    /// Komfort-Zugriff: Start-Wegpunkt-Vorlagen-ID.
    var startWaypointID: UUID { waypointTemplateIDs.first ?? UUID() }
    /// Komfort-Zugriff: Ziel-Wegpunkt-Vorlagen-ID.
    var destinationWaypointID: UUID { waypointTemplateIDs.last ?? UUID() }
}

/// Datengetriebener Katalog für das Ostfriesische Wattenmeer.
///
/// Wird aus einer mitgelieferten JSON-Datei geladen. Neue Inseln, Häfen, Routen,
/// Wegpunkte oder Peilplanwerte müssen nur in den JSON-Daten ergänzt werden,
/// nicht im Berechnungscode.
///
/// Der Katalog ist so ausgelegt, dass zukünftige Gebiete (Nordfriesland,
/// niederländisches Wattenmeer) durch weitere Daten ergänzt werden können.
struct WaddenSeaCatalog: Codable, Equatable {
    var stations: [TidalReferenceStation]
    var waypoints: [WaypointTemplate]
    var routeTemplates: [RouteTemplate]

    func station(byID id: String) -> TidalReferenceStation? {
        stations.first { $0.id == id }
    }

    func waypointTemplate(byID id: UUID) -> WaypointTemplate? {
        waypoints.first { $0.id == id }
    }

    /// Findet Routenvorlagen, die die gegebenen Start- und Ziel-Wegpunkt-Vorlagen verbinden.
    func routeTemplates(from startID: UUID, to destinationID: UUID) -> [RouteTemplate] {
        routeTemplates.filter {
            $0.startWaypointID == startID && $0.destinationWaypointID == destinationID
        }
    }

    /// Findet Routenvorlagen, die zu den gegebenen HarbourOption-IDs passen.
    /// Bildet HarbourOption-IDs auf WaypointTemplate-Namen zum Abgleich ab.
    func routeTemplates(fromHarbourID startHarbourID: String, toHarbourID destHarbourID: String) -> [RouteTemplate] {
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

    /// Findet eine Wegpunkt-Vorlage, die zur HarbourOption-ID passt.
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

    /// Alle Wegpunkt-Vorlagen der Kategorie „Hafen“.
    var harbourWaypoints: [WaypointTemplate] {
        waypoints.filter { $0.category == "Hafen" }
    }

    /// Lädt den Katalog aus der mitgelieferten JSON-Ressource.
    static func loadBundled() -> WaddenSeaCatalog {
        guard let url = Bundle.main.url(forResource: "wadden_sea_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return WaddenSeaCatalog(stations: [], waypoints: [], routeTemplates: [])
        }

        let decoder = JSONDecoder()
        return (try? decoder.decode(WaddenSeaCatalog.self, from: data))
            ?? WaddenSeaCatalog(stations: [], waypoints: [], routeTemplates: [])
    }

    /// Baut einen RoutePlan aus einer Routenvorlage mit Nutzerparametern.
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

    /// Baut eine direkte 2-Wegpunkt-Fallback-Route aus Hafenoptionen.
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
