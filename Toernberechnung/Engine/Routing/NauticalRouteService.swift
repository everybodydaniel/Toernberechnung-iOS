import Foundation
import CoreLocation

extension Notification.Name {
    /// Posted on the main thread once `SeaMask` has finished building, so the
    /// map can redraw a route that was first drawn as a straight-line fallback
    /// while the mask was still unavailable (mirrors the reactive
    /// `SeaMask.isReady` observation in `MapScreen`).
    static let seaMaskDidBecomeReady = Notification.Name("seaMaskDidBecomeReady")
}

final class NauticalRouteService {

    static let shared = NauticalRouteService()

    private static let depthSampleM = 250.0

    private let pathfinder = AStarPathfinder()

    private struct BridgeRule {
        let harbor: CLLocationCoordinate2D
        let via: [CLLocationCoordinate2D]
        let matchRadiusM: Double
    }

    private let bridgeRules = [
        BridgeRule(
            harbor: CLLocationCoordinate2D(latitude: 53.3382, longitude: 7.1945),
            via: [
                CLLocationCoordinate2D(latitude: 53.3200, longitude: 7.1800),
                CLLocationCoordinate2D(latitude: 53.3100, longitude: 7.0500),
                CLLocationCoordinate2D(latitude: 53.3700, longitude: 6.9200),
                CLLocationCoordinate2D(latitude: 53.4500, longitude: 6.9500)
            ],
            matchRadiusM: 3000.0
        ),
        BridgeRule(
            harbor: CLLocationCoordinate2D(latitude: 53.5150, longitude: 8.1500),
            via: [
                CLLocationCoordinate2D(latitude: 53.52743262744863, longitude: 8.20080110975966),
                CLLocationCoordinate2D(latitude: 53.65600309601381, longitude: 8.137997413254762)
            ],
            matchRadiusM: 5000.0
        ),
        BridgeRule(
            harbor: CLLocationCoordinate2D(latitude: 53.4500, longitude: 8.1200),
            via: [
                CLLocationCoordinate2D(latitude: 53.52743262744863, longitude: 8.20080110975966),
                CLLocationCoordinate2D(latitude: 53.65600309601381, longitude: 8.137997413254762)
            ],
            matchRadiusM: 5000.0
        ),
        BridgeRule(
            harbor: CLLocationCoordinate2D(latitude: 53.6280, longitude: 8.0430),
            via: [
                CLLocationCoordinate2D(latitude: 53.660676, longitude: 8.102389),
                CLLocationCoordinate2D(latitude: 53.65600309601381, longitude: 8.137997413254762)
            ],
            matchRadiusM: 5000.0
        ),
        BridgeRule(
            harbor: CLLocationCoordinate2D(latitude: 53.6900, longitude: 8.0000),
            via: [
                CLLocationCoordinate2D(latitude: 53.68442552008205, longitude: 8.026188181851579),
                CLLocationCoordinate2D(latitude: 53.684758103906816, longitude: 8.027591485261341),
                CLLocationCoordinate2D(latitude: 53.68426991325801, longitude: 8.03027190151226),
                CLLocationCoordinate2D(latitude: 53.68366786285469, longitude: 8.032813226495673),
                CLLocationCoordinate2D(latitude: 53.682307995589746, longitude: 8.035652370546673),
                CLLocationCoordinate2D(latitude: 53.68635761439309, longitude: 8.037761461836245),
                CLLocationCoordinate2D(latitude: 53.69191912175027, longitude: 8.044052238929034)
            ],
            matchRadiusM: 5000.0
        ),
        BridgeRule(
            harbor: CLLocationCoordinate2D(latitude: 53.77485124022699, longitude: 7.867251072413869),
            via: [
                CLLocationCoordinate2D(latitude: 53.768564770764016, longitude: 7.863543835115352)
            ],
            matchRadiusM: 5000.0
        )
    ]

    private init() {}

