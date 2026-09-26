import XCTest
@testable import Toernberechnung

final class BoatSpeedConfigurationTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "boatSpeed")
    }

    func testLoadSpeedFromSettingsFallback() {
        UserDefaults.standard.removeObject(forKey: "boatSpeed")
        let speed = RoutePlannerViewModel.loadSpeedFromSettings()
        XCTAssertEqual(speed, 6.0, accuracy: 0.001)
    }

    func testLoadSpeedFromSettingsDotAndCommaNotation() {
        UserDefaults.standard.set("7.5", forKey: "boatSpeed")
        XCTAssertEqual(RoutePlannerViewModel.loadSpeedFromSettings(), 7.5, accuracy: 0.001)

        UserDefaults.standard.set("8,2", forKey: "boatSpeed")
        XCTAssertEqual(RoutePlannerViewModel.loadSpeedFromSettings(), 8.2, accuracy: 0.001)
    }

    func testLoadSpeedFromSettingsClamped() {
        UserDefaults.standard.set("0.1", forKey: "boatSpeed")
        XCTAssertEqual(RoutePlannerViewModel.loadSpeedFromSettings(), 0.5, accuracy: 0.001)

        UserDefaults.standard.set("99.9", forKey: "boatSpeed")
        XCTAssertEqual(RoutePlannerViewModel.loadSpeedFromSettings(), 50.0, accuracy: 0.001)
    }

    @MainActor
    func testSpeedChangeUpdatesRouteLegsAndCalculation() async {
        let viewModel = RoutePlannerViewModel()
        viewModel.speedKnots = 6.0

        // Häfen auswählen
        viewModel.startHarbourID = "norderney_harbor"
        viewModel.destinationHarbourID = "juist_harbor"

        // Kurz warten, bis die Berechnung eingeplant ist
        try? await Task.sleep(nanoseconds: 50_000_000)

        guard let plan = viewModel.routePlan else {
            XCTFail("Expected routePlan to be generated")
            return
        }
        XCTAssertEqual(plan.legs.first?.speedThroughWaterKnots ?? 0, 6.0, accuracy: 0.01)

        // Geschwindigkeit ändern
        viewModel.speedKnots = 8.0
        XCTAssertEqual(UserDefaults.standard.string(forKey: "boatSpeed"), "8.0")

        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.routePlan?.legs.first?.speedThroughWaterKnots ?? 0, 8.0, accuracy: 0.01)
    }

    @MainActor
    func testReloadBoatSettingsPicksUpSettingsChange() {
        let viewModel = RoutePlannerViewModel()
        viewModel.speedKnots = 5.0

        UserDefaults.standard.set("7.0", forKey: "boatSpeed")
        viewModel.reloadBoatSettings()

        XCTAssertEqual(viewModel.speedKnots, 7.0, accuracy: 0.01)
    }

    func testBaltrumSoundingCannotMeetHalfMeterReserveForOnePointFourMeterDraft() throws {
        let sounding = try XCTUnwrap(SurveyedDepthCatalog.record(for: "baltrum_s"))
        let result = WaypointDepthSolver.solve(
            WaypointDepthSolver.Inputs(
                calculationMode: .lottiefe,
                referenceLevelMeters: sounding.depthMeters,
                chartDepthMeters: nil,
                meanTidalRangeMeters: 2.6,
                deviationHours: 0,
                waterLevelCorrectionMeters: 0,
                draftMeters: 1.4
            )
        )
        guard case .success(let output) = result else {
            return XCTFail("Die Tiefe bei MHW muss berechenbar sein")
        }

        XCTAssertEqual(output.clearanceUnderKeelMeters, 0.2, accuracy: 1e-9)
        XCTAssertLessThan(output.clearanceUnderKeelMeters, 0.5)
    }

    @MainActor
    func testEmdenToNorderneyWarningProvidesDescriptiveDetailText() async {
        let viewModel = RoutePlannerViewModel()
        viewModel.speedKnots = 6.0
        viewModel.startHarbourID = "emden_harbor"
        viewModel.destinationHarbourID = "norderney_harbor"

        let cal = AppDateFormatters.berlinCalendar
        if let d = cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 6, minute: 28)) {
            viewModel.planningDay = d
            viewModel.departure = d
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        var attempts = 0
        while (viewModel.isSearchingWindow || viewModel.isCalculating) && attempts < 150 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }

        XCTAssertNotNil(viewModel.statusDetailText, "A descriptive status detail text must be provided to explain warning reasons")
    }
}
