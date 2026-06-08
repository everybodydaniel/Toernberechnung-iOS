import Foundation

// MARK: - Wattsegler Lotungen Service
//
// Pulls sounded chart depths ("gelotete Wassertiefen") from
// https://www.wattsegler.de/toernplanung/lotungen.html
//
// These soundings are referenced to MHW (NOT to SKN/LAT), which is the
// exact convention the calculation engine expects. Each entry maps a watt-name
// (e.g. "Norderneyer Seegat", "Otzumer Balje") to a depth in meters.
//
// The service performs a lightweight HTML scrape with a regex tailored to
// the published table structure. On any failure it returns an empty
// dictionary so the calculation engine falls back to the bundled catalog.

actor WattseglerLotungenService {

    static let shared = WattseglerLotungenService()

    private let url = URL(string: "https://www.wattsegler.de/toernplanung/lotungen.html")!
    private var cached: (data: [String: Double], fetchedAt: Date)?
    private let cacheLifetime: TimeInterval = 6 * 3600  // 6 hours

    // MARK: - Public API

    /// Fetch the latest sounding map keyed by location name (lowercased).
    /// Empty dictionary on failure.
    func soundings(force: Bool = false) async -> [String: Double] {
        if !force, let cached, Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.data
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iOS Toernberechnung)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return [:] }

            let map = Self.parse(html: html)
            cached = (map, Date())
            return map
        } catch {
            return [:]
        }
    }

    /// Lookup helper — returns nil if no match for the given fairway name.
    func soundedDepth(for fairwayName: String) async -> Double? {
        let map = await soundings()
        let key = fairwayName.lowercased()
        if let direct = map[key] { return direct }
        return map.first(where: { key.contains($0.key) || $0.key.contains(key) })?.value
    }

    // MARK: - HTML Parsing

    /// Extract `<location, depth-in-meters>` pairs from the Lotungen HTML.
    /// The site publishes its table as plain rows of the shape
    /// `<td>Norderneyer Seegat</td><td>… 1,8 m …</td>` (and variants).
    /// We don't bring in a full HTML parser to keep the dependency surface
    /// minimal; the regex is permissive enough for the published format.
    static func parse(html: String) -> [String: Double] {
        let stripped = html.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var result: [String: Double] = [:]

        // Regex: capture a row's first <td> as name and look for the first
        // depth in meters within the row.
        let rowPattern = #"<tr[^>]*>\s*<td[^>]*>(?<name>[^<]+)</td>\s*<td[^>]*>(?<rest>[^<]+)</td>"#
        guard let regex = try? NSRegularExpression(pattern: rowPattern, options: [.caseInsensitive])
        else { return [:] }

        let nsRange = NSRange(stripped.startIndex..., in: stripped)
        let matches = regex.matches(in: stripped, options: [], range: nsRange)

        let depthRegex = try? NSRegularExpression(
            pattern: #"(-?\d+(?:[\.,]\d+)?)\s*m"#,
            options: [.caseInsensitive]
        )

        for match in matches {
            guard let nameRange = Range(match.range(withName: "name"), in: stripped),
                  let restRange = Range(match.range(withName: "rest"), in: stripped)
            else { continue }

            let name = stripped[nameRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
                .lowercased()
            let rest = String(stripped[restRange])

            guard let depthMatch = depthRegex?.firstMatch(
                in: rest, options: [], range: NSRange(rest.startIndex..., in: rest)
            ),
                  let depthRange = Range(depthMatch.range(at: 1), in: rest)
            else { continue }

            let raw = rest[depthRange].replacingOccurrences(of: ",", with: ".")
            if let value = Double(raw) {
                result[name] = value
            }
        }

        return result
    }
}
