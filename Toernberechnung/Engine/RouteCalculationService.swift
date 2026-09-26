import Foundation

// MARK: - Routenberechnung

/// Zentrale Berechnung der gezeitenabhängigen Befahrbarkeit in der App.
///
/// Die Berechnung verwendet strukturierte Wegpunkt-, Gezeiten-, Strecken- und Bootsdaten.
/// Sie hängt nicht von festen Wegpunktnamen, Inselnamen oder bestimmten Routen ab.
/// Emden → Norderney dient nur als Referenz für einen Regressionstest.
///
/// ## Berechnungsablauf
/// 1. Eingaben prüfen
/// 2. Ankunftszeiten aus den Streckenabschnitten berechnen
/// 3. Jeden Wegpunkt auswerten:
///    a. Passendes Hochwasser vom Anbieter oder aus manueller Eingabe ermitteln
///    b. Zeitversatz des Hochwassers anwenden
///    c. Abstand der Ankunft zum Hochwasser berechnen
///    d. Fehlmenge Wasser mit der Gezeitenstrategie (Zwölftelregel) berechnen
///    e. Verfügbare Wassertiefe im MHW- oder Lottiefe-Modus bestimmen
///    f. Wasser unter Kiel berechnen
///    g. Status des Wegpunkts bestimmen
/// 4. Einzelne Statuswerte zum Routenstatus zusammenführen
final class RouteCalculationService {

    private let tidalHeightStrategy: TidalHeightStrategy
    private let calendar: Calendar

    /// Erstellt den Berechnungsdienst.
    /// - Parameters:
    ///   - tidalHeightStrategy: Strategie zur Berechnung der Fehlmenge Wasser. Standard: TwelfthsRuleStrategy.
    ///   - timeZone: Zeitzone für Datumsberechnungen. Standard: Europe/Berlin.
    init(
        tidalHeightStrategy: TidalHeightStrategy = ContinuousTwelfthsStrategy(),
        timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
    ) {
        self.tidalHeightStrategy = tidalHeightStrategy
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal
    }

    // MARK: - Hauptberechnung

