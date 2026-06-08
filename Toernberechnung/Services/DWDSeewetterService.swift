import Foundation

// MARK: - DWD Seewetterbericht Service
//
// Fetches the textual DWD Seewetterbericht for "Nord-/Ostsee" from
// https://www.dwd.de/DE/leistungen/seewetternordostsee/seewetternordostsee.html
//
// This is a supplementary text feed that augments the structured MOSMIX
// values provided by `DWDCompactService`. The Seewetterbericht is a plain
// HTML page with embedded `<pre>` blocks containing the text bulletin —
// we extract the bulletin text without rendering, and the calling code can
// surface it next to the structured numbers.

actor DWDSeewetterService {

    static let shared = DWDSeewetterService()

    private let url = URL(string: "https://www.dwd.de/DE/leistungen/seewetternordostsee/seewetternordostsee.html")!
    private var cached: (text: String, fetchedAt: Date)?
    private let cacheLifetime: TimeInterval = 3 * 3600

    struct Report: Equatable {
        let text: String
        let fetchedAt: Date
    }

    /// Returns the latest Seewetterbericht text, or nil on failure.
    func report(force: Bool = false) async -> Report? {
        if !force, let cached, Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return Report(text: cached.text, fetchedAt: cached.fetchedAt)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iOS Toernberechnung)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return nil }

            let text = Self.extractBulletin(html: html)
            guard !text.isEmpty else { return nil }
            cached = (text, Date())
            return Report(text: text, fetchedAt: Date())
        } catch {
            return nil
        }
    }

    /// Extract the text of any `<pre>` block — DWD wraps the bulletin inside.
    static func extractBulletin(html: String) -> String {
        let stripped = html.replacingOccurrences(of: "\r", with: "")
        let pattern = #"<pre[^>]*>(?<body>[\s\S]*?)</pre>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return "" }
        let nsRange = NSRange(stripped.startIndex..., in: stripped)
        var collected: [String] = []
        regex.enumerateMatches(in: stripped, options: [], range: nsRange) { match, _, _ in
            guard let match,
                  let range = Range(match.range(withName: "body"), in: stripped)
            else { return }
            let body = stripped[range]
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            collected.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return collected.joined(separator: "\n\n")
    }
}
