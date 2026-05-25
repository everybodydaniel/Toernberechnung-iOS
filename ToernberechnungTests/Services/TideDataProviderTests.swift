import XCTest
@testable import Toernberechnung

/// Tests für `MockTideDataProvider` und den `BSHTideDataProvider`-Adapter.
final class TideDataProviderTests: XCTestCase {

    func test_mock_returnsEmptyForUnknownStation() async throws {
        let provider = MockTideDataProvider()
        let result = try await provider.highWaters(for: "UNKNOWN", around: Date())
        XCTAssertTrue(result.isEmpty)
    }

    func test_mock_returnsPreconfiguredEvents() async throws {
        let provider = MockTideDataProvider()
        let event = TideEvent(time: Date(), heightMeters: 3.5, type: "HW", phase: "S")
        provider.highWatersByStation["111P"] = [event]

        let result = try await provider.highWaters(for: "111P", around: Date())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].time, event.time)
    }

    func test_mock_throwsWhenConfigured() async {
        let provider = MockTideDataProvider()
        provider.shouldThrow = true
        do {
            _ = try await provider.highWaters(for: "111P", around: Date())
            XCTFail("Provider sollte werfen")
        } catch let error as BSHTideError {
            XCTAssertEqual(error, .badResponse)
        } catch {
            XCTFail("Unerwarteter Fehler: \(error)")
        }
    }

    func test_mock_meanTidalRange_returnsConfiguredValue() async throws {
        let provider = MockTideDataProvider()
        provider.meanTidalRanges["111P"] = 2.4
        let mth = try await provider.meanTidalRange(for: "111P")
        XCTAssertEqual(mth, 2.4)
    }

    func test_mock_meanTidalRange_returnsNilForUnknownStation() async throws {
        let provider = MockTideDataProvider()
        let mth = try await provider.meanTidalRange(for: "UNKNOWN")
        XCTAssertNil(mth)
    }

    // Adapter-Test: BSHTideDataProvider returnt leere Liste statt Fehler weiterzuwerfen.
    func test_bshAdapter_returnsEmptyOnError() async throws {
        // Adapter ruft `BSHTideService.shared` auf. Ohne Stubs ist die URL unerreichbar,
        // der Adapter muss das Schluck-Verhalten zeigen (returns []).
        // Test ist defensiv – auf CI ohne Netz wäre ein echter Call ohnehin fehlerhaft.
        let adapter = BSHTideDataProvider()
        let result = try await adapter.highWaters(for: "ZZZ_UNKNOWN", around: Date())
        XCTAssertEqual(result, [], "Adapter darf den Fehler nicht weitergeben")
    }

    func test_bshAdapter_meanTidalRange_isNil() async throws {
        let adapter = BSHTideDataProvider()
        let mth = try await adapter.meanTidalRange(for: "111P")
        XCTAssertNil(mth, "Adapter liefert MTH aktuell bewusst nicht")
    }
}
