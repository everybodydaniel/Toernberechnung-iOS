import Foundation
import XCTest
@testable import Toernberechnung

/// Proves that the depth chain of `RouteCalculationService` reproduces rows
/// `L29`…`L57` of "Excel-Tool-Törnberechnung_V2.1".
///
/// ```
/// L29  HW am WP        = L23 ± M25/M27
/// L35  1/12tel         = L33 / 12
/// L37  Abweichung      = ABS(L29 - L31) * 24
/// L39  FmW             = <Staffel> * L35
/// L45  Basis - FmW     = (L41 | L43) - L39
/// L47  BSH-Wasserstand = $AD$13
/// L49  HG              = L45 + L47          ("leer" bei Lottiefe)
/// L53  WT              = L45 + L47 + L51
/// L57  WuK             = L53 - M55
/// ```
///
/// Every case drives the real `calculate(route:…)` entry point so the assertions
/// cover the resolution chains as well, not just the arithmetic.
final class ExcelParityDepthChainTests: XCTestCase {

    private let accuracy = 1e-9
    private let stationID = "TEST"
    /// Excel `L31` for waypoint 1 — the planned start time.
    private let startTime = Date(timeIntervalSince1970: 1_768_500_000)

    // MARK: - Fixture

    /// Builds a two-waypoint route whose legs take zero time, so both waypoints
    /// are reached at `startTime` and the deviation is fully controlled by
    /// `deviationHours`.
    ///
    /// The water level correction is supplied through the provider with
    /// `.localOfficial` quality, because any other quality would downgrade the
    /// status in `applyCorrectionQuality` and mask the depth result.
    private func makeRoute(
        mode: WaypointCalculationMode,
        meanHighWaterMeters: Double? = nil,
        lottiefeMeters: Double? = nil,
        chartDepthMeters: Double? = nil,
        meanTidalRangeMeters: Double,
        deviationHours: Double,
        highWaterOffsetMinutes: Int = 0
    ) -> RoutePlan {
        func sourced(_ value: Double?) -> SourcedValue<Double>? {
            value.map { SourcedValue(value: $0, source: .manual, sourceNotes: nil) }
        }

        // Excel L23: the reference high water. L29 adds the offset on top, so the
        // reference is shifted back by the offset to land on the wanted deviation.
        let referenceHighWater = startTime
            .addingTimeInterval(-deviationHours * 3_600)
            .addingTimeInterval(-Double(highWaterOffsetMinutes) * 60)

        let start = RouteWaypoint(
            id: UUID(),
            name: "WP 1",
            latitude: 53.7,
            longitude: 7.2,
            tidalReferenceStation: "Testpegel",
            tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: highWaterOffsetMinutes,
            meanTidalRangeMeters: sourced(meanTidalRangeMeters),
            meanHighWaterMeters: sourced(meanHighWaterMeters),
            lottiefeMeters: sourced(lottiefeMeters),
            chartDepthMeters: sourced(chartDepthMeters),
            calculationMode: mode,
            bshWaterLevelCorrectionOverride: nil,
            manualHighWaterTime: referenceHighWater,
            notes: "",
            category: "Wattenhoch",
            island: nil
        )
        var destination = start
        destination.id = UUID()
        destination.name = "WP 2"

        let leg = RouteLeg(
            id: UUID(),
            fromWaypointID: start.id,
            toWaypointID: destination.id,
            distanceNm: 0,
            courseDegrees: nil,
            speedThroughWaterKnots: 6,
            tidalCurrentKnots: 0
        )

        return RoutePlan(
            id: UUID(),
            date: startTime,
            routeName: "Parität",
            plannedStartTime: startTime,
            waypoints: [start, destination],
            legs: [leg],
            bshWaterLevelCorrectionMeters: nil,
            tidalStateLabel: "Mitteltide"
        )
    }

    /// Excel `$AD$13` delivered as an official local forecast, so the status is
    /// not downgraded by `applyCorrectionQuality`.
    private func makeProvider(waterLevelCorrectionMeters: Double) -> MockTideDataProvider {
        let provider = MockTideDataProvider()
        provider.correctionsByStation[stationID] = WaterLevelCorrectionResolution(
            meters: waterLevelCorrectionMeters,
            quality: .localOfficial,
            localStationID: stationID,
            sourceStationID: stationID,
            sourceStationName: "Testpegel",
            issuedAt: startTime,
            detail: "Lokale amtliche Scheitelwertvorhersage."
        )
        return provider
    }

