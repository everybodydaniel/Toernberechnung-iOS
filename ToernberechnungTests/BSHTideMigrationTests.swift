import XCTest
@testable import Toernberechnung

final class BSHTideMigrationTests: XCTestCase {
    func testRouteGaugeCatalogContainsCorrectOfficialMappings() {
        let expected: [String: String] = [
            "Borkum, Fischerbalje": "101P",
            "Emden, Ems, Große Seeschleuse": "507P",
            "Knock, Ems": "802P",
            "Juist, Hafen": "794P",
            "Norderney, Riffgat": "111P",
            "Baltrum, Westende": "784P",
            "Langeoog, Hafeneinfahrt": "781P",
            "Spiekeroog, ehem. Landungsbrücke": "779P",
            "Wangerooge, Hafen": "777P",
            "Norddeich, Westerriede": "790A",
            "Bensersiel": "782P",
            "Neuharlingersiel": "780P",
            "Harlesiel, Hafen": "778P",
            "Hooksiel": "765P",
            "Wilhelmshaven, Alter Vorhafen": "512P"
        ]

        XCTAssertEqual(BSHTideStationCatalog.stations.count, 15)
        XCTAssertEqual(Set(BSHTideStationCatalog.stations.map(\.id)).count, 15)
        for (name, identifier) in expected {
            XCTAssertEqual(BSHTideStationCatalog.station(id: identifier)?.name, name)
        }
    }

    func testAllSevenIslandsHaveAstronomicalStationsWithoutInventingForecasts() {
        XCTAssertEqual(BSHTideStationCatalog.islands.count, 7)
        for identifier in ["101P", "794P", "784P"] {
            XCTAssertEqual(BSHTideStationCatalog.station(id: identifier)?.kind, .interpolated)
            XCTAssertFalse(BSHTideStationCatalog.station(id: identifier)?.hasLocalWaterLevelForecast ?? true)
        }

        for identifier in ["111P", "781P", "779P", "777P"] {
            XCTAssertTrue(BSHTideStationCatalog.station(id: identifier)?.hasLocalWaterLevelForecast == true)
        }

        XCTAssertEqual(BSHTideStationCatalog.requiredComparisonStation(for: "101P")?.id, "507P")
        XCTAssertEqual(BSHTideStationCatalog.requiredComparisonStation(for: "794P")?.id, "111P")
        XCTAssertEqual(BSHTideStationCatalog.requiredComparisonStation(for: "784P")?.id, "781P")
        XCTAssertFalse(BSHTideStationCatalog.usesDirectWaterLevelForecast("101P"))
        XCTAssertTrue(BSHTideStationCatalog.usesDirectWaterLevelForecast("111P"))
        XCTAssertEqual(BSHTideStationCatalog.nearestComparisonStation(for: "794P")?.id, "111P")
        XCTAssertEqual(BSHTideStationCatalog.nearestComparisonStation(for: "784P")?.id, "781P")
    }

    func testCurrentWattseglerSoundingsCoverTheSelectableIslandCorridors() throws {
        let expectedDepths: [String: Double] = [
            "borkum_east": 1.70,
            "memmert_w": 2.60,
            "juist_s": 1.90,
            "norderney_sw": 2.30,
            "watt_norden": 1.90,
            "baltrum_s": 1.60,
            "watt_nesskana": 1.60,
            "watt_bensersiel": 1.80,
            "watt_neuharling": 2.10,
            "wangerooge_s": 2.00
        ]

        for (identifier, depth) in expectedDepths {
            let record = try XCTUnwrap(SurveyedDepthCatalog.record(for: identifier), identifier)
            XCTAssertEqual(record.calculationMode, .lottiefe, identifier)
            XCTAssertEqual(record.depthMeters, depth, accuracy: 1e-9, identifier)
            XCTAssertEqual(record.sourceName, "Wattsegler", identifier)
        }

        XCTAssertEqual(
            Set(HarbourOption.options.map(\.tideStationID)).subtracting(BSHTideStationCatalog.stations.map(\.id)),
            Set<String>()
        )
    }

    func testEverySelectableHarbourPairIsConnectedByTheFairwayGraph() {
        for origin in HarbourOption.options {
            for destination in HarbourOption.options where destination.id != origin.id {
                let path = NauticalRouter.route(
                    from: origin.location.coordinate,
                    to: destination.location.coordinate
                )
                XCTAssertFalse(path.isEmpty, "Keine Route: \(origin.name) → \(destination.name)")
            }
        }
    }

