import Foundation
import CoreLocation

enum PathSmoother {

    private static let dpEpsilonMeters = 80.0
    private static let chaikinIterations = 2
    private static let validationSampleMeters = 50.0

    static func smooth(_ path: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard path.count > 2 else { return path }

        let simplified = douglasPeucker(path, epsilon: dpEpsilonMeters)

        var result = simplified
        for _ in 0..<chaikinIterations {
            result = chaikinIteration(result)
        }

        return validateAndFix(smoothed: result, fallback: simplified)
    }

    // MARK: - Vereinfachung nach Douglas-Peucker

    static func simplify(
        _ points: [CLLocationCoordinate2D],
        epsilon: Double
    ) -> [CLLocationCoordinate2D] {
        return douglasPeucker(points, epsilon: epsilon)
    }

    private static func douglasPeucker(
        _ points: [CLLocationCoordinate2D],
        epsilon: Double
    ) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        dpRecurse(points: points, keep: &keep, startIndex: 0, endIndex: points.count - 1, epsilon: epsilon)

        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func dpRecurse(
        points: [CLLocationCoordinate2D],
        keep: inout [Bool],
        startIndex: Int,
        endIndex: Int,
        epsilon: Double
    ) {
        guard endIndex - startIndex > 1 else { return }

        var maxDist = 0.0
        var maxIndex = startIndex

        let a = points[startIndex]
        let b = points[endIndex]

        for i in (startIndex + 1)..<endIndex {
            let dist = perpendicularDistanceMeters(point: points[i], lineStart: a, lineEnd: b)
            if dist > maxDist {
                maxDist = dist
                maxIndex = i
            }
        }

        if maxDist > epsilon {
            keep[maxIndex] = true
            dpRecurse(points: points, keep: &keep, startIndex: startIndex, endIndex: maxIndex, epsilon: epsilon)
            dpRecurse(points: points, keep: &keep, startIndex: maxIndex, endIndex: endIndex, epsilon: epsilon)
        }
    }

    private static func perpendicularDistanceMeters(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> Double {
        let segDLat = lineEnd.latitude - lineStart.latitude
        let segDLon = lineEnd.longitude - lineStart.longitude
        let segLenSq = segDLat * segDLat + segDLon * segDLon

        if segLenSq < 1e-15 {
            return GridConfig.approxMeters(from: point, to: lineStart)
        }

        let pDLat = point.latitude - lineStart.latitude
        let pDLon = point.longitude - lineStart.longitude

        let t = max(0.0, min(1.0, (pDLat * segDLat + pDLon * segDLon) / segLenSq))

        let projLat = lineStart.latitude + t * segDLat
        let projLon = lineStart.longitude + t * segDLon
        let projection = CLLocationCoordinate2D(latitude: projLat, longitude: projLon)

        return GridConfig.approxMeters(from: point, to: projection)
    }

    // MARK: - Unterteilung nach Chaikin

    private static func chaikinIteration(
        _ points: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard points.count >= 2 else { return points }

        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(2 * points.count)

        result.append(points[0])

        for i in 0..<(points.count - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]

            let qLat = 0.75 * p0.latitude + 0.25 * p1.latitude
            let qLon = 0.75 * p0.longitude + 0.25 * p1.longitude

            let rLat = 0.25 * p0.latitude + 0.75 * p1.latitude
            let rLon = 0.25 * p0.longitude + 0.75 * p1.longitude

            result.append(CLLocationCoordinate2D(latitude: qLat, longitude: qLon))
            result.append(CLLocationCoordinate2D(latitude: rLat, longitude: rLon))
        }

        result.append(points[points.count - 1])

        return result
    }

    // MARK: - Prüfung

    private static func validateAndFix(
        smoothed: [CLLocationCoordinate2D],
        fallback: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(smoothed.count)

        for i in 0..<smoothed.count {
            let current = smoothed[i]

            if i > 0 {
                let previous = smoothed[i - 1]
                let segmentDist = GridConfig.approxMeters(from: previous, to: current)
                // Prüft mindestens zwei Schritte und den
                // geschlossenen Bereich `1...steps` einschließlich des Endpunkts bei t = 1.0.
                // Das vorherige `max(1,…)` + `1..<sampleCount` ließ kurze
                // Segmente ungeprüft und übersprang den Endpunkt — dadurch
                // rutschten Land-Querungen durch die Validierung.
                let steps = max(2, Int(segmentDist / validationSampleMeters))

                var segmentBlocked = false
                for s in 1...steps {
                    let fraction = Double(s) / Double(steps)
                    let sampleLat = previous.latitude + fraction * (current.latitude - previous.latitude)
                    let sampleLon = previous.longitude + fraction * (current.longitude - previous.longitude)
                    let sample = CLLocationCoordinate2D(latitude: sampleLat, longitude: sampleLon)

                    let cell = SeaMask.shared.cellAtLatLng(lat: sample.latitude, lon: sample.longitude)
                    if cell.isBlocked {
                        segmentBlocked = true
                        break
                    }
                }

                if segmentBlocked {
                    let fallbackSegment = nearestFallbackSegment(a: previous, b: current, fallback: fallback)
                    for fb in fallbackSegment {
                        result.append(fb)
                    }
                }
            }

            result.append(current)
        }

        return result
    }

    private static func nearestFallbackSegment(
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D,
        fallback: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard fallback.count >= 2 else { return [] }

        var bestStartIdx = 0
        var bestStartDist = Double.greatestFiniteMagnitude
        var bestEndIdx = fallback.count - 1
        var bestEndDist = Double.greatestFiniteMagnitude

        for (i, point) in fallback.enumerated() {
            let distA = GridConfig.approxMeters(from: a, to: point)
            if distA < bestStartDist {
                bestStartDist = distA
                bestStartIdx = i
            }

            let distB = GridConfig.approxMeters(from: b, to: point)
            if distB < bestEndDist {
                bestEndDist = distB
                bestEndIdx = i
            }
        }

        if bestStartIdx > bestEndIdx {
            swap(&bestStartIdx, &bestEndIdx)
        }

        guard bestStartIdx < bestEndIdx else { return [] }

        return Array(fallback[(bestStartIdx + 1)..<bestEndIdx])
    }
}
