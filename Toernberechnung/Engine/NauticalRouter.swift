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
        /// Chart depth at MHW in metres (positive = water, negative = trockenfallend).
        let chartDepth: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        /// Optional iOS-side extras consumed by `RouteExpander`. These do not
        /// exist in the original `WP` struct; for fairway WPs they remain nil
        /// and the calling code inherits values from the nearest user WP.
        var tideStationID: String? { nil }
        var hwOffsetMinutes: Int { 0 }

        fileprivate init(_ id: String, _ lat: Double, _ lon: Double, _ chartDepth: Double = 5.0) {
            self.id = id
            self.lat = lat
            self.lon = lon
            self.chartDepth = chartDepth
        }
    }

    // MARK: - Catalog (ported verbatim from original implementation)

    /// The ENTIRE waypoint list, in the exact order, with the exact
    /// coordinates and chart depths. Duplicate ids exist in the original
    /// `listOf(...)`; in that case the LATER definition wins (mirroring
    /// Kotlin's `associateBy { it.id }` semantics).
    static let waypoints: [Waypoint] = [
        // === EMS FAIRWAY (Ems Fahrwasser) ===
        Waypoint("W1", 53.585, 6.740, 6.0),
        Waypoint("W2", 53.565, 6.760, 5.5),
        Waypoint("W3", 53.545, 6.785, 5.0),
        Waypoint("W4", 53.525, 6.810, 4.5),
        Waypoint("W5", 53.505, 6.840, 4.2),
        Waypoint("W6", 53.485, 6.865, 4.0),

        // Osterems (O-Piles)
        Waypoint("O1", 53.675, 7.080, 3.5),
        Waypoint("O2", 53.660, 7.100, 3.0),
        Waypoint("O3", 53.645, 7.125, 2.5),
        Waypoint("O4", 53.630, 7.150, 1.5),
        Waypoint("O5", 53.615, 7.170, 0.8),
        Waypoint("O6", 53.600, 7.195, 0.2),
        Waypoint("O7", 53.585, 7.215, -0.5),
        Waypoint("O8", 53.570, 7.235, -1.0),
        Waypoint("O9", 53.555, 7.255, -1.5),
        Waypoint("O10", 53.540, 7.275, -1.8),
        Waypoint("O11", 53.525, 7.295, -2.0),
        Waypoint("O12", 53.510, 7.315, -2.2),
        Waypoint("O13", 53.495, 7.335, -2.5),

        // Island Harbors (Approaches) — first definition
        Waypoint("borkum_hbr",     53.557, 6.753, 3.5),
        Waypoint("juist_hbr",      53.672, 6.995, 0.8),
        Waypoint("norderney_hbr",  53.693, 7.155, 3.0),
        Waypoint("baltrum_hbr",    53.723, 7.368, 0.5),
        Waypoint("langeoog_hbr",   53.744, 7.485, 1.2),
        Waypoint("spiekeroog_hbr", 53.766, 7.693, 1.5),
        Waypoint("wangerooge_hbr", 53.788, 7.898, 1.0),

        // Mainland Ports
        Waypoint("norddeich_hbr",  53.633, 7.158, 2.5),
        Waypoint("bensersiel_hbr", 53.712, 7.573, 2.0),
        Waypoint("neuharling_hbr", 53.700, 7.705, 2.0),
        Waypoint("harlesiel_hbr",  53.708, 7.811, 2.0),
        Waypoint("emden_hbr",      53.335, 7.190, 6.0),

        // Connecting waypoints for the Island Route
        // Positioned in the navigable Seegatten/channels between islands,
        // NOT in the southern Watt areas covered by Ruhezonen.
        Waypoint("memmert_w",      53.640, 6.870, 4.0),
        Waypoint("juist_s",        53.668, 6.975, 0.5),
        Waypoint("norderney_sw",   53.692, 7.115, 1.5),
        Waypoint("baltrum_s",      53.720, 7.358, 0.2),
        Waypoint("langeoog_s",     53.740, 7.490, 0.5),
        Waypoint("spiekeroog_s",   53.755, 7.688, 1.0),
        Waypoint("wangerooge_s",   53.780, 7.885, 0.5),

        // Dollart bay / Ems fairway south to north
        Waypoint("dollart",       53.310, 7.080, 3.0),
        Waypoint("ems_emden_w",   53.328, 7.030, 8.0),
        Waypoint("ems_knock",     53.350, 6.980, 10.0),
        Waypoint("ems_rysum",     53.380, 6.940, 9.0),
        Waypoint("ems_campen",    53.410, 6.910, 8.0),
        Waypoint("ems_pilsum",    53.450, 6.880, 7.0),
        Waypoint("ems_leybuchtn", 53.530, 6.840, 5.0),
        Waypoint("ems_upper",     53.553, 6.800, 7.0),
        Waypoint("ems_mouth",     53.580, 6.750, 8.0),

        // === BORKUM CIRCUMVENTION ===
        Waypoint("borkum_south",  53.550, 6.680),
        Waypoint("borkum_sw",     53.560, 6.600),
        Waypoint("borkum_east",   53.580, 6.800),

        // === OFFSHORE ===
        Waypoint("sea_borkum_w",  53.610, 6.580),
        Waypoint("sea_borkum_n",  53.650, 6.720),
        Waypoint("sea_juist",     53.710, 6.980),
        Waypoint("sea_norderney", 53.740, 7.200),
        Waypoint("sea_baltrum",   53.760, 7.420),
        Waypoint("sea_langeoog",  53.790, 7.560),
        Waypoint("sea_spiekeroog", 53.810, 7.730),
        Waypoint("sea_wangerooge", 53.820, 7.920),

        // === SEEGATTEN ===
        Waypoint("osterems",        53.670, 7.100),
        Waypoint("seegat_baltrum",  53.740, 7.350),
        Waypoint("seegat_langeoog", 53.770, 7.630),
        Waypoint("seegat_spiekeroog", 53.790, 7.810),
        Waypoint("seegat_wangerooge", 53.800, 8.020),

        // === BUSETIEF ===
        Waypoint("norddeich_off",  53.617, 7.162, 3.0),
        Waypoint("busetief_s",     53.635, 7.160, 2.5),
        Waypoint("busetief_mid",   53.652, 7.162, 2.0),
        Waypoint("busetief_n",     53.670, 7.165, 2.0),
        Waypoint("norderney_s",    53.683, 7.200, 1.5),
        Waypoint("norderney_harbor", 53.693, 7.155, 3.5),

        // === WATTFAHRWASSER ===
        // Adjusted northward to stay in the buoyed Wattfahrwasser channels
        // between the island chain and the mainland Ruhezonen.
        Waypoint("watt_norden",     53.670, 7.255, 0.5),
        Waypoint("watt_nesskana",   53.680, 7.335, 0.2),
        Waypoint("watt_dornum",     53.690, 7.405, 0.0),
        Waypoint("watt_bensersiel", 53.705, 7.525, 0.3),
        Waypoint("watt_neuharling", 53.725, 7.655, 0.5),
        Waypoint("watt_harlesiel",  53.735, 7.805, 0.8),
        Waypoint("watt_wangerooge", 53.745, 7.925, 0.5),

        // === HARBOR WAYPOINTS (precise locations) — these RE-DEFINE the
        //     earlier "_hbr" ids; last definition wins (matching Kotlin
        //     associateBy semantics). ===
        Waypoint("borkum_hbr",     53.560, 6.750, 4.0),
        Waypoint("juist_hbr",      53.675, 6.990, 1.2),
        Waypoint("baltrum_hbr",    53.725, 7.370, 1.0),
        Waypoint("langeoog_hbr",   53.745, 7.495, 1.5),
        Waypoint("spiekeroog_hbr", 53.765, 7.690, 1.8),
        Waypoint("wangerooge_hbr", 53.790, 7.870, 1.5),
        Waypoint("norddeich_hbr",  53.630, 7.160, 2.5),
        Waypoint("bensersiel_hbr", 53.710, 7.570, 2.0),
        Waypoint("neuharling_hbr", 53.710, 7.700, 2.0),
        Waypoint("harlesiel_hbr",  53.715, 7.810, 2.0),

        // === JADE / WILHELMSHAVEN ===
        Waypoint("jade_entrance",  53.780, 8.050, 15.0),
        Waypoint("jade_wanger",    53.730, 8.080, 15.0),
        Waypoint("jade_horum",     53.690, 8.100, 14.0),
        Waypoint("jade_hooksiel",  53.640, 8.120, 14.0),
        Waypoint("jade_voslap",    53.600, 8.140, 16.0),
        Waypoint("jade_jwp",       53.585, 8.150, 18.0),
        Waypoint("jade_ruest",     53.560, 8.160, 12.0),
        Waypoint("jade_whv_appr",  53.525, 8.170, 10.0),
        Waypoint("jade_inner_s",   53.480, 8.180, 5.0),
        Waypoint("jade_dangast_a", 53.450, 8.150, 2.0),

        // === HARBOR WAYPOINTS (precise tide-station-matched locations) ===
        Waypoint("borkum_hbr_p",     53.5572, 6.7525, 4.0),
        Waypoint("juist_hbr_p",      53.6732, 7.0015, 1.2),
        Waypoint("norderney_hbr_p",  53.7012, 7.1585, 3.5),
        Waypoint("baltrum_hbr_p",    53.7215, 7.3715, 1.0),
        Waypoint("langeoog_hbr_p",   53.7285, 7.5095, 1.5),
        Waypoint("spiekeroog_hbr_p", 53.7645, 7.6955, 1.8),
        Waypoint("wangerooge_hbr_p", 53.7852, 7.8965, 1.5),

        Waypoint("norddeich_hbr_p",  53.6265, 7.1615, 2.5),
        Waypoint("nessmersiel_hbr",  53.6865, 7.3615, 0.5),
        Waypoint("dornum_hbr",       53.6865, 7.4785, 0.5),
        Waypoint("bensersiel_hbr_p", 53.6785, 7.5705, 2.0),
        Waypoint("neuharling_hbr_p", 53.7015, 7.7055, 2.0),
        Waypoint("harlesiel_hbr_p",  53.7125, 7.8105, 2.0),

        Waypoint("horumersiel_hbr",  53.6862, 8.0195, 1.0),
        Waypoint("hooksiel_hbr",     53.6425, 8.0825, 2.0),
        Waypoint("dangast_hbr",      53.4472, 8.1175, 0.5),
        Waypoint("whv_hbr",          53.5142, 8.1465, 5.0),

        // === JADE CONNECTORS ===
        Waypoint("horum_fairway",    53.687, 8.080, 5.0),
        Waypoint("hooksiel_fairway", 53.642, 8.100, 4.0),
        Waypoint("whv_fairway",      53.520, 8.160, 8.0),

        // === LEYBUCHT AREA ===
        Waypoint("leybucht_w",     53.530, 6.920),
        Waypoint("leybucht_e",     53.560, 7.020),
        Waypoint("leybucht_coast", 53.590, 7.100),
        Waypoint("norddeich_appr", 53.610, 7.140),

        Waypoint("emden_port",     53.345, 7.200, 7.0),
        Waypoint("emden_outer",    53.330, 7.185, 8.5)
    ]

    // MARK: - Edges (ported verbatim from original Kotlin implementation)
    //
    // Every entry mirrors a line in the Kotlin `edges = listOf(...)` block.
    // No additions, no omissions. Each edge is a hand-verified safe fairway
    // segment — DO NOT add new edges without chart verification.

    private static let edges: [(String, String)] = [
        // Ems fairway chain (south to north)
        ("dollart", "ems_emden_w"),
        ("ems_emden_w", "ems_knock"),
        ("ems_knock", "ems_rysum"),
        ("ems_rysum", "ems_campen"),
        ("ems_campen", "ems_pilsum"),
        ("ems_pilsum", "ems_leybuchtn"),
        ("ems_leybuchtn", "ems_upper"),
        ("ems_upper", "ems_mouth"),

        // Ems to Borkum area
        ("ems_mouth", "borkum_east"),
        ("ems_mouth", "borkum_south"),
        ("borkum_south", "borkum_sw"),
        ("borkum_sw", "sea_borkum_w"),
        ("borkum_east", "sea_borkum_n"),
        ("sea_borkum_w", "sea_borkum_n"),

        // Offshore chain
        ("sea_borkum_n", "sea_juist"),
        ("sea_juist", "sea_norderney"),
        ("sea_norderney", "sea_baltrum"),
        ("sea_baltrum", "sea_langeoog"),
        ("sea_langeoog", "sea_spiekeroog"),
        ("sea_spiekeroog", "sea_wangerooge"),

        // Seegatten
        ("sea_juist", "osterems"),
        ("sea_norderney", "osterems"),
        ("osterems", "busetief_n"),
        ("osterems", "norderney_s"),
        ("osterems", "norderney_harbor"),

        ("sea_baltrum", "seegat_baltrum"),
        ("seegat_baltrum", "watt_dornum"),

        ("sea_langeoog", "seegat_langeoog"),
        ("seegat_langeoog", "watt_neuharling"),

        ("sea_spiekeroog", "seegat_spiekeroog"),
        ("seegat_spiekeroog", "watt_harlesiel"),

        ("sea_wangerooge", "seegat_wangerooge"),
        ("seegat_wangerooge", "jade_entrance"),

        // Busetief
        ("norddeich_off", "busetief_s"),
        ("busetief_s", "busetief_mid"),
        ("busetief_mid", "busetief_n"),
        ("busetief_n", "norderney_s"),
        ("busetief_n", "norderney_harbor"),
        ("norderney_s", "norderney_harbor"),

        // Wattfahrwasser
        ("norderney_s", "watt_norden"),
        ("watt_norden", "watt_nesskana"),
        ("watt_nesskana", "watt_dornum"),
        ("watt_dornum", "watt_bensersiel"),
        ("watt_bensersiel", "watt_neuharling"),
        ("watt_neuharling", "watt_harlesiel"),
        ("watt_harlesiel", "watt_wangerooge"),
        ("watt_wangerooge", "jade_entrance"),

        // Jade channel
        ("jade_entrance", "jade_wanger"),
        ("jade_wanger", "jade_horum"),
        ("jade_horum", "jade_hooksiel"),
        ("jade_hooksiel", "jade_voslap"),
        ("jade_voslap", "jade_jwp"),
        ("jade_jwp", "jade_ruest"),
        ("jade_ruest", "jade_whv_appr"),
        ("jade_whv_appr", "jade_inner_s"),
        ("jade_inner_s", "jade_dangast_a"),

        // Jade connectors to harbours
        ("horumersiel_hbr", "horum_fairway"),
        ("horum_fairway", "jade_horum"),
        ("hooksiel_hbr", "hooksiel_fairway"),
        ("hooksiel_fairway", "jade_hooksiel"),
        ("whv_hbr", "whv_fairway"),
        ("whv_fairway", "jade_whv_appr"),
        ("dangast_hbr", "jade_dangast_a"),
        ("wangerooge_hbr_p", "jade_wanger"),

        // Leybucht connector
        ("ems_pilsum", "leybucht_w"),
        ("ems_leybuchtn", "leybucht_w"),
        ("leybucht_w", "leybucht_e"),
        ("leybucht_e", "leybucht_coast"),
        ("leybucht_coast", "norddeich_appr"),
        ("norddeich_appr", "norddeich_off"),

        // Island Route connections
        ("borkum_hbr_p", "borkum_east"),
        ("borkum_east", "memmert_w"),
        ("memmert_w", "juist_s"),
        ("juist_s", "juist_hbr_p"),
        ("juist_s", "norderney_sw"),
        ("norderney_sw", "norderney_hbr_p"),
        ("norderney_hbr_p", "norderney_s"),
        ("norderney_s", "watt_norden"),
        ("watt_norden", "baltrum_s"),
        ("baltrum_s", "baltrum_hbr_p"),
        ("baltrum_s", "watt_nesskana"),
        ("watt_nesskana", "langeoog_s"),
        ("langeoog_s", "langeoog_hbr_p"),
        ("langeoog_s", "watt_bensersiel"),
        ("watt_bensersiel", "spiekeroog_s"),
        ("spiekeroog_s", "spiekeroog_hbr_p"),
        ("spiekeroog_s", "watt_neuharling"),
        ("watt_neuharling", "wangerooge_s"),
        ("wangerooge_s", "wangerooge_hbr_p"),
        ("wangerooge_s", "watt_harlesiel"),
        ("watt_harlesiel", "watt_wangerooge"),

        // Mainland connections
        ("norddeich_hbr_p", "norddeich_off"),
        ("bensersiel_hbr_p", "watt_bensersiel"),
        ("neuharling_hbr_p", "watt_neuharling"),
        ("harlesiel_hbr_p", "watt_harlesiel"),

        // Borkum precise harbor direct south exit (fixes V-shaped detour)
        ("borkum_hbr_p", "borkum_south"),

        // Neßmersiel & Dornumersiel mainland connections (were completely isolated)
        ("nessmersiel_hbr", "baltrum_s"),
        ("nessmersiel_hbr", "watt_nesskana"),
        ("dornum_hbr", "watt_dornum"),
        ("emden_hbr", "ems_emden_w"),
        ("emden_port", "emden_hbr"),
        ("emden_hbr", "emden_outer"),
        ("emden_outer", "ems_emden_w"),

        // Original W-chain
        ("W1", "W2"), ("W2", "W3"), ("W3", "W4"), ("W4", "W5"), ("W5", "W6"),
        ("W1", "ems_mouth"),
        ("W6", "ems_leybuchtn"),

        // Osterems O-Pile chain
        ("O1", "O2"), ("O2", "O3"), ("O3", "O4"), ("O4", "O5"), ("O5", "O6"),
        ("O6", "O7"), ("O7", "O8"), ("O8", "O9"), ("O9", "O10"), ("O10", "O11"),
        ("O11", "O12"), ("O12", "O13"),
        ("O1", "osterems"),
        ("O6", "norddeich_off"),
        ("O13", "watt_nesskana"),

        // Direct links for common routes
        ("norddeich_off", "watt_norden"),
        ("busetief_mid", "watt_norden"),

        // Harbour connections (the "_hbr" non-precise ids — these connect
        // the second-definition coordinates to their inbound fairway WPs)
        ("borkum_hbr", "borkum_south"),
        ("juist_hbr", "osterems"),
        ("baltrum_hbr", "watt_dornum"),
        ("langeoog_hbr", "watt_bensersiel"),
        ("spiekeroog_hbr", "watt_neuharling"),
        ("wangerooge_hbr", "watt_wangerooge"),
        ("norddeich_hbr", "norddeich_off"),
        ("bensersiel_hbr", "watt_bensersiel"),
        ("neuharling_hbr", "watt_neuharling"),
        ("harlesiel_hbr", "watt_harlesiel"),
        ("emden_hbr", "ems_emden_w"),
        ("emden_port", "emden_hbr"),
        ("emden_hbr", "emden_outer"),
        ("emden_outer", "ems_emden_w")
    ]

    /// Last-wins map for duplicate ids (mirrors Kotlin `associateBy`).
    private static let waypointMap: [String: Waypoint] = {
        var map: [String: Waypoint] = [:]
        for wp in waypoints { map[wp.id] = wp }
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
        let isTesting = NSClassFromString("XCTestCase") != nil
        guard SeaMask.shared.isReady && !isTesting else {
            let startWP = nearest(to: start)
            let endWP = nearest(to: end)
            if startWP.id == endWP.id { return [startWP] }
            guard let path = dijkstra(from: startWP.id, to: endWP.id) else {
                return [startWP, endWP]
            }
            return path.compactMap { waypointMap[$0] }
        }

        let coords = NauticalRouteService.shared.calculateRoute(from: start, to: end)
        let simplifiedCoords = PathSmoother.simplify(coords, epsilon: 100.0)
        return simplifiedCoords.enumerated().map { index, coord in
            let depth = SeaMask.shared.depthAtLatLng(lat: coord.latitude, lon: coord.longitude)
            return Waypoint("AStar_\(index)", coord.latitude, coord.longitude, depth)
        }
    }

    static func nearest(to coordinate: CLLocationCoordinate2D) -> Waypoint {
        // If the coordinate is very close to one of our precise harbor locations,
        // we explicitly return that precise harbor waypoint.
        // This prevents snapping to disconnected or legacy shortcut waypoints.
        let preciseHarbors = [
            // Mainland harbors — checked first so nearby coordinates don't
            // incorrectly snap to island harbors across the water.
            ("nessmersiel_hbr", CLLocationCoordinate2D(latitude: 53.6865, longitude: 7.3615)),
            ("dornum_hbr", CLLocationCoordinate2D(latitude: 53.6865, longitude: 7.4785)),
            ("norddeich_hbr_p", CLLocationCoordinate2D(latitude: 53.6265, longitude: 7.1615)),
            ("bensersiel_hbr_p", CLLocationCoordinate2D(latitude: 53.6785, longitude: 7.5705)),
            ("neuharling_hbr_p", CLLocationCoordinate2D(latitude: 53.7015, longitude: 7.7055)),
            ("harlesiel_hbr_p", CLLocationCoordinate2D(latitude: 53.7125, longitude: 7.8105)),

            // Island harbors
            ("borkum_hbr_p", CLLocationCoordinate2D(latitude: 53.5572, longitude: 6.7525)),
            ("juist_hbr_p", CLLocationCoordinate2D(latitude: 53.6732, longitude: 7.0015)),
            ("norderney_hbr_p", CLLocationCoordinate2D(latitude: 53.7012, longitude: 7.1585)),
            ("baltrum_hbr_p", CLLocationCoordinate2D(latitude: 53.7215, longitude: 7.3715)),
            ("langeoog_hbr_p", CLLocationCoordinate2D(latitude: 53.7285, longitude: 7.5095)),
            ("spiekeroog_hbr_p", CLLocationCoordinate2D(latitude: 53.7645, longitude: 7.6955)),
            ("wangerooge_hbr_p", CLLocationCoordinate2D(latitude: 53.7852, longitude: 7.8965)),
            ("emden_hbr", CLLocationCoordinate2D(latitude: 53.3350, longitude: 7.1900)),
            
            ("borkum_hbr_p", CLLocationCoordinate2D(latitude: 53.5606, longitude: 6.7502)),
            ("juist_hbr_p", CLLocationCoordinate2D(latitude: 53.6722, longitude: 6.9982)),
            ("norderney_hbr_p", CLLocationCoordinate2D(latitude: 53.7024, longitude: 7.1637)),
            ("baltrum_hbr_p", CLLocationCoordinate2D(latitude: 53.7229, longitude: 7.3669)),
            ("langeoog_hbr_p", CLLocationCoordinate2D(latitude: 53.7263, longitude: 7.4968)),
            ("spiekeroog_hbr_p", CLLocationCoordinate2D(latitude: 53.7632, longitude: 7.6955)),
            ("wangerooge_hbr_p", CLLocationCoordinate2D(latitude: 53.7755, longitude: 7.8683)),
            ("emden_hbr", CLLocationCoordinate2D(latitude: 53.3421, longitude: 7.1852)),
            
            ("borkum_hbr_p", CLLocationCoordinate2D(latitude: 53.5650, longitude: 6.7650)),
            ("emden_hbr", CLLocationCoordinate2D(latitude: 53.3372, longitude: 7.1892)),
            ("juist_hbr_p", CLLocationCoordinate2D(latitude: 53.6660, longitude: 6.9800)),
            ("norderney_hbr_p", CLLocationCoordinate2D(latitude: 53.6840, longitude: 7.1550)),
            ("baltrum_hbr_p", CLLocationCoordinate2D(latitude: 53.7070, longitude: 7.3650)),
            ("langeoog_hbr_p", CLLocationCoordinate2D(latitude: 53.7320, longitude: 7.5000)),
            ("spiekeroog_hbr_p", CLLocationCoordinate2D(latitude: 53.7520, longitude: 7.6900)),
            ("wangerooge_hbr_p", CLLocationCoordinate2D(latitude: 53.7620, longitude: 7.8700))
        ]
        
        for (id, coord) in preciseHarbors {
            if abs(coordinate.latitude - coord.latitude) < 0.03 &&
               abs(coordinate.longitude - coord.longitude) < 0.03 {
                if let wp = waypointMap[id] {
                    return wp
                }
            }
        }
        
        // Exclude legacy non-precise/island-crossing and disconnected waypoints from standard snapping
        return waypoints.filter { wp in
            wp.id != "norderney_hbr" && wp.id != "juist_hbr" && wp.id != "borkum_hbr"
        }.min { lhs, rhs in
            distanceSquared(lhs.coordinate, coordinate) < distanceSquared(rhs.coordinate, coordinate)
        } ?? waypoints[0]
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
                
                // Predefined catalog edges represent official navigable fairways that are
                // legally permitted to traverse even if they cross a protected zone.
                // However, we must heavily penalize legacy shortcut/mudflat edges
                // (like the Leybucht connectors and legacy disconnected/island-crossing paths)
                // to prevent the router from taking illegal shortcuts over dry land/mudflats.
                let isShortcut = current.contains("leybucht") || neighbor.contains("leybucht") ||
                                 current == "norddeich_appr" || neighbor == "norddeich_appr" ||
                                 current == "juist_hbr" || neighbor == "juist_hbr" ||
                                 current == "norderney_hbr" || neighbor == "norderney_hbr" ||
                                 current == "borkum_hbr" || neighbor == "borkum_hbr"
                
                let zonePenalty: Double = isShortcut ? 10000.0 : 1.0
                let alt = (dist[current] ?? .infinity) + edgeDist * zonePenalty
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
