import XCTest
import CoreLocation
@testable import Toernberechnung

final class MaritimeWarningsTests: XCTestCase {

    @MainActor
    func testCuratedWarningsContainNorthSeaNotices() {
        let warnings = MaritimeWarningsService.defaultCuratedWarnings
        XCTAssertGreaterThanOrEqual(warnings.count, 5)

        // Verify Wangerooge hazard notice
        let wangerooge = warnings.first { $0.id == "bsh-nwn-2026-08" }
        XCTAssertNotNil(wangerooge)
        XCTAssertEqual(wangerooge?.severity, .hazard)
        XCTAssertEqual(wangerooge?.source, .bsh)
        XCTAssertTrue(wangerooge?.isNorthSeaOrGermanBight == true)
        XCTAssertNotNil(wangerooge?.coordinate)

        // Verify Helgoland shooting area notice
        let helgoland = warnings.first { $0.id == "bsh-nwn-2026-15" }
        XCTAssertNotNil(helgoland)
        XCTAssertEqual(helgoland?.severity, .hazard)
        XCTAssertTrue(helgoland?.isNorthSeaOrGermanBight == true)

        // Ensure all curated warnings are strictly North Sea / German Bight
        for warning in warnings {
            XCTAssertTrue(warning.isNorthSeaOrGermanBight)
        }
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

    func testWarningFormattedCoordinatesAndDisplayColor() {
        let warning = MaritimeWarning(
            id: "test-1",
            source: .bsh,
            severity: .hazard,
            title: "Test Gefahrenstelle",
            details: "Details",
            areaName: "Deutsche Bucht",
            publishDate: Date(),
            latitude: 53.85,
            longitude: 7.9
        )

        XCTAssertNotNil(warning.formattedCoordinates)
        XCTAssertTrue(warning.formattedCoordinates?.contains("53°51.00' N") == true)
        XCTAssertTrue(warning.formattedCoordinates?.contains("007°54.00' E") == true)
        XCTAssertEqual(warning.severity.displayColor, .red)

        let pin = WarningPinAnnotation(
            coordinate: warning.coordinate!,
            title: warning.title,
            subtitle: warning.areaName,
            warning: warning
        )
        XCTAssertEqual(pin.warning?.id, "test-1")
        XCTAssertEqual(pin.subtitle, "Deutsche Bucht")
    }

    // MARK: - BSH Nautical Warnings Parser Tests

    func testBSHNauticalWarningsParserRealText() {
        let bshSampleText = """
        Nordsee / North Sea
        nautische warnnachrichten für den deutschen nordseebereich
        -internationale verbreitung- (auch über navtex verfügbar).
        aktualisiert: 141100 utc sep 26 durch seewarndienst emden, deutschland
        navigational warnings for the german north sea area
        -international edition- (also available by navtex).
        updated: 141100 utc sep 26 by navigational warning service emden, germany.

        141100 utc sep 26
        nautische warnnachricht nr. 518
        deutsche bucht. noerdlich offshore windpark 'deutsche bucht'.
        unterwasserarbeiten durch ms 'kamara', rz '9ha4953'
        im gebiet zwischen
        54-22,0n 005-51,6e und
        54-33,4n 005-51,9e
        durch arbeiten eingeschraenkt manoevrierfaehig.
        notwendiger abstand erforderlich.

        141100 utc sep 26
        navigational warning no. 518
        german bight. northerly offshore windpark 'deutsche bucht'.

        110615 utc sep 26
        nautische warnnachricht nr. 511
        1. navtex- gebiet (s) warnungen gueltig ab 110615 utc sep 26:
        2026: 429 447 454 458 479 481 493 495 508 509

        100550 utc sep 26
        nautische warnnachricht nr. 509
        ostfriesische inseln. noerdlich norderney.
        munitionsfund auf ungefaehr
        53-46,7n 007-09,9e
        53-47,2n 007-07,6e
        ankern und fischen verboten im umkreis von 500m.

        031430 utc sep 26
        nautische warnnachricht nr. 495
        ostfriesische inseln. norderney.
        leuchtturm 'norderney' 53-43n 007-14e
        kennung geaendert in: blz (3) 15s.

        nautische warnnachrichten für den deutschen nordseebereich.
        -nationale verbreitung-
        (empfang auch ueber ndr per digitalradio dab+,
        satellit dvb-s radio, livestream im internet und ndr radio app and ndr-info spezial.)
        navigational warnings for the german north sea area.
        -local warnings-
        (also available via radio broadcast station ndr by digital radio dab+, satellite dvb-s radio, as live
        stream on the internet, ndr app and ndr-info spezial.)
        nordfriesische inseln. sylt.
        gruene leuchttonne 'lister tief 3' verloescht.
        nord frisian islands. sylt.
        green lightbuoy 'lister tief 3' unlit.
        eom.
        """

        let warnings = BSHNauticalWarningsParser.parse(text: bshSampleText)
        // 518 (underwater work), 509 (munitions), 495 (lighthouse) + local warning
        // 511 (navtex index) is skipped
        XCTAssertGreaterThanOrEqual(warnings.count, 3)

        // Check warning 509 (Hazard: Munition at Norderney)
        let norderneyMunition = warnings.first { $0.id.contains("509") }
        XCTAssertNotNil(norderneyMunition)
        XCTAssertEqual(norderneyMunition?.severity, .hazard)
        XCTAssertEqual(norderneyMunition?.source, .bsh)
        XCTAssertTrue(norderneyMunition?.areaName.contains("Ostfriesische Inseln") == true)
        XCTAssertTrue(norderneyMunition?.details.contains("Munitionsfund") == true || norderneyMunition?.details.contains("munitionsfund") == true)
        XCTAssertNotNil(norderneyMunition?.coordinate)
        if let coord = norderneyMunition?.coordinate {
            XCTAssertEqual(coord.latitude, 53.0 + (46.7 / 60.0), accuracy: 0.001)
            XCTAssertEqual(coord.longitude, 7.0 + (9.9 / 60.0), accuracy: 0.001)
        }

        // Check warning 518 (Warning: Underwater operations)
        let underwater = warnings.first { $0.id.contains("518") }
        XCTAssertNotNil(underwater)
        XCTAssertEqual(underwater?.severity, .warning)
        XCTAssertTrue(underwater?.areaName.contains("Deutsche Bucht") == true)

        // Check warning 495 (Notice: Lighthouse character change)
        let lighthouse = warnings.first { $0.id.contains("495") }
        XCTAssertNotNil(lighthouse)
        XCTAssertEqual(lighthouse?.severity, .notice)

        // Ensure 511 navtex broadcast index was excluded
        let navtexIndex = warnings.first { $0.id.hasSuffix("-511") }
        XCTAssertNil(navtexIndex)
    }

    func testBSHCoordinateParsing() {
        let coord1 = BSHNauticalWarningsParser.parseCoordinate(from: "Position 53-46,7n 007-09,9e")
        XCTAssertNotNil(coord1)
        XCTAssertEqual(coord1?.latitude ?? 0, 53.77833, accuracy: 0.001)
        XCTAssertEqual(coord1?.longitude ?? 0, 7.165, accuracy: 0.001)

        let coord2 = BSHNauticalWarningsParser.parseCoordinate(from: "im bereich 54-22,0n 005-51,6e")
        XCTAssertNotNil(coord2)
        XCTAssertEqual(coord2?.latitude ?? 0, 54.36667, accuracy: 0.001)
        XCTAssertEqual(coord2?.longitude ?? 0, 5.86, accuracy: 0.001)

        let invalid = BSHNauticalWarningsParser.parseCoordinate(from: "Keine Koordinaten im Text")
        XCTAssertNil(invalid)
    }

    func testBSHDateParsing() {
        let date = BSHNauticalWarningsParser.parseBSHDate("141100 utc sep 26")
        XCTAssertNotNil(date)
        if let date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            XCTAssertEqual(cal.component(.year, from: date), 2026)
            XCTAssertEqual(cal.component(.month, from: date), 9)
            XCTAssertEqual(cal.component(.day, from: date), 14)
            XCTAssertEqual(cal.component(.hour, from: date), 11)
            XCTAssertEqual(cal.component(.minute, from: date), 0)
        }
    }
}
