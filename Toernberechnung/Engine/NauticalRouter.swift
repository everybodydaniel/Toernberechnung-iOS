import Foundation
import CoreLocation

// MARK: - Nautical Router
//
// 1:1 port of the original implementation.  The waypoint coordinates
// and edges are taken VERBATIM from the verified reference graph; they are
// the hand-curated fairways of the East Frisian Wadden Sea sourced from
// OpenSeaMap, BSH nautical charts and the Emden Plantabelle.
//
// Because every edge in this graph is verified to lie in navigable water,
// there is NO automatic land-pruning here — the safe routes are encoded
// by construction.  Adding new edges therefore demands chart verification
// before merging.

enum NauticalRouter {

    // MARK: - Waypoint type

    struct Waypoint: Hashable, Identifiable {
        let id: String
        let lat: Double
        let lon: Double
        /// Planning chart depth relative to SKN in metres (negative = trockenfallend).
        /// RouteExpander preserves these Android reference depths.
        let chartDepth: Double
        let isSeegat: Bool

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        /// Optional iOS-side extras consumed by `RouteExpander`. These do not
        /// exist in the original `WP` struct; for fairway WPs they remain nil
        /// and the calling code inherits values from the nearest user WP.
        var tideStationID: String? { nil }
        var hwOffsetMinutes: Int { 0 }

        fileprivate init(_ id: String, _ lat: Double, _ lon: Double, _ chartDepth: Double = -1.5, isSeegat: Bool = false) {
            self.id = id
            self.lat = lat
            self.lon = lon
            self.chartDepth = chartDepth
            self.isSeegat = isSeegat
        }
    }

    // MARK: - Catalog (ported verbatim from Android implementation)

