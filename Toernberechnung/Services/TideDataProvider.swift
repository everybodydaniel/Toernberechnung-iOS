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
        // BSH yearly data may contain MHW and MNW from which MTH can be derived.
        // For now, return nil — the calculation engine will fall back to catalog/template values.
        // Future: parse MHW-MNW from BSHTidePayload if available.
        return nil
    }

    func meanHighWater(for stationID: String) async throws -> Double? {
        // Future: extract from BSH yearly data if available.
        return nil
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
    /// If true, throws an error on fetch to simulate network failure.
    var shouldThrow: Bool = false

    func highWaters(for stationID: String, around date: Date) async throws -> [TideEvent] {
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
}
