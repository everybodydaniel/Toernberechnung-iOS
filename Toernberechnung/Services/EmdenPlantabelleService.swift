import Foundation

// MARK: - Emden Plantabelle Service
//
// Downloads the WSA Ems-Nordsee "Plantabelle Emden" survey PDF from BSCW.
// The PDF contains scheduled fairway depths in SKN (Seekartennull / LAT).
// We don't OCR the PDF here — instead the service caches the raw file so
// the user can open the latest version externally, and we expose the file's
// publication date / size as a freshness signal for the catalog.
//
// Source: https://bscw.bund.de/pub/bscw.cgi/d87422538/plantabelle_gesamt_emden.pdf

actor EmdenPlantabelleService {

    static let shared = EmdenPlantabelleService()

    private let url = URL(string: "https://bscw.bund.de/pub/bscw.cgi/d87422538/plantabelle_gesamt_emden.pdf")!
    private var cached: CachedSnapshot?
    private let cacheLifetime: TimeInterval = 24 * 3600  // 24 hours

    struct CachedSnapshot: Equatable {
        let fileURL: URL
        let lastModified: Date?
        let sizeBytes: Int
        let fetchedAt: Date
    }

    /// Returns the cached snapshot if fresh, otherwise refreshes from BSCW.
    /// Nil on failure.
    func snapshot(force: Bool = false) async -> CachedSnapshot? {
        if !force, let cached,
           Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let file = dir.appendingPathComponent("plantabelle_gesamt_emden.pdf")
            try data.write(to: file, options: .atomic)

            let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                .flatMap(Self.httpDateFormatter.date(from:))

            let snapshot = CachedSnapshot(
                fileURL: file,
                lastModified: lastModified,
                sizeBytes: data.count,
                fetchedAt: Date()
            )
            cached = snapshot
            return snapshot
        } catch {
            return nil
        }
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return f
    }()
}