    private func calculate(
        _ route: RoutePlan,
        waterLevelCorrectionMeters: Double,
        draftMeters: Double = 1.1,
        safetyMarginMeters: Double = 0
    ) async -> WaypointCalculationResult {
        let result = await RouteCalculationService().calculate(
            route: route,
            boatSettings: BoatSettings(
                draftMeters: draftMeters,
                safetyMarginMeters: safetyMarginMeters
            ),
            tideDataProvider: makeProvider(waterLevelCorrectionMeters: waterLevelCorrectionMeters)
        )
        return result.waypointResults[0]
    }

    // MARK: - Case A — MHW mode with a negative chart depth

    /// Wattenhoch Memmert values from `wadden_sea_catalog.json`.
    /// A negative chart depth means the spot dries out above chart datum.
    func testMHWModeWithNegativeChartDepthMatchesExcelColumn() async {
        let route = makeRoute(
            mode: .meanHighWater,
            meanHighWaterMeters: 3.10,
            chartDepthMeters: -0.80,
            meanTidalRangeMeters: 2.60,
            deviationHours: 3.0
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: -0.25)

        XCTAssertEqual(waypoint.oneTwelfthMeters ?? .nan, 2.60 / 12, accuracy: accuracy)      // L35
        XCTAssertEqual(waypoint.deviationHours ?? .nan, 3.0, accuracy: accuracy)              // L37
        XCTAssertEqual(waypoint.missingWaterFmWMeters ?? .nan, 1.30, accuracy: accuracy)      // L39
        XCTAssertEqual(waypoint.baseWaterAtTideMeters ?? .nan, 1.80, accuracy: accuracy)      // L45
        XCTAssertEqual(waypoint.bshWaterLevelCorrectionMeters, -0.25, accuracy: accuracy)     // L47
        XCTAssertEqual(waypoint.tideHeightHGMeters ?? .nan, 1.55, accuracy: accuracy)         // L49
        XCTAssertEqual(waypoint.chartDepthMetersApplied ?? .nan, -0.80, accuracy: accuracy)   // L51
        XCTAssertEqual(waypoint.availableWaterDepthWTMeters ?? .nan, 0.75, accuracy: accuracy) // L53
        XCTAssertEqual(waypoint.boatDraftMeters, 1.10, accuracy: accuracy)                    // M55
        XCTAssertEqual(waypoint.clearanceUnderKeelWuKMeters ?? .nan, -0.35, accuracy: accuracy) // L57
        XCTAssertEqual(waypoint.status, .noGo)
    }

    // MARK: - Case B — MHW mode, passable

    func testMHWModePassableMatchesExcelColumn() async {
        let route = makeRoute(
            mode: .meanHighWater,
            meanHighWaterMeters: 3.10,
            chartDepthMeters: 1.20,
            meanTidalRangeMeters: 2.50,
            deviationHours: 1.0
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: 0)

        let oneTwelfth = 2.50 / 12
        XCTAssertEqual(waypoint.missingWaterFmWMeters ?? .nan, oneTwelfth, accuracy: accuracy)
        XCTAssertEqual(waypoint.baseWaterAtTideMeters ?? .nan, 3.10 - oneTwelfth, accuracy: accuracy)
        XCTAssertEqual(waypoint.tideHeightHGMeters ?? .nan, 3.10 - oneTwelfth, accuracy: accuracy)
        XCTAssertEqual(
            waypoint.availableWaterDepthWTMeters ?? .nan,
            3.10 - oneTwelfth + 1.20,
            accuracy: accuracy
        )
        XCTAssertEqual(
            waypoint.clearanceUnderKeelWuKMeters ?? .nan,
            3.10 - oneTwelfth + 1.20 - 1.10,
            accuracy: accuracy
        )
        XCTAssertEqual(waypoint.status, .go)
    }

    // MARK: - Case C — Lottiefe mode

    func testLottiefeModeLeavesTideHeightEmpty() async {
        let route = makeRoute(
            mode: .lottiefe,
            lottiefeMeters: 2.30,
            meanTidalRangeMeters: 2.60,
            deviationHours: 2.0
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: 0.15)

        XCTAssertEqual(waypoint.missingWaterFmWMeters ?? .nan, 0.65, accuracy: accuracy)       // L39
        XCTAssertEqual(waypoint.baseWaterAtTideMeters ?? .nan, 1.65, accuracy: accuracy)       // L45
        XCTAssertEqual(waypoint.availableWaterDepthWTMeters ?? .nan, 1.80, accuracy: accuracy) // L53
        XCTAssertEqual(waypoint.clearanceUnderKeelWuKMeters ?? .nan, 0.70, accuracy: accuracy) // L57
        // Excel L49 shows the literal text "leer" in Lottiefe mode.
        XCTAssertNil(waypoint.tideHeightHGMeters)
        XCTAssertNil(waypoint.chartDepthMetersApplied)
        XCTAssertEqual(waypoint.status, .go)
    }

