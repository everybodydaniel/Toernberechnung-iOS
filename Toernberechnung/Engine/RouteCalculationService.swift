import Foundation

// MARK: - Route Calculation Service

/// The single source of truth for all tidal Go / No-Go calculations in the app.
///
/// This service replaces `ManualPassageCalculator`. It calculates ETA, tidal water depth,
/// and clearance under keel for every waypoint in a multi-waypoint route.
///
/// The service is **geography-independent**: it consumes structured waypoint, tide, leg,
/// and boat data. No calculation code depends on fixed waypoint names, island names,
/// or specific routes. The Emden → Norderney example is only a regression test fixture.
///
/// ## Calculation Flow
/// 1. Validate inputs
/// 2. Calculate arrival times at each waypoint using leg data
/// 3. For each waypoint:
///    a. Resolve relevant high water (from provider or manual entry)
///    b. Apply HW offset
///    c. Calculate deviation from HW
///    d. Apply tidal height strategy (1/12 rule) to get FmW
///    e. Calculate available water depth (MHW or Lottiefe mode)
///    f. Calculate clearance under keel
///    g. Determine waypoint status
/// 4. Combine all waypoint statuses into overall route status
final class RouteCalculationService {

    private let tidalHeightStrategy: TidalHeightStrategy
    private let calendar: Calendar

    /// Creates a calculation service.
    /// - Parameters:
    ///   - tidalHeightStrategy: Strategy for computing FmW. Default is TwelfthsRuleStrategy.
    ///   - timeZone: Time zone for date calculations. Default is Europe/Berlin.
    init(
        tidalHeightStrategy: TidalHeightStrategy = TwelfthsRuleStrategy(),
        timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
    ) {
        self.tidalHeightStrategy = tidalHeightStrategy
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal
    }

    // MARK: - Main Calculation

