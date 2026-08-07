import Foundation

protocol NautiConversationRepository: Sendable {
    func load() async throws -> [NautiConversation]
    func save(_ conversations: [NautiConversation]) async throws
}

enum NautiConversationRepositoryError: LocalizedError, Equatable {
    case corruptedHistory(backupName: String)

    var errorDescription: String? {
        switch self {
        case .corruptedHistory(let backupName):
            return "Die lokale Chat-Historie war beschädigt. Eine Sicherung wurde als \(backupName) abgelegt."
        }
    }
}

actor FileNautiConversationRepository: NautiConversationRepository {
    static let shared = FileNautiConversationRepository()

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("TideNode", isDirectory: true)
                .appendingPathComponent("Nauti", isDirectory: true)
                .appendingPathComponent("conversations-v1.json", isDirectory: false)
        }
    }

    func load() async throws -> [NautiConversation] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([NautiConversation].self, from: data)
        } catch {
            let backupURL = try preserveCorruptedHistory()
            throw NautiConversationRepositoryError.corruptedHistory(
                backupName: backupURL.lastPathComponent
            )
        }
    }

    func save(_ conversations: [NautiConversation]) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(conversations)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func preserveCorruptedHistory() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let backupURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "conversations-corrupt-\(formatter.string(from: .now)).json",
                isDirectory: false
            )

        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.moveItem(at: fileURL, to: backupURL)
        return backupURL
    }
}
