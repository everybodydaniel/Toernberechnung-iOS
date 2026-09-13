import Foundation

// MARK: - Tide Data Provider Protocol

/// Abstraction for obtaining tidal event data for a BSH reference station.
///
/// Supports multiple backends:
/// - Online BSH API (`BSHTideDataProvider`)
/// - Mock data for unit tests (`MockTideDataProvider`)
/// - Manual user entry fallback
///
/// The provider must fail gracefully if a station ID is unknown, unavailable,
/// renamed, or not supported by BSH. Never crash on missing data.
protocol TideDataProvider {
    /// Fetch high-water events for a reference station around a date.
    ///
    /// - Parameters:
    ///   - stationID: BSH station ID (e.g. "507P"). May be provisional or incorrect.
    ///   - date: The approximate date to search around.
    /// - Returns: Array of `TideEvent` sorted by time, or empty if station is unknown.
    /// - Throws: Network errors, parse errors. Unknown station should return empty, not throw.
    func highWaters(
        for stationID: String,
        around date: Date
    ) async throws -> [TideEvent]

    /// Fetch mean tidal range for a station, if available from the data source.
    /// Returns nil if the provider does not supply this value.
    func meanTidalRange(for stationID: String) async throws -> Double?

    /// Fetch mean high water for a station, if available from the data source.
    /// Returns nil if the provider does not supply this value.
    func meanHighWater(for stationID: String) async throws -> Double?

    /// Current-year BSH reference values and station capability metadata.
    func stationReference(
        for stationID: String,
        around date: Date
    ) async throws -> TideStationReference?

    /// Conservative meteorological correction for the relevant HW cycle.
    /// A comparison station is only considered when explicitly supplied.
    func waterLevelCorrection(
        for stationID: String,
        at highWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionResolution

    /// Time-dependent correction over `span`, so a waypoint reached hours away
    /// from high water is not charged the peak surge.
    ///
    /// `anchorHighWaterTime` selects the gauge's HW cycle (and its uncertainty
    /// band); the caller samples the result at the actual arrival time.
    func waterLevelCorrectionSeries(
        for stationID: String,
        covering span: ClosedRange<Date>,
        anchorHighWaterTime: Date,
        confirmedComparisonStationID: String?
    ) async -> WaterLevelCorrectionSeries
}

extension TideDataProvider {
    /// Providers without a forecast curve keep the previous behaviour: one
    /// scalar sampled at the high-water peak, applied flat.
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

// MARK: - BSH Tide Data Provider

/// Wraps the existing `BSHTideService` to conform to `TideDataProvider`.
///
/// Maps station IDs to `HarbourOption` for the BSH fetch call.
/// If a station ID is not found in the known harbour list, returns empty results
/// rather than throwing, so the calculation engine marks the waypoint as incomplete.
final class BSHTideDataProvider: TideDataProvider {

    func highWaters(
        for stationID: String,
        around date: Date
    ) async throws -> [TideEvent] {
        do {
            return try await BSHTideService.shared.highWaters(for: stationID, around: date)
        } catch {
            // BSH fetch failed — return empty so the waypoint is marked incomplete.
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

// MARK: - Mock Tide Data Provider

/// Mock provider for unit tests. Returns configurable tide events.
final class MockTideDataProvider: TideDataProvider {
    /// Pre-configured high water events keyed by station ID.
    var highWatersByStation: [String: [TideEvent]] = [:]
    /// Pre-configured mean tidal ranges keyed by station ID.
    var meanTidalRanges: [String: Double] = [:]
    /// Pre-configured mean high water values keyed by station ID.
    var meanHighWaters: [String: Double] = [:]
    var referencesByStation: [String: TideStationReference] = [:]
    var correctionsByStation: [String: WaterLevelCorrectionResolution] = [:]
    /// Optional time-dependent corrections. When a station is absent here, the
    /// protocol's default kicks in and the scalar from `correctionsByStation`
    /// is used — so tests written before the curve existed keep working.
    var correctionSeriesByStation: [String: WaterLevelCorrectionSeries] = [:]
    /// If true, throws an error on fetch to simulate network failure.
    var shouldThrow: Bool = false
    /// Counts `highWaters(for:around:)` calls so tests can prove the passage
    /// window search resolves tide data once per waypoint instead of once per
    /// candidate departure time.
    ///
    /// Lock-protected: `PassageWindowSolver` resolves its waypoints
    /// concurrently, so an unsynchronised dictionary would race.
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
