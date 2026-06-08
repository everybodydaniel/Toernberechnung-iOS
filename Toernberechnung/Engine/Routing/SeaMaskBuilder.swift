import Foundation
import CoreLocation

enum SeaMaskBuilder {

    private static let osmAsset = "east_frisia_osm"
    private static let demoAsset = "east_frisia"
    private static let nordsbefvAsset = "nordsbefv"
    private static let nordsbefvRouteBufferMeters = 250.0
    private static let buoyRadiusMeters = 250.0
    private static let defaultSeaDepthMeters = 5.0

    struct BuildResult {
        let cells: [UInt8]
        let chartDepth: [Int16]
        let buoyPositions: [Float]
    }

    private struct SeamarkPolygon {
        let points: [CLLocationCoordinate2D]
        let seamarkType: String
    }

    private struct BuoyPoint {
        let lat: Double
        let lon: Double
    }

    // MARK: - Build

    static func build() -> BuildResult {
        let n = GridConfig.rows * GridConfig.cols
        var cells = [UInt8](repeating: CellType.openSea.rawValue, count: n)
        let depthScaled = Int16(defaultSeaDepthMeters * Double(SeaMask.depthScale))
        var depth = [Int16](repeating: depthScaled, count: n)

        var fairwayPolys: [SeamarkPolygon] = []
        var harbourPolys: [SeamarkPolygon] = []
        var restrictedPolys: [SeamarkPolygon] = []
        var buoys: [BuoyPoint] = []

        if let data = loadBundledJSON(named: osmAsset, ext: "geojson") {
            parseFeatureCollection(data, fairways: &fairwayPolys, harbours: &harbourPolys, restricted: &restrictedPolys, buoys: &buoys)
            print("[SeaMaskBuilder] OSM: \(fairwayPolys.count) fairway, \(harbourPolys.count) harbour, \(restrictedPolys.count) restricted, \(buoys.count) buoys")
        }

        if let data = loadBundledJSON(named: demoAsset, ext: "geojson") {
            parseDemoLineStringFairways(data, cells: &cells)
        }

        for poly in fairwayPolys {
            rasterizePolygon(poly.points, cells: &cells, value: .fairway, overwriteLand: false)
        }

        for poly in IslandPolygons.all {
            rasterizePolygon(poly, cells: &cells, value: .land, overwriteLand: true)
        }

        for poly in IslandPolygons.waterOverrides {
            rasterizePolygon(poly, cells: &cells, value: .openSea, overwriteLand: true)
        }

        for poly in harbourPolys {
            rasterizePolygon(poly.points, cells: &cells, value: .harbour, overwriteLand: true)
        }

        rasterizePolygon(IslandPolygons.festlandBackstopWangerland, cells: &cells, value: .land, overwriteLand: true)
        rasterizePolygon(IslandPolygons.festlandBackstopHarlesiel, cells: &cells, value: .land, overwriteLand: true)

        stampBuoyProximity(buoys, cells: &cells, radiusMeters: buoyRadiusMeters)

        for poly in restrictedPolys {
            rasterizePolygon(poly.points, cells: &cells, value: .restricted, overwriteLand: false)
        }

        var nordSchutzPolys: [[CLLocationCoordinate2D]] = []
        var nordRouten: [[CLLocationCoordinate2D]] = []

        if let data = loadBundledJSON(named: nordsbefvAsset, ext: "geojson") {
            parseNordSBefVCollection(data, schutzPolys: &nordSchutzPolys, routen: &nordRouten)
            print("[SeaMaskBuilder] NordSBefV: \(nordSchutzPolys.count) Schutzgebiete, \(nordRouten.count) erlaubte Routen")
        }

        for ring in nordSchutzPolys {
            rasterizePolygon(ring, cells: &cells, value: .ruhezone, overwriteLand: false)
        }

        for line in nordRouten {
            stampLineStringBuffer(line, cells: &cells, value: .fairway, bufferMeters: nordsbefvRouteBufferMeters, overwriteRestricted: true)
        }

        for line in IslandPolygons.manualFairwayRoutes {
            stampLineStringBuffer(line, cells: &cells, value: .fairway, bufferMeters: nordsbefvRouteBufferMeters, overwriteRestricted: true, overwriteLand: true)
        }

        var buoyFlat = [Float](repeating: 0, count: buoys.count * 2)
        for (i, b) in buoys.enumerated() {
            buoyFlat[2 * i] = Float(b.lat)
            buoyFlat[2 * i + 1] = Float(b.lon)
        }

        var typeCounts = [Int](repeating: 0, count: CellType.allCases.count)
        for b in cells {
            let idx = Int(b)
            if idx < typeCounts.count { typeCounts[idx] += 1 }
        }
        let distribution = CellType.allCases.map { "\($0)=\(typeCounts[Int($0.rawValue)])" }.joined(separator: ", ")
        print("[SeaMaskBuilder] Distribution: \(distribution)")

        return BuildResult(cells: cells, chartDepth: depth, buoyPositions: buoyFlat)
    }

