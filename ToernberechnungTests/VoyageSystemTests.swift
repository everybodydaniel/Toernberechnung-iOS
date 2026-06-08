import XCTest
import CoreLocation
@testable import Toernberechnung

// MARK: - NavigationTracker geometry

final class NavigationTrackerGeometryTests: XCTestCase {

    func testPerpendicularDistanceOnSegment() {
        // Segment from (53.5, 7.0) to (53.5, 7.1). A point at (53.51, 7.05)
        // lies 0.01° north of the midpoint — ~1.111 km, irrespective of
        // the chosen longitude (because the segment runs east-west).
        let segA = CLLocationCoordinate2D(latitude: 53.5, longitude: 7.0)
        let segB = CLLocationCoordinate2D(latitude: 53.5, longitude: 7.1)
        let point = CLLocationCoordinate2D(latitude: 53.51, longitude: 7.05)
        let metres = NavigationTracker.perpendicularDistance(point: point, segA: segA, segB: segB)
        XCTAssertEqual(metres, 1113, accuracy: 50)
    }

    func testPerpendicularClampToEndpoint() {
        // Point well past the eastern endpoint — perpendicular foot is
        // clamped onto the endpoint, so we get the straight distance to it.
        // Accuracy = 200 m tolerates the ~0.2 % planar-vs-spherical drift
        // at marine latitudes over a 26 km baseline.
        let segA = CLLocationCoordinate2D(latitude: 53.5, longitude: 7.0)
        let segB = CLLocationCoordinate2D(latitude: 53.5, longitude: 7.1)
        let point = CLLocationCoordinate2D(latitude: 53.5, longitude: 7.5)
        let metres = NavigationTracker.perpendicularDistance(point: point, segA: segA, segB: segB)
        let expectedKm = CLLocation(latitude: 53.5, longitude: 7.1)
            .distance(from: CLLocation(latitude: 53.5, longitude: 7.5))
        XCTAssertEqual(metres, expectedKm, accuracy: 200)
    }

    func testBearingDueEast() {
        let a = CLLocationCoordinate2D(latitude: 53.5, longitude: 7.0)
        let b = CLLocationCoordinate2D(latitude: 53.5, longitude: 7.1)
        let bearing = NavigationTracker.bearing(from: a, to: b)
        XCTAssertEqual(bearing, 90, accuracy: 0.5)
    }

    func testBearingDueNorth() {
        let a = CLLocationCoordinate2D(latitude: 53.5, longitude: 7.0)
        let b = CLLocationCoordinate2D(latitude: 53.6, longitude: 7.0)
        let bearing = NavigationTracker.bearing(from: a, to: b)
        XCTAssertEqual(bearing, 0, accuracy: 0.5)
    }
}

// MARK: - NavigationTracker high-level update

final class NavigationTrackerUpdateTests: XCTestCase {

    @MainActor
    func testUpdateProducesPlausibleETAandDTW() {
        // Two-leg route: A (start) → B (intermediate) → C (destination).
        // All three are user-selected harbours.
        let wpA = makeWP("A", lat: 53.50, lon: 7.00)
        let wpB = makeWP("B", lat: 53.50, lon: 7.20)
        let wpC = makeWP("C", lat: 53.50, lon: 7.40)
        let route = makeRoute(waypoints: [wpA, wpB, wpC])

        let tracker = NavigationTracker()
        tracker.setRoute(route, userWaypointIDs: [wpA.id, wpB.id, wpC.id], plannedSpeedKnots: 6)

        // Boat sitting on the line between A and B, at lon 7.1.
        let location = CLLocation(latitude: 53.50, longitude: 7.10)
        tracker.update(location: location, speedKnots: 6)

        // Active waypoint is the END of the segment we're on (i.e. B).
        XCTAssertEqual(tracker.activeWaypointName, "B")
        // DTW ≈ boat→B = 0.10° lon at lat 53.5 ≈ 6.6 km ≈ 3.58 sm.
        XCTAssertEqual(tracker.distanceToWaypointNm ?? -1, 3.58, accuracy: 0.2)
        // Final = boat→B + B→C = 3.58 + 7.15 ≈ 10.73 sm.
        XCTAssertEqual(tracker.distanceToFinalNm ?? -1, 10.73, accuracy: 0.3)
        // XTE is essentially zero — boat is on the line.
        XCTAssertLessThan(tracker.crossTrackErrorMeters ?? 999, 10)
        XCTAssertFalse(tracker.isOffCourse)
        // ETA: 10.73 sm / 6 kn ≈ 1.79 h ≈ 6435 s from now.
        let etaInSeconds = tracker.dynamicETA?.timeIntervalSinceNow ?? 0
        XCTAssertEqual(etaInSeconds, 6435, accuracy: 200)
    }