    /// Calculate tidal Go/No-Go for a complete multi-waypoint route.
    ///
    /// - Parameters:
    ///   - route: The route plan with all waypoints and legs.
    ///   - boatSettings: Boat draft and safety margin.
    ///   - tideDataProvider: Provider for BSH tide data.
    /// - Returns: Complete route calculation result.
    func calculate(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider,
        confirmedComparisonGaugeIDs: [String: String] = [:]
    ) async -> RouteCalculationResult {
        var messages: [String] = []

        // Validate basic inputs.
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

        // Calculate arrival times.
        let legResults = Self.calculateLegResults(
            startTime: route.plannedStartTime,
            legs: route.legs
        )

        var arrivalTimes: [Date] = [route.plannedStartTime]
        for legResult in legResults {
            arrivalTimes.append(legResult.arrivalTime)
        }

        // Calculate each waypoint.
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

        // Determine overall tidal status.
        let tidalStatus = Self.determineRouteStatus(
            waypointStatuses: waypointResults.map(\.status)
        )

        // Compute summary values.
        let totalDistance = legResults.reduce(0) { $0 + $1.leg.distanceNm }
        let totalTime = legResults.reduce(0) { $0 + $1.travelTimeHours }
        let worstWuK = waypointResults.compactMap(\.clearanceUnderKeelWuKMeters).min()

        // Add leg validity warnings.
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
            weatherStatus: .incomplete, // Weather is assessed separately by the view model.
            combinedStatus: CombinedRouteStatus.combine(tidal: tidalStatus, weather: .incomplete),
            messages: messages
        )
    }

    // MARK: - Per-Waypoint Calculation

    // The calculation is intentionally kept linear so every safety input remains auditable.
    // swiftlint:disable:next function_body_length
    private func calculateWaypoint(
        waypoint: RouteWaypoint,
        arrivalTime: Date,
        routeWaterLevelCorrectionMeters: Double?,
        confirmedComparisonStationID: String?,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider
    ) async -> WaypointCalculationResult {
        var messages: [String] = []

        let stationReference = try? await tideDataProvider.stationReference(
            for: waypoint.tidalReferenceStationID,
            around: arrivalTime
        )

        // Resolve MTH using priority chain:
        // 1. waypoint value (user override or template)
        // 2. TideDataProvider value
        // 3. incomplete
        let mthMeters: Double?
        if let sourced = waypoint.meanTidalRangeMeters, sourced.source == .manual {
            mthMeters = sourced.value
        } else if let referenceValue = stationReference?.meanTidalRangeMeters {
            mthMeters = referenceValue
        } else if let catalogValue = waypoint.meanTidalRangeMeters?.value {
            mthMeters = catalogValue
        } else {
            mthMeters = try? await tideDataProvider.meanTidalRange(
                for: waypoint.tidalReferenceStationID
            )
        }

        guard let mth = mthMeters, mth > 0 else {
            messages.append("MTH (Mittlerer Tidenhub) fehlt oder ist ungültig für \(waypoint.name).")
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                bshCorrection: 0,
                correctionQuality: .unavailable,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }

        // Resolve relevant high water time.
        let hwTime: Date?
        if let manual = waypoint.manualHighWaterTime {
            hwTime = manual
        } else {
            let hwEvents = (try? await tideDataProvider.highWaters(
                for: waypoint.tidalReferenceStationID,
                around: arrivalTime
            )) ?? []
            hwTime = Self.findNearestHighWater(to: arrivalTime, from: hwEvents)
        }

        guard let referenceHWTime = hwTime else {
            messages.append("Kein Hochwasser für \(waypoint.tidalReferenceStation) verfügbar.")
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                bshCorrection: 0,
                correctionQuality: .unavailable,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }

        // Apply waypoint HW offset.
        let waypointHWTime = Self.applyHighWaterOffset(
            referenceHWTime: referenceHWTime,
            offsetMinutes: waypoint.highWaterOffsetMinutes
        )

        let correction: WaterLevelCorrectionResolution
        if let manual = waypoint.bshWaterLevelCorrectionOverride {
            correction = WaterLevelCorrectionResolution(
                meters: manual,
                quality: .manual,
                localStationID: waypoint.tidalReferenceStationID,
                sourceStationID: nil,
                sourceStationName: nil,
                issuedAt: nil,
                detail: "Manuell eingetragene Wasserstandskorrektur."
            )
        } else if let routeCorrection = routeWaterLevelCorrectionMeters {
            // Excel's global $AD$13. A typed 0,00 is a real answer ("no surge"),
            // so the value is optional rather than sentinel-checked against zero.
            correction = WaterLevelCorrectionResolution(
                meters: routeCorrection,
                quality: .manual,
                localStationID: waypoint.tidalReferenceStationID,
                sourceStationID: nil,
                sourceStationName: nil,
                issuedAt: nil,
                detail: "Manuell eingetragene Korrektur für den Törn."
            )
        } else {
            // The anchor selects the gauge's HW cycle (and its uncertainty
            // band); the sample is taken at the time the boat is actually
            // there. Both matter: two waypoints on the same gauge with
            // different `highWaterOffsetMinutes` are passed at different times
            // and must not receive an identical surge.
            let series = await tideDataProvider.waterLevelCorrectionSeries(
                for: waypoint.tidalReferenceStationID,
                covering: arrivalTime.addingTimeInterval(-3 * 3_600)
                    ... arrivalTime.addingTimeInterval(3 * 3_600),
                anchorHighWaterTime: referenceHWTime,
                confirmedComparisonStationID: confirmedComparisonStationID
            )
            correction = series.resolution(at: arrivalTime)
        }
        if correction.quality != .localOfficial {
            messages.append(correction.detail)
        }

        // Calculate deviation from HW.
        let deviation = Self.calculateDeviationHours(
            arrivalTime: arrivalTime,
            highWaterTime: waypointHWTime
        )

        // Resolve the reference level (Excel L41 or L43) for the waypoint's mode.
        let referenceLevel: Double?
        switch waypoint.calculationMode {
        case .meanHighWater:
            referenceLevel = resolvedMeanHighWater(
                waypoint: waypoint,
                stationReference: stationReference
            )
            if referenceLevel == nil {
                messages.append("MHW (Mittleres Hochwasser) fehlt für \(waypoint.name).")
            }
        case .lottiefe:
            referenceLevel = waypoint.lottiefeMeters?.value
            if referenceLevel == nil {
                messages.append("Lottiefe fehlt für \(waypoint.name).")
            }
        }

        guard let level = referenceLevel else {
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                referenceHighWaterTime: referenceHWTime,
                meanTidalRangeMeters: mth,
                bshCorrection: correction.meters,
                correctionQuality: correction.quality,
                correctionDetail: correction.detail,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }

        // The depth chain itself lives in `WaypointDepthSolver` so the passage
        // window search evaluates the identical arithmetic.
        let solved = WaypointDepthSolver.solve(
            WaypointDepthSolver.Inputs(
                calculationMode: waypoint.calculationMode,
                referenceLevelMeters: level,
                chartDepthMeters: waypoint.chartDepthMeters?.value,
                meanTidalRangeMeters: mth,
                deviationHours: deviation,
                waterLevelCorrectionMeters: correction.meters,
                draftMeters: boatSettings.draftMeters
            ),
            strategy: tidalHeightStrategy
        )

        switch solved {
        case .success(let depth):
            let baseStatus = Self.determineWaypointStatus(
                clearanceUnderKeel: depth.clearanceUnderKeelMeters,
                safetyMargin: boatSettings.safetyMarginMeters
            )
            let status = Self.applyCorrectionQuality(correction.quality, to: baseStatus)

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
                waterLevelCorrectionQuality: correction.quality,
                waterLevelCorrectionDetail: correction.detail,
                chartDepthMetersApplied: depth.chartDepthApplied,
                tideHeightHGMeters: depth.tideHeightHGMeters,
                availableWaterDepthWTMeters: depth.availableWaterDepthMeters,
                boatDraftMeters: boatSettings.draftMeters,
                clearanceUnderKeelWuKMeters: depth.clearanceUnderKeelMeters,
                status: status,
                messages: messages
            )

        case .failure(.deviationExceedsTidalCycle(let tidalMessages)):
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
                waterLevelCorrectionQuality: correction.quality,
                waterLevelCorrectionDetail: correction.detail,
                chartDepthMetersApplied: nil,
                tideHeightHGMeters: nil,
                availableWaterDepthWTMeters: nil,
                boatDraftMeters: boatSettings.draftMeters,
                clearanceUnderKeelWuKMeters: nil,
                status: .invalid,
                messages: messages
            )

        case .failure(.missingChartDepth):
            messages.append("Kartentiefe / Peilplanwert fehlt für \(waypoint.name) (MHW-Modus).")
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                referenceHighWaterTime: referenceHWTime,
                meanTidalRangeMeters: mth,
                bshCorrection: correction.meters,
                correctionQuality: correction.quality,
                correctionDetail: correction.detail,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }
    }

    private func resolvedMeanHighWater(
        waypoint: RouteWaypoint,
        stationReference: TideStationReference?
    ) -> Double? {
        if let sourced = waypoint.meanHighWaterMeters, sourced.source == .manual {
            return sourced.value
        }
        return stationReference?.meanHighWaterAboveSknMeters
            ?? waypoint.meanHighWaterMeters?.value
    }

    // MARK: - Static Helper Functions (Pure, Testable)

    /// Speed over ground = speed through water + tidal current.
    static func calculateSpeedOverGround(
        speedThroughWaterKnots: Double,
        tidalCurrentKnots: Double
    ) -> Double {
        speedThroughWaterKnots + tidalCurrentKnots
    }

    /// Travel time in hours = distance / speed over ground.
    /// Returns nil if SOG <= 0.
    static func calculateTravelTimeHours(
        distanceNm: Double,
        speedOverGroundKnots: Double
    ) -> Double? {
        guard speedOverGroundKnots > 0 else { return nil }
        return distanceNm / speedOverGroundKnots
    }

    /// Calculate leg results including arrival times, cumulative distance, and validity.
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

    /// Apply signed high-water offset to a reference HW time.
    static func applyHighWaterOffset(
        referenceHWTime: Date,
        offsetMinutes: Int
    ) -> Date {
        referenceHWTime.addingTimeInterval(Double(offsetMinutes) * 60)
    }

    /// Calculate the absolute deviation in decimal hours between arrival and high water.
    ///
    /// Uses the absolute time interval, handling midnight crossing correctly
    /// because both values carry full date context.
    static func calculateDeviationHours(
        arrivalTime: Date,
        highWaterTime: Date
    ) -> Double {
        abs(arrivalTime.timeIntervalSince(highWaterTime)) / 3600
    }

    /// Find the high water event nearest to the target time.
    static func findNearestHighWater(
        to targetTime: Date,
        from events: [TideEvent]
    ) -> Date? {
        events
            .map { $0.time }
            .min(by: { abs($0.timeIntervalSince(targetTime)) < abs($1.timeIntervalSince(targetTime)) })
    }

    /// Determine waypoint status from clearance under keel and safety margin.
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
        if status == .noGo || status == .invalid { return status }
        switch quality {
        case .localOfficial:
            return status
        case .confirmedComparison, .manual:
            return status == .go ? .warning : status
        case .stale, .outsideForecastHorizon, .unavailable:
            return .incomplete
        }
    }

    /// Determine overall route status from all waypoint statuses.
    ///
    /// - `invalid` if any waypoint is invalid (calculation error)
    /// - `noGo` if any waypoint is noGo (insufficient depth)
    /// - `incomplete` if any required input is missing
    /// - `warning` if any waypoint is below safety margin
    /// - `go` only if all waypoints are go
    static func determineRouteStatus(
        waypointStatuses: [WaypointStatus]
    ) -> RouteStatus {
        if waypointStatuses.contains(.invalid) { return .noGo }
        if waypointStatuses.contains(.noGo) { return .noGo }
        if waypointStatuses.contains(.incomplete) { return .incomplete }
        if waypointStatuses.contains(.warning) { return .warning }
        // An empty list means nothing was evaluated — that is missing data,
        // never a green light.
        return waypointStatuses.isEmpty ? .incomplete : .go
    }

    // MARK: - Private Helpers

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