    // MARK: - Bundle Loading

    private static func loadBundledJSON(named name: String, ext: String) -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - OSM Feature Collection Parsing

    private static func parseFeatureCollection(
        _ json: [String: Any],
        fairways: inout [SeamarkPolygon],
        harbours: inout [SeamarkPolygon],
        restricted: inout [SeamarkPolygon],
        buoys: inout [BuoyPoint]
    ) {
        guard let features = json["features"] as? [[String: Any]] else { return }
        for feature in features {
            parseFeature(feature, fairways: &fairways, harbours: &harbours, restricted: &restricted, buoys: &buoys)
        }
    }

    private static func parseFeature(
        _ feature: [String: Any],
        fairways: inout [SeamarkPolygon],
        harbours: inout [SeamarkPolygon],
        restricted: inout [SeamarkPolygon],
        buoys: inout [BuoyPoint]
    ) {
        guard let properties = feature["properties"] as? [String: Any],
              let seamarkType = properties["seamark:type"] as? String
        else { return }

        guard let geometry = feature["geometry"] as? [String: Any] else { return }
        let geom = parseGeometry(geometry)

        switch seamarkType {
        case "fairway":
            for ring in geom.polygons {
                fairways.append(SeamarkPolygon(points: ring, seamarkType: seamarkType))
            }
        case "harbour", "harbour_basin", "small_craft_facility":
            for ring in geom.polygons {
                harbours.append(SeamarkPolygon(points: ring, seamarkType: seamarkType))
            }
        case "restricted_area":
            for ring in geom.polygons {
                restricted.append(SeamarkPolygon(points: ring, seamarkType: seamarkType))
            }
        case "buoy_lateral", "beacon_lateral":
            if let p = geom.point, GridConfig.inBounds(lat: p.latitude, lon: p.longitude) {
                buoys.append(BuoyPoint(lat: p.latitude, lon: p.longitude))
            }
        default:
            break
        }
    }

    // MARK: - NordSBefV Parsing

    private static func parseNordSBefVCollection(
        _ json: [String: Any],
        schutzPolys: inout [[CLLocationCoordinate2D]],
        routen: inout [[CLLocationCoordinate2D]]
    ) {
        guard let features = json["features"] as? [[String: Any]] else { return }
        for feature in features {
            parseNordSBefVFeature(feature, schutzPolys: &schutzPolys, routen: &routen)
        }
    }

    private static func parseNordSBefVFeature(
        _ feature: [String: Any],
        schutzPolys: inout [[CLLocationCoordinate2D]],
        routen: inout [[CLLocationCoordinate2D]]
    ) {
        let properties = feature["properties"] as? [String: Any]
        let name = (properties?["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let geometry = feature["geometry"] as? [String: Any] else { return }
        let geom = parseGeometry(geometry)

        if name.hasPrefix("Besonderes Schutzgebiet") {
            for ring in geom.polygons where ring.count >= 3 {
                schutzPolys.append(ring)
            }
        } else if (name.hasPrefix("Schutzgebiets-Route") || name.hasPrefix("Schnellfahrkorridor"))
                    && !name.contains("nicht-maschinenangetriebene") {
            if geom.line.count >= 2 {
                routen.append(geom.line)
            }
        }
    }

    // MARK: - Geometry Parsing

    private struct ParsedGeometry {
        var point: CLLocationCoordinate2D?
        var polygons: [[CLLocationCoordinate2D]] = []
        var line: [CLLocationCoordinate2D] = []
    }

    private static func parseGeometry(_ geometry: [String: Any]) -> ParsedGeometry {
        guard let type = geometry["type"] as? String,
              let coordinates = geometry["coordinates"]
        else { return ParsedGeometry() }

        switch type {
        case "Point":
            guard let coords = coordinates as? [Double], coords.count >= 2 else { return ParsedGeometry() }
            return ParsedGeometry(point: CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0]))

        case "Polygon":
            guard let rings = coordinates as? [[[Double]]],
                  let outer = rings.first
            else { return ParsedGeometry() }
            let pts = outer.compactMap { xy -> CLLocationCoordinate2D? in
                guard xy.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: xy[1], longitude: xy[0])
            }
            guard pts.count >= 3 else { return ParsedGeometry() }
            return ParsedGeometry(polygons: [pts])

        case "LineString":
            guard let coords = coordinates as? [[Double]] else { return ParsedGeometry() }
            let pts = coords.compactMap { xy -> CLLocationCoordinate2D? in
                guard xy.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: xy[1], longitude: xy[0])
            }
            guard pts.count >= 2 else { return ParsedGeometry() }
            return ParsedGeometry(line: pts)