    /// Berechnet die gezeitenabhängige Befahrbarkeit einer vollständigen Route.
    ///
    /// - Parameters:
    ///   - route: Routenplan mit allen Wegpunkten und Streckenabschnitten.
    ///   - boatSettings: Tiefgang und Sicherheitsabstand des Boots.
    ///   - tideDataProvider: Anbieter der BSH-Gezeitendaten.
    /// - Returns: Vollständiges Ergebnis der Routenberechnung.
    func calculate(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider,
        confirmedComparisonGaugeIDs: [String: String] = [:]
    ) async -> RouteCalculationResult {
        var messages: [String] = []

        // Grundlegende Eingaben prüfen.
        guard boatSettings.draftMeters.isFinite, boatSettings.draftMeters > 0 else {
            return errorResult(route: route, boatSettings: boatSettings,
                               message: "Tiefgang muss größer als 0 sein.")
        }
        guard boatSettings.safetyMarginMeters.isFinite, boatSettings.safetyMarginMeters >= 0 else {
            return errorResult(route: route, boatSettings: boatSettings,
                               message: "Sicherheitsmarge darf nicht negativ sein.")
        }
        guard route.waypoints.count >= 2 else {
            return errorResult(route: route, boatSettings: boatSettings,
                               message: "Eine Route benötigt mindestens Start- und Zielpunkt.")
        }
        guard route.legs.count == route.waypoints.count - 1 else {
            return errorResult(route: route, boatSettings: boatSettings,
                               message: "Anzahl der Legs stimmt nicht mit den Wegpunkten überein.")
        }

        // Die gleichen Vorhersagewerte wie für die Abfahrtssuche verwenden.
        var currentModels: [TidalPassageLeg]?
        if tideDataProvider.usesForecastWaterLevels {
            var models: [TidalPassageLeg] = []
            for index in route.legs.indices {
                let events = (try? await tideDataProvider.routeEvents(for: route.waypoints[index],
                    covering: route.plannedStartTime ... route.plannedStartTime)) ?? []
                models.append(TidalPassageLeg(distanceNm: route.legs[index].distanceNm,
                    speedKnots: route.legs[index].speedThroughWaterKnots,
                    courseDegrees: TidalPassageLeg.course(from: route.waypoints[index], to: route.waypoints[index + 1]),
                    events: events))
            }
            currentModels = models
        }
        let legResults = Self.calculateLegResults(
            startTime: route.plannedStartTime, legs: route.legs, currentModels: currentModels
        )

        var arrivalTimes: [Date] = [route.plannedStartTime]
        for legResult in legResults {
            arrivalTimes.append(legResult.arrivalTime)
        }

        // Jeden Wegpunkt berechnen.
        var waypointResults: [WaypointCalculationResult] = []
        for (index, waypoint) in route.waypoints.enumerated() {
            let arrivalTime = arrivalTimes[index]
            let result = await calculateWaypoint(
                waypoint: waypoint,
                arrivalTime: arrivalTime,
                routeWaterLevelCorrectionMeters: route.bshWaterLevelCorrectionMeters,
                confirmedComparisonStationID: confirmedComparisonGaugeIDs[waypoint.tidalReferenceStationID],
                boatSettings: boatSettings,
                tideDataProvider: tideDataProvider
            )
            waypointResults.append(result)
        }

        // Gesamten Gezeitenstatus bestimmen.
        let tidalStatus: RouteStatus = legResults.contains(where: { !$0.isValid }) ? .noGo : Self.determineRouteStatus(
            waypointStatuses: waypointResults.map(\.status)
        )

        // Zusammengefasste Werte berechnen.
        let totalDistance = legResults.reduce(0) { $0 + $1.leg.distanceNm }
        let totalTime = legResults.reduce(0) { $0 + $1.travelTimeHours }
        let worstWuK = waypointResults.compactMap(\.clearanceUnderKeelWuKMeters).min()

        // Warnungen zu ungültigen Streckenabschnitten ergänzen.
        for legResult in legResults where !legResult.isValid {
            messages.append(contentsOf: legResult.messages)
        }

        return RouteCalculationResult(
            waypointResults: waypointResults,
            legResults: legResults,
            totalDistanceNm: totalDistance,
            totalTravelTimeHours: totalTime,
            worstClearanceUnderKeel: worstWuK,
            tidalStatus: tidalStatus,
            weatherStatus: .incomplete, // Das ViewModel bewertet das Wetter gesondert.
            combinedStatus: CombinedRouteStatus.combine(tidal: tidalStatus, weather: .incomplete),
            messages: messages
        )
    }

    // MARK: - Berechnung einzelner Wegpunkte

    // Die Berechnung bleibt geradlinig, damit jede sicherheitsrelevante Eingabe nachvollziehbar ist.
    private func calculateWaypoint(
        waypoint: RouteWaypoint,
        arrivalTime: Date,
        routeWaterLevelCorrectionMeters: Double?,
        confirmedComparisonStationID: String?,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider
    ) async -> WaypointCalculationResult {
        guard let context = await WaypointTideContext.resolve(
            waypoint: waypoint, plannedArrivalTime: arrivalTime, travelOffsetHours: 0,
            draftMeters: boatSettings.draftMeters,
            manualCorrectionMeters: waypoint.bshWaterLevelCorrectionOverride ?? routeWaterLevelCorrectionMeters,
            searchSpan: arrivalTime ... arrivalTime, tideDataProvider: tideDataProvider,
            confirmedComparisonStationID: confirmedComparisonStationID
        ), let waypointHWTime = context.nearestWaypointHighWater(to: arrivalTime) else {
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime, bshCorrection: 0,
                correctionQuality: .unavailable, boatDraft: boatSettings.draftMeters,
                messages: ["Tiefe oder angrenzende Gezeitendaten fehlen für \(waypoint.name)."]
            )
        }
        let correction = context.correction.resolution(at: arrivalTime)
        let quality = context.quality(at: arrivalTime)
        let qualityDetail = context.qualityDetail(at: arrivalTime) ?? correction.detail
        let referenceHWTime = waypointHWTime.addingTimeInterval(-context.referenceOffsetSeconds)
        let deviation = abs(arrivalTime.timeIntervalSince(waypointHWTime)) / 3_600
        let mth = context.meanTidalRangeMeters
        let level = context.referenceLevelMeters