    static let waypoints: [Waypoint] = [
        // === EMS-FAHRWASSER (Süd→Nord) ===
        Waypoint("emden_port",      53.345, 7.200, 7.0),
        Waypoint("emden_outer",     53.330, 7.185, 8.5),
        Waypoint("dollart",         53.310, 7.080, 3.0),
        Waypoint("ems_emden_w",     53.328, 7.030, 8.0),
        Waypoint("ems_knock",       53.350, 6.980, 10.0),
        Waypoint("ems_rysum",       53.380, 6.940, 9.0),
        Waypoint("ems_campen",      53.410, 6.910, 8.0),
        Waypoint("ems_pilsum",      53.450, 6.880, 7.0),
        Waypoint("ems_leybuchtn",   53.530, 6.840, 5.0),
        Waypoint("ems_upper",       53.553, 6.800, 7.0),
        Waypoint("ems_mouth",       53.580, 6.750, 8.0),

        // === MEMMERTBALJE (Borkum-Ost → Memmert ← Juist-Süd) ===
        Waypoint("memmert_n1",      53.598, 6.812, 0.5),
        Waypoint("memmert_n2",      53.612, 6.838, 0.2),
        Waypoint("memmert_w",       53.620, 6.850, -0.2),
        Waypoint("memmert_e1",      53.634, 6.892, -0.5),
        Waypoint("memmert_e2",      53.650, 6.928, -0.8),
        Waypoint("memmert_e3",      53.660, 6.965, -1.1),
        Waypoint("memmert_juist_s", 53.665, 6.992, -0.4),

        // === OSTEREMS (O-Tonnen Nord→Süd) ===
        Waypoint("O1",  53.675, 7.080, 3.5),
        Waypoint("O2",  53.660, 7.100, 3.0),
        Waypoint("O3",  53.645, 7.125, 2.5),
        Waypoint("O4",  53.630, 7.150, 1.5),
        Waypoint("O5",  53.615, 7.170, 0.8),
        Waypoint("O6",  53.600, 7.195, 0.2),
        Waypoint("O7",  53.585, 7.215, -0.5),
        Waypoint("O8",  53.570, 7.235, -1.0),
        Waypoint("O9",  53.555, 7.255, -1.5),
        Waypoint("O10", 53.540, 7.275, -1.8),
        Waypoint("O11", 53.525, 7.295, -2.0),
        Waypoint("O12", 53.510, 7.315, -2.2),
        Waypoint("O13", 53.495, 7.335, -2.5),
        Waypoint("osterems",        53.670, 7.100, 4.0),

        // === BUSETIEF (Norddeich ↔ Norderney) ===
        Waypoint("norddeich_off",   53.617, 7.162, 1.8),
        Waypoint("busetief_s",      53.635, 7.160, 1.5),
        Waypoint("busetief_mid",    53.652, 7.162, 1.2),
        Waypoint("busetief_n",      53.670, 7.165, 1.2),
        Waypoint("norderney_s",     53.683, 7.200, 1.0),

        // === WATTFAHRWASSER (Innenkanal, Küste Ost) ===
        Waypoint("watt_norden",     53.660, 7.250, -1.4),
        Waypoint("watt_nesskana",   53.670, 7.330, -1.5),
        Waypoint("watt_dornum",     53.680, 7.400, -1.6),
        Waypoint("watt_bensersiel", 53.700, 7.520, -1.3),
        Waypoint("watt_neuharling", 53.720, 7.650, -1.2),
        Waypoint("watt_harlesiel",  53.730, 7.800, -0.5),
        Waypoint("watt_wangerooge", 53.740, 7.920, -1.1),

        // === BORKUM-UMFAHRUNG ===
        Waypoint("borkum_south",    53.550, 6.680, 4.0),
        Waypoint("borkum_sw",       53.560, 6.600, 6.0),
        Waypoint("borkum_east",     53.580, 6.800, 4.0),

        // === OFFSHORE-RAND (offene See nördlich der Inseln) ===
        Waypoint("sea_borkum_w",    53.610, 6.580, 12.0),
        Waypoint("sea_borkum_n",    53.650, 6.720, 15.0),
        Waypoint("sea_juist",       53.710, 6.980, 15.0),
        Waypoint("sea_norderney",   53.740, 7.200, 15.0),
        Waypoint("sea_baltrum",     53.760, 7.420, 15.0),
        Waypoint("sea_langeoog",    53.790, 7.560, 15.0),
        Waypoint("sea_spiekeroog",  53.810, 7.730, 15.0),
        Waypoint("sea_wangerooge",  53.820, 7.920, 15.0),

        // === SEEGATTEN (Tidenrinnen zwischen Inseln) ===
        Waypoint("seegat_baltrum",    53.740, 7.350, 3.0, isSeegat: true),  // Accumer Ee
        Waypoint("seegat_langeoog",   53.770, 7.630, 2.5, isSeegat: true),  // Otzumer Balje
        Waypoint("seegat_spiekeroog", 53.790, 7.810, 2.0, isSeegat: true),  // Harle
        Waypoint("seegat_wangerooge", 53.800, 8.020, 4.0, isSeegat: true),  // Blaue Balje

        // === LEYBUCHT (Ems ↔ Norddeich) ===
        Waypoint("leybucht_w",      53.530, 6.920, -0.3),
        Waypoint("leybucht_e",      53.560, 7.020, -0.8),
        Waypoint("leybucht_coast",  53.590, 7.100, -1.2),
        Waypoint("norddeich_appr",  53.610, 7.140, 0.5),

        // === HAFEN-WAYPOINTS ===
        Waypoint("borkum_hbr",      53.5606, 6.7502, 3.0),
        Waypoint("juist_hbr",       53.6722, 6.9982, -1.2),
        Waypoint("norderney_hbr",   53.7024, 7.1637, 1.5),
        Waypoint("baltrum_hbr",     53.7229, 7.3669, -1.0),
        Waypoint("langeoog_hbr",    53.7263, 7.4968, -0.5),
        Waypoint("spiekeroog_hbr",  53.7632, 7.6955, -0.8),
        Waypoint("wangerooge_hbr",  53.7755, 7.8683, -0.6),
        Waypoint("emden_hbr",       53.3421, 7.1852, 5.0),
        Waypoint("norddeich_hbr",   53.6265, 7.1615, 1.5),
        Waypoint("nessmersiel_hbr", 53.6865, 7.3615, -1.5),
        Waypoint("dornum_hbr",      53.6865, 7.4785, -1.5),
        Waypoint("bensersiel_hbr",  53.6785, 7.5705, 1.2),
        Waypoint("neuharling_hbr",  53.7015, 7.7055, 1.0),
        Waypoint("harlesiel_hbr",   53.7125, 7.8105, 1.0),
        Waypoint("horumersiel_hbr", 53.6862, 8.0195, 0.5),
        Waypoint("hooksiel_hbr",    53.6425, 8.0825, 1.5),
        Waypoint("dangast_hbr",     53.4472, 8.1175, -0.5),
        Waypoint("whv_hbr",         53.5142, 8.1465, 5.0),

        // === JADE-FAHRWASSER ===
        Waypoint("jade_entrance",   53.780, 8.050, 15.0),
        Waypoint("jade_wanger",     53.730, 8.080, 15.0),
        Waypoint("jade_horum",      53.690, 8.100, 14.0),
        Waypoint("jade_hooksiel",   53.640, 8.120, 14.0),
        Waypoint("jade_voslap",     53.600, 8.140, 16.0),
        Waypoint("jade_jwp",        53.585, 8.150, 18.0),
        Waypoint("jade_ruest",      53.560, 8.160, 12.0),
        Waypoint("jade_whv_appr",   53.525, 8.170, 10.0),
        Waypoint("jade_inner_s",    53.480, 8.180, 5.0),
        Waypoint("jade_dangast_a",  53.450, 8.150, 2.0),

        // === JADE-CONNECTORS ===
        Waypoint("horum_fairway",   53.687, 8.080, 5.0),
        Waypoint("hooksiel_fairway", 53.642, 8.100, 4.0),
        Waypoint("whv_fairway",     53.520, 8.160, 8.0),

        // === Reserve-WPs (alte Ems-Pegelpunkte, Rückwärtskompat) ===
        Waypoint("W1", 53.585, 6.740, 6.0),
        Waypoint("W2", 53.565, 6.760, 5.5),
        Waypoint("W3", 53.545, 6.785, 5.0),
        Waypoint("W4", 53.525, 6.810, 4.5),
        Waypoint("W5", 53.505, 6.840, 4.2),
        Waypoint("W6", 53.485, 6.865, 4.0),

    ]

