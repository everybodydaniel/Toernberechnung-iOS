import Foundation

/// Zentrale Quelle der Wahrheit für alle Tidenberechnungen (Go/No-Go) in der App.
///
/// Berechnet ETA, Tidenwassertiefe und Wasser-unter-Kiel für jeden Wegpunkt
/// einer mehrgliedrigen Route.
///
/// Der Service ist **geografieunabhängig**: Er verarbeitet strukturierte Wegpunkt-, Tiden-,
/// Leg- und Bootsdaten. Kein Berechnungscode hängt von festen Wegpunktnamen, Inselnamen
/// oder konkreten Routen ab.
///
/// ## Berechnungsablauf
/// 1. Eingaben validieren
/// 2. Ankunftszeiten an jedem Wegpunkt aus den Legdaten berechnen
/// 3. Für jeden Wegpunkt:
///    a. Relevantes Hochwasser ermitteln (vom Provider oder manueller Eintrag)
///    b. HW-Offset anwenden
///    c. Abweichung vom HW berechnen
///    d. Tidenhöhen-Strategie anwenden (1/12-Regel) für FmW
///    e. Verfügbare Wassertiefe berechnen (MHW- oder Lottiefe-Modus)
///    f. Wasser unter dem Kiel berechnen
///    g. Wegpunkt-Status bestimmen
/// 4. Alle Wegpunkt-Status zum Gesamtstatus der Route zusammenführen
final class RouteCalculationService {

    private let tidalHeightStrategy: TidalHeightStrategy
    private let calendar: Calendar

    /// Erstellt einen Berechnungs-Service.
    /// - Parameters:
    ///   - tidalHeightStrategy: Strategie zur FmW-Berechnung. Standard: TwelfthsRuleStrategy.
    ///   - timeZone: Zeitzone für Datumsberechnungen. Standard: Europe/Berlin.
    init(
        tidalHeightStrategy: TidalHeightStrategy = TwelfthsRuleStrategy(),
        timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
    ) {
        self.tidalHeightStrategy = tidalHeightStrategy
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal
    }

    // MARK: - Routen-Berechnung

    /// Berechnet Go/No-Go für eine komplette mehrgliedrige Route.
    ///
    /// - Parameters:
    ///   - route: Der Routenplan mit allen Wegpunkten und Legs.
    ///   - boatSettings: Tiefgang und Sicherheitsmarge des Bootes.
    ///   - tideDataProvider: Anbieter für BSH-Tidendaten.
    /// - Returns: Vollständiges Routenberechnungsergebnis.
    func calculate(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider
    ) async -> RouteCalculationResult {
        var messages: [String] = []

        guard boatSettings.draftMeters > 0 else {
            return errorResult(route: route, boatSettings: boatSettings,
                               message: "Tiefgang muss größer als 0 sein.")
        }
        guard boatSettings.safetyMarginMeters >= 0 else {
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

        let legResults = Self.calculateLegResults(
            startTime: route.plannedStartTime,
            legs: route.legs
        )

        var arrivalTimes: [Date] = [route.plannedStartTime]
        for legResult in legResults {
            arrivalTimes.append(legResult.arrivalTime)
        }

        var waypointResults: [WaypointCalculationResult] = []
        for (index, waypoint) in route.waypoints.enumerated() {
            let arrivalTime = arrivalTimes[index]
            let bshCorrection = waypoint.bshWaterLevelCorrectionOverride
                ?? route.bshWaterLevelCorrectionMeters

            let result = await calculateWaypoint(
                waypoint: waypoint,
                arrivalTime: arrivalTime,
                bshWaterLevelCorrectionMeters: bshCorrection,
                boatSettings: boatSettings,
                tideDataProvider: tideDataProvider
            )
            waypointResults.append(result)
        }

        let tidalStatus = Self.determineRouteStatus(
            waypointStatuses: waypointResults.map(\.status)
        )

        let totalDistance = legResults.reduce(0) { $0 + $1.leg.distanceNm }
        let totalTime = legResults.reduce(0) { $0 + $1.travelTimeHours }
        let worstWuK = waypointResults.compactMap(\.clearanceUnderKeelWuKMeters).min()

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
            weatherStatus: .incomplete,
            combinedStatus: CombinedRouteStatus.combine(tidal: tidalStatus, weather: .incomplete),
            messages: messages
        )
    }

    // MARK: - Wegpunkt-Berechnung

