import Foundation
import CoreLocation

// MARK: - Maritime Warning Source & Severity

public enum MaritimeWarningSource: String, Codable, Sendable, CaseIterable {
    case bsh = "BSH Seewarndienst"
    case dma = "Danish Maritime Authority"
    case elwis = "ELWIS / WSV"
    case dwd = "DWD Seewetterdienst"

    public var shortName: String {
        switch self {
        case .bsh: return "BSH"
        case .dma: return "DMA"
        case .elwis: return "ELWIS"
        case .dwd: return "DWD"
        }
    }
}

public enum MaritimeWarningSeverity: String, Codable, Sendable, CaseIterable {
    case hazard   // Red: Sperrungen, akute Gefahr, Wracks, Treibgut
    case warning  // Amber: Verlegte Tonnen, Baggerarbeiten, Schießgebiete
    case notice   // Blue: Allgemeine nautische Hinweise

    public var title: String {
        switch self {
        case .hazard: return "Gefahr / Sperrung"
        case .warning: return "Warnung / Behinderung"
        case .notice: return "Nautischer Hinweis"
        }
    }

    public var systemImage: String {
        switch self {
        case .hazard: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .notice: return "info.circle.fill"
        }
    }
}

// MARK: - Primary Domain Model

public struct MaritimeWarning: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let source: MaritimeWarningSource
    public let severity: MaritimeWarningSeverity
    public let title: String
    public let details: String
    public let areaName: String
    public let publishDate: Date
    public let validUntil: Date?
    public let latitude: Double?
    public let longitude: Double?
    public let webUrl: URL?
    public let pdfUrl: URL?

    public init(
        id: String,
        source: MaritimeWarningSource,
        severity: MaritimeWarningSeverity,
        title: String,
        details: String,
        areaName: String,
        publishDate: Date,
        validUntil: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        webUrl: URL? = nil,
        pdfUrl: URL? = nil
    ) {
        self.id = id
        self.source = source
        self.severity = severity
        self.title = title
        self.details = details
        self.areaName = areaName
        self.publishDate = publishDate
        self.validUntil = validUntil
        self.latitude = latitude
        self.longitude = longitude
        self.webUrl = webUrl
        self.pdfUrl = pdfUrl
    }

    public var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var isNorthSeaOrGermanBight: Bool {
        if let lat = latitude, let lon = longitude {
            // Coordinate bounding box for German Bight, East Frisian Islands, and Southern North Sea
            if (53.0...56.2).contains(lat) && (3.0...9.2).contains(lon) {
                return true
            }
        }
        let text = "\(areaName) \(title) \(details)".lowercased()
        let keywords = [
            "nordsee", "north sea", "german bight", "deutsche bucht",
            "ems", "weser", "elbe", "jade", "borkum", "norderney",
            "juist", "baltrum", "langeoog", "spiekeroog", "wangerooge",
            "helgoland", "sylt", "amrum", "foehr", "watt", "wadden",
            "horn rev", "esbjerg", "dan tysk", "butendiek"
        ]
        return keywords.contains { text.contains($0) }
    }

    public var isBalticSea: Bool {
        let text = "\(areaName) \(title) \(details)".lowercased()
        let keywords = ["ostsee", "baltic", "kiel", "flensburg", "fehmarn", "rostock", "ruegen", "bornholm"]
        return keywords.contains { text.contains($0) }
    }
}

// MARK: - DMA Niord API Decoding Models

struct FlexibleID: Decodable, CustomStringConvertible {
    let value: String
    var description: String { value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self.value = str
        } else if let intVal = try? container.decode(Int.self) {
            self.value = String(intVal)
        } else {
            self.value = UUID().uuidString
        }
    }
}

struct NiordSearchResponseItem: Decodable {
    let id: FlexibleID?
    let shortId: String?
    let mainType: String?
    let type: String?
    let status: String?
    let publishDateFrom: Int64?
    let followUpDate: Int64?
    let areas: [NiordArea]?
    let parts: [NiordPart]?
    let descs: [NiordDesc]?