    @MainActor
    func testUpdateUsesPlannedSpeedWhenDrifting() {
        let wpA = makeWP("A", lat: 53.50, lon: 7.00)
        let wpB = makeWP("B", lat: 53.50, lon: 7.20)
        let route = makeRoute(waypoints: [wpA, wpB])

        let tracker = NavigationTracker()
        tracker.setRoute(route, userWaypointIDs: [wpA.id, wpB.id], plannedSpeedKnots: 4)
        tracker.update(
            location: CLLocation(latitude: 53.50, longitude: 7.10),
            speedKnots: 0.2 // drifting — below the 1 kn floor
        )
        // ETA should be derived from the 4-kn fallback, not infinity.
        let etaSeconds = tracker.dynamicETA?.timeIntervalSinceNow ?? 0
        XCTAssertGreaterThan(etaSeconds, 0)
        XCTAssertLessThan(etaSeconds, 2.5 * 3600)
    }

    @MainActor
    func testOffCourseDetection() {
        let wpA = makeWP("A", lat: 53.50, lon: 7.00)
        let wpB = makeWP("B", lat: 53.50, lon: 7.20)
        let route = makeRoute(waypoints: [wpA, wpB])
        let tracker = NavigationTracker()
        tracker.setRoute(route, userWaypointIDs: [wpA.id, wpB.id], plannedSpeedKnots: 6)
        // Sit ~250 m north of the route → off-course (threshold = 150 m).
        let offCourse = CLLocation(latitude: 53.5023, longitude: 7.10)
        tracker.update(location: offCourse, speedKnots: 5)
        XCTAssertTrue(tracker.isOffCourse)
        XCTAssertGreaterThan(tracker.crossTrackErrorMeters ?? 0, 150)
    }
}

// MARK: - ActiveVoyageManager lifecycle

final class ActiveVoyageManagerTests: XCTestCase {

    @MainActor
    func testStartAccumulatesDistanceAndStopReturnsRecord() {
        let location = LocationService()
        let tracker = NavigationTracker()
        let voyage = ActiveVoyageManager(locationService: location, tracker: tracker)

        let wpA = makeWP("A", lat: 53.500, lon: 7.000)
        let wpB = makeWP("B", lat: 53.510, lon: 7.020)
        let route = makeRoute(waypoints: [wpA, wpB])
        voyage.startVoyage(route: route, userWaypointIDs: [wpA.id, wpB.id], plannedSpeedKnots: 6)
        XCTAssertTrue(voyage.isVoyageActive)

        // Stop without any GPS — distance stays 0, but the record persists.
        let context = makeInMemoryModelContext()
        let record = voyage.stopVoyageAndSaveLogbook(modelContext: context)
        XCTAssertNotNil(record)
        XCTAssertTrue(record!.isActualVoyage)
        XCTAssertEqual(record!.actualDistanceNM, 0, accuracy: 1e-6)
        XCTAssertFalse(voyage.isVoyageActive)
    }

    @MainActor
    func testCancelClearsState() {
        let location = LocationService()
        let tracker = NavigationTracker()
        let voyage = ActiveVoyageManager(locationService: location, tracker: tracker)
        let wpA = makeWP("A", lat: 53.5, lon: 7.0)
        let wpB = makeWP("B", lat: 53.5, lon: 7.1)
        let route = makeRoute(waypoints: [wpA, wpB])
        voyage.startVoyage(route: route, userWaypointIDs: [wpA.id, wpB.id], plannedSpeedKnots: 6)
        XCTAssertTrue(voyage.isVoyageActive)
        voyage.cancelVoyage()
        XCTAssertFalse(voyage.isVoyageActive)
        XCTAssertNil(voyage.activeRoute)
    }
}

// MARK: - Helpers

@MainActor
private func makeWP(_ name: String, lat: Double, lon: Double) -> RouteWaypoint {
    RouteWaypoint(
        id: UUID(),
        name: name,
        latitude: lat,
        longitude: lon,
        tidalReferenceStation: "",
        tidalReferenceStationID: "",
        highWaterOffsetMinutes: 0,
        meanTidalRangeMeters: nil,
        meanHighWaterMeters: nil,
        lottiefeMeters: nil,
        chartDepthMeters: nil,
        calculationMode: .meanHighWater,
        bshWaterLevelCorrectionOverride: nil,
        manualHighWaterTime: nil,
        notes: "",
        category: "Hafen",
        island: nil
    )
}

@MainActor
private func makeRoute(waypoints: [RouteWaypoint]) -> RoutePlan {
    let legs: [RouteLeg] = zip(waypoints, waypoints.dropFirst()).map { from, to in
        RouteLeg(
            id: UUID(),
            fromWaypointID: from.id, toWaypointID: to.id,
            distanceNm: 0, courseDegrees: nil,
            speedThroughWaterKnots: 6, tidalCurrentKnots: 0
        )
    }
    return RoutePlan(
        id: UUID(),
        date: Date(),
        routeName: waypoints.map(\.name).joined(separator: " → "),
        plannedStartTime: Date(),
        waypoints: waypoints,
        legs: legs,
        bshWaterLevelCorrectionMeters: 0,
        tidalStateLabel: "Mitteltide"
    )
}

import SwiftData

@MainActor
private func makeInMemoryModelContext() -> ModelContext {
    let schema = Schema([CalculationRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    // swiftlint:disable:next force_try
    let container = try! ModelContainer(for: schema, configurations: config)
    return ModelContext(container)
}
