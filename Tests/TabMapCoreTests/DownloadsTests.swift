import XCTest
@testable import TabMapCore

// Goes in Tests/TabMapCoreTests.
final class DownloadsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func u(_ s: String) -> URL { URL(string: "https://\(s).example")! }
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @discardableResult
    func add(_ ledger: inout DownloadLedger, _ name: String, tab: TabID?, trail: TrailID? = nil,
             at seconds: TimeInterval = 0, finish: Bool = true) -> DownloadID {
        let id = ledger.start(filename: name, sourceURL: u("files").appendingPathComponent(name),
                              pageURL: u("page"), pageTitle: "Page", tabID: tab, trailID: trail, now: at(seconds))
        if finish { ledger.finish(id, byteCount: 10, now: at(seconds + 1)) }
        return id
    }

    func testBadgeCountsFinishedAndRunningButNotFailed() {
        var ledger = DownloadLedger()
        let tab = TabID(), other = TabID()
        add(&ledger, "a.pdf", tab: tab)
        add(&ledger, "b.pdf", tab: tab, finish: false)
        let failed = add(&ledger, "c.pdf", tab: tab, finish: false)
        ledger.fail(failed, cancelled: false, now: at(5))
        let cancelled = add(&ledger, "d.pdf", tab: tab, finish: false)
        ledger.fail(cancelled, cancelled: true, now: at(5))
        add(&ledger, "e.pdf", tab: other)

        XCTAssertEqual(ledger.count(forTab: tab), 2)
        XCTAssertEqual(ledger.count(forTab: other), 1)
        XCTAssertEqual(ledger.count(forTab: TabID()), 0)
        XCTAssertTrue(ledger.isDownloading(tab: tab))
        XCTAssertFalse(ledger.isDownloading(tab: other))
        XCTAssertEqual(ledger.activeCount, 1)
        XCTAssertEqual(ledger.record(cancelled)?.state, .cancelled)
    }

    func testFinishedDownloadCannotLaterBeMarkedFailed() {
        var ledger = DownloadLedger()
        let id = add(&ledger, "a.pdf", tab: TabID())
        ledger.fail(id, cancelled: false, now: at(9))
        XCTAssertEqual(ledger.record(id)?.state, .finished)
    }

    func testFileNameFindsItsTab() {
        var ledger = DownloadLedger()
        let tab = TabID(), other = TabID()
        add(&ledger, "Quarterly Report.pdf", tab: tab)
        add(&ledger, "holiday.jpg", tab: other)
        XCTAssertEqual(ledger.tabIDs(matching: "report"), [tab])
        XCTAssertEqual(ledger.tabIDs(matching: ".jpg"), [other])
        XCTAssertEqual(ledger.tabIDs(matching: ""), [])
        XCTAssertEqual(ledger.tabIDs(matching: "nothing"), [])
        XCTAssertEqual(ledger.firstMatch(forTab: tab, query: "quart")?.filename, "Quarterly Report.pdf")
        XCTAssertNil(ledger.firstMatch(forTab: other, query: "quart"))
    }

    func testSearchLayoutKeepsTabsFoundByFileName() {
        var map = TabMap()
        let a = map.openRoot(url: u("alpha"), title: "Alpha", now: t0)
        let b = map.openChild(of: a, url: u("beta"), title: "Beta", now: at(1), activate: false)!
        let c = map.openRoot(url: u("gamma"), title: "Gamma", now: at(2))

        // Nothing is called "report", so a plain search finds nothing.
        XCTAssertTrue(map.layout(matching: "report").isEmpty)

        let found = map.layout(matching: "report", alsoShowing: [b])
        XCTAssertEqual(found.open.map { $0.tabs.map(\.id) }, [[b]])

        // Title matches and file matches combine, and row order is the map's own.
        let both = map.layout(matching: "gamma", alsoShowing: [b])
        XCTAssertEqual(both.open.map { $0.tabs.map(\.id) }, [[c], [b]])

        // With nothing extra it is exactly the ordinary search.
        XCTAssertEqual(map.layout(matching: "alpha", alsoShowing: []), map.layout(matching: "alpha"))
    }

    func testSearchLayoutKeepsClosedRowsBelowTheHorizon() {
        var map = TabMap()
        let a = map.openRoot(url: u("alpha"), title: "Alpha", now: t0)
        _ = map.openRoot(url: u("beta"), title: "Beta", now: at(1))
        map.close(a, now: at(2))
        let found = map.layout(matching: "report", alsoShowing: [a])
        XCTAssertTrue(found.open.isEmpty)
        XCTAssertEqual(found.archived.map { $0.tabs.map(\.id) }, [[a]])
    }

    func testGroupsFollowRowsNewestFirst() {
        var map = TabMap()
        let a = map.openRoot(url: u("alpha"), title: "Alpha", now: t0)
        let a2 = map.openChild(of: a, url: u("alpha2"), title: "Alpha two", now: at(1), activate: false)!
        let b = map.openRoot(url: u("beta"), title: "Beta", now: at(2))
        let rowA = map.trails[map.locate(a)!.trail].id
        let rowB = map.trails[map.locate(b)!.trail].id

        var ledger = DownloadLedger()
        add(&ledger, "one.pdf", tab: a, trail: rowA, at: 10)
        add(&ledger, "two.pdf", tab: b, trail: rowB, at: 20)
        add(&ledger, "three.pdf", tab: a2, trail: rowA, at: 30)

        let groups = ledger.groups(in: map)
        XCTAssertEqual(groups.map(\.trailID), [rowA, rowB])
        XCTAssertEqual(groups.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(groups[0].records.map(\.filename), ["three.pdf", "one.pdf"])

        let onlyA = ledger.groups(in: map, onlyTab: a)
        XCTAssertEqual(onlyA.count, 1)
        XCTAssertEqual(onlyA[0].records.map(\.filename), ["one.pdf"])
    }

    func testDownloadsOutliveTheirTab() {
        var map = TabMap()
        let a = map.openRoot(url: u("alpha"), title: "Alpha", now: t0)
        let a2 = map.openChild(of: a, url: u("alpha2"), title: "Alpha two", now: at(1), activate: false)!
        let b = map.openRoot(url: u("beta"), title: "Beta", now: at(2))
        let rowA = map.trails[map.locate(a)!.trail].id
        let rowB = map.trails[map.locate(b)!.trail].id

        var ledger = DownloadLedger()
        add(&ledger, "kept.pdf", tab: a2, trail: rowA, at: 10)
        add(&ledger, "orphan.pdf", tab: b, trail: rowB, at: 20)

        // Closing keeps the tab in the map; the file still belongs to its row.
        map.close(a2, now: at(30))
        XCTAssertEqual(ledger.groups(in: map).first { $0.trailID == rowA }?.records.count, 1)

        // Forgetting the tab: the row is still there, so the file stays with the row.
        map.remove(a2)
        XCTAssertEqual(ledger.groups(in: map).first { $0.trailID == rowA }?.records.map(\.filename), ["kept.pdf"])
        XCTAssertEqual(ledger.count(forTab: a2), 1, "the record itself is untouched")

        // Forgetting a whole row: its files are still listed, under their own heading.
        map.remove(b)
        let lost = ledger.groups(in: map).first { $0.trailID == nil }
        XCTAssertEqual(lost?.records.map(\.filename), ["orphan.pdf"])
        XCTAssertEqual(lost?.records.first?.pageURL, u("page"))
    }

    func testRetargetMovesEveryFileFromTheOldTab() {
        var ledger = DownloadLedger()
        let old = TabID(), new = TabID(), row = TrailID(), unrelated = TabID()
        let first = add(&ledger, "a.pdf", tab: old)
        add(&ledger, "b.pdf", tab: old)
        add(&ledger, "c.pdf", tab: unrelated)
        ledger.retarget(from: old, record: first, to: new, trail: row)
        XCTAssertEqual(ledger.count(forTab: new), 2)
        XCTAssertEqual(ledger.count(forTab: old), 0)
        XCTAssertEqual(ledger.count(forTab: unrelated), 1)
        XCTAssertEqual(ledger.records(forTab: new).map(\.trailID), [row, row])

        // A record with no tab at all moves on its own.
        let loose = add(&ledger, "d.pdf", tab: nil)
        ledger.retarget(from: nil, record: loose, to: new, trail: row)
        XCTAssertEqual(ledger.count(forTab: new), 3)
    }

    func testInterruptedDownloadsFailAtLaunch() {
        var ledger = DownloadLedger()
        let tab = TabID()
        let running = add(&ledger, "big.zip", tab: tab, finish: false)
        let done = add(&ledger, "small.zip", tab: tab)
        ledger.markInterrupted(now: at(100))
        XCTAssertEqual(ledger.record(running)?.state, .failed)
        XCTAssertEqual(ledger.record(done)?.state, .finished)
        XCTAssertEqual(ledger.count(forTab: tab), 1)
    }

    func testLookupByPathAndSourceAndClearing() {
        var ledger = DownloadLedger()
        let tab = TabID()
        let id = add(&ledger, "a.pdf", tab: tab)
        ledger.setDestination(id, path: "/Users/x/Downloads/a (1).pdf", filename: "a (1).pdf")
        XCTAssertEqual(ledger.record(atPath: "/Users/x/Downloads/a (1).pdf")?.id, id)
        XCTAssertNil(ledger.record(atPath: "/Users/x/Downloads/a.pdf"))
        XCTAssertEqual(ledger.record(fromSource: u("files").appendingPathComponent("a.pdf"))?.id, id)

        let running = add(&ledger, "b.pdf", tab: tab, finish: false)
        ledger.clearInactive()
        XCTAssertEqual(ledger.records.map(\.id), [running])
        ledger.remove(running)
        XCTAssertTrue(ledger.records.isEmpty)
    }

    func testLedgerSurvivesSavingAndLoading() throws {
        var ledger = DownloadLedger()
        let id = add(&ledger, "a.pdf", tab: TabID(), trail: TrailID())
        ledger.setDestination(id, path: "/tmp/a.pdf", filename: "a.pdf")
        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(DownloadLedger.self, from: data), ledger)
    }

    func testRowCountGathersEveryTabInTheRow() {
        var map = TabMap()
        let a = map.openRoot(url: u("alpha"), title: "Alpha", now: t0)
        let a2 = map.openChild(of: a, url: u("alpha2"), title: "Alpha two", now: at(1), activate: false)!
        let a3 = map.openChild(of: a, url: u("alpha3"), title: "Alpha three", now: at(2), activate: false)!
        let b = map.openRoot(url: u("beta"), title: "Beta", now: at(3))
        let rowA = map.trails[map.locate(a)!.trail].id
        let rowB = map.trails[map.locate(b)!.trail].id

        var ledger = DownloadLedger()
        add(&ledger, "one.pdf", tab: a, trail: rowA, at: 10)
        add(&ledger, "two.pdf", tab: a2, trail: rowA, at: 20)
        add(&ledger, "three.pdf", tab: a2, trail: rowA, at: 30)
        let failed = add(&ledger, "bad.zip", tab: a3, trail: rowA, at: 35, finish: false)
        ledger.fail(failed, cancelled: false, now: at(36))
        add(&ledger, "other.pdf", tab: b, trail: rowB, at: 40)

        XCTAssertEqual(ledger.count(forTrail: rowA, in: map), 3, "failed downloads don't count")
        XCTAssertEqual(ledger.tabCount(forTrail: rowA, in: map), 2)
        XCTAssertEqual(ledger.count(forTrail: rowB, in: map), 1)
        XCTAssertEqual(ledger.records(forTrail: rowA, in: map).map(\.filename),
                       ["bad.zip", "three.pdf", "two.pdf", "one.pdf"])
        XCTAssertFalse(ledger.isDownloading(trail: rowA, in: map))

        // A closed tab still counts for its row; a forgotten one too, while the row is there.
        map.close(a2, now: at(50))
        XCTAssertEqual(ledger.count(forTrail: rowA, in: map), 3)
        map.remove(a2)
        XCTAssertEqual(ledger.count(forTrail: rowA, in: map), 3)

        // Still downloading lights the row up.
        add(&ledger, "big.iso", tab: a, trail: rowA, at: 60, finish: false)
        XCTAssertTrue(ledger.isDownloading(trail: rowA, in: map))
        XCTAssertEqual(ledger.count(forTrail: rowA, in: map), 4)

        // The panel narrowed to a row lists just that row.
        let only = ledger.groups(in: map, onlyTrail: rowB)
        XCTAssertEqual(only.map(\.trailID), [rowB])
        XCTAssertEqual(only.first?.records.map(\.filename), ["other.pdf"])
    }

    func testGroupTitleUsesTheRowsName() {
        var map = TabMap()
        let a = map.openRoot(url: u("alpha"), title: "Alpha", now: t0)
        let loc = map.locate(a)!
        map.trails[loc.trail].name = "Trip planning"
        var ledger = DownloadLedger()
        add(&ledger, "one.pdf", tab: a, trail: map.trails[loc.trail].id)
        XCTAssertEqual(ledger.groups(in: map).first?.title, "Trip planning")
    }
}
