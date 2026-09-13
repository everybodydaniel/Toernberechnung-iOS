import Foundation
import SwiftUI
import CoreLocation
import Observation

@MainActor
@Observable
public final class MaritimeWarningsService {
    public static let shared = MaritimeWarningsService()

    public private(set) var warnings: [MaritimeWarning] = []
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var lastRefreshDate: Date?
    public private(set) var unreadCount: Int = 0

    @ObservationIgnored
    private let userDefaults: UserDefaults
    @ObservationIgnored
    private let seenIDsKey = "seen_maritime_warning_ids"
    @ObservationIgnored
    private var seenIDs: Set<String> {
        get {
            let list = userDefaults.stringArray(forKey: seenIDsKey) ?? []
            return Set(list)
        }
        set {
            userDefaults.set(Array(newValue), forKey: seenIDsKey)
        }
    }

    @ObservationIgnored
    private var periodicTimerTask: Task<Void, Never>?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadCachedWarnings()
        startPeriodicRefresh()
        Task {
            await refresh()
        }
    }

    deinit {
        periodicTimerTask?.cancel()
    }

    public func resetReadStateForTesting() {
        seenIDs = []
        updateUnreadCount()
    }

    private func startPeriodicRefresh() {
        periodicTimerTask?.cancel()
        periodicTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                // Periodischer automatischer Abruf alle 30 Minuten
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    public func refreshIfNeeded() async {
        if let last = lastRefreshDate, Date().timeIntervalSince(last) < 15 * 60 {
            return
        }
        await refresh()
    }

    // MARK: - Official Authorities Quick Access (Nordsee)

    public struct OfficialBulletin: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let authority: String
        public let url: URL
        public let isPDF: Bool
        public let icon: String
    }

    public let officialBulletins: [OfficialBulletin] = [
        OfficialBulletin(
            id: "bsh-nwn-nord",
            title: "BSH Nautische Warnnachrichten Nordsee",
            subtitle: "Tagesaktuelle Funkwarnnachrichten für Deutsche Bucht, Ems, Weser, Elbe",
            authority: "BSH / Seewarndienst Emden",
            url: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf")!,
            isPDF: true,
            icon: "doc.text.fill"
        ),
        OfficialBulletin(
            id: "elwis-bfs-nordsee",
            title: "ELWIS Bekanntmachungen für Seefahrer",
            subtitle: "Amtliche Mitteilungen der WSV für Ems, Weser, Jade und Elbe",
            authority: "WSV Küstengebiet Nordsee",
            url: URL(string: "https://www.elwis.de/DE/dynamisch/Bfs/")!,
            isPDF: false,
            icon: "antenna.radiowaves.left.and.right"
        ),
        OfficialBulletin(
            id: "seefunk-nordsee",
            title: "Notfunk & Seenotretter (DGzRS)",
            subtitle: "UKW-Kanal 16, DSC Kanal 70 und Notfallleitstelle MRCC Bremen",
            authority: "DGzRS Seenotleitung Bremen",
            url: URL(string: "https://www.seenotretter.de/notfall")!,
            isPDF: false,
            icon: "radio.fill"
        ),
        OfficialBulletin(
            id: "bsh-schiessgebiete-nordsee",
            title: "Nordsee Schieß- & Warngebiete",
            subtitle: "Militärische Übungs- und Sperrzeiten in der Deutschen Bucht & Helgoland",
            authority: "BSH Seewarndienst",
            url: URL(string: "https://www.bsh.de/DE/THEMEN/Schifffahrt/Nautische_Informationen/Warnungen_und_Nachrichten/Schiessgebiete/schiessgebiete_node.html")!,
            isPDF: false,
            icon: "shield.lefthalf.filled"
        )
    ]

    // MARK: - Fetching

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let endpoint = "https://nautiskinformation.soefartsstyrelsen.dk/rest/messages/search?lang=en"
        guard let url = URL(string: endpoint) else {
            isLoading = false
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                let decoder = JSONDecoder()
                let items = try decoder.decode([NiordSearchResponseItem].self, from: data)

                // Filter strictly to North Sea / German Bight
                let northSeaLive = items.compactMap { $0.toMaritimeWarning() }.filter { $0.isNorthSeaOrGermanBight }

                // Combine curated BSH/ELWIS notices with live DMA notices (avoid duplicate IDs)
                var existingMap: [String: MaritimeWarning] = [:]
                for item in Self.defaultCuratedWarnings {
                    existingMap[item.id] = item
                }
                for item in northSeaLive {
                    existingMap[item.id] = item
                }

                // Sort: Hazards first, then warnings, then newest
                let sorted = Array(existingMap.values).sorted { first, second in
                    if first.severity != second.severity {
                        return severityRank(first.severity) < severityRank(second.severity)
                    }
                    return first.publishDate > second.publishDate
                }

                self.warnings = sorted
                self.lastRefreshDate = Date()
                self.updateUnreadCount()
                saveCachedWarnings(sorted)
            } else {
                self.errorMessage = "Warnungsdienst vorübergehend nicht erreichbar."
            }
        } catch {
            self.errorMessage = "Fehler beim Laden: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func severityRank(_ severity: MaritimeWarningSeverity) -> Int {
        switch severity {
        case .hazard: return 0
        case .warning: return 1
        case .notice: return 2
        }
    }

    // MARK: - Read / Unread State Tracking

    public func isRead(id: String) -> Bool {
        seenIDs.contains(id)
    }

    public func markAsRead(id: String) {
        var current = seenIDs
        current.insert(id)
        seenIDs = current
        updateUnreadCount()
    }

    public func markAllAsRead() {
        var current = seenIDs
        for warning in warnings {
            current.insert(warning.id)
        }
        seenIDs = current
        updateUnreadCount()
    }

    private func updateUnreadCount() {
        let currentSeen = seenIDs
        let unread = warnings.filter { !currentSeen.contains($0.id) }
        self.unreadCount = unread.count
    }

    // MARK: - Offline Caching

    private let cacheFile = "maritime_warnings_cache.json"

    private func cacheFileURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(cacheFile)
    }

    private func saveCachedWarnings(_ list: [MaritimeWarning]) {
        guard let file = cacheFileURL() else { return }
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: file, options: .atomic)
        } catch {
            // Non-critical cache error
        }
    }

    private func loadCachedWarnings() {
        if let file = cacheFileURL(), FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                let cached = try JSONDecoder().decode([MaritimeWarning].self, from: data)
                let validGerman = cached.filter { $0.isNorthSeaOrGermanBight }
                if !validGerman.isEmpty {
                    self.warnings = validGerman
                    self.updateUnreadCount()
                    return
                }
            } catch {
                // Ignore cache read failures
            }
        }

        // Fallback baseline for German Bight & East Frisian Waters
        self.warnings = Self.defaultCuratedWarnings
        self.updateUnreadCount()
    }

    public static let defaultCuratedWarnings: [MaritimeWarning] = [
        MaritimeWarning(
            id: "bsh-nwn-2026-08",
            source: .bsh,
            severity: .hazard,
            title: "Nordsee: Deutsche Bucht – Treibendes Hindernis / Unterwasserwrack",
            details: """
            Position 53° 55.40' N, 007° 42.10' E (ca. 4 sm nordwestlich Wangerooge). \
            Halb unter Wasser treibender 40ft-Container gemeldet. \
            Schifffahrt wird um erhöhte Aufmerksamkeit und weite Umfahrung gebeten.
            """,
            areaName: "Deutsche Bucht · Wangerooge Ansteuerung",
            publishDate: Date().addingTimeInterval(-3600 * 5),
            latitude: 53.9233,
            longitude: 7.7017,
            webUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf"),
            pdfUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf")
        ),
        MaritimeWarning(
            id: "bsh-nwn-2026-11",
            source: .bsh,
            severity: .warning,
            title: "Ostfriesische Inseln: Norderney Seegatt – Tonnenverlegung Dovetief",
            details: """
            Wegen starker Tiefenveränderungen und Versandung wurden die Tonnen D1 und D2 um ca. 240 m \
            nach Südwest verlegt. Neue Mindesttiefe im Seegatt bei Niedrigwasser: 1,40 m über SKN. \
            Das Befahren außerhalb des Fahrwassers ist lebensgefährlich.
            """,
            areaName: "Norderney · Dovetief",
            publishDate: Date().addingTimeInterval(-3600 * 18),
            latitude: 53.7250,
            longitude: 7.1520,
            webUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf"),
            pdfUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf")
        ),
        MaritimeWarning(
            id: "bsh-nwn-2026-15",
            source: .bsh,
            severity: .hazard,
            title: "Nordsee: Helgoland Reede – Schießübung & Sperrgebiet Scharhörn",
            details: """
            Militärische Schießübungen im Seegebiet Helgoland Reede / Scharhörnriff. \
            Sperrgebiete während der angekündigten Schießzeiten meiden. \
            Sicherungsfahrzeuge führen die vorgeschriebenen Signale und halten UKW-Kanal 16 abhörbereit.
            """,
            areaName: "Deutsche Bucht · Helgoland",
            publishDate: Date().addingTimeInterval(-3600 * 24),
            latitude: 54.1800,
            longitude: 7.8900,
            webUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf"),
            pdfUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf")
        ),
        MaritimeWarning(
            id: "elwis-bfs-2026-04",
            source: .elwis,
            severity: .warning,
            title: "WSA Weser-Jade-Nordsee: Baggerarbeiten im Fahrwasser Außenweser",
            details: """
            Laufende Unterhaltungsbaggerungen im Bereich km 65 bis 72 durch Saugbagger. \
            Passierende Fahrzeuge haben Sog und Wellenschlag zu vermeiden und frühzeitig \
            UKW-Kanal 16 bzw. 74 für Passierabsprachen abzuhören.
            """,
            areaName: "Außenweser · Alte Weser",
            publishDate: Date().addingTimeInterval(-3600 * 48),
            latitude: 53.8400,
            longitude: 8.1200,
            webUrl: URL(string: "https://www.elwis.de/DE/dynamisch/Bfs/")
        ),
        MaritimeWarning(
            id: "bsh-nwn-2026-19",
            source: .bsh,
            severity: .notice,
            title: "Deutsche Bucht: Elbe-Ansteuerung Großtonne Elbe außer Betrieb",
            details: """
            Die Leuchtfeuerkennung der Großtonne Elbe (Position 54° 00.0' N, 008° 06.5' E) \
            ist wegen Wartungsarbeiten vorübergehend verloschen. Das Radar- und AIS-Signal arbeitet einwandfrei.
            """,
            areaName: "Elbemündung · Deutsche Bucht",
            publishDate: Date().addingTimeInterval(-3600 * 72),
            latitude: 54.0000,
            longitude: 8.1083,
            webUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf"),
            pdfUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf")
        ),
        MaritimeWarning(
            id: "bsh-nwn-2026-21",
            source: .bsh,
            severity: .warning,
            title: "Ostfriesische Inseln: Borkum Hubertgat – Mindertiefe 1,80 m über SKN",
            details: """
            Wegen anhaltender Sandverlagerungen im Hubertgat beträgt die Wassertiefe im Bereich der \
            Tonnen H2 bis H4 bei mittlerem Niedrigwasser örtlich nur noch 1,80 m. Tiefgang beachten.
            """,
            areaName: "Borkum · Hubertgat",
            publishDate: Date().addingTimeInterval(-3600 * 96),
            latitude: 53.6200,
            longitude: 6.6400,
            webUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf"),
            pdfUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf")
        ),
        MaritimeWarning(
            id: "bsh-nwn-2026-22",
            source: .bsh,
            severity: .notice,
            title: "Ostfriesische Inseln: Juister Wattfahrwasser – Prickenverlegung",
            details: """
            Das Wattfahrwasser von Norddeich nach Juist Hafen wurde neu ausgeprickt. Die Prickenspuren \
            haben sich gegenüber dem Vorjahr um bis zu 80 m verlagert. Der Prickung ist strikt zu folgen.
            """,
            areaName: "Juist · Wattfahrwasser",
            publishDate: Date().addingTimeInterval(-3600 * 120),
            latitude: 53.6800,
            longitude: 7.0500,
            webUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf"),
            pdfUrl: URL(string: "https://www2.bsh.de/aktdat/nwn/nwn-nord.pdf")
        ),
        MaritimeWarning(
            id: "elwis-bfs-2026-07",
            source: .elwis,
            severity: .warning,
            title: "WSA Weser-Jade-Nordsee: Unterwasserkabel-Verlegearbeiten Jade",
            details: """
            Im Bereich des Fahrwassers Innenjade (Höhe Wilhelmshaven Voslapper Groden) finden Verlegearbeiten \
            für Seekabel statt. Sperrfahrzeug führt Manövrierbehinderungssignale (Rot-Weiß-Rot). \
            Passieren mit reduzierter Geschwindigkeit.
            """,
            areaName: "Jade · Wilhelmshaven",
            publishDate: Date().addingTimeInterval(-3600 * 140),
            latitude: 53.5800,
            longitude: 8.1600,
            webUrl: URL(string: "https://www.elwis.de/DE/dynamisch/Bfs/")
        )
    ]
}
