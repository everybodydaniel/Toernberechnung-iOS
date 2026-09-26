import Foundation

// MARK: - Protokoll für Gezeitendatenanbieter

/// Schnittstelle für Gezeitenereignisse einer BSH-Referenzstation.
///
/// Unterstützt verschiedene Datenquellen:
/// - BSH-Online-API (`BSHTideDataProvider`)
/// - Testdaten (`MockTideDataProvider`)
/// - Manuelle Eingabe als Ersatz
///
/// Unbekannte, fehlende, umbenannte oder nicht unterstützte Stationskennungen
/// müssen kontrolliert behandelt werden. Fehlende Daten dürfen keinen Absturz auslösen.
protocol TideDataProvider {
    var usesForecastWaterLevels: Bool { get }
    func routeEvents(for waypoint: RouteWaypoint, covering span: ClosedRange<Date>) async throws -> [TideEvent]
    /// Vollständige Hoch- und Niedrigwasserdaten einschließlich benachbarter Ereignisse außerhalb des angefragten Zeitraums.
    func tidalEvents(for stationID: String, covering span: ClosedRange<Date>) async throws -> [TideEvent]

    /// Lädt Hochwasserereignisse einer Referenzstation um ein Datum.
    ///
    /// - Parameters:
    ///   - stationID: BSH-Stationskennung, z. B. "507P". Kann vorläufig oder fehlerhaft sein.
    ///   - date: Ungefähres Datum für die Suche.
    /// - Returns: Nach Zeit sortierte `TideEvent`-Liste; bei unbekannter Station leer.
    /// - Throws: Netzwerk- oder Einlesefehler. Unbekannte Stationen liefern eine leere Liste statt eines Fehlers.
    func highWaters(
        for stationID: String,
        around date: Date
    ) async throws -> [TideEvent]

    /// Lädt den mittleren Tidenhub einer Station, sofern die Quelle ihn liefert.
    /// Gibt andernfalls nil zurück.
    func meanTidalRange(for stationID: String) async throws -> Double?

    /// Lädt das mittlere Hochwasser einer Station, sofern die Quelle es liefert.
    /// Gibt andernfalls nil zurück.
    func meanHighWater(for stationID: String) async throws -> Double?

    /// BSH-Referenzwerte des aktuellen Jahres und Angaben zu verfügbaren Stationsdaten.
    func stationReference(
        for stationID: String,
        around date: Date
    ) async throws -> TideStationReference?

    /// Vorsichtige wetterbedingte Korrektur für den passenden Hochwasserzyklus.
    /// Eine Vergleichsstation wird nur verwendet, wenn sie ausdrücklich angegeben ist.
    func waterLevelCorrection(
        for stationID: String,
        at highWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionResolution

    /// Zeitabhängige Korrektur über `span`. An einem Wegpunkt mit Ankunft weit
    /// vor oder nach Hochwasser wird dadurch nicht die Spitzenabweichung verwendet.
    ///
    /// `anchorHighWaterTime` wählt den Hochwasserzyklus des Pegels samt Unsicherheitsbereich.
    /// Der Aufrufer wertet das Ergebnis zur tatsächlichen Ankunftszeit aus.
    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries
}

extension TideDataProvider {
    var usesForecastWaterLevels: Bool { false }
    func routeEvents(for waypoint: RouteWaypoint, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        try await tidalEvents(for: waypoint.tidalReferenceStationID, covering: span)
    }
    func tidalEvents(for stationID: String, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        // Kompatibilität für manuelle und Testanbieter, die nur Hochwasser liefern.
        let middle = span.lowerBound.addingTimeInterval(span.upperBound.timeIntervalSince(span.lowerBound) / 2)
        return try await highWaters(for: stationID, around: middle)
    }

