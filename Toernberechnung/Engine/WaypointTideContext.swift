import Foundation

// MARK: - Gezeitenkontext eines Wegpunkts

/// Einmal ermittelte Daten zur Berechnung des Wassers unter Kiel für beliebige
/// Ankunftszeiten. Nach `resolve(...)` werden keine weiteren Daten geladen.
/// `clearance(atArrival:strategy:)` ruft synchron `WaypointDepthSolver` auf
/// und nutzt dieselben Rechenschritte wie die Routenberechnung.
///
/// So muss die Passagefenstersuche die gleichen Pegeldaten nicht für jede
/// mögliche Abfahrtszeit erneut laden.
struct WaypointTideContext: Equatable {

    let waypointID: UUID
    let name: String
    let category: String?
    let calculationMode: WaypointCalculationMode

    /// Hochwasserzeiten am Wegpunkt für den Suchbereich.
    /// Der Wegpunktversatz ist bereits auf die Pegelereignisse angewendet.
    let waypointHighWaters: [Date]
    /// Excel `L33`.
    let meanTidalRangeMeters: Double
    /// Excel `L41` oder `L43`, je nach Modus.
    let referenceLevelMeters: Double
    /// Excel `L51`. Im Lottiefe-Modus nil.
    let chartDepthMeters: Double?
    /// Excel `M55`.
    let draftMeters: Double
    let correction: WaterLevelCorrectionSeries
    var astronomicalCurve: AstronomicalTideCurve? = nil
    var meanHighWaterAboveSkn: Double = 0
    var depthRequiresVerification: Bool = false
    var depthSourceDescription: String? = nil
    var referenceOffsetSeconds: TimeInterval = 0
    var comparisonTideStationID: String? = nil
    var forecastEvents: [TideEvent] = []
    var tidalTravelLegs: [TidalPassageLeg]? = nil

    func arrival(forDeparture departure: Date) -> Date {
        guard let tidalTravelLegs else { return departure.addingTimeInterval(travelOffsetHours * 3_600) }
        return tidalTravelLegs.reduce(departure) { $1.arrival(after: $0) }
    }

    let plannedArrivalTime: Date
    /// Gesamte Fahrtdauer vom Routenstart bis zu diesem Wegpunkt.
    let travelOffsetHours: Double

    // MARK: - Auswertung

    func depthResult(atArrival time: Date, strategy: TidalHeightStrategy) -> Result<WaypointDepthSolver.Output, WaypointDepthSolver.Failure>? {
        var missing: Double?
        if let curve = astronomicalCurve {
            guard let height = curve.height(at: time) else {
                // Ohne umgebende Vorhersageereignisse liegt kein Wasserstand vor.
                return nil
            }
            if calculationMode == .meanHighWater, let chartDepthMeters {
                return .success(WaypointDepthSolver.solveTideHeight(
                    height, chartDepth: chartDepthMeters,
                    correction: correction.resolution(at: time).meters, draft: draftMeters,
                    meanHighWater: referenceLevelMeters, meanRange: meanTidalRangeMeters
                ))
            }
            missing = meanHighWaterAboveSkn - height
        }
        guard let highWater = nearestWaypointHighWater(to: time) else { return nil }

        return WaypointDepthSolver.solve(
            WaypointDepthSolver.Inputs(
                calculationMode: calculationMode,
                referenceLevelMeters: referenceLevelMeters,
                chartDepthMeters: chartDepthMeters,
                meanTidalRangeMeters: meanTidalRangeMeters,
                deviationHours: abs(time.timeIntervalSince(highWater)) / 3_600,
                waterLevelCorrectionMeters: correction.resolution(at: time).meters,
                draftMeters: draftMeters,
                missingWaterOverrideMeters: missing
            ), strategy: strategy
        )
    }