        case "MultiLineString":
            guard let lines = coordinates as? [[[Double]]] else { return ParsedGeometry() }
            let pts = lines.flatMap { line in
                line.compactMap { xy -> CLLocationCoordinate2D? in
                    guard xy.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: xy[1], longitude: xy[0])
                }
            }
            guard pts.count >= 2 else { return ParsedGeometry() }
            return ParsedGeometry(line: pts)

        case "MultiPolygon":
            guard let polys = coordinates as? [[[[Double]]]] else { return ParsedGeometry() }
            let rings: [[CLLocationCoordinate2D]] = polys.compactMap { polyRings in
                guard let outer = polyRings.first else { return nil }
                let pts = outer.compactMap { xy -> CLLocationCoordinate2D? in
                    guard xy.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: xy[1], longitude: xy[0])
                }
                return pts.count >= 3 ? pts : nil
            }
            return ParsedGeometry(polygons: rings)

        default:
            return ParsedGeometry()
        }
    }

    // MARK: - Demo LineString Fairways

    private static func parseDemoLineStringFairways(_ json: [String: Any], cells: inout [UInt8]) {
        guard let features = json["features"] as? [[String: Any]] else { return }
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String,
                  type == "LineString",
                  let coords = geometry["coordinates"] as? [[Double]]
            else { continue }

            let pts = coords.compactMap { xy -> CLLocationCoordinate2D? in
                guard xy.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: xy[1], longitude: xy[0])
            }
            if pts.count >= 2 {
                stampLineStringBuffer(pts, cells: &cells, value: .fairway, bufferMeters: 200.0)
            }
        }
    }

    // MARK: - Rasterization

    private static func rasterizePolygon(
        _ polygon: [CLLocationCoordinate2D],
        cells: inout [UInt8],
        value: CellType,
        overwriteLand: Bool
    ) {
        guard polygon.count >= 3 else { return }

        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        for p in polygon {
            if p.latitude < minLat { minLat = p.latitude }
            if p.latitude > maxLat { maxLat = p.latitude }
            if p.longitude < minLon { minLon = p.longitude }
            if p.longitude > maxLon { maxLon = p.longitude }
        }

        guard maxLat >= GridConfig.minLat, minLat <= GridConfig.maxLat,
              maxLon >= GridConfig.minLon, minLon <= GridConfig.maxLon else { return }

        let rowMin = GridConfig.latToRow(minLat)
        let rowMax = GridConfig.latToRow(maxLat)
        let valByte = value.rawValue
        let landByte = CellType.land.rawValue

        let n = polygon.count
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            ys[i] = (polygon[i].latitude - GridConfig.minLat) / GridConfig.latStep
            xs[i] = (polygon[i].longitude - GridConfig.minLon) / GridConfig.lonStep
        }

        var xIntersections = [Double](repeating: 0, count: n)
        for row in rowMin...rowMax {
            let y = Double(row) + 0.5
            var ixCount = 0

            for i in 0..<n {
                let j = i == 0 ? n - 1 : i - 1
                let yi = ys[i]
                let yj = ys[j]
                if (yi > y) != (yj > y) {
                    let t = (y - yi) / (yj - yi)
                    let xx = xs[i] + t * (xs[j] - xs[i])
                    if ixCount < xIntersections.count {
                        xIntersections[ixCount] = xx
                        ixCount += 1
                    }
                }
            }

            if ixCount >= 2 {
                for a in 0..<ixCount - 1 {
                    for b in (a + 1)..<ixCount {
                        if xIntersections[a] > xIntersections[b] {
                            let tmp = xIntersections[a]
                            xIntersections[a] = xIntersections[b]
                            xIntersections[b] = tmp
                        }
                    }
                }
            }

            var k = 0
            while k + 1 < ixCount {
                let cStart = max(0, Int(xIntersections[k]))
                let cEnd = min(GridConfig.cols - 1, Int(xIntersections[k + 1]))
                if cStart <= cEnd {
                    let baseIdx = row * GridConfig.cols
                    for c in cStart...cEnd {
                        let idx = baseIdx + c
                        if !overwriteLand && cells[idx] == landByte { continue }
                        cells[idx] = valByte
                    }
                }
                k += 2
            }
        }
    }

    // MARK: - Buoy Proximity Stamping

    private static func stampBuoyProximity(
        _ buoys: [BuoyPoint],
        cells: inout [UInt8],
        radiusMeters: Double
    ) {
        guard !buoys.isEmpty else { return }
        let openSeaByte = CellType.openSea.rawValue
        let wattByte = CellType.wattfahrwasser.rawValue

        let metersPerRow = GridConfig.latStep * 111_320.0
        let midLatRad = (GridConfig.minLat + GridConfig.maxLat) / 2.0 * .pi / 180.0
        let metersPerCol = GridConfig.lonStep * 111_320.0 * cos(midLatRad)
        let rowRadius = max(1, Int((radiusMeters / metersPerRow).rounded()))
        let colRadius = max(1, Int((radiusMeters / metersPerCol).rounded()))
        let radiusSquared = radiusMeters * radiusMeters

        for b in buoys {
            guard GridConfig.inBounds(lat: b.lat, lon: b.lon) else { continue }
            let r0 = GridConfig.latToRow(b.lat)
            let c0 = GridConfig.lonToCol(b.lon)
            let rMin = max(0, r0 - rowRadius)
            let rMax = min(GridConfig.rows - 1, r0 + rowRadius)
            let cMin = max(0, c0 - colRadius)
            let cMax = min(GridConfig.cols - 1, c0 + colRadius)

            for r in rMin...rMax {
                let rowLat = GridConfig.rowToLat(r)
                let baseIdx = r * GridConfig.cols
                for c in cMin...cMax {
                    let idx = baseIdx + c
                    guard cells[idx] == openSeaByte else { continue }
                    let colLon = GridConfig.colToLon(c)
                    let d = GridConfig.approxMeters(lat1: b.lat, lon1: b.lon, lat2: rowLat, lon2: colLon)
                    if d * d <= radiusSquared {
                        cells[idx] = wattByte
                    }
                }
            }
        }
    }

    // MARK: - LineString Buffer Stamping

    private static func stampLineStringBuffer(
        _ line: [CLLocationCoordinate2D],
        cells: inout [UInt8],
        value: CellType,
        bufferMeters: Double,
        overwriteRestricted: Bool = false,
        overwriteLand: Bool = false
    ) {
        guard line.count >= 2 else { return }
        let openSeaByte = CellType.openSea.rawValue
        let landByte = CellType.land.rawValue
        let restrictedByte = CellType.restricted.rawValue
        let ruhezoneByte = CellType.ruhezone.rawValue
        let wattByte = CellType.wattfahrwasser.rawValue
        let valByte = value.rawValue

        let metersPerRow = GridConfig.latStep * 111_320.0
        let midLatRad = (GridConfig.minLat + GridConfig.maxLat) / 2.0 * .pi / 180.0
        let metersPerCol = GridConfig.lonStep * 111_320.0 * cos(midLatRad)
        let rowRadius = max(1, Int((bufferMeters / metersPerRow).rounded()))
        let colRadius = max(1, Int((bufferMeters / metersPerCol).rounded()))
        let bufferSquared = bufferMeters * bufferMeters

        for i in 0..<(line.count - 1) {
            let a = line[i]
            let b = line[i + 1]
            let segLen = GridConfig.approxMeters(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
            let steps = max(2, Int(segLen / 80.0))

            for s in 0...steps {
                let t = Double(s) / Double(steps)
                let lat = a.latitude + (b.latitude - a.latitude) * t
                let lon = a.longitude + (b.longitude - a.longitude) * t
                guard GridConfig.inBounds(lat: lat, lon: lon) else { continue }

                let r0 = GridConfig.latToRow(lat)
                let c0 = GridConfig.lonToCol(lon)
                let rMin = max(0, r0 - rowRadius)
                let rMax = min(GridConfig.rows - 1, r0 + rowRadius)
                let cMin = max(0, c0 - colRadius)
                let cMax = min(GridConfig.cols - 1, c0 + colRadius)

                for r in rMin...rMax {
                    let rowLat = GridConfig.rowToLat(r)
                    let baseIdx = r * GridConfig.cols
                    for c in cMin...cMax {
                        let idx = baseIdx + c
                        let cur = cells[idx]
                        if cur == landByte && !overwriteLand { continue }

                        let allowed = cur == openSeaByte
                            || cur == wattByte
                            || cur == ruhezoneByte
                            || (overwriteLand && cur == landByte)
                            || (overwriteRestricted && cur == restrictedByte)
                        guard allowed else { continue }

                        let colLon = GridConfig.colToLon(c)
                        let d = GridConfig.approxMeters(lat1: lat, lon1: lon, lat2: rowLat, lon2: colLon)
                        if d * d <= bufferSquared {
                            cells[idx] = valByte
                        }
                    }
                }
            }
        }
    }
}
