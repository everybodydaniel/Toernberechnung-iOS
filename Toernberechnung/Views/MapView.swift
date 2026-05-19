import SwiftUI
import MapLibre
import CoreLocation
import UIKit

struct CompactMapView: UIViewRepresentable {
    let zoomLevel: Double
    let start: HarbourOption
    let destination: HarbourOption
    var routePlan: RoutePlan?
    /// Optionale Zwischen-Wegpunkte mit Statusfarben je Wegpunkt.
    var waypointResults: [WaypointCalculationResult]?

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        mapView.styleURL = SeaRoutePlanner.nauticalStyleURL
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.showsScale = false
        mapView.delegate = context.coordinator
        mapView.setCenter(centerCoordinate, zoomLevel: zoomLevel, animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.routePlan = routePlan
        context.coordinator.waypointResults = waypointResults
        context.coordinator.drawRoute(on: mapView, start: start, destination: destination)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var centerCoordinate: CLLocationCoordinate2D {
        let startCoordinate = SeaRoutePlanner.mapCoordinate(for: start)
        let destinationCoordinate = SeaRoutePlanner.mapCoordinate(for: destination)
        return CLLocationCoordinate2D(
            latitude: (startCoordinate.latitude + destinationCoordinate.latitude) / 2,
            longitude: (startCoordinate.longitude + destinationCoordinate.longitude) / 2
        )
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var routePlan: RoutePlan?
        var waypointResults: [WaypointCalculationResult]?

        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let point = annotation as? MLNPointAnnotation else { return nil }

            let markerID: String
            let color: UIColor

            if let statusRaw = point.subtitle, let status = WaypointStatus(rawValue: statusRaw) {
                markerID = "wp-\(statusRaw)"
                color = Self.markerColor(for: status)
            } else if point.title?.lowercased() == "start" {
                markerID = "start-marker"
                color = .systemGreen
            } else {
                markerID = "destination-marker"
                color = .systemBlue
            }

            if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: markerID) {
                return existing
            }

            let isSmall = markerID.hasPrefix("wp-")
            let size = isSmall ? CGSize(width: 20, height: 24) : CGSize(width: 28, height: 34)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                color.setFill()
                if isSmall {
                    ctx.cgContext.fillEllipse(in: CGRect(x: 3, y: 1, width: 14, height: 14))
                    ctx.cgContext.move(to: CGPoint(x: 10, y: 23))
                    ctx.cgContext.addLine(to: CGPoint(x: 5, y: 13))
                    ctx.cgContext.addLine(to: CGPoint(x: 15, y: 13))
                    ctx.cgContext.closePath()
                    ctx.cgContext.fillPath()
                    UIColor.white.setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: 7, y: 5, width: 6, height: 6))
                } else {
                    ctx.cgContext.fillEllipse(in: CGRect(x: 5, y: 2, width: 18, height: 18))
                    ctx.cgContext.move(to: CGPoint(x: 14, y: 32))
                    ctx.cgContext.addLine(to: CGPoint(x: 8, y: 17))
                    ctx.cgContext.addLine(to: CGPoint(x: 20, y: 17))
                    ctx.cgContext.closePath()
                    ctx.cgContext.fillPath()
                    UIColor.white.setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: 11, y: 8, width: 6, height: 6))
                }
            }
            return MLNAnnotationImage(image: image, reuseIdentifier: markerID)
        }

        @MainActor
        func drawRoute(on mapView: MLNMapView, start: HarbourOption, destination: HarbourOption) {
            let waypointKey = routePlan?.waypoints
                .map { "\($0.name):\($0.latitude ?? 0):\($0.longitude ?? 0)" }
                .joined(separator: "|") ?? ""
            let resultKey = waypointResults?
                .map { "\($0.waypoint.name):\($0.status.rawValue)" }
                .joined(separator: "|") ?? ""
            let key = "\(start.id)-\(destination.id)-\(waypointKey)-\(resultKey)"
            guard key != routeKey else { return }
            routeKey = key
            render(route: SeaRoutePlanner.route(from: start, to: destination), on: mapView, start: start, destination: destination)
        }

        private var routeKey = ""

        @MainActor
        private func render(route: [CLLocationCoordinate2D], on mapView: MLNMapView, start: HarbourOption, destination: HarbourOption) {
            mapView.removeAnnotations(mapView.annotations ?? [])
            mapView.addAnnotations(routeSegments(for: route, start: start, destination: destination))

            var annotations: [MLNPointAnnotation] = [
                Self.marker(title: "Start", subtitle: nil, coordinate: SeaRoutePlanner.mapCoordinate(for: start)),
                Self.marker(title: "Ziel", subtitle: nil, coordinate: SeaRoutePlanner.mapCoordinate(for: destination))
            ]

            let waypointStatusByID = Dictionary(
                uniqueKeysWithValues: (waypointResults ?? []).map { ($0.waypoint.id, $0.status) }
            )
            let displayWaypoints = routePlan?.waypoints ?? waypointResults?.map(\.waypoint) ?? []
            if displayWaypoints.count > 2 {
                for waypoint in displayWaypoints.dropFirst().dropLast() {
                    if let lat = waypoint.latitude, let lon = waypoint.longitude {
                        let annotation = Self.marker(
                            title: waypoint.name,
                            subtitle: (waypointStatusByID[waypoint.id] ?? .incomplete).rawValue,
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        )
                        annotations.append(annotation)
                    }
                }
            }

            mapView.addAnnotations(annotations)
            fit(route: route + annotations.map { $0.coordinate }, on: mapView)
        }

        private func routeSegments(
            for route: [CLLocationCoordinate2D],
            start: HarbourOption,
            destination: HarbourOption
        ) -> [MLNPolyline] {
            guard route.count > 1 else { return [] }
            guard let waypointResults, waypointResults.count > 1 else {
                return [polyline(route, status: .go)]
            }

            let checkpoints = routeCheckpoints(
                for: waypointResults,
                route: route,
                start: start,
                destination: destination
            )
            guard checkpoints.count > 1 else {
                return [polyline(route, status: cumulativeStatus(for: waypointResults))]
            }

            var segments: [MLNPolyline] = []
            var statusSoFar = checkpoints.first?.status ?? .go

            for index in 1 ..< checkpoints.count {
                statusSoFar = Self.worseStatus(statusSoFar, checkpoints[index].status)
                let lower = checkpoints[index - 1].routeIndex
                let upper = checkpoints[index].routeIndex
                guard lower != upper else { continue }

                let segmentCoordinates = Array(route[min(lower, upper) ... max(lower, upper)])
                guard segmentCoordinates.count > 1 else { continue }
                segments.append(polyline(segmentCoordinates, status: statusSoFar))
            }

            return segments.isEmpty ? [polyline(route, status: statusSoFar)] : segments
        }

        private func routeCheckpoints(
            for waypointResults: [WaypointCalculationResult],
            route: [CLLocationCoordinate2D],
            start: HarbourOption,
            destination: HarbourOption
        ) -> [(routeIndex: Int, status: WaypointStatus)] {
            var checkpoints: [(routeIndex: Int, status: WaypointStatus)] = []
            var lastRouteIndex = 0

            for (index, result) in waypointResults.enumerated() {
                let coordinate: CLLocationCoordinate2D
                if index == 0 {
                    coordinate = SeaRoutePlanner.mapCoordinate(for: start)
                } else if index == waypointResults.count - 1 {
                    coordinate = SeaRoutePlanner.mapCoordinate(for: destination)
                } else if let lat = result.waypoint.latitude, let lon = result.waypoint.longitude {
                    coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                } else {
                    coordinate = route[min(index, route.count - 1)]
                }

                let routeIndex: Int
                if index == 0 {
                    routeIndex = 0
                } else if index == waypointResults.count - 1 {
                    routeIndex = route.count - 1
                } else {
                    routeIndex = max(lastRouteIndex, nearestRouteIndex(to: coordinate, in: route))
                }

                checkpoints.append((routeIndex, result.status))
                lastRouteIndex = routeIndex
            }

            return checkpoints
        }

        private func nearestRouteIndex(to coordinate: CLLocationCoordinate2D, in route: [CLLocationCoordinate2D]) -> Int {
            route.indices.min {
                Self.distanceSquared(from: coordinate, to: route[$0]) < Self.distanceSquared(from: coordinate, to: route[$1])
            } ?? 0
        }

        private func polyline(_ route: [CLLocationCoordinate2D], status: WaypointStatus) -> MLNPolyline {
            var mutableRoute = route
            let line = MLNPolyline(coordinates: &mutableRoute, count: UInt(mutableRoute.count))
            line.subtitle = status.rawValue
            return line
        }

        private func cumulativeStatus(for waypointResults: [WaypointCalculationResult]) -> WaypointStatus {
            waypointResults.reduce(.go) { Self.worseStatus($0, $1.status) }
        }

        private func fit(route: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            guard route.count > 1 else {
                if let coordinate = route.first {
                    mapView.setCenter(coordinate, zoomLevel: 11, animated: true)
                }
                return
            }

            let coordinates = route
            let padding = UIEdgeInsets(top: 32, left: 28, bottom: 32, right: 28)
            coordinates.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                mapView.setVisibleCoordinates(
                    baseAddress,
                    count: UInt(buffer.count),
                    edgePadding: padding,
                    animated: true
                )
            }
        }

        private static func marker(title: String, subtitle: String?, coordinate: CLLocationCoordinate2D) -> MLNPointAnnotation {
            let annotation = MLNPointAnnotation()
            annotation.coordinate = coordinate
            annotation.title = title
            annotation.subtitle = subtitle
            return annotation
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if let statusRaw = annotation.subtitle, let status = WaypointStatus(rawValue: statusRaw) {
                return Self.routeColor(for: status)
            }
            return UIColor.systemBlue
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            4
        }

        private static func worseStatus(_ lhs: WaypointStatus, _ rhs: WaypointStatus) -> WaypointStatus {
            severity(lhs) >= severity(rhs) ? lhs : rhs
        }

        private static func severity(_ status: WaypointStatus) -> Int {
            switch status {
            case .go: return 0
            case .warning: return 1
            case .incomplete: return 1
            case .noGo: return 2
            case .invalid: return 2
            }
        }

        private static func distanceSquared(from lhs: CLLocationCoordinate2D, to rhs: CLLocationCoordinate2D) -> Double {
            let latDistance = lhs.latitude - rhs.latitude
            let lonDistance = (lhs.longitude - rhs.longitude) * cos(lhs.latitude * .pi / 180)
            return latDistance * latDistance + lonDistance * lonDistance
        }

        private static func routeColor(for status: WaypointStatus) -> UIColor {
            switch status {
            case .go: return .systemGreen
            case .warning: return .systemOrange
            case .noGo: return .systemRed
            case .incomplete: return .systemOrange
            case .invalid: return .systemRed
            }
        }

        private static func markerColor(for status: WaypointStatus) -> UIColor {
            switch status {
            case .go: return .systemGreen
            case .warning: return .systemOrange
            case .noGo: return .systemRed
            case .incomplete: return .systemGray
            case .invalid: return .systemRed
            }
        }
    }
}
