import SwiftUI
import MapKit
import CoreLocation
import UIKit

// MARK: - CompactMapView
//
// Two-tile-overlay nautical chart:
//   1. OSM standard raster as the base map (`canReplaceMapContent=true`)
//      — wipes Apple's basemap so the look stays consistent with paper
//      sea charts and removes Apple POIs/labels we don't want.
//   2. OpenSeaMap seamark tiles (transparent PNG) painted on top so the
//      buoys, depth contours and harbour symbols sit above the OSM base.
//
// The planned-route polyline is built from the FULL list of
// `routePlan.waypoints` — every Dijkstra node, in order. No node is
// skipped. The chain is smoothed once with Chaikin (`NauticalRouter.smooth`).
//
// Protected zones from the Befahrensverordnung Nationalpark are drawn
// as red semi-transparent polygons so the skipper can see why the route
// detours; the same polygons are what the router avoids.
//
// OSM tile usage: this consumer-style raster source is rate-limited by
// the OSMF and only acceptable for low-volume apps. Switch to a paid
// tile host (MapTiler, Stadia) once traffic warrants it.

struct CompactMapView: UIViewRepresentable {

    let zoomLevel: Double
    let start: HarbourOption
    let destination: HarbourOption
    var routePlan: RoutePlan?
    var waypointResults: [WaypointCalculationResult]?
    /// `true` while an `ActiveVoyageManager` is recording. Switches the map
    /// into a "follow me" state with heading-up rotation and shows the
    /// user-location dot.
    var voyageActive: Bool = false
    /// Real-time breadcrumb trail of the currently recording voyage.
    /// Drawn on top of the planned polyline as a thin orange line.
    var breadcrumbCoordinates: [CLLocationCoordinate2D] = []

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.showsBuildings = false
        map.pointOfInterestFilter = .excludingAll
        map.isRotateEnabled = true
        map.isPitchEnabled = false

        Self.installBaseAndSeamarkOverlays(on: map)
        Self.installProtectedZoneOverlays(on: map)

