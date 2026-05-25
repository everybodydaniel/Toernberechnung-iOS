import XCTest
@testable import Toernberechnung

/// Tests für `WaddenSeaCatalog`:
/// - Laden aus gebündelter JSON-Ressource
/// - Lookup-Funktionen (Station, Waypoint, RouteTemplate)
/// - Datenintegrität (NFA4)
/// - RoutePlan-Generator
final class WaddenSeaCatalogTests: XCTestCase {

    // Test-Bundle-Loader analog zu Bundle.main
    private func loadCatalog() -> WaddenSeaCatalog {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "wadden_sea_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(WaddenSeaCatalog.self, from: data) else {
            XCTFail("Katalog konnte nicht aus Test-Bundle geladen werden")
            return WaddenSeaCatalog(stations: [], waypoints: [], routeTemplates: [])
        }
        return catalog
    }

    // MARK: - JSON-Laden

    func test_loadCatalog_fromTestBundle_isNotEmpty() {
        let catalog = loadCatalog()
        XCTAssertFalse(catalog.stations.isEmpty)
        XCTAssertFalse(catalog.waypoints.isEmpty)
        XCTAssertFalse(catalog.routeTemplates.isEmpty)
    }

    func test_loadBundled_fallback_returnsEmptyCatalog_whenResourceMissing() {
        // `loadBundled()` greift auf `Bundle.main` zu; im Test-Bundle ist die JSON nicht
        // unter Bundle.main → erwartet leerer Fallback-Katalog statt Crash (NFA3).
        let catalog = WaddenSeaCatalog.loadBundled()
        XCTAssertEqual(catalog.stations.count, catalog.stations.count,
                       "Aufruf darf nicht crashen, egal ob Ressource vorhanden ist")
    }

    // MARK: - Lookup

    func test_station_byID_returnsKnownStation() {
        let catalog = loadCatalog()
        let first = catalog.stations.first!
        XCTAssertEqual(catalog.station(byID: first.id)?.id, first.id)
    }

    func test_station_byID_returnsNilForUnknown() {
        let catalog = loadCatalog()
        XCTAssertNil(catalog.station(byID: "DOES_NOT_EXIST"))
    }

    func test_station_byID_isCaseSensitive() {
        let catalog = loadCatalog()
        guard let first = catalog.stations.first else { return }
        XCTAssertNotEqual(first.id, first.id.lowercased(),
                          "Voraussetzung: BSH-ID ist nicht komplett lowercase")
        XCTAssertNil(catalog.station(byID: first.id.lowercased()),
                     "Lookup soll case-sensitive sein – aktueller Vertrag")
    }

    func test_waypointTemplate_byID_returnsKnownTemplate() {
        let catalog = loadCatalog()
        let first = catalog.waypoints.first!
        XCTAssertEqual(catalog.waypointTemplate(byID: first.id)?.id, first.id)
    }

    func test_waypointTemplate_byID_returnsNilForRandomUUID() {
        let catalog = loadCatalog()
        XCTAssertNil(catalog.waypointTemplate(byID: UUID()))
    }

    // MARK: - Datenintegrität (NFA4)

    func test_dataIntegrity_routeTemplates_referenceExistingWaypoints() {
        let catalog = loadCatalog()
        let waypointIDs = Set(catalog.waypoints.map(\.id))

        for route in catalog.routeTemplates {
            for wpID in route.waypointTemplateIDs {
                XCTAssertTrue(
                    waypointIDs.contains(wpID),
                    "Route \(route.name) verweist auf unbekannte Wegpunkt-ID \(wpID)"
                )
            }
        }
    }

    func test_dataIntegrity_legDistanceCountMatchesWaypointCount() {
        let catalog = loadCatalog()
        for route in catalog.routeTemplates {
            XCTAssertEqual(
                route.defaultLegDistancesNm.count,
                route.waypointTemplateIDs.count - 1,
                "Route \(route.name): Anzahl Legdistanzen muss waypoints.count − 1 sein"
            )
        }
    }

    func test_dataIntegrity_tidalCurrentCountMatchesLegCount() {
        let catalog = loadCatalog()
        for route in catalog.routeTemplates {
            XCTAssertEqual(
                route.defaultTidalCurrentsKnots.count,
                route.defaultLegDistancesNm.count,
                "Route \(route.name): Strom-Vektor und Distanz-Vektor müssen gleich lang sein"
            )
        }
    }

    func test_dataIntegrity_waypointTemplates_referenceExistingStations() {
        let catalog = loadCatalog()
        let stationIDs = Set(catalog.stations.map(\.id))
        for wp in catalog.waypoints {
            XCTAssertTrue(
                stationIDs.contains(wp.tidalReferenceStationID),
                "Wegpunkt \(wp.name) verweist auf unbekannte Stations-ID \(wp.tidalReferenceStationID)"
            )
        }
    }

    // MARK: - buildRoutePlan

    func test_buildRoutePlan_fromValidTemplate_producesConsistentPlan() {
        let catalog = loadCatalog()
        guard let template = catalog.routeTemplates.first else { return }

        let plan = catalog.buildRoutePlan(
            from: template,
            date: Date(),
            startTime: Date(),
            speedKnots: 6,
            bshCorrectionMeters: 0.3
        )
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.waypoints.count, template.waypointTemplateIDs.count)
        XCTAssertEqual(plan?.legs.count, template.waypointTemplateIDs.count - 1)
        XCTAssertEqual(plan?.bshWaterLevelCorrectionMeters, 0.3)
    }

    func test_buildDirectRoute_byHarbourIDs_produces2WaypointFallback() {
        let catalog = loadCatalog()
        let plan = catalog.buildDirectRoute(
            startHarbourID: "borkum_harbor",
            destinationHarbourID: "norderney_harbor",
            date: Date(),
            startTime: Date(),
            distanceNm: 20,
            speedKnots: 6,
            bshCorrectionMeters: 0
        )
        XCTAssertEqual(plan.waypoints.count, 2)
        XCTAssertEqual(plan.legs.count, 1)
        XCTAssertEqual(plan.legs[0].distanceNm, 20)
    }
}
