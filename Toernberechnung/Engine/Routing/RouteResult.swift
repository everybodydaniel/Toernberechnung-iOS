import Foundation
import CoreLocation

struct RouteResult {
    let coordinates: [CLLocationCoordinate2D]
    let totalDistanceNauticalMiles: Double
    let legs: [RouteLegResult]
}

struct RouteLegResult {
    let fromCoordinate: CLLocationCoordinate2D
    let toCoordinate: CLLocationCoordinate2D
    let coordinates: [CLLocationCoordinate2D]
    let distanceNauticalMiles: Double
    let courseDegrees: Double
}

enum DepthClassification {
    case safe
    case critical
    case noGo
}

struct DepthSegment {
    let coordinates: [CLLocationCoordinate2D]
    let classification: DepthClassification
    let minimumDepthMeters: Double
}

struct DepthSample {
    let coordinate: CLLocationCoordinate2D
    let depthMeters: Double
    let classification: DepthClassification
}
