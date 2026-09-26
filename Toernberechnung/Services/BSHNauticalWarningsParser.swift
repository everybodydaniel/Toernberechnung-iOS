import Foundation
import CoreLocation
import PDFKit

/// Liest die amtlichen nautischen Warnnachrichten (NWN) des BSH-Seewarndienstes Emden.
/// PDF-Quelle: `https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf`
public enum BSHNauticalWarningsParser {

    private static let bshPdfURL = URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf")!

    /// Wandelt den aus dem BSH-NWN-PDF gelesenen Text in eine Liste von MaritimeWarning-Objekten um.
    public static func parse(pdfDocument: PDFDocument) -> [MaritimeWarning] {
        var fullText = ""
        for i in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: i), let pageText = page.string {
                fullText += pageText + "\n"
            }
        }
        return parse(text: fullText)
    }

    /// Wandelt den BSH-NWN-Rohtext in strukturierte `MaritimeWarning`-Einträge um.
    public static func parse(text: String) -> [MaritimeWarning] {
        guard !text.isEmpty else { return [] }

        var results: [MaritimeWarning] = []
        var seenIDs = Set<String>()

        // 1. Nummerierte deutsche nautische Warnnachrichten
        // Beispielkopf: "141100 utc sep 26\nnautische warnnachricht nr. 518\n..."
        let pattern = "(?i)(\\d{6}\\s+utc\\s+[a-z]{3}\\s+\\d{2})\\s*\\n\\s*nautische warnnachricht nr\\.\\s*(\\d+)\\s*\\n"
            + "([\\s\\S]*?)(?=\\d{6}\\s+utc|nautische warnnachrichten|navigational warning|eom|$)"

        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsString = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

            for match in matches {
                guard match.numberOfRanges >= 4 else { continue }
                let dateRaw = nsString.substring(with: match.range(at: 1))
                let number = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                let bodyRaw = nsString.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)

                // Navtex-Verzeichnisse und Zusammenfassungen überspringen, z. B. "1. navtex- gebiet (s) warnungen gueltig ab..."
                if bodyRaw.lowercased().contains("navtex- gebiet (s) warnungen") || bodyRaw.lowercased().contains("navtex- area (s) warnings") {
                    continue
                }

                let pubDate = parseBSHDate(dateRaw) ?? Date()
                let calendar = Calendar(identifier: .gregorian)
                let year = calendar.component(.year, from: pubDate)
                let warningID = "bsh-nwn-\(year)-\(number)"

                if seenIDs.contains(warningID) { continue }
                seenIDs.insert(warningID)

                let coordinate = parseCoordinate(from: bodyRaw)
                let severity = classifySeverity(body: bodyRaw)
                let (title, area) = extractTitleAndArea(number: number, body: bodyRaw)
                let cleanDetails = formatDetails(bodyRaw)

                let warning = MaritimeWarning(
                    id: warningID,
                    source: .bsh,
                    severity: severity,
                    title: title,
                    details: cleanDetails,
                    areaName: area,
                    publishDate: pubDate,
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude,
                    webUrl: bshPdfURL,
                    pdfUrl: bshPdfURL
                )
                results.append(warning)
            }
        }

        // 2. Lokale und nationale Warnungen ohne Nummer, z. B. "lister tief 3 verloescht"
        if let localWarning = parseLocalNationalWarning(from: text) {
            if !seenIDs.contains(localWarning.id) {
                results.append(localWarning)
            }
        }

        return results
    }

    // MARK: - Datum einlesen

    private static let bshDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "ddHHmm 'utc' MMM yy"
        return df
    }()

    public static func parseBSHDate(_ raw: String) -> Date? {
        let cleaned = raw.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return bshDateFormatter.date(from: cleaned)
    }

    // MARK: - Koordinaten einlesen

    /// Erkennt BSH-Koordinaten wie `54-22,0n 005-51,6e`, `53-46,7n 007-09,9e` oder `53-43n 007-14e`.
    public static func parseCoordinate(from text: String) -> CLLocationCoordinate2D? {
        let pattern = "(?i)(\\d{2})-(\\d{1,2}(?:[,.]\\d+)?)[ns]\\s+(\\d{2,3})-(\\d{1,2}(?:[,.]\\d+)?)[ew]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }

        let latDegStr = ns.substring(with: match.range(at: 1))
        let latMinStr = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: ".")
        let lonDegStr = ns.substring(with: match.range(at: 3))
        let lonMinStr = ns.substring(with: match.range(at: 4)).replacingOccurrences(of: ",", with: ".")

        guard let latDeg = Double(latDegStr), let latMin = Double(latMinStr),
              let lonDeg = Double(lonDegStr), let lonMin = Double(lonMinStr) else { return nil }

        let lat = latDeg + (latMin / 60.0)
        let lon = lonDeg + (lonMin / 60.0)

        // Koordinaten auf einen plausiblen Bereich nahe Nord- und Ostsee prüfen
        guard (50.0...60.0).contains(lat) && (0.0...20.0).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Schweregrad zuordnen

    public static func classifySeverity(body: String) -> MaritimeWarningSeverity {
        let lower = body.lowercased()

        let hazardKeywords = [
            "munitionsfund", "munition", "kampfmittel", "unterwasserhindernis",
            "wrack", "untiefe", "gefahr fuer", "sperrgebiet", "untersagt",
            "verboten", "treibendes hindernis", "sperrung"
        ]
        if hazardKeywords.contains(where: { lower.contains($0) }) {
            return .hazard
        }

        let warningKeywords = [
            "unterwasserarbeiten", "unterwasser arbeiten", "taucherarbeiten",
            "sondierung", "manoevrierfaehig", "abstand", "mindertiefe",
            "flachstelle", "tonnenverlegung", "verlegt", "ausgefallen",
            "verloescht", "unzuverlaessig", "fehlt", "vertrieben",
            "baggerarbeiten", "kabelverlegearbeiten"
        ]
        if warningKeywords.contains(where: { lower.contains($0) }) {
            return .warning
        }

        return .notice
    }

    // MARK: - Titel und Gebiet auslesen

    private static func extractTitleAndArea(number: String, body: String) -> (title: String, area: String) {
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else {
            return ("BSH Warnung Nr. \(number)", "Deutsche Bucht & Nordsee")
        }

        // Gebiet: meist erster Satz oder erste Zeile
        let cleanFirst = germanizeText(firstLine)
        let parts = cleanFirst.components(separatedBy: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let area: String
        if parts.count >= 2 {
            area = "\(parts[0].capitalizedWords()) · \(parts[1].capitalizedWords())"
        } else {
            area = cleanFirst.capitalizedWords()
        }

        // Titel: Thema aus der zweiten Zeile oder einem maßgeblichen Satz
        var title = "Nautische Warnnachricht Nr. \(number)"
        if lines.count > 1 {
            var subj = lines[1]
            // Technische Funkrufzeichen wie ", rz '9ha4953'" entfernen
            subj = subj.replacingOccurrences(of: "(?i),?\\s*rz\\s*['\"][^'\"]+['\"]", with: "", options: .regularExpression)
            // Angehängte Ortsangaben für einen kurzen Titel entfernen
            subj = subj.replacingOccurrences(of: "(?i)\\s+auf\\s+(ungefaehr|position).*", with: "", options: .regularExpression)
            subj = subj.replacingOccurrences(of: "(?i)\\s+zwischen.*", with: "", options: .regularExpression)
            subj = subj.replacingOccurrences(of: "(?i)\\s+im\\s+gebiet.*", with: "", options: .regularExpression)
            subj = germanizeText(subj).trimmingCharacters(in: CharacterSet(charactersIn: "., \n\t"))

            if !subj.isEmpty {
                let capitalizedSubj = subj.prefix(1).uppercased() + subj.dropFirst()
                title = "Nr. \(number): \(capitalizedSubj)"
            }
        }

        return (title, area)
    }

    // MARK: - Lokale und nationale Warnungen ohne Nummer

    private static func parseLocalNationalWarning(from text: String) -> MaritimeWarning? {
        let pattern = "(?i)-local warnings-[^)]*\\)\\s*([\\s\\S]*?)(?=\\n[a-z\\s]+islands|\\neom|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }

        let raw = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let first = lines.first else { return nil }
        let area = germanizeText(first).capitalizedWords()
        let subj = lines.dropFirst().joined(separator: " ")
        let cleanSubj = germanizeText(subj).trimmingCharacters(in: CharacterSet(charactersIn: "., \t"))
        let title = cleanSubj.isEmpty ? "Lokale Warnnachricht" : cleanSubj.prefix(1).uppercased() + cleanSubj.dropFirst()

        let severity = classifySeverity(body: raw)
        let coord = parseCoordinate(from: raw)

        let slug = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: "-")
        let localID = slug.isEmpty ? "bsh-nwn-local" : "bsh-nwn-local-\(slug)"

        return MaritimeWarning(
            id: localID,
            source: .bsh,
            severity: severity,
            title: title,
            details: formatDetails(raw),
            areaName: area,
            publishDate: Date(),
            latitude: coord?.latitude,
            longitude: coord?.longitude,
            webUrl: bshPdfURL,
            pdfUrl: bshPdfURL
        )
    }

    // MARK: - Hilfsfunktionen zur Textbereinigung

    private static func formatDetails(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return germanizeText(joined)
    }

    private static func germanizeText(_ str: String) -> String {
        var res = str
        let replacements: [(String, String)] = [
            ("noerdlich", "nördlich"),
            ("Noerdlich", "Nördlich"),
            ("oestlich", "östlich"),
            ("Oestlich", "Östlich"),
            ("suedlich", "südlich"),
            ("Suedlich", "Südlich"),
            ("westlich", "westlich"),
            ("Westlich", "Westlich"),
            ("manoevrierfaehig", "manövrierfähig"),
            ("geaendert", "geändert"),
            ("verloescht", "verloschen"),
            ("fuer", "für"),
            ("ueber", "über"),
            ("einschraenkt", "eingeschränkt"),
            ("gueltig", "gültig"),
            ("ungefaehr", "ungefähr"),
            ("vollstaendigen", "vollständigen"),
            ("flachstelle", "Flachstelle"),
            ("mindertiefe", "Mindertiefe")
        ]
        for (old, new) in replacements {
            res = res.replacingOccurrences(of: old, with: new)
        }
        return res
    }
}

private extension String {
    func capitalizedWords() -> String {
        self.components(separatedBy: " ")
            .map { word in
                if word.hasPrefix("'") || word.hasPrefix("\"") {
                    return word
                }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
