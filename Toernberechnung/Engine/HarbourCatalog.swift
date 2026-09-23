import CoreLocation
import Foundation

struct HarbourOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let chartDepth: Double
    let tideStationID: String
    let tideStationName: String

    static let options: [HarbourOption] = [
        .init(id: "borkum_harbor", name: "Borkum, Fischerbalje", latitude: 53.5606, longitude: 6.7502, chartDepth: 3.0, tideStationID: "101P", tideStationName: "Borkum, Fischerbalje"),
        .init(id: "emden_harbor", name: "Emden, Hafen", latitude: 53.3421, longitude: 7.1852, chartDepth: 5.0, tideStationID: "507P", tideStationName: "Emden, Große Seeschleuse"),
        .init(id: "juist_harbor", name: "Juist, Hafen", latitude: 53.6722, longitude: 6.9982, chartDepth: -1.2, tideStationID: "794P", tideStationName: "Juist, Hafen"),
        .init(id: "norderney_harbor", name: "Norderney, Hafen", latitude: 53.7024, longitude: 7.1637, chartDepth: 1.5, tideStationID: "111P", tideStationName: "Norderney, Riffgat"),
        .init(id: "baltrum_harbor", name: "Baltrum, Hafen", latitude: 53.7229, longitude: 7.3669, chartDepth: -1.0, tideStationID: "784P", tideStationName: "Baltrum, Westende"),
        .init(id: "langeoog_harbor", name: "Langeoog, Hafen", latitude: 53.7263, longitude: 7.4968, chartDepth: -0.5, tideStationID: "781P", tideStationName: "Langeoog, Hafeneinfahrt"),
        .init(id: "spiekeroog_harbor", name: "Spiekeroog, Hafen", latitude: 53.7632, longitude: 7.6955, chartDepth: -0.8, tideStationID: "779P", tideStationName: "Spiekeroog"),
        .init(id: "wangerooge_harbor", name: "Wangerooge, Hafen", latitude: 53.7755, longitude: 7.8683, chartDepth: -0.6, tideStationID: "777P", tideStationName: "Wangerooge, Hafen")
    ]

    static func byID(_ id: String) -> HarbourOption {
        options.first(where: { $0.id == id }) ?? options[0]
    }

    static func optionalByID(_ id: String?) -> HarbourOption? {
        guard let id, !id.isEmpty else { return nil }
        return options.first(where: { $0.id == id })
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var coordinate: (latitude: Double, longitude: Double) {
        (latitude, longitude)
    }
}

enum BSHTideStationKind: String, Codable, Sendable {
    case gauge
    case interpolated

    var label: String {
        switch self {
        case .gauge: return "Pegel"
        case .interpolated: return "Interpolierter Pegel"
        }
    }
}

enum BSHTideStationArea: String, Codable, Sendable {
    case island
    case mainland

    var label: String {
        switch self {
        case .island: return "Ostfriesische Inseln"
        case .mainland: return "Festland und Referenzpegel"
        }
    }
}

/// Canonical station metadata shared by the tide UI and route calculation.
/// IDs and names match the BSH station index published at
/// `https://gezeiten.bsh.de/data/tides_overview.json`.
struct BSHTideStation: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let seoID: String
    let latitude: Double
    let longitude: Double
    let kind: BSHTideStationKind
    let area: BSHTideStationArea
    let forecastFeatureID: String?

    var hasLocalWaterLevelForecast: Bool { forecastFeatureID != nil }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distanceKilometers(to other: BSHTideStation) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude)) / 1_000
    }
}

enum BSHTideStationCatalog {
    /// Curated meteorological comparison gauges. The local station continues
    /// to provide HW/NW timing; only the wind-driven residual is transferred.
    /// These assignments are hydrologically explicit and must never be
    /// replaced by an arbitrary straight-line nearest-neighbour choice.
    private static let requiredComparisonStationIDs: [String: String] = [
        "101P": "507P", // Borkum -> Emden (Ems)
        "794P": "111P", // Juist -> Norderney
        "784P": "781P"  // Baltrum -> Langeoog
    ]

