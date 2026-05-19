import Foundation

/// Sucht sichere Abfahrtsfenster rund um eine angegebene Abfahrtszeit.
///
/// Bewertet die **gesamte mehrgliedrige Route**, nicht nur einen Flachpunkt.
/// Ein Abfahrtsfenster ist nur dann „sicher“, wenn die gesamte Route bei dieser Abfahrt Go oder Warning ist.
struct PassageWindowScanner {
    /// Ein sicheres Abfahrtsfenster mit Start- und Endzeit.
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
    /// Schrittweite des Scans in Sekunden. Standard: 10 Minuten.
    var scanIncrementSeconds: TimeInterval = 10 * 60
    /// Wie weit vor der Mittelzeit gescannt wird. Standard: 12 Stunden.
    var scanBackwardHours: Double = 12
    /// Wie weit nach der Mittelzeit gescannt wird. Standard: 24 Stunden.
    var scanForwardHours: Double = 24

    init(calculationService: RouteCalculationService = RouteCalculationService()) {
        self.calculationService = calculationService
    }

    /// Sucht sichere Abfahrtsfenster um die geplante Abfahrtszeit.
    ///
    /// Bewertet bei jedem Scan-Schritt die gesamte Route. Eine Abfahrt ist „sicher“, wenn
    /// der Gesamttidenstatus `.go` oder `.warning` ist (nicht `.noGo` oder `.incomplete`).
    ///
    /// - Parameters:
    ///   - route: Der Routenplan (die Abfahrtszeit wird für jeden Scan-Schritt verschoben).
    ///   - boatSettings: Tiefgang und Sicherheitsmarge des Bootes.
    ///   - tideDataProvider: Anbieter für BSH-Tidendaten.
    /// - Returns: Das beste sichere Abfahrtsfenster oder nil, wenn keines gefunden wird.
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

        if let start = openStart, let end = openEnd {
            windows.append(Window(start: start, end: end))
        }

        if let active = windows.first(where: { $0.contains(center) }) {
            return active
        }

        return windows.first(where: { $0.start > center })
    }
}