    /// Wasser unter Kiel bei Ankunft zu `time`. Nil, wenn der Abstand zum
    /// Hochwasser einen ganzen Zyklus überschreitet oder eine nötige Eingabe fehlt.
    func depth(atArrival time: Date, strategy: TidalHeightStrategy) -> WaypointDepthSolver.Output? {
        if case .success(let output) = depthResult(atArrival: time, strategy: strategy) {
            return output
        }
        return nil
    }

    func clearance(atArrival time: Date, strategy: TidalHeightStrategy) -> Double? {
        depth(atArrival: time, strategy: strategy)?.clearanceUnderKeelMeters
    }

    func quality(at time: Date) -> WaterLevelCorrectionQuality {
        if depthRequiresVerification { return .unverifiedDepth }
        if comparisonTideStationID != nil { return .confirmedComparison }
        if astronomicalCurve?.usesAstronomicalPrediction(at: time) == true { return .outsideForecastHorizon }
        if astronomicalCurve?.estimatedHeights == true { return .estimatedTide }
        return correction.resolution(at: time).quality
    }

    /// Hält mehrere unabhängige Einschränkungen gleichzeitig sichtbar.
    /// Eine Route kann eine ungeprüfte Lotung verwenden und zugleich außerhalb
    /// der Wettervorhersage liegen. Ein einzelner Statuswert würde dabei
    /// Informationen verbergen, die der Skipper benötigt.
    func qualityDetails(at time: Date) -> [String] {
        let correctionResolution = correction.resolution(at: time)
        var details = [correctionResolution.detail]
        if let source = comparisonTideStationID {
            details.append("Gezeitenhöhen und -zeiten vom Vergleichspegel \(source), keine örtliche Höhenprognose.")
        }
        if astronomicalCurve?.estimatedHeights == true,
           let tideDetail = PassageWindowSolver.detail(for: .estimatedTide) {
            details.append(tideDetail)
        }
        if astronomicalCurve?.usesAstronomicalPrediction(at: time) == true,
           let tideDetail = PassageWindowSolver.detail(for: .outsideForecastHorizon) {
            details.append(tideDetail)
        }
        if depthRequiresVerification,
           let depthDetail = PassageWindowSolver.detail(for: .unverifiedDepth) {
            details.append(depthDetail)
        }
        return details.reduce(into: []) { unique, detail in
            guard !detail.isEmpty, !unique.contains(detail) else { return }
            unique.append(detail)
        }
    }

    func qualityDetail(at time: Date) -> String? {
        let details = qualityDetails(at: time)
        return details.isEmpty ? nil : details.joined(separator: " ")
    }

    /// Alle Steigungswechsel für die genaue abschnittsweise lineare Abfahrtsberechnung.
    var breakpoints: [Date] {
        let tidal = astronomicalCurve?.points.map(\.time) ?? waypointHighWaters.flatMap { hw in
            (-6 ... 6).map { hw.addingTimeInterval(Double($0) * 3_600) }
        }
        return tidal + correction.samples.map(\.time)
    }

    func isCorrectionCoverageBoundary(atArrival time: Date) -> Bool {
        guard let first = correction.samples.first?.time,
              let last = correction.samples.last?.time else { return false }
        return time == first || time == last
    }

    /// Zulässige Fehlmenge Wasser, bevor der Kiel den Grund berührt.
    ///
    /// Umstellen der Tiefenberechnung für `WuK ≥ 0`:
    /// `Basis − FmW + Korrektur (+ Kartentiefe) − Tiefgang ≥ 0`.
    func missingWaterBudgetMeters(correctionMeters: Double) -> Double {
        let chartDepth = calculationMode == .meanHighWater ? (chartDepthMeters ?? 0) : 0
        return referenceLevelMeters + correctionMeters + chartDepth - draftMeters
    }

    func nearestWaypointHighWater(to time: Date) -> Date? {
        waypointHighWaters.min {
            abs($0.timeIntervalSince(time)) < abs($1.timeIntervalSince(time))
        }
    }