    // MARK: - Edges (ported verbatim from Android implementation)

    private static let edges: [(String, String)] = [
        // ── Ems-Fahrwasser (Süd→Nord) ──
        ("emden_port", "emden_hbr"),
        ("emden_hbr", "emden_outer"),
        ("emden_outer", "ems_emden_w"),
        ("dollart", "ems_emden_w"),
        ("ems_emden_w", "ems_knock"),
        ("ems_knock", "ems_rysum"),
        ("ems_rysum", "ems_campen"),
        ("ems_campen", "ems_pilsum"),
        ("ems_pilsum", "ems_leybuchtn"),
        ("ems_leybuchtn", "ems_upper"),
        ("ems_upper", "ems_mouth"),

        // ── Borkum-Umfahrung ──
        ("ems_mouth", "borkum_east"),
        ("ems_mouth", "borkum_south"),
        ("borkum_south", "borkum_sw"),
        ("borkum_sw", "sea_borkum_w"),
        ("borkum_east", "sea_borkum_n"),
        ("sea_borkum_w", "sea_borkum_n"),
        ("borkum_hbr", "borkum_east"),
        ("borkum_hbr", "borkum_south"),

        // ── Memmertbalje (echte Pricken-Kette Borkum→Juist) ──
        ("borkum_east", "memmert_n1"),
        ("memmert_n1", "memmert_n2"),
        ("memmert_n2", "memmert_w"),
        ("memmert_w", "memmert_e1"),
        ("memmert_e1", "memmert_e2"),
        ("memmert_e2", "memmert_e3"),
        ("memmert_e3", "memmert_juist_s"),
        ("memmert_juist_s", "juist_hbr"),
        ("memmert_w", "sea_juist"),

        // ── Offshore-Kette ──
        ("sea_borkum_n", "sea_juist"),
        ("sea_juist", "sea_norderney"),
        ("sea_norderney", "sea_baltrum"),
        ("sea_baltrum", "sea_langeoog"),
        ("sea_langeoog", "sea_spiekeroog"),
        ("sea_spiekeroog", "sea_wangerooge"),

        // ── Seegatten (Offshore → Inneres Watt & Häfen) ──
        ("sea_juist", "osterems"),
        ("sea_norderney", "osterems"),
        ("osterems", "busetief_n"),
        ("osterems", "norderney_s"),
        ("osterems", "norderney_hbr"),
        ("sea_baltrum", "seegat_baltrum"),
        ("seegat_baltrum", "watt_dornum"),
        ("sea_langeoog", "seegat_langeoog"),
        ("seegat_langeoog", "watt_neuharling"),
        ("sea_spiekeroog", "seegat_spiekeroog"),
        ("seegat_spiekeroog", "watt_harlesiel"),
        ("sea_wangerooge", "seegat_wangerooge"),
        ("seegat_wangerooge", "jade_entrance"),

        // ── Busetief (Norddeich ↔ Norderney) ──
        ("norddeich_off", "busetief_s"),
        ("busetief_s", "busetief_mid"),
        ("busetief_mid", "busetief_n"),
        ("busetief_n", "norderney_s"),
        ("busetief_n", "norderney_hbr"),
        ("norderney_s", "norderney_hbr"),
        ("norddeich_off", "watt_norden"),
        ("busetief_mid", "watt_norden"),

        // ── Wattfahrwasser (Innenkanal, Küste Ost) ──
        ("norderney_s", "watt_norden"),
        ("watt_norden", "watt_nesskana"),
        ("watt_nesskana", "watt_dornum"),
        ("watt_dornum", "watt_bensersiel"),
        ("watt_bensersiel", "watt_neuharling"),
        ("watt_neuharling", "watt_harlesiel"),
        ("watt_harlesiel", "watt_wangerooge"),
        ("watt_wangerooge", "jade_entrance"),

        // ── Inselhäfen ↔ Wattfahrwasser ──
        ("juist_hbr", "osterems"),
        ("norderney_hbr", "norderney_s"),
        ("baltrum_hbr", "watt_dornum"),
        ("langeoog_hbr", "watt_bensersiel"),
        ("spiekeroog_hbr", "watt_neuharling"),
        ("wangerooge_hbr", "watt_wangerooge"),
        ("wangerooge_hbr", "jade_wanger"),

        // ── Festland-Häfen ↔ Wattfahrwasser ──
        ("norddeich_hbr", "norddeich_off"),
        ("nessmersiel_hbr", "watt_nesskana"),
        ("dornum_hbr", "watt_dornum"),
        ("bensersiel_hbr", "watt_bensersiel"),
        ("neuharling_hbr", "watt_neuharling"),
        ("harlesiel_hbr", "watt_harlesiel"),

        // ── Jade-Fahrwasser ──
        ("jade_entrance", "jade_wanger"),
        ("jade_wanger", "jade_horum"),
        ("jade_horum", "jade_hooksiel"),
        ("jade_hooksiel", "jade_voslap"),
        ("jade_voslap", "jade_jwp"),
        ("jade_jwp", "jade_ruest"),
        ("jade_ruest", "jade_whv_appr"),
        ("jade_whv_appr", "jade_inner_s"),
        ("jade_inner_s", "jade_dangast_a"),

        // ── Jade-Connectors ──
        ("horumersiel_hbr", "horum_fairway"),
        ("horum_fairway", "jade_horum"),
        ("hooksiel_hbr", "hooksiel_fairway"),
        ("hooksiel_fairway", "jade_hooksiel"),
        ("whv_hbr", "whv_fairway"),
        ("whv_fairway", "jade_whv_appr"),
        ("dangast_hbr", "jade_dangast_a"),

        // ── Leybucht-Verbinder (Ems ↔ Norddeich) ──
        ("ems_pilsum", "leybucht_w"),
        ("ems_leybuchtn", "leybucht_w"),
        ("leybucht_w", "leybucht_e"),
        ("leybucht_e", "leybucht_coast"),
        ("leybucht_coast", "norddeich_appr"),
        ("norddeich_appr", "norddeich_off"),

        // ── Reserve-W-Kette + Osterems-Kette ──
        ("W1", "W2"), ("W2", "W3"), ("W3", "W4"), ("W4", "W5"), ("W5", "W6"),
        ("W1", "ems_mouth"),
        ("W6", "ems_leybuchtn"),
        ("O1", "O2"), ("O2", "O3"), ("O3", "O4"), ("O4", "O5"), ("O5", "O6"),
        ("O6", "O7"), ("O7", "O8"), ("O8", "O9"), ("O9", "O10"), ("O10", "O11"),
        ("O11", "O12"), ("O12", "O13"),
        ("O1", "osterems"),
        ("O6", "norddeich_off"),
        ("O13", "watt_nesskana"),

    ]