    /// Anbieter ohne Vorhersagekurve behalten das bisherige Verhalten:
    /// ein Wert am Hochwassergipfel wird für den gesamten Zeitraum angewendet.
    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries {
        .constant(await waterLevelCorrection(
            for: stationID,
            at: anchorHighWaterTime,
            confirmedComparisonStationID: confirmedComparisonStationID
        ))
    }
}

// MARK: - BSH-Gezeitendatenanbieter

/// Bindet den vorhandenen `BSHTideService` an `TideDataProvider` an.
///
/// Ordnet Stationskennungen einer `HarbourOption` für den BSH-Abruf zu.
/// Unbekannte Kennungen liefern leere Ergebnisse, damit die Berechnung
/// den Wegpunkt als unvollständig markieren kann.
final class BSHTideDataProvider: TideDataProvider {
    var usesForecastWaterLevels: Bool { true }
    func routeEvents(for waypoint: RouteWaypoint, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        guard let latitude = waypoint.latitude, let longitude = waypoint.longitude else { return [] }
        return try await BSHPassageForecastStore.shared.events(
            latitude: latitude, longitude: longitude, covering: span
        )
    }
    func tidalEvents(for stationID: String, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        try await BSHTideService.shared.tidalEvents(for: stationID, covering: span)
    }


    func highWaters(
        for stationID: String,
        around date: Date
    ) async throws -> [TideEvent] {
        do {
            return try await BSHTideService.shared.highWaters(for: stationID, around: date)
        } catch {
            // Bei fehlgeschlagenem BSH-Abruf leeres Ergebnis liefern, damit der Wegpunkt als unvollständig gilt.
            return []
        }
    }

    func meanTidalRange(for stationID: String) async throws -> Double? {
        try await BSHTideService.shared.reference(for: stationID, around: .now)?.meanTidalRangeMeters
    }

    func meanHighWater(for stationID: String) async throws -> Double? {
        try await BSHTideService.shared.reference(for: stationID, around: .now)?.meanHighWaterAboveSknMeters
    }

    func stationReference(
        for stationID: String,
        around date: Date
    ) async throws -> TideStationReference? {
        try await BSHTideService.shared.reference(for: stationID, around: date)
    }

    func waterLevelCorrection(
        for stationID: String,
        at highWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionResolution {
        await BSHWaterLevelForecastService.shared.correction(
            for: stationID,
            at: highWaterTime,
            comparisonStationID: confirmedComparisonStationID
        )
    }

    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries {
        await BSHWaterLevelForecastService.shared.correctionSeries(
            for: stationID,
            covering: span,
            anchorHighWaterTime: anchorHighWaterTime,
            comparisonStationID: confirmedComparisonStationID
        )
    }
}

// MARK: - Gezeitendatenanbieter für Tests

/// Testanbieter mit einstellbaren Gezeitenereignissen.
final class MockTideDataProvider: TideDataProvider {
    var tidalEventsByStation: [String: [TideEvent]] = [:]
    func tidalEvents(for stationID: String, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        if shouldThrow { throw BSHTideError.badResponse }
        if let events = tidalEventsByStation[stationID] { return events }
        return try await highWaters(for: stationID, around: span.lowerBound)
    }

    /// Vorbereitete Hochwasserereignisse nach Stationskennung.
    var highWatersByStation: [String: [TideEvent]] = [:]
    /// Vorbereitete mittlere Tidenhübe nach Stationskennung.
    var meanTidalRanges: [String: Double] = [:]
    /// Vorbereitete mittlere Hochwasserwerte nach Stationskennung.
    var meanHighWaters: [String: Double] = [:]
    var referencesByStation: [String: TideStationReference] = [:]
    var correctionsByStation: [String: WaterLevelCorrectionResolution] = [:]
    /// Optionale zeitabhängige Korrekturen. Fehlt hier eine Station, verwendet
    /// die Standardimplementierung den Einzelwert aus `correctionsByStation`.
    /// So bleiben ältere Tests ohne Vorhersagekurve verwendbar.
    var correctionSeriesByStation: [String: WaterLevelCorrectionSeries] = [:]
    /// Löst bei true einen Abruffehler aus, um einen Netzwerkausfall nachzubilden.
    var shouldThrow: Bool = false
    /// Zählt `highWaters(for:around:)`-Aufrufe. Tests können damit prüfen, ob die
    /// Passagefenstersuche Gezeitendaten einmal pro Wegpunkt statt einmal pro Abfahrt lädt.
    ///
    /// Eine Sperre schützt die gemeinsame Zuordnung auch bei parallelen Aufrufen.
    var highWatersCallCount: [String: Int] {
        callCountLock.withLock {
            storedHighWatersCallCount
        }
    }

    private let callCountLock = NSLock()
    private var storedHighWatersCallCount: [String: Int] = [:]

