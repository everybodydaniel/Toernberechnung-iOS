import Foundation

// MARK: - Passage Window Scanner

/// Scans for safe departure windows around a given departure time.
///
/// Replaces the passage-window scanning from the former `ManualPassageCalculator`.
/// Now evaluates the **full multi-waypoint route**, not just one shallow point.
/// A departure window is "safe" only if the entire route is Go or Warning at that departure time.
struct PassageWindowScanner {
    /// A safe departure window with start and end times.
    struct Window: Equatable {
        let start: Date
        let end: Date

        func contains(_ date: Date) -> Bool {
            date >= start && date <= end
        }

        var displayString: String {
            "\(Self.timeFormatter.string(from: start)) – \(Self.timeFormatter.string(from: end)) Uhr"
        }

        private static let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
    }

    private let calculationService: RouteCalculationService
    /// Scan step size in seconds. Default 10 minutes.
    var scanIncrementSeconds: TimeInterval = 10 * 60
    /// How far back to scan from the center time. Default 12 hours.
    var scanBackwardHours: Double = 12
    /// How far forward to scan from the center time. Default 24 hours.
    var scanForwardHours: Double = 24

    init(calculationService: RouteCalculationService = RouteCalculationService()) {
        self.calculationService = calculationService
    }

    /// Scan for safe departure windows around the planned departure time.
    ///
    /// Evaluates the full route at each scan step. A departure is "safe" if
    /// the overall tidal route status is `.go` or `.warning` (not `.noGo` or `.incomplete`).
    ///
    /// - Parameters:
    ///   - route: The route plan (departure time will be shifted for each scan step).
    ///   - boatSettings: Boat draft and safety margin.
    ///   - tideDataProvider: Provider for BSH tide data.
    /// - Returns: The best safe departure window, or nil if none found.
    func findSafeWindow(
        route: RoutePlan,
        boatSettings: BoatSettings,
        tideDataProvider: TideDataProvider
    ) async -> Window? {
        let center = route.plannedStartTime
        let scanStart = center.addingTimeInterval(-scanBackwardHours * 3600)
        let scanEnd = center.addingTimeInterval(scanForwardHours * 3600)

        var windows: [Window] = []
        var openStart: Date?
        var openEnd: Date?

        var candidate = scanStart
        while candidate <= scanEnd {
            // Shift the route's departure time to the candidate.
            var shifted = route
            shifted.plannedStartTime = candidate

            let result = await calculationService.calculate(
                route: shifted,
                boatSettings: boatSettings,
                tideDataProvider: tideDataProvider
            )

            let isSafe = result.tidalStatus == .go || result.tidalStatus == .warning

            if isSafe {
                if openStart == nil { openStart = candidate }
                openEnd = candidate
            } else if let start = openStart, let end = openEnd {
                windows.append(Window(start: start, end: end))
                openStart = nil
                openEnd = nil
            }

            candidate = candidate.addingTimeInterval(scanIncrementSeconds)
        }

        // Close any remaining open window.
        if let start = openStart, let end = openEnd {
            windows.append(Window(start: start, end: end))
        }

        // Prefer the window that contains the original departure time.
        if let active = windows.first(where: { $0.contains(center) }) {
            return active
        }

        // Otherwise return the next window after the original departure time.
        return windows.first(where: { $0.start > center })
    }
}