    func testJuistFixtureKeepsTimesButNoEventHeights() throws {
        let json = """
        {
          "station_name": "Juist, Hafen",
          "bshnr": "794P",
          "years": [{
            "2026": {
              "level_tidalvalues": "PNP",
              "MHW": 627,
              "MNW": 379,
              "MTH": 248,
              "SKN (ueber PNP)": 315,
              "notice": ["Keine Gezeitenhöhen verfügbar"],
              "has_height": false,
              "has_curve": false,
              "hwnw_prediction": {
                "level": "PNP",
                "data": [
                  {"timestamp": "2026-07-12 21:10:00+02:00", "height": null, "type": "NW", "phase": "MT"},
                  {"timestamp": "2026-07-13 03:15:00+02:00", "height": null, "type": "HW", "phase": "MT"}
                ]
              }
            }
          }]
        }
        """
        let around = try XCTUnwrap(BSHDateParser.date(from: "2026-07-12 23:00:00+02:00"))
        let reading = try BSHTideService.decodeReading(
            data: Data(json.utf8),
            stationID: "794P",
            around: around
        )

        XCTAssertEqual(reading.stationID, "794P")
        XCTAssertEqual(reading.previousEvent?.type, "NW")
        XCTAssertEqual(reading.nextEvent?.type, "HW")
        XCTAssertNil(reading.nextEvent?.heightMeters)
        XCTAssertEqual(reading.nextEvent?.heightText, "Höhe nicht verfügbar")
        XCTAssertFalse(reading.reference.hasEventHeights)
        XCTAssertEqual(try XCTUnwrap(reading.reference.meanTidalRangeMeters), 2.48, accuracy: 0.001)
    }

    func testOGCFixtureDecodesFlexibleNumbersAndConvertsPNPToSKN() throws {
        let station = try XCTUnwrap(BSHTideStationCatalog.station(id: "111P"))
        let json = """
        {
          "type": "Feature",
          "id": "norderney_riffgat",
          "properties": {
            "gauge_label": "Norderney, Riffgat",
            "official_warning_level_region": "Wasserstandsvorhersage",
            "information_text": {"de": "Amtliche Testdaten"},
            "gaugezero_relative_to_nhn": -500,
            "chartdatum_relative_to_gaugezero": "316",
            "mean_high_water": 626,
            "mean_low_water": "383",
            "forecast_timestamp": "2026-07-12 23:42:46+02:00",
            "automated_curveforecast_timestamp": "2026-07-13 00:11:30+02:00",
            "bsh_url_waterlevel": "https://wasserstand-nordsee.bsh.de/norderney_riffgat",
            "high_water_low_water": [{
              "event_timestamp": "2026-07-13 10:58:00+02:00",
              "event": "HW",
              "tidal_prediction_value": "627",
              "forecast_value": 606,
              "forecast_uncertainty": "10",
              "forecast_deviation": "-0,2 m"
            }],
            "curve": [{
              "timestamp": "2026-07-13 10:50:00+02:00",
              "tidal_prediction": "620",
              "automated_curve_forecast": 600,
              "measurement": "605"
            }]
          }
        }
        """

        let forecast = try BSHWaterLevelForecastService.decodeForecast(
            data: Data(json.utf8),
            station: station
        )
        let event = try XCTUnwrap(forecast.events.first)
        let curve = try XCTUnwrap(forecast.curve.first)

        XCTAssertEqual(try XCTUnwrap(forecast.sknAbovePnpMeters), 3.16, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(forecast.mhwAboveSknMeters), 3.10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(forecast.mnwAboveSknMeters), 0.67, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(event.tidalPredictionMetersAboveSkn), 3.11, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(event.forecastMetersAboveSkn), 2.90, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(event.conservativeCorrectionMeters), -0.31, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(curve.astroMetersSkn), 3.04, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(curve.forecastMetersSkn), 2.84, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(curve.measurementMetersSkn), 2.89, accuracy: 0.001)
    }

    func testWaterLevelQualityIsAdvisoryAndNeverTurnsNoGoSafe() {
        XCTAssertEqual(
            RouteCalculationService.applyCorrectionQuality(.confirmedComparison, to: .go),
            .go
        )
        XCTAssertEqual(
            RouteCalculationService.applyCorrectionQuality(.confirmedComparison, to: .noGo),
            .noGo
        )
        XCTAssertEqual(
            RouteCalculationService.applyCorrectionQuality(.outsideForecastHorizon, to: .go),
            .go
        )
        XCTAssertEqual(
            RouteCalculationService.applyCorrectionQuality(.stale, to: .noGo),
            .noGo
        )
    }