    static let stations: [BSHTideStation] = [
        .init(id: "101P", name: "Borkum, Fischerbalje", seoID: "borkum_fischerbalje", latitude: 53.55750, longitude: 6.74778, kind: .interpolated, area: .island, forecastFeatureID: nil),
        .init(id: "794P", name: "Juist, Hafen", seoID: "juist_hafen", latitude: 53.67250, longitude: 6.99583, kind: .interpolated, area: .island, forecastFeatureID: nil),
        .init(id: "111P", name: "Norderney, Riffgat", seoID: "norderney_riffgat", latitude: 53.69639, longitude: 7.15778, kind: .gauge, area: .island, forecastFeatureID: "norderney_riffgat"),
        .init(id: "784P", name: "Baltrum, Westende", seoID: "baltrum_westende", latitude: 53.72278, longitude: 7.36444, kind: .interpolated, area: .island, forecastFeatureID: nil),
        .init(id: "781P", name: "Langeoog, Hafeneinfahrt", seoID: "langeoog_hafeneinfahrt", latitude: 53.72333, longitude: 7.50167, kind: .gauge, area: .island, forecastFeatureID: "langeoog_hafeneinfahrt"),
        .init(id: "779P", name: "Spiekeroog, ehem. Landungsbrücke", seoID: "spiekeroog", latitude: 53.74917, longitude: 7.68194, kind: .gauge, area: .island, forecastFeatureID: "spiekeroog"),
        .init(id: "777P", name: "Wangerooge, Hafen", seoID: "wangerooge_hafen", latitude: 53.77639, longitude: 7.86806, kind: .gauge, area: .island, forecastFeatureID: "wangerooge_hafen"),
        .init(id: "507P", name: "Emden, Ems, Große Seeschleuse", seoID: "emden_grosse_seeschleuse", latitude: 53.33667, longitude: 7.18639, kind: .gauge, area: .mainland, forecastFeatureID: "emden_grosse_seeschleuse"),
        .init(id: "802P", name: "Knock, Ems", seoID: "knock", latitude: 53.32722, longitude: 7.03056, kind: .gauge, area: .mainland, forecastFeatureID: "knock"),
        .init(id: "790A", name: "Norddeich, Westerriede", seoID: "norddeich_westerriede", latitude: 53.64361, longitude: 7.14806, kind: .interpolated, area: .mainland, forecastFeatureID: nil),
        .init(id: "782P", name: "Bensersiel", seoID: "bensersiel", latitude: 53.67472, longitude: 7.57500, kind: .gauge, area: .mainland, forecastFeatureID: "bensersiel"),
        .init(id: "780P", name: "Neuharlingersiel", seoID: "neuharlingersiel", latitude: 53.70167, longitude: 7.70417, kind: .interpolated, area: .mainland, forecastFeatureID: nil),
        .init(id: "778P", name: "Harlesiel, Hafen", seoID: "harlesiel", latitude: 53.70694, longitude: 7.80861, kind: .gauge, area: .mainland, forecastFeatureID: "harlesiel"),
        .init(id: "765P", name: "Hooksiel", seoID: "hooksiel", latitude: 53.64194, longitude: 8.08194, kind: .interpolated, area: .mainland, forecastFeatureID: nil),
        .init(id: "512P", name: "Wilhelmshaven, Alter Vorhafen", seoID: "wilhelmshaven_alter_vorhafen", latitude: 53.51444, longitude: 8.14500, kind: .gauge, area: .mainland, forecastFeatureID: "wilhelmshaven_alter_vorhafen")
    ]

    static var islands: [BSHTideStation] {
        stations.filter { $0.area == .island }
    }

    static var mainland: [BSHTideStation] {
        stations.filter { $0.area == .mainland }
    }

    static func station(id: String) -> BSHTideStation? {
        stations.first { $0.id == id }
    }

    static func station(for harbour: HarbourOption) -> BSHTideStation {
        station(id: harbour.tideStationID) ?? stations[0]
    }

    static func requiredComparisonStation(for stationID: String) -> BSHTideStation? {
        requiredComparisonStationIDs[stationID].flatMap(station(id:))
    }

    static func requiresComparisonStation(_ stationID: String) -> Bool {
        requiredComparisonStationIDs[stationID] != nil
            || station(id: stationID)?.hasLocalWaterLevelForecast == false
    }

    static func usesDirectWaterLevelForecast(_ stationID: String) -> Bool {
        station(id: stationID)?.hasLocalWaterLevelForecast == true
            && requiredComparisonStationIDs[stationID] == nil
    }

    static func comparisonCandidates(for stationID: String, limit: Int = 3) -> [BSHTideStation] {
        guard let local = station(id: stationID) else { return [] }
        return stations
            .filter { $0.id != stationID && $0.hasLocalWaterLevelForecast }
            .sorted { local.distanceKilometers(to: $0) < local.distanceKilometers(to: $1) }
            .prefix(limit)
            .map { $0 }
    }

    static func nearestComparisonStation(for stationID: String) -> BSHTideStation? {
        comparisonCandidates(for: stationID, limit: 1).first
    }
}