    /// Suchbereich der Abfahrt, in Ankunftszeiten an diesem Wegpunkt umgerechnet.
    func searchSpanShiftedToArrival(_ span: ClosedRange<Date>) -> ClosedRange<Date> {
        let shift = travelOffsetHours * 3_600
        return span.lowerBound.addingTimeInterval(shift)
            ... span.upperBound.addingTimeInterval(shift)
    }

    // MARK: - Ermittlung der Eingaben

    // Die Auswahlreihenfolgen entsprechen `RouteCalculationService.calculateWaypoint`.
    // Sie bleiben ausdrücklich ausgeschrieben, damit die Übereinstimmung nachvollziehbar ist.
    static func resolve(
        waypoint: RouteWaypoint,
        plannedArrivalTime: Date,
        travelOffsetHours: Double,
        draftMeters: Double,
        manualCorrectionMeters: Double?,
        searchSpan: ClosedRange<Date>,
        tideDataProvider: TideDataProvider,
        confirmedComparisonStationID: String?
    ) async -> WaypointTideContext? {
        if tideDataProvider.usesForecastWaterLevels, waypoint.manualHighWaterTime == nil,
           waypoint.calculationMode == .meanHighWater {
            guard let chartDepth = waypoint.chartDepthMeters?.value, chartDepth.isFinite,
                  draftMeters.isFinite,
                  let events = try? await tideDataProvider.routeEvents(for: waypoint, covering: searchSpan),
                  !events.isEmpty else { return nil }
            let highWaters = events.filter { $0.type == "HW" || $0.type.localizedCaseInsensitiveContains("Hochwasser") }.map(\.time)
            let heights = events.compactMap(\.heightMeters)
            let high = heights.max() ?? 0, low = heights.min() ?? 0
            let correction = WaterLevelCorrectionResolution(
                meters: manualCorrectionMeters ?? 0,
                quality: manualCorrectionMeters == nil ? .localOfficial : .manual,
                localStationID: waypoint.tidalReferenceStationID, sourceStationID: nil, sourceStationName: nil,
                issuedAt: nil, detail: "BSH-HW/NW-Prognose inklusive Windstau; zusätzliche Korrektur.")
            var context = WaypointTideContext(waypointID: waypoint.id, name: waypoint.name, category: waypoint.category,
                calculationMode: .meanHighWater, waypointHighWaters: highWaters, meanTidalRangeMeters: high - low,
                referenceLevelMeters: high, chartDepthMeters: chartDepth, draftMeters: draftMeters,
                correction: .constant(correction), plannedArrivalTime: plannedArrivalTime, travelOffsetHours: travelOffsetHours)
            context.astronomicalCurve = AstronomicalTideCurve(events: events, meanHighWater: high, meanRange: high - low, offset: 0)
            context.forecastEvents = events.sorted { $0.time < $1.time }
            context.depthRequiresVerification = waypoint.chartDepthMeters?.source == .catalog
            context.depthSourceDescription = "Kartentiefe: \(String(format: "%.2f", chartDepth)) m SKN"
            return context
        }
        let stationReference = try? await tideDataProvider.stationReference(
            for: waypoint.tidalReferenceStationID,
            around: plannedArrivalTime
        )

        guard let mth = await resolveMeanTidalRange(
            waypoint: waypoint,
            stationReference: stationReference,
            tideDataProvider: tideDataProvider
        ), mth.isFinite, mth > 0 else { return nil }

        guard let level = resolveReferenceLevel(
            waypoint: waypoint,
            stationReference: stationReference
        ), level.isFinite, draftMeters.isFinite else { return nil }
        if waypoint.calculationMode == .meanHighWater {
            guard let depth = waypoint.chartDepthMeters?.value, depth.isFinite else { return nil }
        }

        // Hochwasser für den gesamten Suchbereich mit angewendetem Wegpunktversatz.
        let arrivalSpan = searchSpan.lowerBound
            .addingTimeInterval(travelOffsetHours * 3_600)
            ... searchSpan.upperBound.addingTimeInterval(travelOffsetHours * 3_600)
        let offsetSeconds = Double(waypoint.highWaterOffsetMinutes) * 60
        var events: [TideEvent] = []
        var comparisonTideStationID: String?
        if let manual = waypoint.manualHighWaterTime {
            events = [TideEvent(time: manual, heightMeters: nil, type: "HW", phase: nil)]
        } else {
            events = (try? await tideDataProvider.routeEvents(
                for: waypoint,
                covering: arrivalSpan.lowerBound.addingTimeInterval(-offsetSeconds)
                    ... arrivalSpan.upperBound.addingTimeInterval(-offsetSeconds)
            )) ?? []

            if !tideDataProvider.usesForecastWaterLevels && (events.isEmpty || events.allSatisfy({ $0.heightMeters == nil })) {
                let fallbackID = confirmedComparisonStationID
                    ?? BSHTideStationCatalog.requiredComparisonStation(for: waypoint.tidalReferenceStationID)?.id
                    ?? BSHTideStationCatalog.nearestComparisonStation(for: waypoint.tidalReferenceStationID)?.id
                if let fallbackID {
                    let comparisonEvents = (try? await tideDataProvider.tidalEvents(
                        for: fallbackID,
                        covering: arrivalSpan.lowerBound.addingTimeInterval(-offsetSeconds)
                            ... arrivalSpan.upperBound.addingTimeInterval(-offsetSeconds)
                    )) ?? []
                    if comparisonEvents.contains(where: { $0.heightMeters != nil }) {
                        events = comparisonEvents
                        comparisonTideStationID = fallbackID
                    }
                }
            }
        }
        var referenceHighWaters = events.filter { $0.type == "HW" }.map(\.time)
        let plannedReferenceTime = plannedArrivalTime.addingTimeInterval(-offsetSeconds)
        if referenceHighWaters.isEmpty && !tideDataProvider.usesForecastWaterLevels {
            let directHW = (try? await tideDataProvider.highWaters(for: waypoint.tidalReferenceStationID, around: plannedReferenceTime)) ?? []
            referenceHighWaters = directHW.map(\.time)
        }
        guard let anchorReferenceHighWater = referenceHighWaters.min(by: {
            abs($0.timeIntervalSince(plannedReferenceTime))
                < abs($1.timeIntervalSince(plannedReferenceTime))
        }) else { return nil }

        let waypointHighWaters = referenceHighWaters
            .map { $0.addingTimeInterval(offsetSeconds) }
            .sorted()

        let correction = await resolveCorrection(
            stationID: waypoint.tidalReferenceStationID,
            manualCorrectionMeters: manualCorrectionMeters ?? (tideDataProvider.usesForecastWaterLevels ? 0 : nil),
            arrivalSpan: arrivalSpan,
            anchorHighWaterTime: anchorReferenceHighWater,
            tideDataProvider: tideDataProvider,
            confirmedComparisonStationID: confirmedComparisonStationID
        )

        var context = WaypointTideContext(
            waypointID: waypoint.id,
            name: waypoint.name,
            category: waypoint.category,
            calculationMode: waypoint.calculationMode,
            waypointHighWaters: waypointHighWaters,
            meanTidalRangeMeters: mth,
            referenceLevelMeters: level,
            chartDepthMeters: waypoint.chartDepthMeters?.value,
            draftMeters: draftMeters,
            correction: correction,
            plannedArrivalTime: plannedArrivalTime,
            travelOffsetHours: travelOffsetHours
        )
        context.forecastEvents = events.sorted { $0.time < $1.time }
        context.referenceOffsetSeconds = offsetSeconds
        context.comparisonTideStationID = comparisonTideStationID
        context.meanHighWaterAboveSkn = stationReference?.meanHighWaterAboveSknMeters
            ?? waypoint.meanHighWaterMeters?.value ?? 0
        if events.contains(where: { $0.type == "NW" }) {
            context.astronomicalCurve = AstronomicalTideCurve(
                events: events, meanHighWater: context.meanHighWaterAboveSkn,
                meanRange: mth, offset: offsetSeconds
            )
        }
        let depthSource = waypoint.calculationMode == .lottiefe ? waypoint.lottiefeMeters : waypoint.chartDepthMeters
        // Lotungen Dritter und mitgelieferte Kartentiefen müssen vom Skipper geprüft
        // werden, auch wenn der Vermessungsmonat dokumentiert ist.
        context.depthRequiresVerification = depthSource?.source == .catalog
        if let depthSource {
            let label = waypoint.calculationMode == .lottiefe ? "Tiefe bei MHW" : "Kartentiefe über SKN"
            var parts = ["\(label): \(String(format: "%.2f", depthSource.value)) m"]
            if let sourceNotes = depthSource.sourceNotes, !sourceNotes.isEmpty { parts.append(sourceNotes) }
            if let surveyedAt = depthSource.surveyedAt {
                let components = AppDateFormatters.berlinCalendar.dateComponents([.month, .year], from: surveyedAt)
                if let month = components.month, let year = components.year {
                    parts.append(String(format: "Stand %02d/%04d", month, year))
                }
            }
            context.depthSourceDescription = parts.joined(separator: " · ")
        }
        return context
    }