    /// Map for waypoint lookups, including legacy and harbor aliases.
    private static let waypointMap: [String: Waypoint] = {
        var map: [String: Waypoint] = [:]
        for wp in waypoints { map[wp.id] = wp }
        let aliases: [String: String] = [
            "borkum_hbr_p": "borkum_hbr",
            "borkum_harbor": "borkum_hbr",
            "juist_hbr_p": "juist_hbr",
            "juist_harbor": "juist_hbr",
            "norderney_hbr_p": "norderney_hbr",
            "norderney_harbor": "norderney_hbr",
            "baltrum_hbr_p": "baltrum_hbr",
            "baltrum_harbor": "baltrum_hbr",
            "langeoog_hbr_p": "langeoog_hbr",
            "langeoog_harbor": "langeoog_hbr",
            "spiekeroog_hbr_p": "spiekeroog_hbr",
            "spiekeroog_harbor": "spiekeroog_hbr",
            "wangerooge_hbr_p": "wangerooge_hbr",
            "wangerooge_harbor": "wangerooge_hbr",
            "norddeich_hbr_p": "norddeich_hbr",
            "bensersiel_hbr_p": "bensersiel_hbr",
            "neuharling_hbr_p": "neuharling_hbr",
            "harlesiel_hbr_p": "harlesiel_hbr",
            "emden_port": "emden_hbr"
        ]
        for (alias, target) in aliases {
            if let targetWP = map[target], map[alias] == nil {
                map[alias] = Waypoint(alias, targetWP.lat, targetWP.lon, targetWP.chartDepth, isSeegat: targetWP.isSeegat)
            }
        }
        return map
    }()

