import XCTest
@testable import TabMapCore

final class CloudSyncTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func page(_ address: String, _ title: String, savedAt minutes: Double = 0) -> Bookmark {
        Bookmark(url: URL(string: address)!, title: title, now: at(minutes))
    }

    /// One Mac: its library, its sync memory, and what it last wrote.
    private struct Mac {
        let id: String
        var library = BookmarkLibrary()
        var state = BookmarkSyncState()
        var published: DeviceBookmarks?

        init(_ id: String) { self.id = id }

        mutating func sync(with others: [Mac], now: Date) {
            BookmarkSync.noteLocalChanges(in: library, state: &state, now: now)
            BookmarkSync.merge(others.compactMap(\.published), into: &library, state: &state)
            published = BookmarkSync.outgoing(library, state: state, deviceID: id, deviceName: id, now: now)
        }
    }

    func testNewBookmarkReachesTheOtherMac() {
        var a = Mac("A"), b = Mac("B")
        let ramen = page("https://example.com/ramen", "Ramen")
        a.library.add(ramen)
        a.sync(with: [], now: at(1))
        b.sync(with: [a], now: at(2))
        XCTAssertEqual(b.library.bookmarks.map(\.id), [ramen.id])
    }

    func testNewestEditWins() {
        var a = Mac("A"), b = Mac("B")
        let ramen = page("https://example.com/ramen", "Ramen")
        a.library.add(ramen)
        a.sync(with: [], now: at(1))
        b.sync(with: [a], now: at(2))

        a.library.update(ramen.id) { $0.note = "from A" }
        a.sync(with: [b], now: at(3))
        b.library.update(ramen.id) { $0.note = "from B" }
        b.sync(with: [a], now: at(4))
        a.sync(with: [b], now: at(5))

        XCTAssertEqual(a.library.bookmark(ramen.id)?.note, "from B")
        XCTAssertEqual(b.library.bookmark(ramen.id)?.note, "from B")
    }

    func testDeletionSpreadsAndDoesNotComeBack() {
        var a = Mac("A"), b = Mac("B")
        let ramen = page("https://example.com/ramen", "Ramen")
        a.library.add(ramen)
        a.sync(with: [], now: at(1))
        b.sync(with: [a], now: at(2))

        b.library.remove(ramen.id)
        b.sync(with: [a], now: at(3))
        XCTAssertNil(b.library.bookmark(ramen.id), "A's older copy must not bring it back")
        a.sync(with: [b], now: at(4))
        XCTAssertNil(a.library.bookmark(ramen.id))
        b.sync(with: [a], now: at(5))
        XCTAssertNil(b.library.bookmark(ramen.id))
    }

    func testEditAfterDeletionKeepsIt() {
        var a = Mac("A"), b = Mac("B")
        let ramen = page("https://example.com/ramen", "Ramen")
        a.library.add(ramen)
        a.sync(with: [], now: at(1))
        b.sync(with: [a], now: at(2))

        b.library.remove(ramen.id)
        b.sync(with: [a], now: at(3))
        a.library.update(ramen.id) { $0.note = "still want this" }
        a.sync(with: [], now: at(4))   // A edits before it hears about the deletion
        a.sync(with: [b], now: at(5))
        XCTAssertEqual(a.library.bookmark(ramen.id)?.note, "still want this")
        b.sync(with: [a], now: at(6))
        XCTAssertEqual(b.library.bookmark(ramen.id)?.note, "still want this")
    }

    func testSamePageSavedOnBothMacsEndsUpOnce() {
        var a = Mac("A"), b = Mac("B")
        let first = page("https://example.com/ramen", "Ramen", savedAt: 0)
        let second = page("https://www.example.com/ramen/", "Ramen!", savedAt: 5)
        a.library.add(first)
        b.library.add(second)
        a.sync(with: [], now: at(10))
        b.sync(with: [a], now: at(11))
        a.sync(with: [b], now: at(12))
        b.sync(with: [a], now: at(13))
        XCTAssertEqual(a.library.bookmarks.map(\.id), [first.id])
        XCTAssertEqual(b.library.bookmarks.map(\.id), [first.id])
    }

    func testKeptCopyIsLocalAndNotAnEdit() {
        var a = Mac("A"), b = Mac("B")
        var ramen = page("https://example.com/ramen", "Ramen")
        ramen.hasCopy = true
        a.library.add(ramen)
        a.sync(with: [], now: at(1))
        b.sync(with: [a], now: at(2))
        XCTAssertEqual(b.library.bookmark(ramen.id)?.hasCopy, false, "the copy is on A, not on B")
        b.sync(with: [a], now: at(3))
        a.sync(with: [b], now: at(4))
        XCTAssertEqual(a.library.bookmark(ramen.id)?.hasCopy, true)
    }

    func testQuietSyncChangesNothing() {
        var a = Mac("A"), b = Mac("B")
        a.library.add(page("https://example.com/ramen", "Ramen"))
        a.sync(with: [], now: at(1))
        b.sync(with: [a], now: at(2))
        let stamps = b.state.changed
        let result = BookmarkSync.merge([a.published!], into: &b.library, state: &b.state)
        XCTAssertTrue(result.isEmpty)
        BookmarkSync.noteLocalChanges(in: b.library, state: &b.state, now: at(3))
        XCTAssertEqual(b.state.changed, stamps)
    }

    func testFilesRoundTripThroughJSON() throws {
        var a = Mac("A")
        a.library.add(page("https://example.com/ramen", "Ramen"))
        a.sync(with: [], now: at(1))
        let data = try JSONEncoder().encode(a.published!)
        XCTAssertEqual(try JSONDecoder().decode(DeviceBookmarks.self, from: data), a.published)
    }

    // MARK: Rows

    func testSyncedRowsListOpenWebPagesMostRecentFirst() {
        var map = TabMap()
        let older = map.openRoot(url: URL(string: "https://a.example/1")!, title: "A1", now: at(0))
        _ = map.openChild(of: older, url: URL(string: "https://a.example/2")!, title: "A2", now: at(1), activate: false)
        let newer = map.openRoot(url: URL(string: "https://b.example/")!, title: "B", now: at(5))
        _ = map.openChild(of: newer, url: URL(string: "file:///tmp/x.html")!, title: "local", now: at(6), activate: false)
        _ = map.openRoot(url: nil, now: at(7))

        let rows = map.syncedRows()
        XCTAssertEqual(rows.map { $0.tabs.map(\.title) }, [["B"], ["A1", "A2"]])
    }

    func testOtherMacsLeaveOutThisMacAndStaleOnes() {
        let row = SyncedRow(id: UUID(), name: "Trip", mark: nil,
                            tabs: [SyncedTab(url: URL(string: "https://x.example")!, title: "X")], lastUsed: t0)
        let me = DeviceRows(deviceID: "me", deviceName: "Mine", savedAt: at(0), rows: [row])
        let fresh = DeviceRows(deviceID: "air", deviceName: "Air", savedAt: at(0), rows: [row])
        let stale = DeviceRows(deviceID: "old", deviceName: "Old", savedAt: at(-60 * 24 * 40), rows: [row])
        let empty = DeviceRows(deviceID: "empty", deviceName: "Empty", savedAt: at(0), rows: [])
        let shown = DeviceRows.others([me, fresh, stale, empty], excluding: "me", now: at(1))
        XCTAssertEqual(shown.map(\.deviceID), ["air"])
    }
}
