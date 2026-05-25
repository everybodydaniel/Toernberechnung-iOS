import XCTest
@testable import Toernberechnung

/// Integrationstests für `BSHTideService` mit `URLProtocol`-Stub.
///
/// Da der Service `URLSession.shared` direkt verwendet, wird `MockURLProtocol` global
/// registriert und fängt alle BSH-Requests ab.
final class BSHTideServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Happy path: gültige Tide-JSON

    func test_fetch_returnsTideReading_forValidResponse() async throws {
        let payload = TestFixtures.bshEmdenJSON.data(using: .utf8)!
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("DE_") ?? false,
                          "Es muss eine BSH-Tide-URL angefragt werden")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, payload)
        }

        // Reading-Fetch ab 25.05.2026 06:00 → Filter ab diesem Zeitpunkt: 6:42, 13:08, 19:21 …
        let harbour = HarbourOption.byID("emden_harbor")
        let date = TestFixtures.berlinDate("2026-05-25 06:00")

        let reading = try await BSHTideService.shared.fetch(for: harbour, around: date, force: true)
        XCTAssertEqual(reading.stationID, harbour.tideStationID)
        XCTAssertFalse(reading.events.isEmpty)
        XCTAssertTrue(reading.events.allSatisfy { $0.time >= date })
    }

    // MARK: - Fehlerpfade (NFA2)

    func test_fetch_throwsBadResponse_onHTTP500() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let harbour = HarbourOption.byID("emden_harbor")
        do {
            _ = try await BSHTideService.shared.fetch(for: harbour, around: Date(), force: true)
            XCTFail("HTTP 500 muss zu badResponse führen")
        } catch let error as BSHTideError {
            XCTAssertEqual(error, .badResponse)
        } catch {
            XCTFail("Unerwarteter Fehler: \(error)")
        }
    }

    func test_fetch_throwsEmptyPayload_whenNoEvents() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, TestFixtures.bshEmptyJSON.data(using: .utf8)!)
        }
        let harbour = HarbourOption.byID("emden_harbor")
        do {
            _ = try await BSHTideService.shared.fetch(for: harbour, around: Date(), force: true)
            XCTFail("Leeres Payload muss zu emptyPayload führen")
        } catch let error as BSHTideError {
            XCTAssertEqual(error, .emptyPayload)
        } catch {
            XCTFail("Unerwarteter Fehler: \(error)")
        }
    }

    func test_fetch_throwsOnMalformedJSON() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, TestFixtures.bshMalformedJSON.data(using: .utf8)!)
        }
        let harbour = HarbourOption.byID("emden_harbor")
        do {
            _ = try await BSHTideService.shared.fetch(for: harbour, around: Date(), force: true)
            XCTFail("Ungültiges JSON muss einen Fehler werfen")
        } catch {
            // DecodingError aus JSONDecoder
            XCTAssertTrue(error is DecodingError || error is BSHTideError,
                          "Erwartet DecodingError oder BSHTideError, war \(type(of: error))")
        }
    }

    // MARK: - highWaters(for:around:)

    func test_highWaters_filtersToHWEventsAroundDate() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, TestFixtures.bshEmdenJSON.data(using: .utf8)!)
        }

        let date = TestFixtures.berlinDate("2026-05-25 12:00")
        let highWaters = try await BSHTideService.shared.highWaters(
            for: "507P", around: date, force: true
        )

        XCTAssertTrue(highWaters.allSatisfy { $0.type == "HW" }, "Filter muss nur HW liefern")
        XCTAssertFalse(highWaters.isEmpty)
    }
}
