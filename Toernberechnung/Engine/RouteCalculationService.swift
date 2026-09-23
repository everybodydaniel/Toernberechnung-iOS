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
        tidalHeightStrategy: TidalHeightStrategy = ContinuousTwelfthsStrategy(),
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

        // Resolve the same forecast inputs used by the Android-compatible scanner.
        var currentModels: [AndroidPassageLeg]?
        if tideDataProvider.usesAndroidForecastLevels {
            var models: [AndroidPassageLeg] = []
            for index in route.legs.indices {
                let events = (try? await tideDataProvider.routeEvents(for: route.waypoints[index],
                    covering: route.plannedStartTime ... route.plannedStartTime)) ?? []
                models.append(AndroidPassageLeg(distanceNm: route.legs[index].distanceNm,
                    speedKnots: route.legs[index].speedThroughWaterKnots,
                    courseDegrees: AndroidPassageLeg.course(from: route.waypoints[index], to: route.waypoints[index + 1]),
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
        let tidalStatus: RouteStatus = legResults.contains(where: { !$0.isValid }) ? .noGo : Self.determineRouteStatus(
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
        legs: [RouteLeg],
        currentModels: [AndroidPassageLeg]? = nil
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
        // Data provenance controls the advisory text, not the physical safety
        // result. A usable fallback (manual value, model estimate, comparison
        // gauge or zero-surge scenario) must never turn adequate clearance into
        // "Beschränkt". Conversely, quality must never make a No-Go safe.
        _ = quality
        return status
    }

    /// Determine overall route status from all waypoint statuses.
    ///
    /// - `noGo` if any waypoint is noGo (insufficient depth)
    /// - `incomplete` if any required input is missing or cannot be evaluated
    /// - `warning` if any waypoint is below safety margin
    /// - `go` only if all waypoints are go
    static func determineRouteStatus(
        waypointStatuses: [WaypointStatus]
    ) -> RouteStatus {
        if waypointStatuses.contains(.noGo) { return .noGo }
        if waypointStatuses.contains(.invalid) || waypointStatuses.contains(.incomplete) {
            return .incomplete
        }
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
