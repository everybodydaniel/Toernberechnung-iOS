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
        tideDataProvider: TideDataProvider
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

    private func calculateWaypoint(
        waypoint: RouteWaypoint,
        arrivalTime: Date,
        bshWaterLevelCorrectionMeters: Double,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider
    ) async -> WaypointCalculationResult {
        var messages: [String] = []

        // Resolve MTH using priority chain:
        // 1. waypoint value (user override or template)
        // 2. TideDataProvider value
        // 3. incomplete
        let mthMeters: Double?
        if let sourced = waypoint.meanTidalRangeMeters {
            mthMeters = sourced.value
        } else {
            mthMeters = try? await tideDataProvider.meanTidalRange(
                for: waypoint.tidalReferenceStationID
            )
        }

        guard let mth = mthMeters, mth > 0 else {
            messages.append("MTH (Mittlerer Tidenhub) fehlt oder ist ungültig für \(waypoint.name).")
            return incompleteWaypointResult(
                waypoint: waypoint, arrivalTime: arrivalTime,
                bshCorrection: bshWaterLevelCorrectionMeters,
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
                bshCorrection: bshWaterLevelCorrectionMeters,
                boatDraft: boatSettings.draftMeters, messages: messages
            )
        }

        // Apply waypoint HW offset.
        let waypointHWTime = Self.applyHighWaterOffset(
            referenceHWTime: referenceHWTime,
            offsetMinutes: waypoint.highWaterOffsetMinutes
        )

        // Calculate deviation from HW.
        let deviation = Self.calculateDeviationHours(
            arrivalTime: arrivalTime,
            highWaterTime: waypointHWTime
        )

        // Apply tidal height strategy (1/12 rule).
        let tidalResult = tidalHeightStrategy.missingWater(
            deviationHours: deviation,
            meanTidalRangeMeters: mth
        )

        guard tidalResult.isValid else {
            messages.append(contentsOf: tidalResult.messages)
            return WaypointCalculationResult(
                waypoint: waypoint,
                arrivalTime: arrivalTime,
                relevantHighWaterTime: waypointHWTime,
                deviationHours: deviation,
                oneTwelfthMeters: tidalResult.oneTwelfthMeters,
                missingWaterFmWMeters: nil,
                baseWaterAtTideMeters: nil,
                bshWaterLevelCorrectionMeters: bshWaterLevelCorrectionMeters,
                chartDepthMetersApplied: nil,
                tideHeightHGMeters: nil,
                availableWaterDepthWTMeters: nil,
                boatDraftMeters: boatSettings.draftMeters,
                clearanceUnderKeelWuKMeters: nil,
                status: .invalid,
                messages: messages
            )
        }

        // Calculate water depth based on mode.
        let depthResult = calculateDepth(
            waypoint: waypoint,
            fmwMeters: tidalResult.fmwMeters,
            bshCorrectionMeters: bshWaterLevelCorrectionMeters,
            boatDraftMeters: boatSettings.draftMeters,
            tideDataProvider: tideDataProvider
        )

        switch depthResult {
        case .calculated(let depth):
            let status = Self.determineWaypointStatus(
                clearanceUnderKeel: depth.wuK,
                safetyMargin: boatSettings.safetyMarginMeters
            )
            messages.append(contentsOf: depth.messages)

            return WaypointCalculationResult(
                waypoint: waypoint,
                arrivalTime: arrivalTime,
                relevantHighWaterTime: waypointHWTime,
                deviationHours: deviation,
                oneTwelfthMeters: tidalResult.oneTwelfthMeters,
                missingWaterFmWMeters: tidalResult.fmwMeters,
                baseWaterAtTideMeters: depth.baseWater,
                bshWaterLevelCorrectionMeters: bshWaterLevelCorrectionMeters,
                chartDepthMetersApplied: depth.chartDepthApplied,
                tideHeightHGMeters: depth.hg,
                availableWaterDepthWTMeters: depth.wt,
                boatDraftMeters: boatSettings.draftMeters,
                clearanceUnderKeelWuKMeters: depth.wuK,
                status: status,
                messages: messages
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

    // MARK: - Depth Calculation

    private struct DepthCalculation {
        let baseWater: Double
        let hg: Double?     // nil for Lottiefe mode
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

    /// MHW mode: baseWater = MHW - FmW; HG = baseWater + bshCorrection; WT = HG + chartDepth
    private func calculateMHWDepth(
        waypoint: RouteWaypoint,
        fmwMeters: Double,
        bshCorrectionMeters: Double,
        boatDraftMeters: Double,
        tideDataProvider: TideDataProvider
    ) -> DepthResult {
        // Resolve MHW using priority chain.
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

    /// Lottiefe mode: baseWater = Lottiefe - FmW; WT = baseWater + bshCorrection; chartDepth NOT applied.
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

        // HG is "leer" (empty) in Lottiefe mode — chart depth is not applied.
        return .calculated(DepthCalculation(
            baseWater: baseWater, hg: nil, chartDepthApplied: nil,
            wt: wt, wuK: wuK, messages: []
        ))
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
        return .go
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
