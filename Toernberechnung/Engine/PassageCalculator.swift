import Foundation

enum ManualPassageDepthMode {
    case mhw
    case sounding
}

struct ManualPassageWindow: Equatable {
    let start: Date
    let end: Date

    func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }

    var displayString: String {
        "\(Self.timeFormatter.string(from: start)) - \(Self.timeFormatter.string(from: end)) Uhr"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct ManualPassageInput {
    let departureTime: Date
    let highWaterTime: Date
    let distanceNM: Double
    let speedKnots: Double
    let offsetMinutes: Double
    let meanTidalRangeMeters: Double
    let referenceDepthMeters: Double
    let bshWaterLevelCorrectionMeters: Double
    let chartDepthMeters: Double
    let boatDraftMeters: Double
    let depthMode: ManualPassageDepthMode
}

struct ManualPassageResult {
    let distanceNM: Double
    let travelHours: Double
    let arrivalAtPassage: Date
    let hwAtPassage: Date
    let hoursFromHW: Double
    let fmw: Double
    let hg: Double?
    let wt: Double
    let ukc: Double
    let isPassable: Bool
    let hasDataError: Bool
    let statusText: String
    let passageWindow: ManualPassageWindow?

    func passageWindowDescription(for departureTime: Date) -> String {
        guard let passageWindow else {
            if hasDataError {
                return "Bitte HW-Zeit, Offset und Rechendaten prüfen."
            }
            return "Im Suchbereich wurde kein sicheres Abfahrtsfenster gefunden."
        }

        if passageWindow.contains(departureTime) {
            return "Die aktuelle Abfahrt liegt innerhalb des sicheren Fensters."
        }

        return "Die aktuelle Abfahrt ist nicht befahrbar. Angezeigt wird das nächste sichere Fenster."
    }
}

enum ManualPassageCalculator {
    private struct Evaluation {
        let distanceNM: Double
        let travelHours: Double
        let arrivalAtPassage: Date
        let hwAtPassage: Date
        let hoursFromHW: Double
        let fmw: Double
        let hg: Double?
        let wt: Double
        let ukc: Double
        let isPassable: Bool
        let hasDataError: Bool
    }

    static func calculate(input: ManualPassageInput) -> ManualPassageResult {
        let evaluation = evaluate(input: input, departureTime: input.departureTime)
        let passageWindow = calculatePassageWindow(input: input, centerDepartureTime: input.departureTime)

        return ManualPassageResult(
            distanceNM: evaluation.distanceNM,
            travelHours: evaluation.travelHours,
            arrivalAtPassage: evaluation.arrivalAtPassage,
            hwAtPassage: evaluation.hwAtPassage,
            hoursFromHW: evaluation.hoursFromHW,
            fmw: evaluation.fmw,
            hg: evaluation.hg,
            wt: evaluation.wt,
            ukc: evaluation.ukc,
            isPassable: evaluation.isPassable,
            hasDataError: evaluation.hasDataError,
            statusText: evaluation.isPassable ? "Befahrbar" : "Nicht befahrbar",
            passageWindow: passageWindow
        )
    }

    private static func calculatePassageWindow(input: ManualPassageInput, centerDepartureTime: Date) -> ManualPassageWindow? {
        // Das sichere Zeitfenster wird in 10-Minuten-Schritten um die gewählte Abfahrt herum gesucht.
        let scanIncrement: TimeInterval = 10 * 60
        let scanStart = centerDepartureTime.addingTimeInterval(-12 * 3600)
        let scanEnd = centerDepartureTime.addingTimeInterval(24 * 3600)

        var windows: [ManualPassageWindow] = []
        var openWindowStart: Date?
        var openWindowEnd: Date?

        var candidate = scanStart
        while candidate <= scanEnd {
            let evaluation = evaluate(input: input, departureTime: candidate)

            if evaluation.isPassable {
                if openWindowStart == nil {
                    openWindowStart = candidate
                }
                openWindowEnd = candidate
            } else if let start = openWindowStart, let end = openWindowEnd {
                windows.append(ManualPassageWindow(start: start, end: end))
                openWindowStart = nil
                openWindowEnd = nil
            }

            candidate = candidate.addingTimeInterval(scanIncrement)
        }

        if let start = openWindowStart, let end = openWindowEnd {
            windows.append(ManualPassageWindow(start: start, end: end))
        }

        if let activeWindow = windows.first(where: { $0.contains(centerDepartureTime) }) {
            return activeWindow
        }

        return windows.first(where: { $0.start > centerDepartureTime })
    }

    private static func evaluate(input: ManualPassageInput, departureTime: Date) -> Evaluation {
        let distanceNM = max(input.distanceNM, 0.1)
        let speedKnots = max(input.speedKnots, 0.1)
        let travelHours = distanceNM / speedKnots
        let arrivalAtPassage = departureTime.addingTimeInterval(travelHours * 3600)
        let hwAtPassage = input.highWaterTime.addingTimeInterval(input.offsetMinutes * 60)
        let hoursFromHW = abs(arrivalAtPassage.timeIntervalSince(hwAtPassage)) / 3600
        let twelfth = input.meanTidalRangeMeters / 12
        let (fmw, hasDataError) = calculateFmW(hoursFromHW: hoursFromHW, twelfth: twelfth)
        let hg = input.depthMode == .mhw
            ? input.referenceDepthMeters - fmw + input.bshWaterLevelCorrectionMeters
            : nil
        let wt: Double

        if input.depthMode == .mhw {
            wt = (hg ?? 0) + input.chartDepthMeters
        } else {
            wt = input.referenceDepthMeters - fmw + input.bshWaterLevelCorrectionMeters + input.chartDepthMeters
        }

        let ukc = wt - input.boatDraftMeters
        let isPassable = ukc >= 0 && !hasDataError

        return Evaluation(
            distanceNM: distanceNM,
            travelHours: travelHours,
            arrivalAtPassage: arrivalAtPassage,
            hwAtPassage: hwAtPassage,
            hoursFromHW: hoursFromHW,
            fmw: fmw,
            hg: hg,
            wt: wt,
            ukc: ukc,
            isPassable: isPassable,
            hasDataError: hasDataError
        )
    }

    private static func calculateFmW(hoursFromHW: Double, twelfth: Double) -> (fmw: Double, hasDataError: Bool) {
        // Zwölftelregel: je weiter die Passage vom Hochwasser entfernt ist, desto stärker wird Wasserhöhe abgezogen.
        if abs(hoursFromHW) < 0.000_001 {
            return (0, false)
        }

        switch hoursFromHW {
        case ...1:
            return (1 * twelfth, false)
        case ...2:
            return (3 * twelfth, false)
        case ...3:
            return (6 * twelfth, false)
        case ...4:
            return (9 * twelfth, false)
        case ...5:
            return (11 * twelfth, false)
        case ...7:
            return (12 * twelfth, false)
        case ...8:
            return (11 * twelfth, false)
        case ...9:
            return (9 * twelfth, false)
        case ...10:
            return (6 * twelfth, false)
        case ...11:
            return (3 * twelfth, false)
        case ...12:
            return (1 * twelfth, false)
        default:
            return (0, true)
        }
    }
}
