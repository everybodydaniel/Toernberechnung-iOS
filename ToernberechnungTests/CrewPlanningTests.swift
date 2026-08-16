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
    func testShareTextContainsEveryFilledFieldAndSkipsEmptyOnes() throws {
        let start = try date("2026-07-16T14:00:00+02:00")
        let full = CrewEventRecord(
            title: "Ablegen Norderney",
            startsAt: start,
            endsAt: start.addingTimeInterval(3600),
            location: "Norderney Hafen",
            notes: "Schwimmwesten prüfen",
            category: CrewEventCategory.departure.rawValue,
            attendees: ["Daniel", "Lea"]
        )

        let text = full.shareText
        XCTAssertTrue(text.hasPrefix("Ablegen Norderney"))
        XCTAssertTrue(text.contains("14:00–15:00 Uhr"))
        XCTAssertTrue(text.contains("Ort: Norderney Hafen"))
        XCTAssertTrue(text.contains("Crew: Daniel, Lea"))
        XCTAssertTrue(text.contains("Schwimmwesten prüfen"))
        XCTAssertTrue(text.hasSuffix("Geplant mit TideNode"))

        let bare = CrewEventRecord(
            title: "Crewtreffen",
            startsAt: start,
            endsAt: start.addingTimeInterval(1800)
        )
        XCTAssertFalse(bare.shareText.contains("Ort:"))
        XCTAssertFalse(bare.shareText.contains("Crew:"))
    }

    @MainActor
    func testAllDayEventReportsTheDayInsteadOfATimeRange() throws {
        let start = try date("2026-07-16T00:00:00+02:00")
        let event = CrewEventRecord(
            title: "Überführung",
            startsAt: start,
            endsAt: try date("2026-07-16T23:59:00+02:00"),
            isAllDay: true
        )
        XCTAssertTrue(event.shareText.contains("ganztägig"))
        XCTAssertFalse(event.shareText.contains("–"))
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
