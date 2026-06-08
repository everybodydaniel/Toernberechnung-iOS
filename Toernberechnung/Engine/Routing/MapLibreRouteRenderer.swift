import Foundation
import UIKit
import CoreLocation
import MapLibre

enum MapLibreRouteRenderer {

    static func renderRoute(_ result: RouteResult, on mapView: MLNMapView) {
        let coords = result.coordinates
        guard !coords.isEmpty else {
            removeRoute(from: mapView)
            return
        }

        let polyline = MLNPolylineFeature(coordinates: coords, count: UInt(coords.count))
        
        if let existingSource = mapView.style?.source(withIdentifier: "nautical-route-source") as? MLNShapeSource {
            existingSource.shape = polyline
        } else {
            let source = MLNShapeSource(identifier: "nautical-route-source", features: [polyline], options: nil)
            mapView.style?.addSource(source)

            let layer = MLNLineStyleLayer(identifier: "nautical-route-layer", source: source)
            layer.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
            layer.lineWidth = NSExpression(forConstantValue: 4.0)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            mapView.style?.addLayer(layer)
        }
    }

    static func renderSegmentedRoute(_ segments: [DepthSegment], on mapView: MLNMapView) {
        removeRoute(from: mapView)

        guard !segments.isEmpty else { return }

        for (index, segment) in segments.enumerated() {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }

            let polyline = MLNPolylineFeature(coordinates: coords, count: UInt(coords.count))
            let sourceId = "nautical-route-segment-source-\(index)"
            let layerId = "nautical-route-segment-layer-\(index)"

            let source = MLNShapeSource(identifier: sourceId, features: [polyline], options: nil)
            mapView.style?.addSource(source)

            let layer = MLNLineStyleLayer(identifier: layerId, source: source)
            
            let color: UIColor
            switch segment.classification {
            case .safe:
                color = .systemGreen
            case .critical:
                color = .systemOrange
            case .noGo:
                color = .systemRed
            }

            layer.lineColor = NSExpression(forConstantValue: color)
            layer.lineWidth = NSExpression(forConstantValue: 4.0)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            mapView.style?.addLayer(layer)
        }
    }

    static func renderProtectedZones(from geojsonURL: URL, on mapView: MLNMapView) {
        guard let data = try? Data(contentsOf: geojsonURL),
              let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue) else {
            return
        }

        if let existingSource = mapView.style?.source(withIdentifier: "protected-zones-source") as? MLNShapeSource {
            existingSource.shape = shape
        } else {
            let source = MLNShapeSource(identifier: "protected-zones-source", shape: shape, options: nil)
            mapView.style?.addSource(source)

            let fillLayer = MLNFillStyleLayer(identifier: "protected-zones-fill-layer", source: source)
            fillLayer.fillColor = NSExpression(forConstantValue: UIColor.systemRed)
            fillLayer.fillOpacity = NSExpression(forConstantValue: 0.15)
            mapView.style?.addLayer(fillLayer)

            let lineLayer = MLNLineStyleLayer(identifier: "protected-zones-line-layer", source: source)
            lineLayer.lineColor = NSExpression(forConstantValue: UIColor.systemRed)
            lineLayer.lineWidth = NSExpression(forConstantValue: 1.0)
            mapView.style?.addLayer(lineLayer)
        }
    }

    static func removeRoute(from mapView: MLNMapView) {
        if let layer = mapView.style?.layer(withIdentifier: "nautical-route-layer") {
            mapView.style?.removeLayer(layer)
        }
        if let source = mapView.style?.source(withIdentifier: "nautical-route-source") {
            mapView.style?.removeSource(source)
        }

        if let layers = mapView.style?.layers {
            for layer in layers where layer.identifier.hasPrefix("nautical-route-segment-layer-") {
                mapView.style?.removeLayer(layer)
            }
        }
        if let style = mapView.style {
            for index in 0...100 {
                if let source = style.source(withIdentifier: "nautical-route-segment-source-\(index)") {
                    style.removeSource(source)
                }
            }
        }
    }
}