    func toMaritimeWarning() -> MaritimeWarning? {
        guard let warnId = shortId ?? id?.value, !warnId.isEmpty,
              status == "PUBLISHED" || status == nil else {
            return nil
        }

        // Get English or fallback description
        let desc = descs?.first(where: { $0.lang == "en" }) ?? descs?.first
        let title = desc?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? warnId

        // Gather details from parts
        var detailsText = ""
        var coordinates: (lat: Double, lon: Double)?

        if let parts {
            for part in parts {
                if let partDesc = part.descs?.first(where: { $0.lang == "en" }) ?? part.descs?.first,
                   let details = partDesc.details {
                    let cleaned = details
                        .replacingOccurrences(of: "<br/>", with: "\n")
                        .replacingOccurrences(of: "<br>", with: "\n")
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        if !detailsText.isEmpty { detailsText += "\n\n" }
                        detailsText += cleaned
                    }
                }

                // Try to extract coordinate from part geometry
                if coordinates == nil, let geom = part.geometry, let features = geom.features {
                    for feat in features {
                        if let geomObj = feat.geometry, let coords = geomObj.coordinates {
                            if let firstPoint = coords.firstPoint {
                                coordinates = firstPoint
                                break
                            }
                        }
                    }
                }
            }
        }

        if detailsText.isEmpty {
            detailsText = desc?.details?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) ?? "Keine weiteren Details angegeben."
        }

        // Area name
        let areaName = areas?.compactMap { $0.descs?.first?.name }.joined(separator: " · ")
            ?? "Nordsee & Dänemark"

        // Severity
        let severity: MaritimeWarningSeverity
        let upperType = (type ?? "").uppercased()
        let upperMain = (mainType ?? "").uppercased()
        if upperType.contains("FIRING") || upperType.contains("HAZARD") || upperMain == "NW" {
            severity = .hazard
        } else if upperType.contains("AID_TO_NAVIGATION") || upperType.contains("WORK") {
            severity = .warning
        } else {
            severity = .notice
        }

        let pubDate: Date
        if let pubMillis = publishDateFrom {
            pubDate = Date(timeIntervalSince1970: TimeInterval(pubMillis) / 1000)
        } else {
            pubDate = Date()
        }

        let valUntil: Date?
        if let followMillis = followUpDate {
            valUntil = Date(timeIntervalSince1970: TimeInterval(followMillis) / 1000)
        } else {
            valUntil = nil
        }

        return MaritimeWarning(
            id: warnId,
            source: .dma,
            severity: severity,
            title: title,
            details: detailsText,
            areaName: areaName,
            publishDate: pubDate,
            validUntil: valUntil,
            latitude: coordinates?.lat,
            longitude: coordinates?.lon,
            webUrl: URL(string: "https://nautiskinformation.soefartsstyrelsen.dk/#/messages/details/\(warnId)")
        )
    }
}

struct NiordArea: Decodable {
    let id: FlexibleID?
    let descs: [NiordAreaDesc]?
}

struct NiordAreaDesc: Decodable {
    let name: String?
    let lang: String?
}

struct NiordDesc: Decodable {
    let title: String?
    let details: String?
    let lang: String?
}

struct NiordPart: Decodable {
    let descs: [NiordPartDesc]?
    let geometry: NiordGeometryWrapper?
}

struct NiordPartDesc: Decodable {
    let subject: String?
    let details: String?
    let lang: String?
}

struct NiordGeometryWrapper: Decodable {
    let features: [NiordFeature]?
}

struct NiordFeature: Decodable {
    let geometry: NiordGeoJSONGeometry?
}

struct NiordGeoJSONGeometry: Decodable {
    let type: String?
    let coordinates: NiordCoordinates?
}

enum NiordCoordinates: Decodable {
    case point([Double])
    case line([[Double]])
    case polygon([[[Double]]])
    case multiPolygon([[[[Double]]]])
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let pt = try? container.decode([Double].self) {
            self = .point(pt)
        } else if let line = try? container.decode([[Double]].self) {
            self = .line(line)
        } else if let poly = try? container.decode([[[Double]]].self) {
            self = .polygon(poly)
        } else if let multi = try? container.decode([[[[Double]]]].self) {
            self = .multiPolygon(multi)
        } else {
            self = .other
        }
    }

    var firstPoint: (lat: Double, lon: Double)? {
        switch self {
        case .point(let pt):
            if pt.count >= 2 { return (lat: pt[1], lon: pt[0]) }
        case .line(let line):
            if let first = line.first, first.count >= 2 { return (lat: first[1], lon: first[0]) }
        case .polygon(let poly):
            if let ring = poly.first, let first = ring.first, first.count >= 2 {
                return (lat: first[1], lon: first[0])
            }
        case .multiPolygon(let multi):
            if let poly = multi.first, let ring = poly.first, let first = ring.first, first.count >= 2 {
                return (lat: first[1], lon: first[0])
            }
        case .other:
            break
        }
        return nil
    }
}
