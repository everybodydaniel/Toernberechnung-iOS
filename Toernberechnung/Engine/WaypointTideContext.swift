import Foundation

// MARK: - Waypoint Tide Context

/// Everything needed to evaluate one waypoint's clearance at **any** arrival
/// time, resolved once. After `resolve(...)` returns, no further I/O happens —
/// `clearance(atArrival:strategy:)` is a synchronous call into
/// `WaypointDepthSolver`, the very same arithmetic the route calculation uses.
///
/// This is what makes per-bottleneck passage windows cheap: the old scanner
/// re-resolved the same gauge data for every candidate departure time.
struct WaypointTideContext: Equatable {

    let waypointID: UUID
    let name: String
    let category: String?
    let calculationMode: WaypointCalculationMode

    /// High waters **at the waypoint** (the gauge's events with the waypoint
    /// offset already applied), covering the search span.
    let waypointHighWaters: [Date]
    /// Excel `L33`.
    let meanTidalRangeMeters: Double
    /// Excel `L41` or `L43`, depending on the mode.
    let referenceLevelMeters: Double
    /// Excel `L51`. Nil in Lottiefe mode.
    let chartDepthMeters: Double?
    /// Excel `M55`.
    let draftMeters: Double
    let correction: WaterLevelCorrectionSeries

    let plannedArrivalTime: Date
    /// Cumulative travel time from the route start to this waypoint.
    let travelOffsetHours: Double

    // MARK: - Evaluation

    /// Clearance under keel for an arrival at `time`. Nil when the deviation
    /// exceeds a full tidal cycle or a required input is missing.
    func clearance(atArrival time: Date, strategy: TidalHeightStrategy) -> Double? {
        guard let highWater = nearestWaypointHighWater(to: time) else { return nil }
        let deviation = abs(time.timeIntervalSince(highWater)) / 3_600

        let solved = WaypointDepthSolver.solve(
            WaypointDepthSolver.Inputs(
                calculationMode: calculationMode,
                referenceLevelMeters: referenceLevelMeters,
                chartDepthMeters: chartDepthMeters,
                meanTidalRangeMeters: meanTidalRangeMeters,
                deviationHours: deviation,
                waterLevelCorrectionMeters: correction.resolution(at: time).meters,
                draftMeters: draftMeters
            ),
            strategy: strategy
        )
        switch solved {
        case .success(let output): return output.clearanceUnderKeelMeters
        case .failure: return nil
        }
    }

    /// How much water may be missing before the keel touches.
    ///
    /// Rearranging the depth chain for `WuK ≥ 0`:
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

    /// The route's departure search span translated into arrival times here.
    func searchSpanShiftedToArrival(_ span: ClosedRange<Date>) -> ClosedRange<Date> {
        let shift = travelOffsetHours * 3_600
        return span.lowerBound.addingTimeInterval(shift)
            ... span.upperBound.addingTimeInterval(shift)
    }

    // MARK: - Resolution

    // The resolution chains mirror `RouteCalculationService.calculateWaypoint`
    // exactly, which is why they are spelled out rather than abbreviated.
    // swiftlint:disable:next function_parameter_count
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
        let stationReference = try? await tideDataProvider.stationReference(
            for: waypoint.tidalReferenceStationID,
            around: plannedArrivalTime
        )

        guard let mth = await resolveMeanTidalRange(
            waypoint: waypoint,
            stationReference: stationReference,
            tideDataProvider: tideDataProvider
        ), mth > 0 else { return nil }

        guard let level = resolveReferenceLevel(
            waypoint: waypoint,
            stationReference: stationReference
        ) else { return nil }

        // High waters covering the whole search span, offset onto the waypoint.
        let arrivalSpan = searchSpan.lowerBound
            .addingTimeInterval(travelOffsetHours * 3_600)
            ... searchSpan.upperBound.addingTimeInterval(travelOffsetHours * 3_600)
        let referenceHighWaters: [Date]
        if let manual = waypoint.manualHighWaterTime {
            referenceHighWaters = [manual]
        } else {
            let midpoint = Date(timeIntervalSince1970: (
                arrivalSpan.lowerBound.timeIntervalSince1970
                    + arrivalSpan.upperBound.timeIntervalSince1970
            ) / 2)
            let events = (try? await tideDataProvider.highWaters(
                for: waypoint.tidalReferenceStationID,
                around: midpoint
            )) ?? []
            referenceHighWaters = events.map(\.time)
        }
        guard let anchorReferenceHighWater = referenceHighWaters.min(by: {
            abs($0.timeIntervalSince(plannedArrivalTime))
                < abs($1.timeIntervalSince(plannedArrivalTime))
        }) else { return nil }

        let offsetSeconds = Double(waypoint.highWaterOffsetMinutes) * 60
        let waypointHighWaters = referenceHighWaters
            .map { $0.addingTimeInterval(offsetSeconds) }
            .sorted()

        let correction = await resolveCorrection(
            stationID: waypoint.tidalReferenceStationID,
            manualCorrectionMeters: manualCorrectionMeters,
            arrivalSpan: arrivalSpan,
            anchorHighWaterTime: anchorReferenceHighWater,
            tideDataProvider: tideDataProvider,
            confirmedComparisonStationID: confirmedComparisonStationID
        )

        return WaypointTideContext(
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
    }

    // MARK: - Resolution helpers
    //
    // Split out purely to keep `resolve` readable; the priority chains are
    // identical to `RouteCalculationService.calculateWaypoint`.

    /// Excel `L33`: manual → BSH reference → catalog → provider.
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
        return try? await tideDataProvider.meanTidalRange(for: waypoint.tidalReferenceStationID)
    }

    /// Excel `L41` (MHW) or `L43` (Lottiefe), depending on the mode.
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
        case .lottiefe:
            return waypoint.lottiefeMeters?.value
        }
    }

    /// Excel `L47`: a manually entered value wins over the BSH forecast.
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