    // MARK: - Hilfsfunktionen zur Ermittlung der Eingaben
    //
    // Für die Lesbarkeit von `resolve` ausgelagert. Die Auswahlreihenfolgen
    // entsprechen `RouteCalculationService.calculateWaypoint`.

    /// Excel `L33`: manuelle Eingabe → BSH-Referenz → Katalog → Datenanbieter.
    private static func resolveMeanTidalRange(
        waypoint: RouteWaypoint,
        stationReference: TideStationReference?,
        tideDataProvider: TideDataProvider
    ) async -> Double? {
        if let sourced = waypoint.meanTidalRangeMeters, sourced.source == .manual {
            return sourced.value
        }
        if let reference = stationReference?.meanTidalRangeMeters { return reference }
        if let catalogValue = waypoint.meanTidalRangeMeters?.value { return catalogValue }
        if let val = try? await tideDataProvider.meanTidalRange(for: waypoint.tidalReferenceStationID) {
            return val
        }
        return 2.6
    }

    /// Excel `L41` (MHW) oder `L43` (Lottiefe), je nach Modus.
    private static func resolveReferenceLevel(
        waypoint: RouteWaypoint,
        stationReference: TideStationReference?
    ) -> Double? {
        switch waypoint.calculationMode {
        case .meanHighWater:
            if let sourced = waypoint.meanHighWaterMeters, sourced.source == .manual {
                return sourced.value
            }
            return stationReference?.meanHighWaterAboveSknMeters
                ?? waypoint.meanHighWaterMeters?.value
                ?? 3.0
        case .lottiefe:
            return waypoint.lottiefeMeters?.value
        }
    }

    /// Excel `L47`: Eine manuelle Eingabe hat Vorrang vor der BSH-Vorhersage.
    private static func resolveCorrection(
        stationID: String,
        manualCorrectionMeters: Double?,
        arrivalSpan: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        tideDataProvider: TideDataProvider,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries {
        if let manual = manualCorrectionMeters {
            return .constant(WaterLevelCorrectionResolution(
                meters: manual,
                quality: .manual,
                localStationID: stationID,
                sourceStationID: nil,
                sourceStationName: nil,
                issuedAt: nil,
                detail: "Manuell eingetragene Korrektur für den Törn."
            ))
        }
        return await tideDataProvider.waterLevelCorrectionSeries(
            for: stationID,
            covering: arrivalSpan,
            anchorHighWaterTime: anchorHighWaterTime,
            confirmedComparisonStationID: confirmedComparisonStationID
        )
    }
}
