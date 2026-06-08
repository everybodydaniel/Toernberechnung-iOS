import XCTest
@testable import Toernberechnung

final class BSHServiceTests: XCTestCase {

    func testWaterLevelForecastServiceFetch() async throws {
        // Fetch forecast for Borkum (101P)
        let forecast = try await BSHWaterLevelForecastService.shared.fetch(
            bshNr: "101P",
            substituteForHarbour: nil,
            force: true
        )
        
        XCTAssertEqual(forecast.bshNr, "101P")
        XCTAssertFalse(forecast.events.isEmpty, "Should have loaded events")
        XCTAssertFalse(forecast.curve.isEmpty, "Should have loaded curve points")
        XCTAssertEqual(forecast.stationName, "Borkum, Fischerbalje")
    }

    func testWaterLevelServiceDeviation() async {
        // Fetch current deviation for Borkum
        let deviation = await BSHWaterLevelService.shared.deviation(
            forGaugeID: "borkum",
            at: Date(),
            force: true
        )
        
        XCTAssertNotNil(deviation, "Deviation should not be nil")
        if let dev = deviation {
            print("Fetched Borkum live deviation: \(dev) m")
            // Normally deviation is between -4m and +4m
            XCTAssertTrue(dev > -5.0 && dev < 5.0, "Deviation \(dev) m is out of normal bounds")
        }
    }
}