    /// Guards the deliberate decision that a chart depth is ignored in Lottiefe
    /// mode ("nicht bei Lottiefe" in the Excel sheet). Setting one must not move
    /// a single number.
    func testLottiefeModeIgnoresChartDepthEntirely() async {
        let withoutChartDepth = await calculate(
            makeRoute(
                mode: .lottiefe,
                lottiefeMeters: 2.30,
                meanTidalRangeMeters: 2.60,
                deviationHours: 2.0
            ),
            waterLevelCorrectionMeters: 0.15
        )
        let withChartDepth = await calculate(
            makeRoute(
                mode: .lottiefe,
                lottiefeMeters: 2.30,
                chartDepthMeters: 5.0,
                meanTidalRangeMeters: 2.60,
                deviationHours: 2.0
            ),
            waterLevelCorrectionMeters: 0.15
        )

        XCTAssertEqual(
            withChartDepth.availableWaterDepthWTMeters,
            withoutChartDepth.availableWaterDepthWTMeters
        )
        XCTAssertEqual(
            withChartDepth.clearanceUnderKeelWuKMeters,
            withoutChartDepth.clearanceUnderKeelWuKMeters
        )
        XCTAssertNil(withChartDepth.chartDepthMetersApplied)
        XCTAssertEqual(withChartDepth.status, withoutChartDepth.status)
    }

    // MARK: - Case D — beyond one tidal cycle

    /// Excel would continue here: `L39` becomes text, `L45` catches that via
    /// `IFERROR` and falls back to `SUM(L41:Q44)` — a bare MHW, as if no water
    /// were missing at all. The app refuses instead, which is the safer answer.
    func testDeviationBeyondTidalCycleIsInvalidInsteadOfSilentlyIgnored() async {
        let route = makeRoute(
            mode: .meanHighWater,
            meanHighWaterMeters: 3.10,
            chartDepthMeters: 1.20,
            meanTidalRangeMeters: 2.50,
            deviationHours: 13.0
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: 0)

        XCTAssertEqual(waypoint.status, .invalid)
        XCTAssertNil(waypoint.missingWaterFmWMeters)
        XCTAssertNil(waypoint.availableWaterDepthWTMeters)
        XCTAssertNil(waypoint.clearanceUnderKeelWuKMeters)
    }

    // MARK: - Case E — the high water offset (Excel L29)

    /// Excel `L29 = IF(M25>0, L23+M25, IF(M27>0, L23-M27, L23))`.
    func testHighWaterOffsetShiftsTheWaypointHighWater() async {
        let route = makeRoute(
            mode: .meanHighWater,
            meanHighWaterMeters: 3.10,
            chartDepthMeters: 1.20,
            meanTidalRangeMeters: 2.50,
            deviationHours: 2.0,
            highWaterOffsetMinutes: 45
        )
        let waypoint = await calculate(route, waterLevelCorrectionMeters: 0)

        // The fixture compensates the offset, so the deviation stays at 2 h and
        // the waypoint HW sits 45 min after the reference HW.
        XCTAssertEqual(waypoint.deviationHours ?? .nan, 2.0, accuracy: 1e-6)
        let waypointHighWater = try? XCTUnwrap(waypoint.relevantHighWaterTime)
        XCTAssertEqual(
            waypointHighWater?.timeIntervalSince1970 ?? .nan,
            startTime.addingTimeInterval(-2 * 3_600).timeIntervalSince1970,
            accuracy: 1e-6
        )
    }

    // MARK: - Case F — status boundaries

    func testWaypointStatusBoundaries() {
        typealias Service = RouteCalculationService
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: -0.01, safetyMargin: 0), .noGo)
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: 0, safetyMargin: 0), .go)
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: 0, safetyMargin: 0.30), .warning)
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: 0.29, safetyMargin: 0.30), .warning)
        XCTAssertEqual(Service.determineWaypointStatus(clearanceUnderKeel: 0.30, safetyMargin: 0.30), .go)
    }

    func testRouteStatusAggregationPrecedence() {
        typealias Service = RouteCalculationService
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.go, .go]), .go)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.go, .warning]), .warning)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.go, .incomplete]), .incomplete)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.warning, .incomplete]), .incomplete)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.warning, .noGo]), .noGo)
        XCTAssertEqual(Service.determineRouteStatus(waypointStatuses: [.invalid, .go]), .noGo)
    }
}
