import Foundation
import CoreLocation

enum BuoyValidator {

    private static let sampleMeters = 100.0
    private static let maxPlausibleDistanceMeters = 1500.0
    private static let openSeaDepthMeters = 10.0

    enum ValidationStatus {
        case passed
        case suspect
    }

    struct ValidationResult {
        let status: ValidationStatus
        let suspectCount: Int
        let maxBuoyDistanceMeters: Double
        let sampleCount: Int
    }

    static func validate(_ path: [CLLocationCoordinate2D]) -> ValidationResult {
        guard path.count >= 2 else {
            return ValidationResult(status: .passed, suspectCount: 0, maxBuoyDistanceMeters: 0, sampleCount: 0)
        }

        var totalSamples = 0
        var suspectSamples = 0
        var maxBuoyDist = 0.0

        for i in 0..<(path.count - 1) {
            let a = path[i]
            let b = path[i + 1]

            let segmentDist = GridConfig.approxMeters(from: a, to: b)
            let steps = max(1, Int(segmentDist / sampleMeters))

            for s in 0...steps {
                let fraction = Double(s) / Double(steps)
                let sampleLat = a.latitude + fraction * (b.latitude - a.latitude)
                let sampleLon = a.longitude + fraction * (b.longitude - a.longitude)

                let buoyDist = SeaMask.shared.nearestBuoyDistance(lat: sampleLat, lon: sampleLon)
                let depth = SeaMask.shared.depthAtLatLng(lat: sampleLat, lon: sampleLon)

                maxBuoyDist = max(maxBuoyDist, buoyDist)
                totalSamples += 1

                if buoyDist > maxPlausibleDistanceMeters && depth < openSeaDepthMeters {
                    suspectSamples += 1
                }
            }
        }

        let status: ValidationStatus
        if totalSamples > 0 && suspectSamples > totalSamples / 10 {
            status = .suspect
        } else {
            status = .passed
        }

        return ValidationResult(
            status: status,
            suspectCount: suspectSamples,
            maxBuoyDistanceMeters: maxBuoyDist,
            sampleCount: totalSamples
        )
    }
}