    private func calculateWaypoint(
        waypoint: RouteWaypoint,
        arrivalTime: Date,
        bshWaterLevelCorrectionMeters: Double,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider
    ) async -> WaypointCalculationResult {
        var messages: [String] = []

        guard let mth = await resolveMeanTidalRange(for: waypoint, provider: tideDataProvider), mth > 0 else {
            messages.append("MTH (Mittlerer Tidenhub) fehlt oder ist ungültig für \(waypoint.name).")
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                bshCorrection: bshWaterLevelCorrectionMeters,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }

        guard let referenceHWTime = await resolveReferenceHighWater(
            for: waypoint, arrivalTime: arrivalTime, provider: tideDataProvider
        ) else {
            messages.append("Kein Hochwasser für \(waypoint.tidalReferenceStation) verfügbar.")
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                bshCorrection: bshWaterLevelCorrectionMeters,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }

        let waypointHWTime = Self.applyHighWaterOffset(
            referenceHWTime: referenceHWTime,
            offsetMinutes: waypoint.highWaterOffsetMinutes
        )
        let deviation = Self.calculateDeviationHours(
            arrivalTime: arrivalTime, highWaterTime: waypointHWTime
        )
        let tidalResult = tidalHeightStrategy.missingWater(
            deviationHours: deviation, meanTidalRangeMeters: mth
        )

        guard tidalResult.isValid else {
            messages.append(contentsOf: tidalResult.messages)
            return invalidTidalResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                waypointHWTime: waypointHWTime, deviation: deviation,
                tidalResult: tidalResult,
                bshCorrection: bshWaterLevelCorrectionMeters,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }

        let depthResult = calculateDepth(
            waypoint: waypoint,
            fmwMeters: tidalResult.fmwMeters,
            bshCorrectionMeters: bshWaterLevelCorrectionMeters,
            boatDraftMeters: boatSettings.draftMeters,
            tideDataProvider: tideDataProvider
        )

        switch depthResult {
        case .calculated(let depth):
            messages.append(contentsOf: depth.messages)
            return makeCalculatedResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                waypointHWTime: waypointHWTime, deviation: deviation,
                tidalResult: tidalResult, depth: depth,
                bshCorrection: bshWaterLevelCorrectionMeters,
                boatSettings: boatSettings, messages: messages
            )
        case .missingData(let errorMessages):
            messages.append(contentsOf: errorMessages)
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                bshCorrection: bshWaterLevelCorrectionMeters,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }
    }

    private func resolveMeanTidalRange(
        for waypoint: RouteWaypoint,
        provider: TideDataProvider
    ) async -> Double? {
        if let sourced = waypoint.meanTidalRangeMeters {
            return sourced.value
        }
        return try? await provider.meanTidalRange(for: waypoint.tidalReferenceStationID)
    }

    private func resolveReferenceHighWater(
        for waypoint: RouteWaypoint,
        arrivalTime: Date,
        provider: TideDataProvider
    ) async -> Date? {
        if let manual = waypoint.manualHighWaterTime {
            return manual
        }
        let hwEvents = (try? await provider.highWaters(
            for: waypoint.tidalReferenceStationID,
            around: arrivalTime
        )) ?? []
        return Self.findNearestHighWater(to: arrivalTime, from: hwEvents)
    }

    private func invalidTidalResult(
        waypoint: RouteWaypoint,
        arrivalTime: Date,
        waypointHWTime: Date,
        deviation: Double,
        tidalResult: TidalHeightResult,
        bshCorrection: Double,
        boatDraft: Double,
        messages: [String]
    ) -> WaypointCalculationResult {
        WaypointCalculationResult(
            waypoint: waypoint,
            arrivalTime: arrivalTime,
            relevantHighWaterTime: waypointHWTime,
            deviationHours: deviation,
            oneTwelfthMeters: tidalResult.oneTwelfthMeters,
            missingWaterFmWMeters: nil,
            baseWaterAtTideMeters: nil,
            bshWaterLevelCorrectionMeters: bshCorrection,
            chartDepthMetersApplied: nil,
            tideHeightHGMeters: nil,
            availableWaterDepthWTMeters: nil,
            boatDraftMeters: boatDraft,
            clearanceUnderKeelWuKMeters: nil,
            status: .invalid,
            messages: messages
        )
    }

    private func makeCalculatedResult(
        waypoint: RouteWaypoint,
        arrivalTime: Date,
        waypointHWTime: Date,
        deviation: Double,
        tidalResult: TidalHeightResult,
        depth: DepthCalculation,
        bshCorrection: Double,
        boatSettings: BoatSettings,
        messages: [String]
    ) -> WaypointCalculationResult {
        let status = Self.determineWaypointStatus(
            clearanceUnderKeel: depth.wuK,
            safetyMargin: boatSettings.safetyMarginMeters
        )
        return WaypointCalculationResult(
            waypoint: waypoint,
            arrivalTime: arrivalTime,
            relevantHighWaterTime: waypointHWTime,
            deviationHours: deviation,
            oneTwelfthMeters: tidalResult.oneTwelfthMeters,
            missingWaterFmWMeters: tidalResult.fmwMeters,
            baseWaterAtTideMeters: depth.baseWater,
            bshWaterLevelCorrectionMeters: bshCorrection,
            chartDepthMetersApplied: depth.chartDepthApplied,
            tideHeightHGMeters: depth.hg,
            availableWaterDepthWTMeters: depth.wt,
            boatDraftMeters: boatSettings.draftMeters,
            clearanceUnderKeelWuKMeters: depth.wuK,
            status: status,
            messages: messages
        )
    }

    // MARK: - Tiefen-Berechnung

    private struct DepthCalculation {
        let baseWater: Double
        let hg: Double?
        let chartDepthApplied: Double?
        let wt: Double
        let wuK: Double
        let messages: [String]
    }

    private enum DepthResult {
        case calculated(DepthCalculation)
        case missingData([String])
    }

    private func calculateDepth(
        waypoint: RouteWaypoint,
        fmwMeters: Double,
        bshCorrectionMeters: Double,
        boatDraftMeters: Double,
        tideDataProvider: TideDataProvider
    ) -> DepthResult {
        switch waypoint.calculationMode {
        case .meanHighWater:
            return calculateMHWDepth(
                waypoint: waypoint,
                fmwMeters: fmwMeters,
                bshCorrectionMeters: bshCorrectionMeters,
                boatDraftMeters: boatDraftMeters,
                tideDataProvider: tideDataProvider
            )
        case .lottiefe:
            return calculateLottiefeDepth(
                waypoint: waypoint,
                fmwMeters: fmwMeters,
                bshCorrectionMeters: bshCorrectionMeters,
                boatDraftMeters: boatDraftMeters
            )
        }
    }

    /// MHW-Modus: baseWater = MHW - FmW; HG = baseWater + bshCorrection; WT = HG + Kartentiefe
    private func calculateMHWDepth(
        waypoint: RouteWaypoint,
        fmwMeters: Double,
        bshCorrectionMeters: Double,
        boatDraftMeters: Double,
        tideDataProvider: TideDataProvider
    ) -> DepthResult {
        guard let mhw = waypoint.meanHighWaterMeters?.value else {
            return .missingData(["MHW (Mittleres Hochwasser) fehlt für \(waypoint.name)."])
        }
        guard let chartDepth = waypoint.chartDepthMeters?.value else {
            return .missingData(["Kartentiefe / Peilplanwert fehlt für \(waypoint.name) (MHW-Modus)."])
        }

        let baseWater = mhw - fmwMeters
        let hg = baseWater + bshCorrectionMeters
        let wt = hg + chartDepth
        let wuK = wt - boatDraftMeters

        return .calculated(DepthCalculation(
            baseWater: baseWater, hg: hg, chartDepthApplied: chartDepth,
            wt: wt, wuK: wuK, messages: []
        ))
    }

    /// Lottiefe-Modus: baseWater = Lottiefe - FmW; WT = baseWater + bshCorrection; Kartentiefe wird NICHT angewendet.
    private func calculateLottiefeDepth(
        waypoint: RouteWaypoint,
        fmwMeters: Double,
        bshCorrectionMeters: Double,
        boatDraftMeters: Double
    ) -> DepthResult {
        guard let lottiefe = waypoint.lottiefeMeters?.value else {
            return .missingData(["Lottiefe fehlt für \(waypoint.name)."])
        }

        let baseWater = lottiefe - fmwMeters
        let wt = baseWater + bshCorrectionMeters
        let wuK = wt - boatDraftMeters

        return .calculated(DepthCalculation(
            baseWater: baseWater, hg: nil, chartDepthApplied: nil,
            wt: wt, wuK: wuK, messages: []
        ))
    }

    // MARK: - Geschwindigkeit & Reisezeit

    /// Geschwindigkeit über Grund = Fahrt durchs Wasser + Tidenstrom.
    static func calculateSpeedOverGround(
        speedThroughWaterKnots: Double,
        tidalCurrentKnots: Double
    ) -> Double {
        speedThroughWaterKnots + tidalCurrentKnots
    }

    /// Reisezeit in Stunden = Distanz / Geschwindigkeit über Grund.
    /// Gibt nil zurück, wenn SOG <= 0.
    static func calculateTravelTimeHours(
        distanceNm: Double,
        speedOverGroundKnots: Double
    ) -> Double? {
        guard speedOverGroundKnots > 0 else { return nil }
        return distanceNm / speedOverGroundKnots
    }

    /// Berechnet die Leg-Ergebnisse inkl. Ankunftszeiten, kumulierter Distanz und Gültigkeit.
    static func calculateLegResults(
        startTime: Date,
        legs: [RouteLeg]
    ) -> [LegCalculationResult] {
        var results: [LegCalculationResult] = []
        var currentTime = startTime
        var cumulativeDistance: Double = 0
        var cumulativeTime: Double = 0

        for leg in legs {
            let sog = calculateSpeedOverGround(
                speedThroughWaterKnots: leg.speedThroughWaterKnots,
                tidalCurrentKnots: leg.tidalCurrentKnots
            )

            var messages: [String] = []
            let isValid: Bool
            let travelTime: Double

            if sog <= 0 {
                isValid = false
                travelTime = 0
                messages.append("Geschwindigkeit über Grund ≤ 0 (SOG = \(String(format: "%.1f", sog)) kn). Leg ist ungültig.")
            } else {
                isValid = true
                travelTime = leg.distanceNm / sog
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

    // MARK: - Hochwasser-Hilfsfunktionen

    /// Wendet einen vorzeichenbehafteten HW-Offset auf eine Referenz-Hochwasserzeit an.
    static func applyHighWaterOffset(
        referenceHWTime: Date,
        offsetMinutes: Int
    ) -> Date {
        referenceHWTime.addingTimeInterval(Double(offsetMinutes) * 60)
    }

    /// Berechnet die absolute Abweichung in Dezimalstunden zwischen Ankunft und Hochwasser.
    ///
    /// Verwendet das absolute Zeitintervall und behandelt Mitternachts-Übergänge korrekt,
    /// da beide Werte vollständigen Datumskontext tragen.
    static func calculateDeviationHours(
        arrivalTime: Date,
        highWaterTime: Date
    ) -> Double {
        abs(arrivalTime.timeIntervalSince(highWaterTime)) / 3600
    }

    /// Findet das Hochwasser-Ereignis, das der Zielzeit am nächsten ist.
    static func findNearestHighWater(
        to targetTime: Date,
        from events: [TideEvent]
    ) -> Date? {
        events
            .map { $0.time }
            .min(by: { abs($0.timeIntervalSince(targetTime)) < abs($1.timeIntervalSince(targetTime)) })
    }

    // MARK: - Status-Bestimmung

    /// Bestimmt den Wegpunkt-Status aus Wasser-unter-Kiel und Sicherheitsmarge.
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

    /// Bestimmt den Gesamtstatus der Route aus allen Wegpunkt-Status.
    ///
    /// - `invalid`, wenn ein Wegpunkt ungültig ist (Berechnungsfehler)
    /// - `noGo`, wenn ein Wegpunkt noGo ist (nicht genug Tiefe)
    /// - `incomplete`, wenn eine benötigte Eingabe fehlt
    /// - `warning`, wenn ein Wegpunkt unter der Sicherheitsmarge liegt
    /// - `go` nur, wenn alle Wegpunkte go sind
    static func determineRouteStatus(
        waypointStatuses: [WaypointStatus]
    ) -> RouteStatus {
        if waypointStatuses.contains(.invalid) { return .noGo }
        if waypointStatuses.contains(.noGo) { return .noGo }
        if waypointStatuses.contains(.incomplete) { return .incomplete }
        if waypointStatuses.contains(.warning) { return .warning }
        return .go
    }

    // MARK: - Fehler-/Fallback-Ergebnisse

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
        bshCorrection: Double,
        boatDraft: Double,
        messages: [String]
    ) -> WaypointCalculationResult {
        WaypointCalculationResult(
            waypoint: waypoint,
            arrivalTime: arrivalTime,
            relevantHighWaterTime: nil,
            deviationHours: nil,
            oneTwelfthMeters: nil,
            missingWaterFmWMeters: nil,
            baseWaterAtTideMeters: nil,
            bshWaterLevelCorrectionMeters: bshCorrection,
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
