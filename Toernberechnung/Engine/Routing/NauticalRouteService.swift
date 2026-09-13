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
        return smoothed
    }

    func calculateMultiStopRoute(stops: [CLLocationCoordinate2D]) -> RouteResult {
        guard stops.count >= 2 else {
            return RouteResult(coordinates: stops)
        }

        var allCoords: [CLLocationCoordinate2D] = []

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

            if allCoords.isEmpty {
                allCoords.append(contentsOf: legCoords)
            } else {
                allCoords.append(contentsOf: legCoords.dropFirst())
            }
        }

        return RouteResult(coordinates: allCoords)
    }
}
