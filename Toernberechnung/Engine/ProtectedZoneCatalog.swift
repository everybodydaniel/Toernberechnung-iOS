import Foundation
import CoreLocation

// MARK: - Schutzgebietskatalog
//
// Liest die mitgelieferte Datei `nordsbefv_eastfrisia.geojson` als gefilterten
// und vereinfachten Auszug der Befahrensverordnung für das niedersächsische
// Wattenmeer. Stellt zwei Abfragen für die Routenführung bereit:
//
//   • `segmentBlocked(a:b:)` — true, wenn der Abschnitt a→b ein Schutzgebiet
//     kreuzt oder ein Endpunkt darin liegt.
//   • `polygons` — Koordinatenringe für die Kartendarstellung.
//
// Vorsorglich wird jedes Gebiet als gesperrt behandelt. Die Kennzeichnung
// `seasonal` bleibt erhalten, damit die Oberfläche später saisonale und
// ganzjährige Sperrungen unterschiedlich darstellen kann.

enum ProtectedZoneCatalog {

    struct Zone: Sendable {
        let name: String
        let typ: String
        let seasonal: Bool
        let outerRing: [CLLocationCoordinate2D]
        /// Gespeichertes Begrenzungsrechteck (minLon, minLat, maxLon, maxLat).
        let bbox: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)
    }

    static let zones: [Zone] = loadZones()

    // MARK: - Öffentliche Abfrage

    /// Prüft, ob ein Schutzgebiet den Abschnitt a→b sperrt.
    /// Für den lokalen Bereich wird die Großkreisverbindung als ebener Abschnitt angenähert.
    static func segmentBlocked(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        let segBox = (
            minLon: min(a.longitude, b.longitude),
            minLat: min(a.latitude, b.latitude),
            maxLon: max(a.longitude, b.longitude),
            maxLat: max(a.latitude, b.latitude)
        )
        for zone in zones {
            guard bboxOverlaps(zone.bbox, segBox) else { continue }
            if segmentCrossesPolygon(a: a, b: b, ring: zone.outerRing) {
                return true
            }
            // Sonderfall: Beide Endpunkte liegen im Gebiet. Auch ohne Grenzübertritt ist der Abschnitt gesperrt.
            if pointInRing(a, ring: zone.outerRing) || pointInRing(b, ring: zone.outerRing) {
                return true
            }
        }
        return false
    }

    // MARK: - Geometrische Grundfunktionen

    private static func bboxOverlaps(
        _ a: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double),
        _ b: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)
    ) -> Bool {
        !(a.maxLon < b.minLon || a.minLon > b.maxLon
          || a.maxLat < b.minLat || a.minLat > b.maxLat)
    }

    /// Prüft mit einem gedachten Strahl, ob der Punkt im Polygon liegt.
    /// Der Ring ist normalerweise geschlossen (erster == letzter Punkt); offene Ringe werden ebenfalls verarbeitet.
    private static func pointInRing(_ p: CLLocationCoordinate2D, ring: [CLLocationCoordinate2D]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0 ..< ring.count {
            let yi = ring[i].latitude,  xi = ring[i].longitude
            let yj = ring[j].latitude,  xj = ring[j].longitude
            let intersect = ((yi > p.latitude) != (yj > p.latitude))
                && (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi)
            if intersect { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Prüft, ob der Abschnitt a→b eine Kante von `ring` kreuzt.
    private static func segmentCrossesPolygon(
        a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
        ring: [CLLocationCoordinate2D]
    ) -> Bool {
        guard ring.count >= 2 else { return false }
        for i in 0 ..< ring.count - 1 {
            if segmentsIntersect(a, b, ring[i], ring[i + 1]) { return true }
        }
        // Offenen Ring schließen.
        if let first = ring.first, let last = ring.last,
           first.latitude != last.latitude || first.longitude != last.longitude {
            if segmentsIntersect(a, b, last, first) { return true }
        }
        return false
    }

    private static func segmentsIntersect(
        _ p1: CLLocationCoordinate2D, _ p2: CLLocationCoordinate2D,
        _ p3: CLLocationCoordinate2D, _ p4: CLLocationCoordinate2D
    ) -> Bool {
        let d1 = direction(p3, p4, p1)
        let d2 = direction(p3, p4, p2)
        let d3 = direction(p1, p2, p3)
        let d4 = direction(p1, p2, p4)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        // Sonderfälle mit Punkten auf derselben Geraden prüfen.
        if d1 == 0, onSegment(p3, p4, p1) { return true }
        if d2 == 0, onSegment(p3, p4, p2) { return true }
        if d3 == 0, onSegment(p1, p2, p3) { return true }
        if d4 == 0, onSegment(p1, p2, p4) { return true }
        return false
    }

    private static func direction(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D
    ) -> Double {
        (c.longitude - a.longitude) * (b.latitude - a.latitude)
            - (b.longitude - a.longitude) * (c.latitude - a.latitude)
    }

    private static func onSegment(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D
    ) -> Bool {
        min(a.longitude, b.longitude) <= c.longitude && c.longitude <= max(a.longitude, b.longitude)
            && min(a.latitude, b.latitude) <= c.latitude && c.latitude <= max(a.latitude, b.latitude)
    }

    // MARK: - Laden aus dem App-Bundle

    private struct RawCollection: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let typ: String?
                let name: String?
                let seasonal: Bool?
            }
            struct Geometry: Decodable {
                let type: String
                let coordinates: [[[Double]]]
            }
            let properties: Properties?
            let geometry: Geometry
        }
        let features: [Feature]
    }

    private static func loadZones() -> [Zone] {
        guard let url = Bundle.main.url(forResource: "nordsbefv_eastfrisia", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(RawCollection.self, from: data)
        else {
            #if DEBUG
            print("[ProtectedZoneCatalog] nordsbefv_eastfrisia.geojson not found in bundle")
            #endif
            return []
        }
        return raw.features.compactMap { feature -> Zone? in
            guard feature.geometry.type == "Polygon",
                  let outer = feature.geometry.coordinates.first
            else { return nil }
            let ring = outer.compactMap { pt -> CLLocationCoordinate2D? in
                guard pt.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pt[1], longitude: pt[0])
            }
            guard ring.count >= 3 else { return nil }
            let lats = ring.map(\.latitude)
            let lons = ring.map(\.longitude)
            return Zone(
                name: feature.properties?.name ?? "",
                typ: feature.properties?.typ ?? "",
                seasonal: feature.properties?.seasonal ?? false,
                outerRing: ring,
                bbox: (lons.min() ?? 0, lats.min() ?? 0, lons.max() ?? 0, lats.max() ?? 0)
            )
        }
    }
}