    func buildSeaMask(completion: @escaping () -> Void = {}) {
        guard !SeaMask.shared.isReady else {
            completion()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            SeaMask.shared.build()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .seaMaskDidBecomeReady, object: nil)
                completion()
            }
        }
    }

    private func bridgeForPoint(_ p: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        for rule in bridgeRules {
            let d = GridConfig.approxMeters(lat1: p.latitude, lon1: p.longitude, lat2: rule.harbor.latitude, lon2: rule.harbor.longitude)
            if d <= rule.matchRadiusM {
                return rule.via
            }
        }
        return []
    }

    func calculateRoute(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        guard SeaMask.shared.isReady else {
            return [start, end]
        }
        guard let raw = pathfinder.findPath(from: start, to: end) else {
            return [start, end]
        }
        let smoothed = PathSmoother.smooth(raw)
        _ = BuoyValidator.validate(smoothed)
        return smoothed
    }

    func calculateMultiStopRoute(stops: [CLLocationCoordinate2D]) -> RouteResult {
        guard stops.count >= 2 else {
            return RouteResult(coordinates: stops, totalDistanceNauticalMiles: 0.0, legs: [])
        }

        var allCoords: [CLLocationCoordinate2D] = []
        var legs: [RouteLegResult] = []
        var totalDistance = 0.0

        for i in 0..<(stops.count - 1) {
            let start = stops[i]
            let end = stops[i + 1]

            let startBridges = bridgeForPoint(start)
            let endBridges = bridgeForPoint(end).reversed()
            
            var viaPoints: [CLLocationCoordinate2D] = [start]
            viaPoints.append(contentsOf: startBridges)
            for p in endBridges {
                if !viaPoints.contains(where: { abs($0.latitude - p.latitude) < 1e-6 && abs($0.longitude - p.longitude) < 1e-6 }) {
                    viaPoints.append(p)
                }
            }
            viaPoints.append(end)

            var legCoords: [CLLocationCoordinate2D] = []
            for j in 0..<(viaPoints.count - 1) {
                let segment = calculateRoute(from: viaPoints[j], to: viaPoints[j + 1])
                if legCoords.isEmpty {
                    legCoords.append(contentsOf: segment)
                } else {
                    legCoords.append(contentsOf: segment.dropFirst())
                }
            }

            let legDistance = zip(legCoords, legCoords.dropFirst()).reduce(0.0) { sum, pair in
                sum + GridConfig.haversineMeters(lat1: pair.0.latitude, lon1: pair.0.longitude, lat2: pair.1.latitude, lon2: pair.1.longitude) / 1852.0
            }
            totalDistance += legDistance

            var course = 0.0
            if let first = legCoords.first, let last = legCoords.last {
                course = calculateBearingDegrees(from: first, to: last)
            }

            legs.append(RouteLegResult(
                fromCoordinate: start,
                toCoordinate: end,
                coordinates: legCoords,
                distanceNauticalMiles: legDistance,
                courseDegrees: course
            ))

            if allCoords.isEmpty {
                allCoords.append(contentsOf: legCoords)
            } else {
                allCoords.append(contentsOf: legCoords.dropFirst())
            }
        }

        return RouteResult(
            coordinates: allCoords,
            totalDistanceNauticalMiles: totalDistance,
            legs: legs
        )
    }

    func calculateSegmentedRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        draft: Double,
        margin: Double,
        currentTime: Date? = nil,
        tideEvents: [TideEvent] = []
    ) -> [DepthSegment] {
        let startBridges = bridgeForPoint(start)
        let endBridges = bridgeForPoint(end).reversed()
        var viaPoints: [CLLocationCoordinate2D] = [start]
        viaPoints.append(contentsOf: startBridges)
        for p in endBridges {
            if !viaPoints.contains(where: { abs($0.latitude - p.latitude) < 1e-6 && abs($0.longitude - p.longitude) < 1e-6 }) {
                viaPoints.append(p)
            }
        }
        viaPoints.append(end)

        if viaPoints.count > 2 {
            return calculateMultiStopSegmentedRoute(points: viaPoints, draft: draft, margin: margin, currentTime: currentTime, tideEvents: tideEvents)
        }

        let route = calculateRoute(from: start, to: end)
        if route.count < 2 { return [] }

        let tideOffset: Double
        if let time = currentTime, !tideEvents.isEmpty {
            tideOffset = calculateTideOffset(time: time, events: tideEvents)
        } else {
            tideOffset = 0.0
        }

        return classifyRouteByDepth(route: route, draft: draft, margin: margin, tideOffset: tideOffset)
    }

    private func calculateMultiStopSegmentedRoute(
        points: [CLLocationCoordinate2D],
        draft: Double,
        margin: Double,
        currentTime: Date?,
        tideEvents: [TideEvent]
    ) -> [DepthSegment] {
        let tideOffset: Double
        if let time = currentTime, !tideEvents.isEmpty {
            tideOffset = calculateTideOffset(time: time, events: tideEvents)
        } else {
            tideOffset = 0.0
        }

        var all: [DepthSegment] = []
        for i in 0..<(points.count - 1) {
            let route = calculateRoute(from: points[i], to: points[i + 1])
            if route.count >= 2 {
                all.append(contentsOf: classifyRouteByDepth(route: route, draft: draft, margin: margin, tideOffset: tideOffset))
            }
        }
        return mergeAdjacentSegments(all)
    }

    func depthSamplesAlongRoute(
        route: [CLLocationCoordinate2D],
        tideOffset: Double,
        draft: Double,
        margin: Double,
        spacingM: Double = 500.0
    ) -> [DepthSample] {
        guard route.count >= 2 else { return [] }
        var samples: [DepthSample] = []
        for i in 0..<(route.count - 1) {
            let a = route[i]
            let b = route[i + 1]
            let len = GridConfig.approxMeters(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
            let steps = max(1, Int(len / spacingM))
            for s in 0...steps {
                let t = Double(s) / Double(steps)
                let lat = a.latitude + (b.latitude - a.latitude) * t
                let lon = a.longitude + (b.longitude - a.longitude) * t
                let chart = SeaMask.shared.depthAtLatLng(lat: lat, lon: lon)
                let current = chart + tideOffset
                let classification = classifyDepth(depth: current, draft: draft, margin: margin)
                samples.append(DepthSample(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    depthMeters: current,
                    classification: classification
                ))
            }
        }
        return samples
    }

    func calculateTideOffset(time: Date, events: [TideEvent]) -> Double {
        if events.isEmpty { return 0.0 }

        let sorted = events.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return 0.0 }

        guard let nextIndex = sorted.firstIndex(where: { $0.time > time }) else {
            return sorted.last?.heightMeters ?? 0.0
        }
        if nextIndex == 0 {
            return sorted.first?.heightMeters ?? 0.0
        }

        let prev = sorted[nextIndex - 1]
        let next = sorted[nextIndex]

        guard let prevHeight = prev.heightMeters, let nextHeight = next.heightMeters else {
            return prev.heightMeters ?? next.heightMeters ?? 0.0
        }

        return RuleOfTwelfths.continuousWaterLevel(
            timeStart: prev.time, heightStart: prevHeight,
            timeEnd: next.time, heightEnd: nextHeight,
            targetTime: time
        )
    }

    func classifyDepth(depth: Double, draft: Double, margin: Double) -> DepthClassification {
        if depth >= (draft + margin) {
            return .safe
        } else if depth >= draft {
            return .critical
        } else {
            return .noGo
        }
    }

    private func classifyRouteByDepth(
        route: [CLLocationCoordinate2D],
        draft: Double,
        margin: Double,
        tideOffset: Double
    ) -> [DepthSegment] {
        guard route.count >= 2 else { return [] }

        var dense: [CLLocationCoordinate2D] = []
        dense.append(route.first!)
        for i in 0..<(route.count - 1) {
            let a = route[i]
            let b = route[i + 1]
            let len = GridConfig.approxMeters(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
            let steps = max(1, Int(len / Self.depthSampleM))
            for s in 1...steps {
                let t = Double(s) / Double(steps)
                dense.append(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                ))
            }
        }

        let perSample = dense.map { p -> (CLLocationCoordinate2D, Double, DepthClassification) in
            let chart = SeaMask.shared.depthAtLatLng(lat: p.latitude, lon: p.longitude)
            let current = chart + tideOffset
            return (p, current, classifyDepth(depth: current, draft: draft, margin: margin))
        }

        var segments: [DepthSegment] = []
        var curPoints: [CLLocationCoordinate2D] = [perSample[0].0]
        var curType = perSample[0].2
        var curMinDepth = perSample[0].1

        for i in 1..<perSample.count {
            let (p, d, t) = perSample[i]
            if t == curType {
                curPoints.append(p)
                if d < curMinDepth { curMinDepth = d }
            } else {
                curPoints.append(p)
                segments.append(DepthSegment(coordinates: curPoints, classification: curType, minimumDepthMeters: curMinDepth))
                curPoints = [p]
                curType = t
                curMinDepth = d
            }
        }
        segments.append(DepthSegment(coordinates: curPoints, classification: curType, minimumDepthMeters: curMinDepth))
        return mergeAdjacentSegments(segments)
    }

    private func mergeAdjacentSegments(_ segments: [DepthSegment]) -> [DepthSegment] {
        guard !segments.isEmpty else { return [] }
        var merged: [DepthSegment] = []
        var currentPoints = segments[0].coordinates
        var currentType = segments[0].classification
        var currentMinDepth = segments[0].minimumDepthMeters

        for i in 1..<segments.count {
            if segments[i].classification == currentType {
                currentPoints.append(contentsOf: segments[i].coordinates.dropFirst())
                currentMinDepth = min(currentMinDepth, segments[i].minimumDepthMeters)
            } else {
                merged.append(DepthSegment(coordinates: currentPoints, classification: currentType, minimumDepthMeters: currentMinDepth))
                currentPoints = segments[i].coordinates
                currentType = segments[i].classification
                currentMinDepth = segments[i].minimumDepthMeters
            }
        }
        merged.append(DepthSegment(coordinates: currentPoints, classification: currentType, minimumDepthMeters: currentMinDepth))
        return merged
    }

    private func calculateBearingDegrees(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180.0
        let lon1 = start.longitude * .pi / 180.0
        let lat2 = end.latitude * .pi / 180.0
        let lon2 = end.longitude * .pi / 180.0

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180.0 / .pi
        return (degrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}