        // Initial center.
        let center = CLLocationCoordinate2D(
            latitude: (start.latitude + destination.latitude) / 2,
            longitude: (start.longitude + destination.longitude) / 2
        )
        let span = MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.9)
        map.setRegion(MKCoordinateRegion(center: center, span: span), animated: false)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(
            map: map,
            start: start,
            destination: destination,
            routePlan: routePlan,
            waypointResults: waypointResults,
            voyageActive: voyageActive,
            breadcrumbCoordinates: breadcrumbCoordinates
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Tile + zone setup (shared by makeUIView and re-add path)

    fileprivate static func installBaseAndSeamarkOverlays(on map: MKMapView) {
        // OSM standard raster — replaces Apple basemap so labels / POIs
        // disappear and the look matches OpenSeaMap on the web.
        let base = MKTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        base.canReplaceMapContent = true
        base.maximumZ = 19
        base.minimumZ = 0
        map.addOverlay(base, level: .aboveRoads)

        // OpenSeaMap seamark symbols on top.
        let seamark = MKTileOverlay(urlTemplate: "https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png")
        seamark.canReplaceMapContent = false
        seamark.maximumZ = 18
        seamark.minimumZ = 0
        map.addOverlay(seamark, level: .aboveLabels)
    }

    fileprivate static func installProtectedZoneOverlays(on map: MKMapView) {
        for zone in ProtectedZoneCatalog.zones {
            var coords = zone.outerRing
            let polygon = MKPolygon(coordinates: &coords, count: coords.count)
            polygon.title = zone.name
            polygon.subtitle = zone.seasonal ? "seasonal" : "year_round"
            // Above roads (so basemap is visible through the fill) but
            // below labels (so the route polyline drawn .aboveLabels reads
            // crisply over the zone).
            map.addOverlay(polygon, level: .aboveRoads)
        }
    }

    // MARK: - Coordinator (MKMapViewDelegate)

    final class Coordinator: NSObject, MKMapViewDelegate {

        private var lastRouteKey: String = ""

        /// Retained so a SeaMask-ready notification can re-run the last draw.
        private weak var lastMap: MKMapView?
        private var lastInputs: DrawInputs?

        private struct DrawInputs {
            let start: HarbourOption
            let destination: HarbourOption
            let routePlan: RoutePlan?
            let waypointResults: [WaypointCalculationResult]?
            let voyageActive: Bool
            let breadcrumbCoordinates: [CLLocationCoordinate2D]
        }

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(seaMaskDidBecomeReady),
                name: .seaMaskDidBecomeReady,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Re-runs the most recent draw once the SeaMask finishes building.
        /// Until the mask is ready `calculateMultiStopRoute` returns straight
        /// `[start, end]` fallbacks; this redraw replaces them with the real
        /// A* route (mirrors the reactive `SeaMask.isReady` redraw).
        @objc private func seaMaskDidBecomeReady() {
            // Posted on the main thread from `NauticalRouteService.buildSeaMask`.
            MainActor.assumeIsolated {
                guard let map = lastMap, let inputs = lastInputs else { return }
                lastRouteKey = "" // force the route polyline to rebuild
                update(
                    map: map,
                    start: inputs.start,
                    destination: inputs.destination,
                    routePlan: inputs.routePlan,
                    waypointResults: inputs.waypointResults,
                    voyageActive: inputs.voyageActive,
                    breadcrumbCoordinates: inputs.breadcrumbCoordinates
                )
            }
        }

        // MARK: Renderer

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                renderer.alpha = 1.0
                return renderer
            }
            if let polygon = overlay as? MKPolygon {
                // Protected zones — red fill so the no-go area is visible at
                // a glance; dashed outline for "Allgemeines Schutzgebiet"
                // (saisonal), solid for ganzjährige Sperren.
                let renderer = MKPolygonRenderer(polygon: polygon)
                let isSeasonal = polygon.subtitle == "seasonal"
                renderer.fillColor = UIColor.systemRed.withAlphaComponent(isSeasonal ? 0.10 : 0.18)
                renderer.strokeColor = UIColor.systemRed.withAlphaComponent(0.85)
                renderer.lineWidth = 1
                if isSeasonal { renderer.lineDashPattern = [4, 3] }
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                // The segment status is shuttled through the polyline's
                // `title` (MKPolyline conforms to MKAnnotation) because
                // MKPolyline cannot be reliably subclassed in Swift.
                if polyline.title == "breadcrumb" {
                    renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.85)
                    renderer.lineWidth = 3
                    renderer.lineDashPattern = [2, 4] // dashed track marks
                } else {
                    let status: WaypointStatus = polyline.title.flatMap(WaypointStatus.init(rawValue:)) ?? .go
                    renderer.strokeColor = Self.routeUIColor(for: status)
                    renderer.lineWidth = 5
                }
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // MARK: Annotation Views

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            guard let pin = annotation as? RoutePinAnnotation else { return nil }

            let reuseID = "pin-\(pin.kind.rawValue)"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                ?? MKAnnotationView(annotation: pin, reuseIdentifier: reuseID)
            view.image = Self.markerImage(for: pin.kind, status: pin.status)
            view.canShowCallout = true
            view.centerOffset = CGPoint(x: 0, y: -view.image!.size.height / 2)
            return view
        }

        // MARK: Update entrypoint

        @MainActor
        func update(
            map: MKMapView,
            start: HarbourOption,
            destination: HarbourOption,
            routePlan: RoutePlan?,
            waypointResults: [WaypointCalculationResult]?,
            voyageActive: Bool,
            breadcrumbCoordinates: [CLLocationCoordinate2D]
        ) {
            // Remember the latest inputs so a SeaMask-ready notification can
            // redraw the route once the mask finishes building.
            lastMap = map
            lastInputs = DrawInputs(
                start: start,
                destination: destination,
                routePlan: routePlan,
                waypointResults: waypointResults,
                voyageActive: voyageActive,
                breadcrumbCoordinates: breadcrumbCoordinates
            )

            // Apply voyage-driven map state on every update so it picks up
            // mid-session transitions instantly.
            map.showsUserLocation = voyageActive
            let targetMode: MKUserTrackingMode = voyageActive ? .followWithHeading : .none
            if map.userTrackingMode != targetMode {
                map.setUserTrackingMode(targetMode, animated: true)
            }

            // The breadcrumb chunk grows monotonically while a voyage is
            // active. Re-draw the breadcrumb polyline every refresh; bail
            // out of the heavier route redraw only when nothing changed.
            let wpKey = routePlan?.waypoints
                .map { "\($0.name):\($0.latitude ?? 0):\($0.longitude ?? 0)" }
                .joined(separator: "|") ?? ""
            let resultKey = waypointResults?
                .map { "\($0.waypoint.name):\($0.status.rawValue)" }
                .joined(separator: "|") ?? ""
            let breadcrumbKey = "bc:\(breadcrumbCoordinates.count)"
            let key = "\(start.id)|\(destination.id)|\(wpKey)|\(resultKey)|voyage:\(voyageActive)|\(breadcrumbKey)|mask:\(SeaMask.shared.isReady)"
            guard key != lastRouteKey else { return }
            lastRouteKey = key

            // Wipe previous polylines + annotations (keep the tile + zone overlays).
            let tileOverlays = map.overlays.compactMap { $0 as? MKTileOverlay }
            let polylines    = map.overlays.compactMap { $0 as? MKPolyline }
            map.removeOverlays(polylines)
            map.removeAnnotations(map.annotations)

            // Re-add tile overlays only if MapKit dropped them (rare).
            if tileOverlays.count < 2 {
                map.removeOverlays(tileOverlays)
                CompactMapView.installBaseAndSeamarkOverlays(on: map)
            }
            // Ensure the protected-zone polygons are present (they sit
            // beneath everything except the basemap).
            let hasZones = map.overlays.contains { $0 is MKPolygon }
            if !hasZones {
                CompactMapView.installProtectedZoneOverlays(on: map)
            }

            // 1. Build the route polyline from the FULL Dijkstra node list.
            let routeCoords = Self.routeCoordinates(
                for: routePlan,
                start: start,
                destination: destination
            )
            guard !routeCoords.isEmpty else { return }

            // 2. Segment polyline by per-WP status so each leg can carry a
            //    different colour (green/orange/red). Falls back to a single
            //    `.go` polyline when no per-WP status is available.
            let segments = Self.colouredSegments(
                routeCoords: routeCoords,
                routePlan: routePlan,
                waypointResults: waypointResults
            )
            for segment in segments {
                var coords = segment.coords
                let line = MKPolyline(coordinates: &coords, count: coords.count)
                line.title = segment.status.rawValue
                map.addOverlay(line, level: .aboveLabels)
            }

            // 3. Breadcrumb trail (actual sailed track).
            if breadcrumbCoordinates.count > 1 {
                var crumbs = breadcrumbCoordinates
                let trail = MKPolyline(coordinates: &crumbs, count: crumbs.count)
                trail.title = "breadcrumb"
                map.addOverlay(trail, level: .aboveLabels)
            }

            // 4. Pins — only user-selected harbours.
            map.addAnnotations(Self.harbourPins(
                start: start,
                destination: destination,
                routePlan: routePlan,
                waypointResults: waypointResults
            ))

            // 5. Fit visible region around the route — only when NOT in
            //    follow-me mode (the tracking mode handles centering for
            //    us during the voyage and a manual setVisibleMapRect call
            //    would fight against it).
            if !voyageActive {
                let polyline = MKPolyline(coordinates: routeCoords, count: routeCoords.count)
                let padding = UIEdgeInsets(top: 40, left: 28, bottom: 40, right: 28)
                map.setVisibleMapRect(
                    polyline.boundingMapRect.insetBy(dx: -2000, dy: -2000),
                    edgePadding: padding,
                    animated: true
                )
            }
        }

        // MARK: - Route coordinates

        /// Builds the drawn polyline EXACTLY like the original implementation: the user's
        /// harbours (start, intermediate stops, destination) are routed through
        /// `NauticalRouteService` — grid A* over the SeaMask, Douglas-Peucker +
        /// Chaikin smoothing and land-validation against the mask — and the
        /// resulting coordinates are drawn verbatim.
        ///
        /// Crucially, NO further Douglas-Peucker simplification or Chaikin pass
        /// is applied on top. The previous chain
        /// (`NauticalRouter.route` → `simplify(epsilon: 100)` → `smooth(2×)`)
        /// re-straightened the carefully land-avoiding path and cut corners
        /// back across land / Ruhezonen / Schutzgebiete.
        private static func routeCoordinates(
            for routePlan: RoutePlan?,
            start: HarbourOption,
            destination: HarbourOption
        ) -> [CLLocationCoordinate2D] {
            // Ordered list of USER stops only. The auto-inserted "Fahrwasser"
            // waypoints from RouteExpander are NOT used for the drawn geometry —
            // the v2 router re-derives the fairway path itself, identically to
            // See `NauticalRouterV2.calculateMultiStopRoute`.
            var stops: [CLLocationCoordinate2D] = [
                CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
            ]
            if let routePlan {
                let intermediates = routePlan.waypoints.dropFirst().dropLast().filter {
                    $0.category != "Fahrwasser"
                }
                for wp in intermediates {
                    guard let lat = wp.latitude, let lon = wp.longitude else { continue }
                    stops.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
            }
            stops.append(CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude))

            return NauticalRouteService.shared.calculateMultiStopRoute(stops: stops).coordinates
        }

        // MARK: - Coloured segments
        //
        // Walks the smoothed coordinate list and switches polyline colour at
        // each user-WP boundary. Because Chaikin doubles the point count
        // every iteration we project each user WP onto the nearest smoothed
        // point.

        private struct Segment {
            var coords: [CLLocationCoordinate2D]
            var status: WaypointStatus
        }

        private static func colouredSegments(
            routeCoords: [CLLocationCoordinate2D],
            routePlan: RoutePlan?,
            waypointResults: [WaypointCalculationResult]?
        ) -> [Segment] {
            guard let waypointResults, !waypointResults.isEmpty else {
                return [Segment(coords: routeCoords, status: .go)]
            }
            // Project each waypoint onto the closest index in routeCoords.
            let wpCoordsWithStatus: [(CLLocationCoordinate2D, WaypointStatus)] =
                waypointResults.compactMap { wp in
                    guard let lat = wp.waypoint.latitude, let lon = wp.waypoint.longitude
                    else { return nil }
                    return (CLLocationCoordinate2D(latitude: lat, longitude: lon), wp.status)
                }
            guard wpCoordsWithStatus.count >= 2 else {
                return [Segment(coords: routeCoords, status: .go)]
            }
            let breakpoints: [(index: Int, status: WaypointStatus)] = wpCoordsWithStatus.map { coord, status in
                let idx = routeCoords.indices.min { lhs, rhs in
                    distSq(routeCoords[lhs], coord) < distSq(routeCoords[rhs], coord)
                } ?? 0
                return (idx, status)
            }

            var segments: [Segment] = []
            for i in 1 ..< breakpoints.count {
                let lo = min(breakpoints[i - 1].index, breakpoints[i].index)
                let hi = max(breakpoints[i - 1].index, breakpoints[i].index)
                guard lo != hi, hi < routeCoords.count else { continue }
                let slice = Array(routeCoords[lo ... hi])
                segments.append(Segment(coords: slice, status: breakpoints[i].status))
            }
            return segments.isEmpty
                ? [Segment(coords: routeCoords, status: .go)]
                : segments
        }

        // MARK: - Pins

        private static func harbourPins(
            start: HarbourOption,
            destination: HarbourOption,
            routePlan: RoutePlan?,
            waypointResults: [WaypointCalculationResult]?
        ) -> [RoutePinAnnotation] {
            var pins: [RoutePinAnnotation] = []
            pins.append(RoutePinAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude),
                title: "Start: \(start.name)",
                kind: .start, status: .go
            ))
            pins.append(RoutePinAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude),
                title: "Ziel: \(destination.name)",
                kind: .destination, status: .go
            ))

            guard let routePlan, routePlan.waypoints.count > 2 else { return pins }
            // Drop start + destination + auto-inserted fairway WPs.
            let intermediates = routePlan.waypoints.dropFirst().dropLast().filter {
                $0.category != "Fahrwasser"
            }
            let statusByID = Dictionary(
                uniqueKeysWithValues: (waypointResults ?? []).map { ($0.waypoint.id, $0.status) }
            )
            for wp in intermediates {
                guard let lat = wp.latitude, let lon = wp.longitude else { continue }
                pins.append(RoutePinAnnotation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    title: wp.name,
                    kind: .stop,
                    status: statusByID[wp.id] ?? .incomplete
                ))
            }
            return pins
        }

        // MARK: - Drawing helpers

        private static func distSq(
            _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D
        ) -> Double {
            let dLat = a.latitude - b.latitude
            let dLon = (a.longitude - b.longitude) * cos(a.latitude * .pi / 180)
            return dLat * dLat + dLon * dLon
        }

        private static func routeUIColor(for status: WaypointStatus) -> UIColor {
            switch status {
            case .go:         return UIColor.systemGreen
            case .warning:    return UIColor.systemOrange
            case .noGo:       return UIColor.systemRed
            case .incomplete: return UIColor.systemGray
            case .invalid:    return UIColor.systemRed
            }
        }

        private static func markerImage(for kind: RoutePinAnnotation.Kind, status: WaypointStatus) -> UIImage {
            let baseColor: UIColor
            switch kind {
            case .start:       baseColor = .systemGreen
            case .destination: baseColor = .systemBlue
            case .stop:        baseColor = routeUIColor(for: status)
            }
            let size = kind == .stop
                ? CGSize(width: 20, height: 24)
                : CGSize(width: 28, height: 34)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { ctx in
                baseColor.setFill()
                if kind == .stop {
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
        }
    }
}

// MARK: - Route Pin Annotation

final class RoutePinAnnotation: NSObject, MKAnnotation {
    enum Kind: String { case start, destination, stop }

    let coordinate: CLLocationCoordinate2D
    let title: String?
    let kind: Kind
    let status: WaypointStatus

    init(coordinate: CLLocationCoordinate2D, title: String?, kind: Kind, status: WaypointStatus) {
        self.coordinate = coordinate
        self.title = title
        self.kind = kind
        self.status = status
    }
}
