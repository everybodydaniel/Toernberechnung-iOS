import CoreTransferable
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Unveränderliche Kopie: Beim Teilen wird kein SwiftData-Modell außerhalb des MainActor gelesen.
struct CrewCalendarExport: Identifiable, Sendable, Transferable {
    let id: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let location: String
    let notes: String
    let category: String
    let isAllDay: Bool
    let attendees: [String]

    @MainActor
    init(event: CrewEventRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity = try encoder.encode(event.persistentModelID)
        id = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        title = event.title
        startsAt = event.startsAt
        endsAt = event.endsAt
        location = event.location
        notes = event.notes
        category = event.category
        isAllDay = event.isAllDay
        attendees = event.attendees
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "ics") ?? .calendarEvent) { event in
            SentTransferredFile(try event.writeFile())
        }
    }

    var fileName: String {
        let safeTitle = title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((safeTitle.isEmpty ? "TideNode-Termin" : safeTitle).prefix(70)) + ".ics"
    }

    func writeFile() throws -> URL {
        // Ein eigenes Verzeichnis verhindert, dass gleichzeitige Exporte einander überschreiben.
        // Das Betriebssystem räumt temporäre Dateien auf; Empfänger können sie nach dem Schließen noch lesen.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TideNode-Calendar", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try Data(calendarText().utf8).write(to: url, options: .atomic)
        return url
    }

    /// RFC 5545: UTC-Zeitpunkte, exklusives Ende ganztägiger Termine, maskierter TEXT und umgebrochene UTF-8-Zeilen.
    func calendarText(generatedAt: Date = .now) -> String {
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.calendar = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//TideNode//Crewspace//DE",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:\(id)@tidenode.app",
            "DTSTAMP:\(utc.string(from: generatedAt))"
        ]
        if isAllDay {
            let calendar = AppDateFormatters.berlinCalendar
            let dateOnly = DateFormatter()
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.calendar = calendar
            dateOnly.timeZone = calendar.timeZone
            dateOnly.dateFormat = "yyyyMMdd"
            let lastDay = calendar.startOfDay(for: max(startsAt, endsAt))
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            lines.append("DTSTART;VALUE=DATE:\(dateOnly.string(from: startsAt))")
            lines.append("DTEND;VALUE=DATE:\(dateOnly.string(from: exclusiveEnd))")
        } else {
            lines.append("DTSTART:\(utc.string(from: startsAt))")
            // Bei DATE-TIME muss das Ende nach dem Beginn liegen.
            let end = endsAt > startsAt ? endsAt : startsAt.addingTimeInterval(60)
            lines.append("DTEND:\(utc.string(from: end))")
        }
        lines.append("SUMMARY:\(Self.escape(title))")
        if !location.isEmpty { lines.append("LOCATION:\(Self.escape(location))") }
        lines.append("CATEGORIES:\(Self.escape(category))")

        var description = [String]()
        if !notes.isEmpty { description.append(notes) }
        // Crew-Namen dienen nur der Beschreibung.
        if !attendees.isEmpty { description.append("Crew: \(attendees.joined(separator: ", "))") }
        description.append("Geplant mit TideNode · Crewspace")
        lines.append("DESCRIPTION:\(Self.escape(description.joined(separator: "\n\n")))")
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(Self.fold).joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }
            .map(String.init).joined()
    }

    private static func fold(_ line: String) -> String {
        var result = ""
        var count = 0
        for scalar in line.unicodeScalars {
            let text = String(scalar)
            let size = text.utf8.count
            if count + size > 75 {
                result += "\r\n "
                count = 1
            }
            result += text
            count += size
        }
        return result
    }
}

enum CrewEventFormat {
    static func timeRange(_ event: CrewEventRecord) -> String {
        guard !event.isAllDay else { return "ganztägig" }
        let start = AppDateFormatters.hourMinute.string(from: event.startsAt)
        let end = AppDateFormatters.hourMinute.string(from: event.endsAt)
        return "\(start) – \(end) Uhr"
    }
}
