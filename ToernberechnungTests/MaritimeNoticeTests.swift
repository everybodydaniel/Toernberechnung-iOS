import XCTest
@testable import Toernberechnung

final class MaritimeNoticeTests: XCTestCase {
    func testUnreadStateTracksEachRevision() {
        var state = MaritimeNoticeReadState()
        let first = makeNotice(revision: 1)
        XCTAssertTrue(state.isUnread(first))

        state.markRead(first)
        XCTAssertFalse(state.isUnread(first))

        let revision = makeNotice(revision: 2)
        XCTAssertTrue(state.isUnread(revision))
        XCTAssertEqual(state.unreadCount(in: [revision]), 1)
    }

    func testMarkAllReadKeepsHighestKnownRevision() {
        var state = MaritimeNoticeReadState()
        state.markAllRead([makeNotice(id: "a", revision: 2), makeNotice(id: "b", revision: 1)])

        XCTAssertFalse(state.isUnread(makeNotice(id: "a", revision: 1)))
        XCTAssertFalse(state.isUnread(makeNotice(id: "a", revision: 2)))
        XCTAssertTrue(state.isUnread(makeNotice(id: "a", revision: 3)))
        XCTAssertEqual(state.unreadCount(in: [makeNotice(id: "a", revision: 2), makeNotice(id: "b", revision: 1)]), 0)
    }

    func testCurrentAndArchiveClassification() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = makeNotice(validUntil: now.addingTimeInterval(3600), state: .current)
        let expired = makeNotice(validUntil: now.addingTimeInterval(-1), state: .current)
        let revoked = makeNotice(validUntil: nil, state: .revoked)

        XCTAssertTrue(current.isCurrent(at: now))
        XCTAssertFalse(expired.isCurrent(at: now))
        XCTAssertFalse(revoked.isCurrent(at: now))
    }

    func testQuickLookPrioritizesUnreadThenNewestCurrentNotices() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unread = makeNotice(id: "unread", updatedAt: now.addingTimeInterval(-300))
        let newest = makeNotice(id: "newest", updatedAt: now)
        let middle = makeNotice(id: "middle", updatedAt: now.addingTimeInterval(-60))
        let oldest = makeNotice(id: "oldest", updatedAt: now.addingTimeInterval(-120))

        let preview = MaritimeNoticePreviewPolicy.select(
            from: [oldest, middle, newest, unread],
            unreadIDs: [unread.id],
            now: now,
            limit: 3
        )

        XCTAssertEqual(preview.map(\.id), ["unread", "newest", "middle"])
    }

    func testQuickLookOmitsReadArchivedNotices() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = makeNotice(
            id: "expired",
            validUntil: now.addingTimeInterval(-1),
            state: .current,
            updatedAt: now.addingTimeInterval(-60)
        )
        let revoked = makeNotice(id: "revoked", state: .revoked, updatedAt: now)

        let preview = MaritimeNoticePreviewPolicy.select(
            from: [expired, revoked],
            unreadIDs: [],
            now: now,
            limit: 3
        )

        XCTAssertTrue(preview.isEmpty)
    }

    func testDisplayTitleMakesDottedRegionReadableWithoutChangingDate() {
        let notice = MaritimeNoticeSummary(
            id: "bfs-194-2026",
            bfsNumber: "BfS 194/2026",
            isTemporary: false,
            publisher: "WSA Ems-Nordsee",
            title: "BfS 194/26, 15.07.2026, Deutschland.Nordsee.Ostfriesische Inseln Norderney",
            regionPath: "Deutschland.Nordsee.Ostfriesische Inseln",
            location: "Norderney",
            publishedAt: .now,
            validFrom: .now,
            validUntil: nil,
            publicationState: .revoked,
            revision: 1,
            updatedAt: .now,
            sourceURL: nil,
            parseStatus: .parsed
        )

        XCTAssertTrue(notice.displayTitle.contains("Deutschland · Nordsee · Ostfriesische Inseln"))
        XCTAssertTrue(notice.displayTitle.contains("15.07.2026"))
    }

    private func makeNotice(
        id: String = "bfs-123-2026",
        revision: Int = 1,
        validUntil: Date? = nil,
        state: MaritimeNoticePublicationState = .current,
        updatedAt: Date = .now
    ) -> MaritimeNoticeSummary {
        MaritimeNoticeSummary(
            id: id,
            bfsNumber: "BfS 123/2026",
            isTemporary: false,
            publisher: "WSA Ems-Nordsee",
            title: "Testmeldung",
            regionPath: "Deutschland.Nordsee.Ostfriesische Inseln",
            location: "Norderney",
            publishedAt: .now,
            validFrom: .now,
            validUntil: validUntil,
            publicationState: state,
            revision: revision,
            updatedAt: updatedAt,
            sourceURL: nil,
            parseStatus: .parsed
        )
    }
}