    /// Adjacency list. The reference graph is hand-verified, so no automated
    /// land-pruning is applied here. Adding edges therefore demands chart
    /// verification before merging.
    private static let adjacency: [String: [String]] = {
        var adj: [String: [String]] = [:]
        for (a, b) in edges {
            guard waypointMap[a] != nil, waypointMap[b] != nil else { continue }
            adj[a, default: []].append(b)
            adj[b, default: []].append(a)
        }
        return adj
    }()

    // MARK: - Public API

    /// Shortest fairway route between two coordinates. Returns the full
    /// ordered list of waypoints; the caller MUST NOT drop intermediate
    /// nodes when rendering the polyline.
    static func route(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> [Waypoint] {
        // Android's safety evaluator uses the catalog fairway path. Raster
        // routing and simplification must never replace its depth samples:
        // SeaMask depths are navigation hints, not surveyed soundings.
        let startWP = nearest(to: start)
        let endWP = nearest(to: end)
        if startWP.id == endWP.id { return [startWP] }
        guard let path = dijkstra(from: startWP.id, to: endWP.id) else {
            return []
        }
        return path.compactMap { waypointMap[$0] }
    }

    static func nearest(to coordinate: CLLocationCoordinate2D) -> Waypoint {
        return waypoints.min(by: {
            let d1 = pow($0.lat - coordinate.latitude, 2) + pow($0.lon - coordinate.longitude, 2)
            let d2 = pow($1.lat - coordinate.latitude, 2) + pow($1.lon - coordinate.longitude, 2)
            return d1 < d2
        }) ?? waypoints[0]
    }

    // MARK: - Dijkstra

    private static func dijkstra(from startID: String, to endID: String) -> [String]? {
        guard waypointMap[startID] != nil, waypointMap[endID] != nil else { return nil }

        var dist: [String: Double] = [startID: 0]
        var prev: [String: String] = [:]
        var visited: Set<String> = []
        var queue: [(id: String, d: Double)] = [(startID, 0)]

        while !queue.isEmpty {
            queue.sort { $0.d < $1.d }
            let (current, _) = queue.removeFirst()
            if visited.contains(current) { continue }
            visited.insert(current)
            if current == endID { break }

            guard let cwp = waypointMap[current] else { continue }
            for neighbor in adjacency[current] ?? [] {
                if visited.contains(neighbor) { continue }
                guard let nwp = waypointMap[neighbor] else { continue }
                let edgeDist = haversineNm(cwp.coordinate, nwp.coordinate)
                
                // Android dijkstraOrNull: apply the same legacy-edge penalty
                // even at endpoints; no additional preference for deep water.
                let isShortcut = current.contains("leybucht") || neighbor.contains("leybucht") ||
                    ["norddeich_appr", "juist_hbr", "norderney_hbr", "borkum_hbr"].contains(current) ||
                    ["norddeich_appr", "juist_hbr", "norderney_hbr", "borkum_hbr"].contains(neighbor)
                let alt = (dist[current] ?? .infinity) + edgeDist * (isShortcut ? 10_000 : 1)
                if alt < (dist[neighbor] ?? .infinity) {
                    dist[neighbor] = alt
                    prev[neighbor] = current
                    queue.append((neighbor, alt))
                }
            }
        }

        guard dist[endID] != nil else { return nil }
        var path: [String] = []
        var cursor: String? = endID
        while let node = cursor {
            path.insert(node, at: 0)
            cursor = prev[node]
        }
        return path.first == startID ? path : nil
    }

    // MARK: - Distance helpers

    static func haversineNm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let earthRadiusNm = 3440.065
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusNm * asin(min(1, sqrt(s)))
    }

    private static func distanceSquared(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = a.latitude - b.latitude
        let dLon = (a.longitude - b.longitude) * cos(a.latitude * .pi / 180)
        return dLat * dLat + dLon * dLon
    }
}