    func testBSHTimestampsPreserveSummerAndWinterOffsets() throws {
        let summer = try XCTUnwrap(BSHDateParser.date(from: "2026-07-12 23:42:46+02:00"))
        let winter = try XCTUnwrap(BSHDateParser.date(from: "2026-12-12 23:42:46+01:00"))
        XCTAssertEqual(summer, ISO8601DateFormatter().date(from: "2026-07-12T21:42:46Z"))
        XCTAssertEqual(winter, ISO8601DateFormatter().date(from: "2026-12-12T22:42:46Z"))
    }

    func testRouteWidePassageWindowUsesTenMinuteScan() async throws {
        let highWater = Date(timeIntervalSince1970: 1_768_500_000)
        let stationID = "TEST"
        let start = RouteWaypoint(
            id: UUID(),
            name: "Start",
            latitude: 53.7,
            longitude: 7.2,
            tidalReferenceStation: "Testpegel",
            tidalReferenceStationID: stationID,
            highWaterOffsetMinutes: 0,
            meanTidalRangeMeters: SourcedValue(value: 2.4, source: .manual, sourceNotes: nil),
            meanHighWaterMeters: nil,
            lottiefeMeters: SourcedValue(value: 1.45, source: .manual, sourceNotes: nil),
            chartDepthMeters: nil,
            calculationMode: .lottiefe,
            bshWaterLevelCorrectionOverride: 0,
            manualHighWaterTime: highWater,
            notes: "",
            category: "Wattenhoch",
            island: nil
        )
        var destination = start
        destination.id = UUID()
        destination.name = "Ziel"
        let leg = RouteLeg(
            id: UUID(),
            fromWaypointID: start.id,
            toWaypointID: destination.id,
            distanceNm: 0,
            courseDegrees: nil,
            speedThroughWaterKnots: 6,
            tidalCurrentKnots: 0
        )
        let route = RoutePlan(
            id: UUID(),
            date: highWater,
            routeName: "Test",
            plannedStartTime: highWater,
            waypoints: [start, destination],
            legs: [leg],
            bshWaterLevelCorrectionMeters: 0,
            tidalStateLabel: "Mitteltide"
        )
        let provider = MockTideDataProvider()

        let result = await PassageWindowScanner().findSafeWindow(
            route: route,
            boatSettings: BoatSettings(draftMeters: 1.1, safetyMarginMeters: 0.1),
            tideDataProvider: provider
        )
        let window = try XCTUnwrap(result)

        XCTAssertEqual(window.start, highWater.addingTimeInterval(-3_600))
        XCTAssertEqual(window.end, highWater.addingTimeInterval(3_600))
        XCTAssertGreaterThan(window.end.timeIntervalSince(window.start), 0)
        XCTAssertEqual(window.waterLevelQuality, .manual)
    }

    func testLiveBSHStationContractWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_BSH_LIVE_TESTS"] == "1" else {
            throw XCTSkip("RUN_BSH_LIVE_TESTS ist nicht aktiviert.")
        }

        for station in BSHTideStationCatalog.stations {
            let paddedID = String(repeating: "_", count: max(0, 5 - station.id.count)) + station.id
            let tideURL = try XCTUnwrap(URL(string: "https://gezeiten.bsh.de/data/DE_\(paddedID)_tides.json"))
            let (tideData, tideResponse) = try await URLSession.shared.data(from: tideURL)
            XCTAssertEqual((tideResponse as? HTTPURLResponse)?.statusCode, 200, station.id)
            let tideObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: tideData) as? [String: Any]
            )
            XCTAssertEqual(tideObject["bshnr"] as? String, station.id)
            XCTAssertEqual(tideObject["station_name"] as? String, station.name)
            XCTAssertEqual(try XCTUnwrap(tideObject["latitude"] as? Double), station.latitude, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(tideObject["longitude"] as? Double), station.longitude, accuracy: 0.001)

            guard let featureID = station.forecastFeatureID else { continue }
            let featureURL = try XCTUnwrap(URL(
                string: "https://gdi.bsh.de/ldproxy/rest/services/WaterLevelForecast/collections/waterlevelforecastdata/items/\(featureID)?lang=de&f=json"
            ))
            let (featureData, featureResponse) = try await URLSession.shared.data(from: featureURL)
            XCTAssertEqual((featureResponse as? HTTPURLResponse)?.statusCode, 200, featureID)
            let feature = try XCTUnwrap(
                JSONSerialization.jsonObject(with: featureData) as? [String: Any]
            )
            XCTAssertEqual(feature["id"] as? String, featureID)
            let properties = try XCTUnwrap(feature["properties"] as? [String: Any])
            XCTAssertEqual(properties["gauge_label"] as? String, station.name)
            XCTAssertNotNil(properties["high_water_low_water"])
            XCTAssertNotNil(properties["curve"])
        }
    }
}