        let depthResult = context.depthResult(atArrival: arrivalTime, strategy: tidalHeightStrategy)
        guard case .success(let depth) = depthResult else {
            if case .failure(.deviationExceedsTidalCycle(let tidalMessages)) = depthResult {
                var messages = [qualityDetail, waypoint.notes.isEmpty ? nil : waypoint.notes].compactMap { $0 }
                messages.append(contentsOf: tidalMessages)
                return WaypointCalculationResult(
                    waypoint: waypoint,
                    arrivalTime: arrivalTime,
                    referenceHighWaterTime: referenceHWTime,
                    relevantHighWaterTime: waypointHWTime,
                    deviationHours: deviation,
                    meanTidalRangeMeters: mth,
                    referenceLevelMeters: level,
                    oneTwelfthMeters: mth / 12,
                    missingWaterFmWMeters: nil,
                    baseWaterAtTideMeters: nil,
                    bshWaterLevelCorrectionMeters: correction.meters,
                    waterLevelCorrectionQuality: quality,
                    waterLevelCorrectionDetail: qualityDetail,
                    chartDepthMetersApplied: nil,
                    tideHeightHGMeters: nil,
                    availableWaterDepthWTMeters: nil,
                    boatDraftMeters: boatSettings.draftMeters,
                    clearanceUnderKeelWuKMeters: nil,
                    status: .invalid,
                    messages: messages
                )
            }
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime, bshCorrection: correction.meters,
                correctionQuality: quality, boatDraft: boatSettings.draftMeters,
                messages: ["Berechnung unvollständig für \(waypoint.name)."]
            )
        }
        let messages = [qualityDetail, waypoint.notes.isEmpty ? nil : waypoint.notes].compactMap { $0 }
            let baseStatus = Self.determineWaypointStatus(
                clearanceUnderKeel: depth.clearanceUnderKeelMeters,
                safetyMargin: boatSettings.safetyMarginMeters
            )
            let status = Self.applyCorrectionQuality(quality, to: baseStatus)

            return WaypointCalculationResult(
                waypoint: waypoint,
                arrivalTime: arrivalTime,
                referenceHighWaterTime: referenceHWTime,
                relevantHighWaterTime: waypointHWTime,
                deviationHours: deviation,
                meanTidalRangeMeters: mth,
                referenceLevelMeters: level,
                oneTwelfthMeters: depth.oneTwelfthMeters,
                missingWaterFmWMeters: depth.missingWaterMeters,
                baseWaterAtTideMeters: depth.baseMeters,
                bshWaterLevelCorrectionMeters: correction.meters,
                waterLevelCorrectionQuality: quality,
                waterLevelCorrectionDetail: qualityDetail,
                chartDepthMetersApplied: depth.chartDepthApplied,
                tideHeightHGMeters: depth.tideHeightHGMeters,
                availableWaterDepthWTMeters: depth.availableWaterDepthMeters,
                boatDraftMeters: boatSettings.draftMeters,
                clearanceUnderKeelWuKMeters: depth.clearanceUnderKeelMeters,
                status: status,
                messages: messages
            )

    }

    // MARK: - Statische, unabhängig prüfbare Hilfsfunktionen

    /// Fahrt über Grund = Fahrt durchs Wasser + Gezeitenströmung.
    static func calculateSpeedOverGround(
        speedThroughWaterKnots: Double,
        tidalCurrentKnots: Double
    ) -> Double {
        speedThroughWaterKnots + tidalCurrentKnots
    }

    /// Fahrtdauer in Stunden = Strecke / Fahrt über Grund.
    /// Gibt nil zurück, wenn SOG <= 0 ist.


    static func calculateTravelTimeHours(
        distanceNm: Double,
        speedOverGroundKnots: Double
    ) -> Double? {
        guard speedOverGroundKnots > 0 else { return nil }
        return distanceNm / speedOverGroundKnots
    }

    /// Berechnet Ankunftszeiten, Gesamtstrecke und Gültigkeit der Streckenabschnitte.
    static func calculateLegResults(
        startTime: Date,
        legs: [RouteLeg],
        currentModels: [TidalPassageLeg]? = nil
    ) -> [LegCalculationResult] {
        var results: [LegCalculationResult] = []
        var currentTime = startTime
        var cumulativeDistance: Double = 0
        var cumulativeTime: Double = 0

        for (index, leg) in legs.enumerated() {
            let sog = currentModels.map { max($0[index].speedOverGround(at: currentTime), 0.1) }
                ?? calculateSpeedOverGround(
                speedThroughWaterKnots: leg.speedThroughWaterKnots,
                tidalCurrentKnots: leg.tidalCurrentKnots
            )

            var messages: [String] = []
            let isValid: Bool
            let travelTime: Double

            if !sog.isFinite || sog <= 0 || !leg.distanceNm.isFinite || leg.distanceNm < 0 {
                isValid = false
                travelTime = 0
                messages.append("Geschwindigkeit über Grund ≤ 0 (SOG = \(String(format: "%.1f", sog)) kn). Leg ist ungültig.")
            } else {
                isValid = true
                let seconds = leg.distanceNm / sog * 3_600
                travelTime = (currentModels == nil ? seconds : seconds.rounded(.towardZero)) / 3_600
            }

            let departureTime = currentTime
            let arrivalTime = currentTime.addingTimeInterval(travelTime * 3600)
            cumulativeDistance += leg.distanceNm
            cumulativeTime += travelTime

            results.append(LegCalculationResult(
                leg: leg,
                speedOverGroundKnots: sog,
                travelTimeHours: travelTime,
                departureTime: departureTime,
                arrivalTime: arrivalTime,
                cumulativeDistanceNm: cumulativeDistance,
                cumulativeTravelTimeHours: cumulativeTime,
                isValid: isValid,
                messages: messages
            ))

            currentTime = arrivalTime
        }

        return results
    }

    /// Wendet den vorzeichenbehafteten Hochwasserversatz auf die Referenzzeit an.
    static func applyHighWaterOffset(
        referenceHWTime: Date,
        offsetMinutes: Int
    ) -> Date {
        referenceHWTime.addingTimeInterval(Double(offsetMinutes) * 60)
    }

    /// Berechnet den absoluten Abstand zwischen Ankunft und Hochwasser in Dezimalstunden.
    ///
    /// Beide Werte enthalten das vollständige Datum. Dadurch wird ein Wechsel
    /// über Mitternacht korrekt berücksichtigt.
    static func calculateDeviationHours(
        arrivalTime: Date,
        highWaterTime: Date
    ) -> Double {
        abs(arrivalTime.timeIntervalSince(highWaterTime)) / 3600
    }

    /// Sucht das Hochwasserereignis, das der Zielzeit am nächsten liegt.
    static func findNearestHighWater(
        to targetTime: Date,
        from events: [TideEvent]
    ) -> Date? {
        events
            .map { $0.time }
            .min(by: { abs($0.timeIntervalSince(targetTime)) < abs($1.timeIntervalSince(targetTime)) })
    }

    /// Bestimmt den Wegpunktstatus aus Wasser unter Kiel und Sicherheitsabstand.
    static func determineWaypointStatus(
        clearanceUnderKeel: Double,
        safetyMargin: Double
    ) -> WaypointStatus {
        if clearanceUnderKeel < 0 {
            return .noGo
        } else if clearanceUnderKeel < safetyMargin {
            return .warning
        } else {
            return .go
        }
    }

    static func applyCorrectionQuality(
        _ quality: WaterLevelCorrectionQuality,
        to status: WaypointStatus
    ) -> WaypointStatus {
        // Die Datenherkunft bestimmt den Hinweistext, nicht das Ergebnis der Tiefenprüfung.
        // Ein nutzbarer Ersatzwert (manuelle Eingabe, Modellschätzung, Vergleichspegel oder
        // Szenario ohne wetterbedingte Abweichung) darf ausreichendes Wasser unter Kiel nicht
        // als "Beschränkt" einstufen. Datenqualität darf umgekehrt ein No-Go nicht als sicher einstufen.
        _ = quality
        return status
    }

    /// Bestimmt den Routenstatus aus allen Wegpunktstatuswerten.
    ///
    /// - `noGo`, wenn an einem Wegpunkt die Wassertiefe nicht ausreicht
    /// - `incomplete`, wenn eine erforderliche Eingabe fehlt oder nicht auswertbar ist
    /// - `warning`, wenn der Sicherheitsabstand an einem Wegpunkt unterschritten wird
    /// - `go` nur, wenn alle Wegpunkte den Status go haben
    static func determineRouteStatus(
        waypointStatuses: [WaypointStatus]
    ) -> RouteStatus {
        if waypointStatuses.contains(.noGo) { return .noGo }
        if waypointStatuses.contains(.invalid) || waypointStatuses.contains(.incomplete) {
            return .incomplete
        }
        if waypointStatuses.contains(.warning) { return .warning }
        // Eine leere Liste bedeutet, dass nichts ausgewertet wurde.
        // Das gilt als fehlende Daten und nicht als Freigabe.
        return waypointStatuses.isEmpty ? .incomplete : .go
    }

    // MARK: - Private Hilfsfunktionen

    private func errorResult(
        route: RoutePlan,
        boatSettings: BoatSettings,
        message: String
    ) -> RouteCalculationResult {
        RouteCalculationResult(
            waypointResults: [],
            legResults: [],
            totalDistanceNm: 0,
            totalTravelTimeHours: 0,
            worstClearanceUnderKeel: nil,
            tidalStatus: .incomplete,
            weatherStatus: .incomplete,
            combinedStatus: .incomplete,
            messages: [message]
        )
    }

    private func incompleteWaypointResult(
        waypoint: RouteWaypoint,
        arrivalTime: Date,
        referenceHighWaterTime: Date? = nil,
        meanTidalRangeMeters: Double? = nil,
        bshCorrection: Double,
        correctionQuality: WaterLevelCorrectionQuality,
        correctionDetail: String? = nil,
        boatDraft: Double,
        messages: [String]
    ) -> WaypointCalculationResult {
        WaypointCalculationResult(
            waypoint: waypoint,
            arrivalTime: arrivalTime,
            referenceHighWaterTime: referenceHighWaterTime,
            relevantHighWaterTime: nil,
            deviationHours: nil,
            meanTidalRangeMeters: meanTidalRangeMeters,
            referenceLevelMeters: nil,
            oneTwelfthMeters: nil,
            missingWaterFmWMeters: nil,
            baseWaterAtTideMeters: nil,
            bshWaterLevelCorrectionMeters: bshCorrection,
            waterLevelCorrectionQuality: correctionQuality,
            waterLevelCorrectionDetail: correctionDetail,
            chartDepthMetersApplied: nil,
            tideHeightHGMeters: nil,
            availableWaterDepthWTMeters: nil,
            boatDraftMeters: boatDraft,
            clearanceUnderKeelWuKMeters: nil,
            status: .incomplete,
            messages: messages
        )
    }
}
