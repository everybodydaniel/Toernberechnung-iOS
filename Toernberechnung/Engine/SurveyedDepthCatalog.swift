import Foundation

/// Dokumentierte hydrographische Lotungen und Vermessungen.
/// Jeder Eintrag enthält Tiefenbezug, Datum der Lotung und Quelle.
struct SurveyedDepthRecord: Equatable, Sendable {
    let identifier: String
    let name: String
    let depthMeters: Double
    let calculationMode: WaypointCalculationMode
    let surveyedAt: Date
    let sourceName: String
    let sourceURL: String?
    let sectionName: String
    let notes: String?
}

enum SurveyedDepthCatalog {

    private static let august2026: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 15
        return AppDateFormatters.berlinCalendar.date(from: components) ?? Date(timeIntervalSince1970: 1_786_752_000)
    }()

    private static let july2026: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 1
        return AppDateFormatters.berlinCalendar.date(from: components) ?? august2026
    }()

    private static let january2021: Date = {
        var components = DateComponents()
        components.year = 2021
        components.month = 1
        components.day = 1
        return AppDateFormatters.berlinCalendar.date(from: components) ?? august2026
    }()

    /// Dokumentierte Wattsegler-Lotungen (Stand: August 2026).
    static let records: [SurveyedDepthRecord] = [
        SurveyedDepthRecord(
            identifier: "borkum_east", name: "Borkumer Wattfahrwasser", depthMeters: 1.70,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Borkumer Wattfahrwasser",
            notes: "1,70 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "memmert_w", name: "Memmert Wattfahrwasser", depthMeters: 2.60,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Memmert Wattfahrwasser",
            notes: "2,60 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "juist_s", name: "Juist-Zufahrt", depthMeters: 1.90,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Juist-Zufahrt",
            notes: "1,90 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "juist_approach",
            name: "Juist-Zufahrt",
            depthMeters: 1.90,
            calculationMode: .lottiefe,
            surveyedAt: august2026,
            sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html",
            sectionName: "Juister Wattfahrwasser / Zufahrt Juist",
            notes: "1,90 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "norderney_sw", name: "Juister Wattfahrwasser", depthMeters: 2.30,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Juister Wattfahrwasser",
            notes: "2,30 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "watt_norden",
            name: "Norderneyer Wattfahrwasser",
            depthMeters: 1.90,
            calculationMode: .lottiefe,
            surveyedAt: august2026,
            sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html",
            sectionName: "Norderneyer Wattfahrwasser",
            notes: "1,90 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "baltrum_s", name: "Baltrumer Wattfahrwasser", depthMeters: 1.60,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Baltrumer Wattfahrwasser",
            notes: "1,60 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "watt_nesskana", name: "Baltrumer Wattfahrwasser", depthMeters: 1.60,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Baltrumer Wattfahrwasser",
            notes: "1,60 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "watt_dornum",
            name: "Baltrumer Wattfahrwasser",
            depthMeters: 1.60,
            calculationMode: .lottiefe,
            surveyedAt: august2026,
            sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html",
            sectionName: "Baltrumer Wattfahrwasser",
            notes: "1,60 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "watt_bensersiel", name: "Langeooger Wattfahrwasser", depthMeters: 1.80,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Langeooger Wattfahrwasser",
            notes: "1,80 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "langeoog_s", name: "Langeoog-Zufahrt", depthMeters: 1.80,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Langeooger Wattfahrwasser",
            notes: "1,80 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "watt_neuharling", name: "Spiekerooger Wattfahrwasser", depthMeters: 2.10,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Spiekerooger Wattfahrwasser",
            notes: "2,10 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "spiekeroog_s", name: "Spiekeroog-Zufahrt", depthMeters: 1.60,
            calculationMode: .lottiefe, surveyedAt: august2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Spiekerooger Wattfahrwasser",
            notes: "1,60 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "watt_harlesiel", name: "Harlesieler Wattfahrwasser (Alte Harle)", depthMeters: 2.00,
            calculationMode: .lottiefe, surveyedAt: july2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Harlesieler Wattfahrwasser",
            notes: "2,00 m bei MHW (Stand 07/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "wangerooge_s", name: "Alte Harle Wattfahrwasser", depthMeters: 2.00,
            calculationMode: .lottiefe, surveyedAt: july2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Alte Harle Wattfahrwasser (Muschelbalje)",
            notes: "2,00 m bei MHW (Stand 07/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "watt_wangerooge", name: "Minsener Oog Wattfahrwasser", depthMeters: 2.10,
            calculationMode: .lottiefe, surveyedAt: july2026, sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html", sectionName: "Minsener Oog Wattfahrwasser",
            notes: "2,10 m bei MHW (Stand 07/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "Norderney_Wattenhoch",
            name: "Norderneyer Wattenhoch",
            depthMeters: 1.90,
            calculationMode: .lottiefe,
            surveyedAt: august2026,
            sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html",
            sectionName: "Norderneyer Wattfahrwasser",
            notes: "1,90 m bei MHW (Stand 08/2026)"
        ),
        SurveyedDepthRecord(
            identifier: "Baltrum_Wattenhoch",
            name: "Baltrumer Wattenhoch",
            depthMeters: 1.60,
            calculationMode: .lottiefe,
            surveyedAt: august2026,
            sourceName: "Wattsegler",
            sourceURL: "https://www.wattsegler.de/lotungen.html",
            sectionName: "Baltrumer Wattfahrwasser",
            notes: "1,60 m bei MHW (Stand 08/2026)"
        )
    ]

    static func record(for identifier: String) -> SurveyedDepthRecord? {
        records.first { $0.identifier.lowercased() == identifier.lowercased() }
    }

    static func displayName(for identifier: String) -> String {
        if let surveyedName = record(for: identifier)?.name { return surveyedName }
        guard identifier.contains("_") else { return identifier }

        let terms = [
            "n": "Nord", "s": "Süd", "e": "Ost", "w": "West",
            "ne": "Nordost", "nw": "Nordwest", "se": "Südost", "sw": "Südwest",
            "mid": "Mitte", "hbr": "Hafen", "appr": "Zufahrt",
            "off": "Außen", "fairway": "Fahrwasser", "watt": "Wattfahrwasser"
        ]
        return identifier.split(separator: "_").map { part in
            let token = String(part).lowercased()
            if let term = terms[token] { return term }
            let suffix = token.dropFirst()
            if suffix.allSatisfy(\.isNumber), !suffix.isEmpty,
               let direction = terms[String(token.prefix(1))] {
                return "\(direction) \(suffix)"
            }
            return String(token.prefix(1)).uppercased() + String(token.dropFirst())
        }.joined(separator: " ")
    }

    /// Ordnet einem Wegpunkt eine dokumentierte Lotung zu, wenn ein passender Eintrag vorliegt.
    /// Ohne dokumentierte Lotung bleibt `surveyedAt == nil`; `.unverifiedDepth` weist
    /// auf die erforderliche Prüfung durch den Skipper hin.
    static func applying(to waypoint: RouteWaypoint, harbourID: String? = nil) -> RouteWaypoint {
        let key = harbourID ?? waypoint.name
        guard let record = record(for: key) else {
            return waypoint
        }

        // Tiefe Fahrwasserrinnen, z. B. die Emsrinne bei borkum_east mit 4,0 m LAT,
        // dürfen nicht durch flache Wattlotungen ersetzt werden, die nur für den
        // trockenfallenden Abzweig über das Wattenhoch gelten.
        if (waypoint.chartDepthMeters?.value ?? 0) >= 3.0 && record.calculationMode == .lottiefe {
            return waypoint
        }

        var updated = waypoint
        let mhw = waypoint.meanHighWaterMeters?.value ?? 3.0
        if record.calculationMode == .lottiefe {
            updated.calculationMode = .lottiefe
            updated.lottiefeMeters = SourcedValue(
                value: record.depthMeters,
                source: .catalog,
                sourceNotes: "\(record.sourceName) (\(record.sectionName))",
                surveyedAt: record.surveyedAt,
                sourceURL: record.sourceURL
            )
            // Auch die Kartentiefe relativ zu LAT erhalten, damit LAT-Berechnung und Lottiefe-Reduktion funktionieren.
            if updated.chartDepthMeters == nil {
                updated.chartDepthMeters = SourcedValue(
                    value: record.depthMeters - mhw,
                    source: .catalog,
                    sourceNotes: "\(record.sourceName) (aus MHW abgeleitet)",
                    surveyedAt: record.surveyedAt,
                    sourceURL: record.sourceURL
                )
            }
        } else {
            updated.calculationMode = .meanHighWater
            updated.chartDepthMeters = SourcedValue(
                value: record.depthMeters,
                source: .catalog,
                sourceNotes: "\(record.sourceName) (\(record.sectionName))",
                surveyedAt: record.surveyedAt,
                sourceURL: record.sourceURL
            )
        }
        if let notes = record.notes {
            updated.notes = updated.notes.isEmpty ? notes : "\(updated.notes); \(notes)"
        }
        return updated
    }
}
