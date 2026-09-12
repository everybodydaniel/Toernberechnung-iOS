import Foundation
import SwiftData
import XCTest
@testable import Toernberechnung

final class CrewPlanningTests: XCTestCase {
    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([CrewMemberRecord.self, CrewEventRecord.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: iso))
    }

    @MainActor
    func testEventsPersistAndFilterByDay() throws {
        let context = try makeContext()
        let morning = try date("2026-07-16T08:00:00+02:00")
        let evening = try date("2026-07-16T19:00:00+02:00")
        let nextDay = try date("2026-07-17T09:00:00+02:00")

        context.insert(CrewEventRecord(title: "Ablegen", startsAt: morning, endsAt: morning.addingTimeInterval(3600)))
        context.insert(CrewEventRecord(title: "Crewtreffen", startsAt: evening, endsAt: evening.addingTimeInterval(5400)))
        context.insert(CrewEventRecord(title: "Rückfahrt", startsAt: nextDay, endsAt: nextDay.addingTimeInterval(7200)))
        try context.save()

        let stored = try context.fetch(
            FetchDescriptor<CrewEventRecord>(sortBy: [SortDescriptor(\.startsAt, order: .forward)])
        )
        XCTAssertEqual(stored.map(\.title), ["Ablegen", "Crewtreffen", "Rückfahrt"])

        let sameDay = stored.filter { Calendar.current.isDate($0.startsAt, inSameDayAs: morning) }
        XCTAssertEqual(sameDay.map(\.title), ["Ablegen", "Crewtreffen"])
    }

    @MainActor
    func testEventEditAndDeleteAffectOnlyTheTargetedRecord() throws {
        let context = try makeContext()
        let start = try date("2026-07-16T14:00:00+02:00")
        let keeper = CrewEventRecord(title: "Bleibt", startsAt: start, endsAt: start.addingTimeInterval(3600))
        let target = CrewEventRecord(title: "Ablegen", startsAt: start, endsAt: start.addingTimeInterval(3600))
        context.insert(keeper)
        context.insert(target)
        try context.save()

        target.title = "Ablegen Norderney"
        target.location = "Norderney Hafen"
        target.notes = "Schwimmwesten prüfen"
        try context.save()

        var stored = try context.fetch(FetchDescriptor<CrewEventRecord>())
        let edited = try XCTUnwrap(stored.first { $0.title == "Ablegen Norderney" })
        XCTAssertEqual(edited.location, "Norderney Hafen")
        XCTAssertEqual(edited.notes, "Schwimmwesten prüfen")
        XCTAssertEqual(try XCTUnwrap(stored.first { $0.title == "Bleibt" }).location, "")

        context.delete(edited)
        try context.save()

        stored = try context.fetch(FetchDescriptor<CrewEventRecord>())
        XCTAssertEqual(stored.map(\.title), ["Bleibt"])
    }

    @MainActor
    func testCrewMembersAreLocalAndTrackOnBoardState() throws {
        let context = try makeContext()
        context.insert(CrewMemberRecord(name: "Daniel", role: CrewRoleOption.skipper.rawValue, isOnBoard: true))
        context.insert(CrewMemberRecord(name: "Lea", role: CrewRoleOption.deck.rawValue, isOnBoard: false))
        try context.save()

        let stored = try context.fetch(
            FetchDescriptor<CrewMemberRecord>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.filter(\.isOnBoard).map(\.name), ["Daniel"])

        let lea = try XCTUnwrap(stored.first { $0.name == "Lea" })
        lea.isOnBoard = true
        try context.save()

        let reloaded = try context.fetch(FetchDescriptor<CrewMemberRecord>())
        XCTAssertEqual(reloaded.filter(\.isOnBoard).count, 2)
    }

    func testCategoryResolutionFallsBackToOtherForUnknownRawValues() {
        XCTAssertEqual(CrewEventCategory.resolved("Törnstart"), .departure)
        XCTAssertEqual(CrewEventCategory.resolved("Wartung"), .maintenance)
        XCTAssertEqual(CrewEventCategory.resolved(""), .other)
        XCTAssertEqual(CrewEventCategory.resolved("Aus einer neueren Version"), .other)
    }

    @MainActor
    func testCalendarExportContainsFieldsAndUTCInstants() throws {
        let start = try date("2026-07-16T14:00:00+02:00")
        let event = CrewEventRecord(
            title: "Ablegen Norderney", startsAt: start, endsAt: start.addingTimeInterval(3600),
            location: "Norderney Hafen", notes: "Schwimmwesten prüfen",
            category: CrewEventCategory.departure.rawValue, attendees: ["Daniel", "Lea"]
        )
        let text = try CrewCalendarExport(event: event).calendarText(generatedAt: start)
            .replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertTrue(text.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"))
        XCTAssertTrue(text.hasSuffix("END:VEVENT\r\nEND:VCALENDAR\r\n"))
        XCTAssertTrue(text.contains("DTSTAMP:20260716T120000Z"))
        XCTAssertTrue(text.contains("DTSTART:20260716T120000Z"))
        XCTAssertTrue(text.contains("DTEND:20260716T130000Z"))
        XCTAssertTrue(text.contains("SUMMARY:Ablegen Norderney"))
        XCTAssertTrue(text.contains("LOCATION:Norderney Hafen"))
        XCTAssertTrue(text.contains("CATEGORIES:Törnstart"))
        XCTAssertTrue(text.contains("Schwimmwesten prüfen"))
        XCTAssertTrue(text.contains("Crew: Daniel\\, Lea"))
        XCTAssertFalse(text.contains("ATTENDEE:"))
    }

    @MainActor
    func testAllDayExportUsesExclusiveEndAcrossDaylightSavingChange() throws {
        let event = CrewEventRecord(
            title: "Überführung", startsAt: try date("2026-10-25T00:00:00+02:00"),
            endsAt: try date("2026-10-25T23:59:00+01:00"), isAllDay: true
        )
        let text = try CrewCalendarExport(event: event).calendarText()
        XCTAssertTrue(text.contains("DTSTART;VALUE=DATE:20261025\r\n"))
        XCTAssertTrue(text.contains("DTEND;VALUE=DATE:20261026\r\n"))
        XCTAssertFalse(text.contains("DTSTART:"))
        XCTAssertTrue(CrewEventFormat.timeRange(event).contains("ganztägig"))
    }

    @MainActor
    func testCalendarExportEscapesTextAndFoldsWithoutBreakingUnicode() throws {
        let start = try date("2026-09-18T15:00:00+02:00")
        let title = "Törn, Crew; \\ Hafen\r\nBEGIN:VEVENT"
        let notes = String(repeating: "Grüße ⚓️ 🌊 ", count: 40)
        let event = CrewEventRecord(title: title, startsAt: start, endsAt: start, notes: notes)
        let export = try CrewCalendarExport(event: event)
        let text = export.calendarText()
        let lines = text.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 75 })
        XCTAssertTrue(lines.contains { $0.hasPrefix(" ") })
        XCTAssertEqual(lines.filter { $0 == "BEGIN:VEVENT" }.count, 1)
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertTrue(unfolded.contains("SUMMARY:Törn\\, Crew\\; \\\\ Hafen\\nBEGIN:VEVENT"))
        XCTAssertTrue(unfolded.contains(notes))
        XCTAssertTrue(unfolded.contains("DTEND:20260918T130100Z"))
        XCTAssertFalse(export.fileName.contains("/"))
        XCTAssertFalse(export.fileName.contains("\n"))
    }

    @MainActor
    func testCalendarIdentityIsStableAfterEditingAndRefetching() throws {
        let context = try makeContext()
        let start = try date("2026-09-18T15:00:00+02:00")
        let event = CrewEventRecord(title: "Törn", startsAt: start, endsAt: start.addingTimeInterval(3600))
        context.insert(event)
        try context.save()
        let original = try CrewCalendarExport(event: event)
        event.title = "Neuer Titel"
        event.startsAt = start.addingTimeInterval(1800)
        try context.save()
        let freshContext = ModelContext(context.container)
        let fetched = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<CrewEventRecord>()).first)
        XCTAssertEqual(try CrewCalendarExport(event: fetched).id, original.id)
        let other = CrewEventRecord(title: fetched.title, startsAt: fetched.startsAt, endsAt: fetched.endsAt)
        context.insert(other)
        try context.save()
        XCTAssertNotEqual(try CrewCalendarExport(event: other).id, original.id)
    }

    @MainActor
    func testSharedFileIsICalendarAndKeepsIndependentExports() throws {
        let start = try date("2026-09-18T15:00:00+02:00")
        let event = CrewEventRecord(title: "Ablegen / Norderney", startsAt: start, endsAt: start.addingTimeInterval(3600))
        let export = try CrewCalendarExport(event: event)
        let first = try export.writeFile()
        let second = try export.writeFile()
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        XCTAssertEqual(first.pathExtension, "ics")
        XCTAssertNotEqual(first, second)
        let text = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(text.contains("SUMMARY:Ablegen / Norderney"))
        XCTAssertFalse(text.contains("LOCATION:"))
        XCTAssertFalse(text.contains("Crew:"))
    }

    @MainActor
    func testCategoryAndAttendeesSurviveAStoreRoundTrip() throws {
        let context = try makeContext()
        let start = try date("2026-07-16T09:00:00+02:00")
        context.insert(CrewEventRecord(
            title: "Sicherheitseinweisung",
            startsAt: start,
            endsAt: start.addingTimeInterval(1800),
            category: CrewEventCategory.briefing.rawValue,
            isAllDay: false,
            attendees: ["Daniel", "Lea"]
        ))
        try context.save()

        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<CrewEventRecord>()).first)
        XCTAssertEqual(stored.resolvedCategory, .briefing)
        XCTAssertEqual(stored.attendees, ["Daniel", "Lea"])
        XCTAssertFalse(stored.isAllDay)
    }

    func testCrewRoleNormalizationFallsBackToCrew() {
        XCTAssertEqual(CrewRoleOption.normalizedRole("Skipper"), "Skipper")
        XCTAssertEqual(CrewRoleOption.normalizedRole("Wachführung"), "Wachführung")
        XCTAssertEqual(CrewRoleOption.normalizedRole("Unbekannt"), "Crew")
        XCTAssertEqual(CrewRoleOption.option(for: "Sicherheit/Medizin").shortLabel, "Medizin")
    }
}
