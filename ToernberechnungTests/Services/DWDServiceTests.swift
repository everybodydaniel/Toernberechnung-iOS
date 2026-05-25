import XCTest
@testable import Toernberechnung

/// Integrationstests für `DWDCompactService` über `URLProtocol`-Stub.
///
/// Das KMZ/XML-Parsing ist privat und komplex; getestet werden hier die
/// Boundary-/Fehlerfälle, die der Service nach außen vertraglich liefert.
final class DWDServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Fehler bei HTTP 500

    func test_fetch_throwsBadResponse_onHTTP500() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let harbour = HarbourOption.byID("emden_harbor")
        do {
            _ = try await DWDCompactService.shared.fetch(for: harbour, force: true)
            XCTFail("HTTP 500 muss zu badResponse führen")
        } catch let error as DWDCompactError {
            XCTAssertEqual(error.errorDescription, DWDCompactError.badResponse.errorDescription)
        } catch {
            XCTFail("Unerwarteter Fehler: \(error)")
        }
    }

    // MARK: - Ungültiges KMZ-Archiv

    func test_fetch_throwsUnreadableArchive_onGarbageData() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("not a real kmz".utf8))
        }

        let harbour = HarbourOption.byID("emden_harbor")
        do {
            _ = try await DWDCompactService.shared.fetch(for: harbour, force: true)
            XCTFail("Ungültiges KMZ muss zu Fehler führen")
        } catch let error as DWDCompactError {
            // Erwartet wird unreadableArchive oder parseFailed
            switch error {
            case .unreadableArchive, .parseFailed:
                break
            default:
                XCTFail("Erwartet unreadableArchive/parseFailed, war \(error)")
            }
        } catch {
            XCTFail("Unerwarteter Fehler: \(error)")
        }
    }

    // MARK: - URL-Konstruktion ist konsistent

    func test_fetch_requestsExpectedStationURL() async {
        let harbour = HarbourOption.byID("norderney_harbor")
        let expectedFragment = "MOSMIX_L_LATEST_\(harbour.weatherStationID).kmz"
        let urlExpectation = expectation(description: "Erwartete URL wird angefragt")

        MockURLProtocol.requestHandler = { request in
            if request.url?.absoluteString.contains(expectedFragment) == true {
                urlExpectation.fulfill()
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 500,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        _ = try? await DWDCompactService.shared.fetch(for: harbour, force: true)
        await fulfillment(of: [urlExpectation], timeout: 5)
    }
}

/// Reine Math-/Pure-Tests für `HarbourOption`.
final class HarbourOptionTests: XCTestCase {

    func test_byID_returnsKnownHarbour() {
        XCTAssertEqual(HarbourOption.byID("borkum_harbor").id, "borkum_harbor")
    }

    func test_byID_returnsDefault_forUnknownID() {
        // Vertrag laut Code: erstes Element wird zurückgegeben statt nil
        let result = HarbourOption.byID("does_not_exist")
        XCTAssertEqual(result.id, HarbourOption.options[0].id)
    }

    func test_distanceNM_betweenSamePoint_isZero() {
        let borkum = HarbourOption.byID("borkum_harbor")
        XCTAssertEqual(borkum.distanceNM(to: borkum), 0, accuracy: 1e-6)
    }

    func test_distanceNM_isSymmetric() {
        let borkum    = HarbourOption.byID("borkum_harbor")
        let norderney = HarbourOption.byID("norderney_harbor")
        XCTAssertEqual(
            borkum.distanceNM(to: norderney),
            norderney.distanceNM(to: borkum),
            accuracy: 1e-6
        )
    }

    func test_distanceNM_borkumToNorderney_isInExpectedRange() {
        let borkum    = HarbourOption.byID("borkum_harbor")
        let norderney = HarbourOption.byID("norderney_harbor")
        let distance  = borkum.distanceNM(to: norderney)
        XCTAssertGreaterThan(distance, 10)
        XCTAssertLessThan(distance, 30,
                          "Real ca. 17 NM; Haversine-Schätzung muss in diesem Korridor liegen")
    }
}