extension BSHTideMigrationTests {
    func testTimestampFormatsResolveToSameInstant() throws {
        for (local, utc) in [("2026-07-12 23:42:46", "2026-07-12T21:42:46Z"),
                             ("2026-12-12T23:42:46", "2026-12-12T22:42:46Z")] {
            XCTAssertEqual(try XCTUnwrap(BSHDateParser.date(from: local)),
                           try XCTUnwrap(BSHDateParser.date(from: utc)))
        }
        XCTAssertNil(BSHDateParser.date(from: "not-a-date"))
    }
}

extension BSHTideMigrationTests {
    func testEmsForecastWithoutDatumResolvesToKnockReferenceStation() throws {
        let json = #"""
        {"features":[{"properties":{"latitude":53.32722,"longitude":7.03056,
          "gauge_label":"Knock, Ems","high_water_low_water":[
            {"event_timestamp":"2026-09-23 10:10:00+02:00","event":"HW","forecast_value":620}
          ]}}]}
        """#
        let station = try XCTUnwrap(BSHPassageForecastStore.decode(Data(json.utf8))
            .first { $0.name == "Termunterzijl" })
        XCTAssertEqual(station.gaugeName, "Knock, Ems")
        XCTAssertNil(station.chartDatumAboveGaugeZeroMeters)
        XCTAssertEqual(station.events.count, 1)
        XCTAssertEqual(BSHTideStationCatalog.stations.first(where: {
            $0.name.localizedCaseInsensitiveCompare(station.gaugeName) == .orderedSame
        })?.id, "802P")
    }

    func testForecastMappingUsesForecastInsteadOfAstronomyAndKeepsMissingCoverage() throws {
        let json = #"""
        {"features":[{"properties":{"latitude":53.69639,"longitude":7.15778,"gauge_label":"Norderney",
          "chartdatum_relative_to_gaugezero":"315",
          "high_water_low_water":[
            {"event_timestamp":"2026-09-22 09:00:00+02:00","event":"HW","forecast_value":"595","tidal_prediction_value":"580"},
            {"event_timestamp":"2026-09-22 15:00:00+02:00","event":"NW","forecast_value":355},
            {"event_timestamp":"2026-09-22 21:00:00+02:00","event":"HW","forecast_value":null,"tidal_prediction_value":"590"}
          ]}}]}
        """#
        let stations = try BSHPassageForecastStore.decode(Data(json.utf8))
        let juist = try XCTUnwrap(stations.first { $0.name == "Juist" })
        XCTAssertEqual(juist.events.count, 3)
        XCTAssertEqual(try XCTUnwrap(juist.events.first?.heightMeters), 2.8, accuracy: 1e-9)
        XCTAssertTrue(try XCTUnwrap(juist.events.last).usesAstronomicalPrediction)
        XCTAssertFalse(try XCTUnwrap(juist.events.first).currentTimestampIsISO8601)
        XCTAssertTrue(try XCTUnwrap(stations.first { $0.name == "Borkum" }).events.isEmpty,
                      "No station within 20 km: do not invent heights or transfer a distant gauge")
    }

    func testMissingForecastDatumAndAdjacentAstronomicalTide() throws {
        let json = #"""
        {"features":[{"properties":{"latitude":53.723333,"longitude":7.501667,
          "gauge_label":"Langeoog, Hafeneinfahrt","high_water_low_water":[
            {"event_timestamp":"2026-09-23 10:10:00+02:00","event":"HW","forecast_value":623},
            {"event_timestamp":"2026-09-23 16:42:00+02:00","event":"NW","tidal_prediction_value":387}
          ]}}]}
        """#
        let station = try XCTUnwrap(BSHPassageForecastStore.decode(Data(json.utf8))
            .first { $0.name == "Langeoog" })
        XCTAssertNil(station.chartDatumAboveGaugeZeroMeters,
                     "Gauge-zero centimetres must not be mistaken for chart-datum heights")
        XCTAssertEqual(try XCTUnwrap(station.events.first?.heightMeters), 6.23, accuracy: 1e-9)
        XCTAssertTrue(try XCTUnwrap(station.events.last).usesAstronomicalPrediction)

        let preceding = TideEvent(time: try XCTUnwrap(BSHDateParser.date(from: "2026-09-23 03:55:00+02:00")),
                                  heightMeters: 0.70, type: "NW", phase: nil)
        let combined = BSHPassageForecastStore.combined(forecast: station.events, calendar: [preceding])
        XCTAssertEqual(combined.count, 3)
        XCTAssertEqual(combined.first?.time, preceding.time)
        XCTAssertTrue(try XCTUnwrap(combined.first).usesAstronomicalPrediction)
    }
}