    func highWaters(for stationID: String, around date: Date) async throws -> [TideEvent] {
        callCountLock.withLock {
            storedHighWatersCallCount[stationID, default: 0] += 1
        }
        if shouldThrow {
            throw BSHTideError.badResponse
        }
        return highWatersByStation[stationID] ?? []
    }

    func meanTidalRange(for stationID: String) async throws -> Double? {
        meanTidalRanges[stationID]
    }

    func meanHighWater(for stationID: String) async throws -> Double? {
        meanHighWaters[stationID]
    }

    func stationReference(
        for stationID: String,
        around date: Date
    ) async throws -> TideStationReference? {
        referencesByStation[stationID]
    }

    func waterLevelCorrection(
        for stationID: String,
        at highWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionResolution {
        correctionsByStation[stationID] ?? .unavailable(
            stationID: stationID,
            detail: "Mock enthält keine Wasserstandskorrektur."
        )
    }

    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries {
        if let series = correctionSeriesByStation[stationID] { return series }
        return .constant(await waterLevelCorrection(
            for: stationID,
            at: anchorHighWaterTime,
            confirmedComparisonStationID: confirmedComparisonStationID
        ))
    }
}

/// Ordnet lokalen Häfen die nächste BSH-Vorhersagestation innerhalb von 20 km zu.
/// Für jeden Messpunkt wird danach der nächste lokale Hafen verwendet.
/// Wasserstände werden von Zentimetern in Meter umgerechnet und auf SKN bezogen.
actor BSHPassageForecastStore {
    static let shared = BSHPassageForecastStore()

    struct Station: Sendable {
        let name: String
        let gaugeName: String
        let latitude: Double
        let longitude: Double
        let events: [TideEvent]
        let chartDatumAboveGaugeZeroMeters: Double?
    }

    static let localHarbours: [(String, Double, Double)] = [
        ("Borkum", 53.5572, 6.7525), ("Juist", 53.6732, 7.0015),
        ("Norderney", 53.7012, 7.1585), ("Baltrum", 53.7215, 7.3715),
        ("Langeoog", 53.7285, 7.5095), ("Spiekeroog", 53.7645, 7.6955),
        ("Wangerooge", 53.7852, 7.8965), ("Emden", 53.3382, 7.1945),
        ("Norddeich", 53.6265, 7.1615), ("Nessmersiel", 53.6865, 7.3615),
        ("Dornumersiel", 53.6865, 7.4785), ("Bensersiel", 53.6785, 7.5705),
        ("Neuharlingersiel", 53.7015, 7.7055), ("Harlesiel", 53.7125, 7.8105),
        ("Horumersiel", 53.6862, 8.0195), ("Hooksiel", 53.6425, 8.0825),
        ("Dangast", 53.4472, 8.1175), ("Wilhelmshaven", 53.5142, 8.1465),
        ("Delfzijl", 53.3305, 6.9335), ("Termunterzijl", 53.3032, 7.0405),
        ("Eemshaven", 53.4445, 6.8365)
    ]
    private var cached: (Date, [Station])?
    private var pending: Task<[Station], Error>?

    func events(latitude: Double, longitude: Double, covering span: ClosedRange<Date>) async throws -> [TideEvent] {
        let stations = try await snapshot()
        guard let station = stations.min(by: {
            Self.distance(latitude, longitude, $0.latitude, $0.longitude)
                < Self.distance(latitude, longitude, $1.latitude, $1.longitude)
        }) else { return [] }
        let gauge = BSHTideStationCatalog.stations.first(where: {
            $0.name.localizedCaseInsensitiveCompare(station.gaugeName) == .orderedSame
        })
        let reference = if let gauge {
            try? await BSHTideService.shared.reference(for: gauge.id, around: span.lowerBound)
        } else {
            nil as TideStationReference?
        }
        guard let datum = station.chartDatumAboveGaugeZeroMeters
            ?? reference?.chartDatumAboveGaugeZeroMeters else { return [] }
        let forecast = station.events.map { event in
            var converted = event
            if station.chartDatumAboveGaugeZeroMeters == nil, let height = event.heightMeters {
                converted = TideEvent(time: event.time, heightMeters: height - datum,
                                      type: event.type, phase: event.phase)
                converted.currentTimestampIsISO8601 = event.currentTimestampIsISO8601
                converted.usesAstronomicalPrediction = event.usesAstronomicalPrediction
            }
            return converted
        }
        guard let gauge, !forecast.isEmpty else { return forecast }
        let calendar = (try? await BSHTideService.shared.tidalEvents(for: gauge.id, covering: span)) ?? []
        return Self.combined(forecast: forecast, calendar: calendar)
    }

    static func combined(forecast: [TideEvent], calendar: [TideEvent]) -> [TideEvent] {
        guard let first = forecast.first?.time, let last = forecast.last?.time else { return forecast }
        let adjacent = calendar.filter { $0.heightMeters != nil && ($0.time < first || $0.time > last) }
            .map { event -> TideEvent in
                var predicted = event
                predicted.usesAstronomicalPrediction = true
                predicted.currentTimestampIsISO8601 = false
                return predicted
            }
        return (forecast + adjacent).sorted { $0.time < $1.time }
    }

    private func snapshot() async throws -> [Station] {
        if let (date, stations) = cached, Date().timeIntervalSince(date) < 600 { return stations }
        if let pending { return try await pending.value }
        let task = Task { () throws -> [Station] in
            let endpoint = "https://gdi.bsh.de/ldproxy/rest/services/WaterLevelForecast/collections/waterlevelforecastdata/items?limit=100&region=north_sea&f=json"
            var request = URLRequest(url: URL(string: endpoint)!)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BSHTideError.badResponse }
            return try Self.decode(data)
        }
        pending = task
        defer { pending = nil }
        let stations = try await task.value
        cached = (Date(), stations)
        return stations
    }

