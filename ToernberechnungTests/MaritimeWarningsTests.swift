import XCTest
import CoreLocation
@testable import Toernberechnung

final class MaritimeWarningsTests: XCTestCase {

    @MainActor
    func testCuratedWarningsContainNorthSeaAndBalticNotices() {
        let warnings = MaritimeWarningsService.defaultCuratedWarnings
        XCTAssertGreaterThanOrEqual(warnings.count, 5)

        // Verify Wangerooge hazard notice
        let wangerooge = warnings.first { $0.id == "bsh-nwn-2026-08" }
        XCTAssertNotNil(wangerooge)
        XCTAssertEqual(wangerooge?.severity, .hazard)
        XCTAssertEqual(wangerooge?.source, .bsh)
        XCTAssertTrue(wangerooge?.isNorthSeaOrGermanBight == true)
        XCTAssertNotNil(wangerooge?.coordinate)

        // Verify Putlos shooting area notice
        let putlos = warnings.first { $0.id == "bsh-nwn-2026-14" }
        XCTAssertNotNil(putlos)
        XCTAssertEqual(putlos?.severity, .hazard)
        XCTAssertTrue(putlos?.isBalticSea == true)
    }

    @MainActor
    func testUnreadTrackingAndMarkAsRead() {
        let service = MaritimeWarningsService.shared
        service.resetReadStateForTesting()
        XCTAssertGreaterThan(service.warnings.count, 0)
        XCTAssertGreaterThan(service.unreadCount, 0)

        guard let firstID = service.warnings.first?.id else {
            XCTFail("No warnings loaded")
            return
        }

        let initialUnread = service.unreadCount
        service.markAsRead(id: firstID)
        XCTAssertTrue(service.isRead(id: firstID))
        XCTAssertEqual(service.unreadCount, initialUnread - 1)

        service.markAllAsRead()
        XCTAssertEqual(service.unreadCount, 0)
    }

    func testNiordDecodingWithFlexibleStringAndIntegerIDs() throws {
        let json = """
        [
          {
            "id": "c3dddc69-d48c-410b-a9e4-24a74061c2e2",
            "shortId": "NM-1050-25",
            "status": "PUBLISHED",
            "mainType": "NM",
            "type": "TEMPORARY_NOTICE",
            "descs": [
              {
                "title": "Kattegat. Light unlit",
                "lang": "en"
              }
            ],
            "parts": [
              {
                "geometry": {
                  "features": [
                    {
                      "geometry": {
                        "type": "Point",
                        "coordinates": [11.5, 56.2]
                      }
                    }
                  ]
                }
              }
            ]
          },
          {
            "id": 98765,
            "shortId": "NW-101-26",
            "status": "PUBLISHED",
            "mainType": "NW",
            "type": "FIRING_EXERCISE",
            "descs": [
              {
                "title": "Great Belt. Firing practice",
                "lang": "en"
              }
            ]
          }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let items = try decoder.decode([NiordSearchResponseItem].self, from: json)
        XCTAssertEqual(items.count, 2)

        let warnings = items.compactMap { $0.toMaritimeWarning() }
        XCTAssertEqual(warnings.count, 2)

        XCTAssertEqual(warnings[0].id, "NM-1050-25")
        XCTAssertEqual(warnings[0].severity, .notice)
        XCTAssertEqual(warnings[0].coordinate?.latitude, 56.2)
        XCTAssertEqual(warnings[0].coordinate?.longitude, 11.5)

        XCTAssertEqual(warnings[1].id, "NW-101-26")
        XCTAssertEqual(warnings[1].severity, .hazard)
    }

    func testNautiDeterministicIntentRouterRoutesWarningsQueries() {
        let request1 = NautiInferenceRequest(
            messages: [NautiConversationMessage(role: .user, text: "Gibt es aktuelle Warnungen auf See?")],
            requestedAt: Date()
        )
        let result1 = NautiDeterministicIntentRouter.route(request1)
        XCTAssertNotNil(result1)
        XCTAssertEqual(result1?.action?.kind, .getWarningsSummary)

        let request2 = NautiInferenceRequest(
            messages: [NautiConversationMessage(role: .user, text: "Öffne bitte die nautischen Warnmeldungen")],
            requestedAt: Date()
        )
        let result2 = NautiDeterministicIntentRouter.route(request2)
        XCTAssertNotNil(result2)
        XCTAssertEqual(result2?.action?.kind, .showWarnings)

        let request3 = NautiInferenceRequest(
            messages: [NautiConversationMessage(role: .user, text: "Zeige mir die Seefahrer-Nachrichten")],
            requestedAt: Date()
        )
        let result3 = NautiDeterministicIntentRouter.route(request3)
        XCTAssertNotNil(result3)
        XCTAssertEqual(result3?.action?.kind, .showWarnings)
    }
}
