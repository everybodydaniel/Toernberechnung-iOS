import Foundation
import CoreLocation

enum SeaRoutePlanner {
    private struct SeamarkGraph {
        let nodes: [Int: CLLocationCoordinate2D]
        let edges: [Int: [Int]]
    }

    private struct OverpassResponse: Decodable {
        let elements: [Element]

        struct Element: Decodable {
            let type: String
            let id: Int64
            let tags: [String: String]?
            let geometry: [Geometry]?
        }

        struct Geometry: Decodable {
            let lat: Double
            let lon: Double
        }
    }

    private struct Node {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let links: [String]
    }

    static var nauticalStyleURL: URL {
        // MapLibre erwartet eine Style-Datei. Der JSON-String wird dafür temporär als lokale Datei bereitgestellt.
        let style = """
        {
          "version": 8,
          "sources": {
            "osm": {
              "type": "raster",
              "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
              "tileSize": 256,
              "attribution": "OpenStreetMap contributors"
            },
            "openseamap": {
              "type": "raster",
              "tiles": ["https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png"],
              "tileSize": 256,
              "attribution": "OpenSeaMap"
            }
          },
          "layers": [
            {
              "id": "osm",
              "type": "raster",
              "source": "osm",
              "minzoom": 0,
              "maxzoom": 19
            },
            {
              "id": "openseamap",
              "type": "raster",
              "source": "openseamap",
              "minzoom": 0,
              "maxzoom": 18
            }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toern-nautical-style.json")
        try? style.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    static func route(from start: HarbourOption, to destination: HarbourOption) -> [CLLocationCoordinate2D] {
        guard start.id != destination.id else {
            return [mapCoordinate(for: start)]
        }

        guard let startNode = harbourNodeIDs[start.id],
              let destinationNode = harbourNodeIDs[destination.id],
              let nodePath = shortestPath(from: startNode, to: destinationNode) else {
            return [mapCoordinate(for: start), mapCoordinate(for: destination)]
        }

        return deduplicated(
            [mapCoordinate(for: start)]
                + nodePath.compactMap { nodes[$0]?.coordinate }
                + [mapCoordinate(for: destination)]
        )
    }

    static func routeFromSeamarks(from start: HarbourOption, to destination: HarbourOption) async -> [CLLocationCoordinate2D]? {
        guard let graph = await loadSeamarkGraph() else { return nil }
        let startCoordinate = mapCoordinate(for: start)
        let destinationCoordinate = mapCoordinate(for: destination)
        guard let startNode = nearestNode(to: startCoordinate, in: graph),
              let destinationNode = nearestNode(to: destinationCoordinate, in: graph),
              let nodePath = shortestPath(from: startNode, to: destinationNode, in: graph) else {
            return nil
        }

        let seamarkRoute = nodePath.compactMap { graph.nodes[$0] }
        guard seamarkRoute.count > 1 else { return nil }
        return deduplicated([startCoordinate] + seamarkRoute + [destinationCoordinate])
    }

    static func distanceNM(from start: HarbourOption, to destination: HarbourOption) -> Double {
        let points = route(from: start, to: destination)
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + distanceNM(from: pair.0, to: pair.1)
        }
    }

    static func mapCoordinate(for harbour: HarbourOption) -> CLLocationCoordinate2D {
        harbourMapCoordinates[harbour.id] ?? CLLocationCoordinate2D(latitude: harbour.latitude, longitude: harbour.longitude)
    }

    private static let harbourMapCoordinates: [String: CLLocationCoordinate2D] = [
        "borkum_harbor": .init(latitude: 53.5650, longitude: 6.7650),
        "emden_harbor": .init(latitude: 53.3372, longitude: 7.1892),
        "juist_harbor": .init(latitude: 53.6660, longitude: 6.9800),
        "norderney_harbor": .init(latitude: 53.6840, longitude: 7.1550),
        "baltrum_harbor": .init(latitude: 53.7070, longitude: 7.3650),
        "langeoog_harbor": .init(latitude: 53.7320, longitude: 7.5000),
        "spiekeroog_harbor": .init(latitude: 53.7520, longitude: 7.6900),
        "wangerooge_harbor": .init(latitude: 53.7620, longitude: 7.8700)
    ]

    private static let harbourNodeIDs: [String: String] = [
        "borkum_harbor": "borkum_harbor",
        "emden_harbor": "emden_harbor",
        "juist_harbor": "juist_harbor",
        "norderney_harbor": "norderney_harbor",
        "baltrum_harbor": "baltrum_harbor",
        "langeoog_harbor": "langeoog_harbor",
        "spiekeroog_harbor": "spiekeroog_harbor",
        "wangerooge_harbor": "wangerooge_harbor"
    ]

    private static let nodes: [String: Node] = {
        let all: [Node] = [
            .init(id: "emden_harbor", coordinate: .init(latitude: 53.3372, longitude: 7.1892), links: ["emden_outer"]),
            .init(id: "emden_outer", coordinate: .init(latitude: 53.3375, longitude: 7.1705), links: ["emden_harbor", "emden_ems_east"]),
            .init(id: "emden_ems_east", coordinate: .init(latitude: 53.3340, longitude: 7.1200), links: ["emden_outer", "emden_ems_west"]),
            .init(id: "emden_ems_west", coordinate: .init(latitude: 53.3320, longitude: 7.0600), links: ["emden_ems_east", "knock_reach"]),
            .init(id: "knock_reach", coordinate: .init(latitude: 53.3420, longitude: 6.9950), links: ["emden_ems_west", "ems_fairway_west"]),
            .init(id: "ems_fairway_west", coordinate: .init(latitude: 53.3850, longitude: 6.9150), links: ["knock_reach", "ems_outer"]),
            .init(id: "ems_outer", coordinate: .init(latitude: 53.5050, longitude: 6.8000), links: ["ems_fairway_west", "borkum_reede", "osterems"]),

            .init(id: "borkum_harbor", coordinate: .init(latitude: 53.5650, longitude: 6.7650), links: ["borkum_reede"]),
            .init(id: "borkum_reede", coordinate: .init(latitude: 53.5570, longitude: 6.7680), links: ["borkum_harbor", "ems_outer", "osterems"]),
            .init(id: "osterems", coordinate: .init(latitude: 53.5550, longitude: 6.8550), links: ["ems_outer", "borkum_reede", "osterems_north"]),
            .init(id: "osterems_north", coordinate: .init(latitude: 53.5850, longitude: 6.8900), links: ["osterems", "memmert_west"]),
            .init(id: "memmert_west", coordinate: .init(latitude: 53.6100, longitude: 6.9400), links: ["osterems_north", "juist_south_west"]),

            .init(id: "juist_harbor", coordinate: .init(latitude: 53.6660, longitude: 6.9800), links: ["juist_west"]),
            .init(id: "juist_west", coordinate: .init(latitude: 53.6630, longitude: 6.9850), links: ["juist_south_west", "juist_harbor", "juist_south_east"]),
            .init(id: "juist_south_west", coordinate: .init(latitude: 53.6350, longitude: 6.9850), links: ["memmert_west", "juist_west", "juist_south_east"]),
            .init(id: "juist_south_east", coordinate: .init(latitude: 53.6450, longitude: 7.0400), links: ["juist_south_west", "juist_west", "norderney_watt_west"]),
            .init(id: "norderney_watt_west", coordinate: .init(latitude: 53.6550, longitude: 7.0800), links: ["juist_south_east", "memmert_watt"]),
            .init(id: "memmert_watt", coordinate: .init(latitude: 53.6650, longitude: 7.1200), links: ["norderney_watt_west", "norderney_south_west"]),

            .init(id: "norderney_harbor", coordinate: .init(latitude: 53.6840, longitude: 7.1550), links: ["norderney_south_west"]),
            .init(id: "norderney_south_west", coordinate: .init(latitude: 53.6840, longitude: 7.1450), links: ["memmert_watt", "norderney_harbor", "norderney_east"]),
            .init(id: "norderney_east", coordinate: .init(latitude: 53.6900, longitude: 7.2500), links: ["norderney_south_west", "baltrum_west"]),

            .init(id: "baltrum_harbor", coordinate: .init(latitude: 53.7070, longitude: 7.3650), links: ["baltrum_south"]),
            .init(id: "baltrum_west", coordinate: .init(latitude: 53.7040, longitude: 7.3100), links: ["norderney_east", "baltrum_south"]),
            .init(id: "baltrum_south", coordinate: .init(latitude: 53.7160, longitude: 7.3500), links: ["baltrum_west", "baltrum_harbor", "baltrum_east"]),
            .init(id: "baltrum_east", coordinate: .init(latitude: 53.7140, longitude: 7.4250), links: ["baltrum_south", "langeoog_west"]),

            .init(id: "langeoog_harbor", coordinate: .init(latitude: 53.7320, longitude: 7.5000), links: ["langeoog_west"]),
            .init(id: "langeoog_west", coordinate: .init(latitude: 53.7200, longitude: 7.4700), links: ["baltrum_east", "langeoog_harbor", "langeoog_east"]),
            .init(id: "langeoog_east", coordinate: .init(latitude: 53.7250, longitude: 7.5550), links: ["langeoog_west", "spiekeroog_west"]),

            .init(id: "spiekeroog_harbor", coordinate: .init(latitude: 53.7520, longitude: 7.6900), links: ["spiekeroog_south"]),
            .init(id: "spiekeroog_west", coordinate: .init(latitude: 53.7420, longitude: 7.6400), links: ["langeoog_east", "spiekeroog_south"]),
            .init(id: "spiekeroog_south", coordinate: .init(latitude: 53.7550, longitude: 7.6850), links: ["spiekeroog_west", "spiekeroog_harbor", "spiekeroog_east"]),
            .init(id: "spiekeroog_east", coordinate: .init(latitude: 53.7550, longitude: 7.7450), links: ["spiekeroog_south", "wangerooge_west"]),

            .init(id: "wangerooge_harbor", coordinate: .init(latitude: 53.7620, longitude: 7.8700), links: ["wangerooge_south"]),
            .init(id: "wangerooge_west", coordinate: .init(latitude: 53.7650, longitude: 7.8100), links: ["spiekeroog_east", "wangerooge_south"]),
            .init(id: "wangerooge_south", coordinate: .init(latitude: 53.7720, longitude: 7.8550), links: ["wangerooge_west", "wangerooge_harbor"])
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    private static var cachedSeamarkGraph: SeamarkGraph?

    private static func loadSeamarkGraph() async -> SeamarkGraph? {
        if let cachedSeamarkGraph { return cachedSeamarkGraph }

        let query = """
        [out:json][timeout:30];
        (
          way["seamark:type"~"^(fairway|recommended_track|navigation_line|separation_lane)$"](53.20,6.45,53.95,8.10);
          way["waterway"="fairway"](53.20,6.45,53.95,8.10);
          way["waterway"="river"]["tidal"="yes"](53.20,6.45,53.95,8.10);
          way["waterway"="river"]["name"~"^(Ems|Jade)$"](53.20,6.45,53.95,8.10);
        );
        out tags geom;
        """

        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)".data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            let payload = try JSONDecoder().decode(OverpassResponse.self, from: data)
            let graph = makeGraph(from: payload)
            guard graph.nodes.count > 8 else { return nil }
            cachedSeamarkGraph = graph
            return graph
        } catch {
            return nil
        }
    }

    private static func makeGraph(from payload: OverpassResponse) -> SeamarkGraph {
        var nodes: [Int: CLLocationCoordinate2D] = [:]
        var edges: [Int: Set<Int>] = [:]
        var nodeIDsByCoordinate: [String: Int] = [:]
        var nextID = 0

        // Koordinaten werden gerundet als Schlüssel verwendet, damit identische Wegpunkte nur einmal im Graphen landen.
        func nodeID(for coordinate: CLLocationCoordinate2D) -> Int {
            let key = "\(Int((coordinate.latitude * 100_000).rounded())):\(Int((coordinate.longitude * 100_000).rounded()))"
            if let existing = nodeIDsByCoordinate[key] { return existing }
            let id = nextID
            nextID += 1
            nodeIDsByCoordinate[key] = id
            nodes[id] = coordinate
            return id
        }

        for element in payload.elements where element.type == "way" && isRoutableSeamarkElement(element) {
            guard let geometry = element.geometry, geometry.count > 1 else { continue }
            let ids = geometry.map { nodeID(for: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
            for pair in zip(ids, ids.dropFirst()) {
                edges[pair.0, default: []].insert(pair.1)
                edges[pair.1, default: []].insert(pair.0)
            }
        }

        return SeamarkGraph(nodes: nodes, edges: edges.mapValues(Array.init))
    }

    private static func isRoutableSeamarkElement(_ element: OverpassResponse.Element) -> Bool {
        guard let tags = element.tags else { return false }
        let seamarkTypes = ["fairway", "recommended_track", "navigation_line", "separation_lane"]
        if let seamarkType = tags["seamark:type"], seamarkTypes.contains(seamarkType) {
            return true
        }
        if tags["waterway"] == "fairway" {
            return true
        }
        if tags["waterway"] == "river", tags["tidal"] == "yes" {
            return true
        }
        if tags["waterway"] == "river", ["Ems", "Jade"].contains(tags["name"] ?? "") {
            return true
        }
        return false
    }

    private static func nearestNode(to coordinate: CLLocationCoordinate2D, in graph: SeamarkGraph) -> Int? {
        graph.nodes.min { lhs, rhs in
            distanceNM(from: coordinate, to: lhs.value) < distanceNM(from: coordinate, to: rhs.value)
        }?.key
    }

    private static func shortestPath(from start: String, to destination: String) -> [String]? {
        var distances = Dictionary(uniqueKeysWithValues: nodes.keys.map { ($0, Double.infinity) })
        var previous: [String: String] = [:]
        var unvisited = Set(nodes.keys)
        distances[start] = 0

        while let current = unvisited.min(by: { (distances[$0] ?? .infinity) < (distances[$1] ?? .infinity) }) {
            if current == destination { break }
            unvisited.remove(current)

            guard let currentNode = nodes[current] else { continue }
            for next in currentNode.links where unvisited.contains(next) {
                guard let nextNode = nodes[next] else { continue }
                let alternative = (distances[current] ?? .infinity) + distanceNM(from: currentNode.coordinate, to: nextNode.coordinate)
                if alternative < (distances[next] ?? .infinity) {
                    distances[next] = alternative
                    previous[next] = current
                }
            }
        }

        guard distances[destination, default: .infinity].isFinite else { return nil }

        var path = [destination]
        var cursor = destination
        while cursor != start {
            guard let parent = previous[cursor] else { return nil }
            path.append(parent)
            cursor = parent
        }
        return Array(path.reversed())
    }

    private static func shortestPath(from start: Int, to destination: Int, in graph: SeamarkGraph) -> [Int]? {
        var distances = Dictionary(uniqueKeysWithValues: graph.nodes.keys.map { ($0, Double.infinity) })
        var previous: [Int: Int] = [:]
        var unvisited = Set(graph.nodes.keys)
        distances[start] = 0

        while let current = unvisited.min(by: { (distances[$0] ?? .infinity) < (distances[$1] ?? .infinity) }) {
            if current == destination { break }
            unvisited.remove(current)

            guard let currentCoordinate = graph.nodes[current] else { continue }
            for next in graph.edges[current, default: []] where unvisited.contains(next) {
                guard let nextCoordinate = graph.nodes[next] else { continue }
                let alternative = (distances[current] ?? .infinity) + distanceNM(from: currentCoordinate, to: nextCoordinate)
                if alternative < (distances[next] ?? .infinity) {
                    distances[next] = alternative
                    previous[next] = current
                }
            }
        }

        guard distances[destination, default: .infinity].isFinite else { return nil }

        var path = [destination]
        var cursor = destination
        while cursor != start {
            guard let parent = previous[cursor] else { return nil }
            path.append(parent)
            cursor = parent
        }
        return Array(path.reversed())
    }

    private static func deduplicated(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        coordinates.reduce(into: []) { result, coordinate in
            guard let last = result.last else {
                result.append(coordinate)
                return
            }
            if abs(last.latitude - coordinate.latitude) > 0.0001 || abs(last.longitude - coordinate.longitude) > 0.0001 {
                result.append(coordinate)
            }
        }
    }

    private static func distanceNM(from lhs: CLLocationCoordinate2D, to rhs: CLLocationCoordinate2D) -> Double {
        let earthRadiusNM = 3440.065
        let lat1 = lhs.latitude * .pi / 180
        let lat2 = rhs.latitude * .pi / 180
        let dLat = (rhs.latitude - lhs.latitude) * .pi / 180
        let dLon = (rhs.longitude - lhs.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusNM * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
