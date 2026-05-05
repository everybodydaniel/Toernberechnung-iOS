import SwiftUI
import MapLibre
import CoreLocation

struct CompactMapView: UIViewRepresentable {
    let zoomLevel: Double
    let start: HarbourOption
    let destination: HarbourOption

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
        context.coordinator.drawRoute(on: mapView, start: start, destination: destination)
        mapView.setCenter(centerCoordinate, zoomLevel: zoomLevel, animated: true)
        if abs(mapView.zoomLevel - zoomLevel) > 0.2 {
            mapView.setZoomLevel(zoomLevel, animated: true)
        }
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
        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard annotation is MLNPointAnnotation else { return nil }
            let id = annotation.title??.lowercased() == "start" ? "start-marker" : "destination-marker"
            if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: id) { return existing }
            let color = id == "start-marker" ? UIColor.systemGreen : UIColor.systemBlue
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 34))
            let image = renderer.image { ctx in
                color.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: 5, y: 2, width: 18, height: 18))
                ctx.cgContext.move(to: CGPoint(x: 14, y: 32))
                ctx.cgContext.addLine(to: CGPoint(x: 8, y: 17))
                ctx.cgContext.addLine(to: CGPoint(x: 20, y: 17))
                ctx.cgContext.closePath()
                ctx.cgContext.fillPath()
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: 11, y: 8, width: 6, height: 6))
            }
            return MLNAnnotationImage(image: image, reuseIdentifier: id)
        }

        @MainActor
        func drawRoute(on mapView: MLNMapView, start: HarbourOption, destination: HarbourOption) {
            let key = "\(start.id)-\(destination.id)"
            // Zuerst wird die lokale Fallback-Route gezeichnet; falls Overpass Daten liefert, wird sie danach ersetzt.
            render(route: SeaRoutePlanner.route(from: start, to: destination), on: mapView, start: start, destination: destination)
            guard key != routeKey else { return }
            routeKey = key
            routeTask?.cancel()
            routeTask = Task {
                guard let route = await SeaRoutePlanner.routeFromSeamarks(from: start, to: destination), !Task.isCancelled else { return }
                await MainActor.run {
                    self.render(route: route, on: mapView, start: start, destination: destination)
                }
            }
        }

        private var routeTask: Task<Void, Never>?
        private var routeKey = ""

        @MainActor
        private func render(route: [CLLocationCoordinate2D], on mapView: MLNMapView, start: HarbourOption, destination: HarbourOption) {
            mapView.removeAnnotations(mapView.annotations ?? [])
            var mutableRoute = route
            let line = MLNPolyline(coordinates: &mutableRoute, count: UInt(mutableRoute.count))
            mapView.addAnnotation(line)
            mapView.addAnnotations([
                Self.marker(title: "Start", harbour: start),
                Self.marker(title: "Ziel", harbour: destination)
            ])
        }

        private static func marker(title: String, harbour: HarbourOption) -> MLNPointAnnotation {
            let annotation = MLNPointAnnotation()
            annotation.coordinate = SeaRoutePlanner.mapCoordinate(for: harbour)
            annotation.title = title
            annotation.subtitle = harbour.name
            return annotation
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            UIColor.systemBlue
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            3
        }
    }
}
