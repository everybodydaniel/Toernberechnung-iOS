import Foundation
import CoreLocation
import SwiftUI

// MARK: - Quelle und Schweregrad nautischer Warnungen

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
    case hazard   // Rot: Sperrungen, akute Gefahr, Wracks, Treibgut
    case warning  // Gelb: verlegte Tonnen, Baggerarbeiten, Schießgebiete
    case notice   // Blau: allgemeine nautische Hinweise

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

    public var displayColor: Color {
        switch self {
        case .hazard: return .red
        case .warning: return .orange
        case .notice: return .cyan
        }
    }
}

// MARK: - Zentrales Datenmodell

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

    public var formattedCoordinates: String? {
        guard let latitude, let longitude else { return nil }
        let latDeg = Int(abs(latitude))
        let latMin = (abs(latitude) - Double(latDeg)) * 60.0
        let latDir = latitude >= 0 ? "N" : "S"

        let lonDeg = Int(abs(longitude))
        let lonMin = (abs(longitude) - Double(lonDeg)) * 60.0
        let lonDir = longitude >= 0 ? "E" : "W"

        return String(format: "%02d°%05.2f' %@ · %03d°%05.2f' %@", latDeg, latMin, latDir, lonDeg, lonMin, lonDir)
    }

    public var isNorthSeaOrGermanBight: Bool {
        let lower = "\(areaName) \(title) \(details)".lowercased()
        // Dänische Meldungen und Meldungen für fremde Ostseegebiete ausschließen
        let foreignKeywords = [
            "dänemark", "denmark", "danmark", "rømø", "romo",
            "lister dyb", "kattegat", "vejers", "great belt",
            "sound", "esbjerg", "bornholm", "limfjord", "fanø", "fanoe"
        ]
        if foreignKeywords.contains(where: { lower.contains($0) }) {
            return false
        }
        if let lat = latitude, let lon = longitude {
            // Koordinatenbereich für Deutsche Bucht, ostfriesische Inseln, Helgoland, Elbe, Weser, Jade und Ems.
            // Helgoland liegt bei 54,18° N.
            // Die Nordgrenze von 54,4° N schließt dänische Gebiete aus (Rømø 55,08° N, Lister Dyb 55,09° N, Vejers 55,6° N).
            if (53.1...54.4).contains(lat) && (6.2...9.2).contains(lon) {
                return true
            }
        }
        let keywords = [
            "deutsche bucht", "german bight",
            "ems", "weser", "elbe", "jade", "borkum", "norderney",
            "juist", "baltrum", "langeoog", "spiekeroog", "wangerooge",
            "helgoland", "wattenmeer", "wadden"
        ]
        return keywords.contains { lower.contains($0) }
    }

    public var isBalticSea: Bool {
        let text = "\(areaName) \(title) \(details)".lowercased()
        let keywords = ["ostsee", "baltic", "kiel", "flensburg", "fehmarn", "rostock", "ruegen", "bornholm"]
        return keywords.contains { text.contains($0) }
    }
}

// MARK: - Modelle zum Dekodieren der DMA-Niord-API

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

    private static func stripAndDecodeHTMLEntities(_ text: String) -> String {
        var str = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&deg;", "°"),
            ("&nbsp;", " "),
            ("&raquo;", "»"),
            ("&laquo;", "«"),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&ndash;", "–"),
            ("&mdash;", "—")
        ]
        for (ent, val) in entities {
            str = str.replacingOccurrences(of: ent, with: val)
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func germanizeMaritimeText(_ text: String) -> String {
        var res = stripAndDecodeHTMLEntities(text)
        let replacements: [(String, String)] = [
            ("Firing exercises", "Militärische Schießübungen"),
            ("firing exercises", "Militärische Schießübungen"),
            ("Warning", "Warnung"),
            ("warning", "Warnung"),
            ("The North Sea", "Nordsee"),
            ("the North Sea", "Nordsee"),
            ("Denmark", "Dänemark"),
            ("Light unlit", "Leuchtfeuer verloschen"),
            ("Light unreliable", "Leuchtfeuer unzuverlässig"),
            ("Light buoy moved", "Leuchttonne verlegt"),
            ("Light buoy", "Leuchttonne"),
            ("Buoy missing", "Tonne fehlt / vertrieben"),
            ("Buoy off station", "Tonne verlegt"),
            ("Buoyage off station", "Betonnung verlegt"),
            ("Maintenance", "Wartungsarbeiten"),
            ("Underwater operations", "Unterwasserarbeiten"),
            ("Cable laying operations", "Kabelverlegearbeiten"),
            ("Dredging operations", "Baggerarbeiten"),
            ("Shoal reported", "Untiefe gemeldet"),
            ("Wreck", "Wrack"),
            ("hours", "Uhr"),
            ("September", "September"),
            ("October", "Oktober"),
            ("November", "November"),
            ("December", "Dezember"),
            ("January", "Januar"),
            ("February", "Februar"),
            ("March", "März"),
            ("May", "Mai"),
            ("June", "Juni"),
            ("July", "Juli")
        ]
        for (eng, deu) in replacements {
            res = res.replacingOccurrences(of: eng, with: deu)
        }
        return res
    }

    func toMaritimeWarning() -> MaritimeWarning? {
        guard let warnId = shortId ?? id?.value, !warnId.isEmpty else { return nil }

        // Englische Beschreibung suchen oder auf eine andere Beschreibung zurückgreifen
        let desc = descs?.first(where: { $0.lang == "en" }) ?? descs?.first
        let title = desc?.title ?? "Nautische Warnung \(shortId ?? warnId)"

        // Koordinaten und Einzelheiten auslesen
        var coordinates: (lat: Double, lon: Double)? = nil
        var detailsText = ""

        if let firstPart = parts?.first {
            if let geom = firstPart.geometry, let features = geom.features {
                for feat in features {
                    if let geomObj = feat.geometry, let coords = geomObj.coordinates {
                        if let firstPoint = coords.firstPoint {
                            coordinates = firstPoint
                            break
                        }
                    }
                }
            }
            if let partDesc = firstPart.descs?.first(where: { $0.lang == "en" }) ?? firstPart.descs?.first {
                detailsText = Self.stripAndDecodeHTMLEntities(partDesc.details ?? "")
            }
        }

        if detailsText.isEmpty {
            detailsText = Self.stripAndDecodeHTMLEntities(desc?.details ?? "Keine weiteren Details angegeben.")
        }

        // Gebietsname
        let areaName = areas?.compactMap { $0.descs?.first?.name }.joined(separator: " · ")
            ?? "Deutsche Bucht & Nordsee"

        // Schweregrad
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
            title: Self.germanizeMaritimeText(title),
            details: Self.germanizeMaritimeText(detailsText),
            areaName: Self.germanizeMaritimeText(areaName),
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