    static func decode(_ data: Data) throws -> [Station] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw BSHTideError.badResponse }
        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? String { return Double(value) }
            return nil
        }
        let forecasts = features.compactMap { feature -> Station? in
            guard let properties = feature["properties"] as? [String: Any],
                  let lat = number(properties["latitude"]), let lon = number(properties["longitude"]) else { return nil }
            let datum = number(properties["chartdatum_relative_to_gaugezero"]).map { $0 / 100 }
            let events = (properties["high_water_low_water"] as? [[String: Any]] ?? []).compactMap { raw -> TideEvent? in
                let forecast = number(raw["forecast_value"])
                guard let height = forecast ?? number(raw["tidal_prediction_value"]), height.isFinite,
                      let timestamp = raw["event_timestamp"] as? String,
                      let time = BSHDateParser.date(from: timestamp),
                      let type = raw["event"] as? String else { return nil }
                var event = TideEvent(time: time, heightMeters: height / 100 - (datum ?? 0), type: type, phase: nil)
                event.usesAstronomicalPrediction = forecast == nil
                // Die Strömungsberechnung verwendet nur ISO-8601-Zeitstempel mit Zeitzonenangabe.
                // Zeitstempel mit Leerzeichen bleiben dafür ausgeschlossen.
                event.currentTimestampIsISO8601 = timestamp.contains("T") &&
                    (timestamp.hasSuffix("Z") || timestamp.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil)
                return event
            }.sorted { $0.time < $1.time }
            return Station(name: properties["gauge_label"] as? String ?? "BSH",
                           gaugeName: properties["gauge_label"] as? String ?? "BSH", latitude: lat, longitude: lon,
                           events: events, chartDatumAboveGaugeZeroMeters: datum)
        }
        return localHarbours.map { name, lat, lon in
            let nearest = forecasts.min { distance(lat, lon, $0.latitude, $0.longitude) < distance(lat, lon, $1.latitude, $1.longitude) }
            let events = nearest.flatMap { distance(lat, lon, $0.latitude, $0.longitude) < 20 ? $0.events : nil } ?? []
            return Station(name: name, gaugeName: nearest?.gaugeName ?? "BSH", latitude: lat, longitude: lon,
                           events: events, chartDatumAboveGaugeZeroMeters: nearest?.chartDatumAboveGaugeZeroMeters)
        }
    }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let value = pow(sin((lat2 - lat1) * rad / 2), 2)
            + cos(lat1 * rad) * cos(lat2 * rad) * pow(sin((lon2 - lon1) * rad / 2), 2)
        return 6_371 * 2 * atan2(sqrt(value), sqrt(1 - value))
    }
}
