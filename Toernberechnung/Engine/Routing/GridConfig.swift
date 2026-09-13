import Foundation
import CoreLocation

enum GridConfig {

    static let rows = 800
    static let cols = 1500

    static let minLat = 53.30
    static let maxLat = 54.00
    static let minLon = 6.30
    static let maxLon = 8.30

    static let latStep = (maxLat - minLat) / Double(rows)
    static let lonStep = (maxLon - minLon) / Double(cols)

    private static let midLatRad = (minLat + maxLat) / 2.0 * .pi / 180.0
    private static let metersPerLatDeg = 111_320.0
    private static let metersPerLonDeg = metersPerLatDeg * cos(midLatRad)

    // MARK: - Coordinate ↔ Grid Conversion

    static func latToRow(_ lat: Double) -> Int {
        let row = Int((lat - minLat) / latStep)
        return min(max(row, 0), rows - 1)
    }

    static func lonToCol(_ lon: Double) -> Int {
        let col = Int((lon - minLon) / lonStep)
        return min(max(col, 0), cols - 1)
    }

    static func rowToLat(_ row: Int) -> Double {
        minLat + (Double(row) + 0.5) * latStep
    }

    static func colToLon(_ col: Int) -> Double {
        minLon + (Double(col) + 0.5) * lonStep
    }

    // MARK: - Bounds Checking

    static func inBounds(row: Int, col: Int) -> Bool {
        (0..<rows).contains(row) && (0..<cols).contains(col)
    }

    static func inBounds(lat: Double, lon: Double) -> Bool {
        (minLat...maxLat).contains(lat) && (minLon...maxLon).contains(lon)
    }

    // MARK: - Indexing

    static func index(row: Int, col: Int) -> Int {
        row * cols + col
    }

    // MARK: - Distance Calculations

    static func approxMeters(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let dy = (lat2 - lat1) * metersPerLatDeg
        let dx = (lon2 - lon1) * metersPerLonDeg
        return sqrt(dx * dx + dy * dy)
    }

    static func approxMeters(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        approxMeters(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
    }
}
