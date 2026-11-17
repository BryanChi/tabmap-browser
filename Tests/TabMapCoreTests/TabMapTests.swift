import XCTest
@testable import TabMapCore

final class TabMapTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func u(_ s: String) -> URL { URL(string: "https://\(s).example")! }
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: X axis

    func testChildOpensToTheRightOfItsParent() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let b = map.openChild(of: a, url: u("b"), now: at(1), activate: false)!
        XCTAssertEqual(map.trails.count, 1)
        XCTAssertEqual(map.trails[0].tabs.map(\.id), [a, b])
        XCTAssertEqual(map.activeTabID, a, "a background child must not steal focus")
    }

    func testSiblingsKeepOpeningOrderAndStayNextToParent() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let z = map.openChild(of: a, url: u("z"), now: at(1), activate: false)!
        // z is now a's child; open a grandchild from z, then two more children from a.
        let z1 = map.openChild(of: z, url: u("z1"), now: at(2), activate: false)!
        let b = map.openChild(of: a, url: u("b"), now: at(3), activate: false)!
        XCTAssertEqual(map.trails[0].tabs.map(\.id), [a, z, b, z1])
        let c = map.openChild(of: a, url: u("c"), now: at(4), activate: false)!
        XCTAssertEqual(map.trails[0].tabs.map(\.id), [a, z, b, c, z1])
    }

    func testNewRootStartsItsOwnRow() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let b = map.openRoot(url: u("b"), now: at(1))
        XCTAssertEqual(map.trails.count, 2)
        XCTAssertEqual(map.activeTabID, b)
        XCTAssertNotNil(map.tab(a))
    }

    // MARK: Y axis

    func testRowsAreOrderedByMostRecentAccess() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let b = map.openRoot(url: u("b"), now: at(10))
        XCTAssertEqual(map.layout().open.map { $0.tabs[0].id }, [b, a])
        map.activate(a, now: at(20))
        XCTAssertEqual(map.layout().open.map { $0.tabs[0].id }, [b, a], "activation alone must not reshuffle")
        map.touch(a, now: at(21))
        XCTAssertEqual(map.layout().open.map { $0.tabs[0].id }, [a, b])
    }

    func testUsingAnyTabLiftsItsWholeRow() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let a2 = map.openChild(of: a, url: u("a2"), now: at(1), activate: false)!
        let b = map.openRoot(url: u("b"), now: at(10))
        map.touch(a2, now: at(20))
        XCTAssertEqual(map.layout().open.first?.tabs.map(\.id), [a, a2])
        XCTAssertEqual(map.layout().open.last?.tabs.map(\.id), [b])
    }

    // MARK: Ageing

    func testOldTabsCloseAutomaticallyAndSinkBelowTheHorizon() {
        var map = TabMap()
        map.settings.closeAfter = 100
        let old = map.openRoot(url: u("old"), now: t0)
        let cur = map.openRoot(url: u("cur"), now: at(90))
        let result = map.sweep(now: at(150))
        XCTAssertEqual(result.closed, [old])
        XCTAssertTrue(map.tab(old)!.isClosed)
        let layout = map.layout()
        XCTAssertEqual(layout.open.map { $0.tabs[0].id }, [cur])
        XCTAssertEqual(layout.archived.map { $0.tabs[0].id }, [old])
    }

    func testActiveAndPinnedTabsAreNeverAutoClosed() {
        var map = TabMap()
        map.settings.closeAfter = 100
        let pinned = map.openRoot(url: u("p"), now: t0)
        map.setPinned(pinned, true)
        let active = map.openRoot(url: u("a"), now: at(1))
        let result = map.sweep(now: at(10_000))
        XCTAssertTrue(result.closed.isEmpty)
        XCTAssertFalse(map.tab(pinned)!.isClosed)
        XCTAssertFalse(map.tab(active)!.isClosed)
    }

    func testClosedTabInALiveRowKeepsItsPlace() {
        var map = TabMap()
        map.settings.closeAfter = 100
        let a = map.openRoot(url: u("a"), now: t0)
        let b = map.openChild(of: a, url: u("b"), now: at(1), activate: false)!
        let c = map.openChild(of: b, url: u("c"), now: at(2), activate: true)!
        map.touch(a, now: at(120))
        map.touch(c, now: at(120))
        _ = map.sweep(now: at(130))
        XCTAssertTrue(map.tab(b)!.isClosed)
        // The stored row keeps b in its place; the drawn row moves it to the right end.
        XCTAssertEqual(map.trails[0].tabs.map(\.id), [a, b, c])
        XCTAssertEqual(map.layout().open.first?.tabs.map(\.id), [a, c, b])
    }

    // MARK: Closed tabs at the end of a live row

    /// One row a-b-c-d-e, all open, with c active.
    private func fiveInARow() -> (TabMap, [TabID]) {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), title: "alpha news", now: t0)
        let b = map.openChild(of: a, url: u("b"), title: "bravo news", now: at(1), activate: false)!
        let c = map.openChild(of: b, url: u("c"), title: "charlie", now: at(2), activate: false)!
        let d = map.openChild(of: c, url: u("d"), title: "delta news", now: at(3), activate: false)!
        let e = map.openChild(of: d, url: u("e"), title: "echo", now: at(4), activate: false)!
        XCTAssertEqual(map.trails.count, 1)
        XCTAssertEqual(map.trails[0].tabs.map(\.id), [a, b, c, d, e])
        return (map, [a, b, c, d, e])
    }

    func testClosedTabsFollowOpenOnesNewestClosedFirst() {
        var (map, ids) = fiveInARow()
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        map.close(b, now: at(10))
        map.close(d, now: at(20))
        map.close(a, now: at(30))
        XCTAssertEqual(map.layout().open.first?.tabs.map(\.id), [c, e, a, d, b])
    }

    func testClosingDoesNotChangeStoredOrder() {
        var (map, ids) = fiveInARow()
        map.close(ids[1], now: at(10))
        map.close(ids[3], now: at(20))
        XCTAssertEqual(map.trails[0].tabs.map(\.id), ids)
    }

    func testReopenedTabReturnsToItsOriginalPlace() {
        var (map, ids) = fiveInARow()
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        map.close(b, now: at(10))
        map.close(d, now: at(20))
        XCTAssertEqual(map.layout().open.first?.tabs.map(\.id), [a, c, e, d, b])
        _ = map.activate(b, now: at(30))
        XCTAssertFalse(map.tab(b)!.isClosed)
        XCTAssertEqual(map.layout().open.first?.tabs.map(\.id), [a, b, c, e, d])
    }

    func testArchivedRowKeepsStoredOrder() {
        var (map, ids) = fiveInARow()
        _ = map.openRoot(url: u("other"), now: at(5))
        // Close the five out of order; once the row is fully closed it is drawn as stored.
        for (i, id) in [ids[3], ids[0], ids[4], ids[1], ids[2]].enumerated() {
            map.close(id, now: at(10 + Double(i)))
        }
        let layout = map.layout()
        XCTAssertEqual(layout.archived.first?.tabs.map(\.id), ids)
    }

    func testFilterStillAppliesWithClosedTabsAtTheEnd() {
        var (map, ids) = fiveInARow()
        let (a, b, c, d, _) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        map.close(a, now: at(10))
        map.close(b, now: at(20))
        // "news" is in alpha, bravo and delta: the open match first, then closed matches newest first.
        XCTAssertEqual(map.layout(matching: "news").open.first?.tabs.map(\.id), [d, b, a])
        XCTAssertEqual(map.layout(matching: "charlie").open.first?.tabs.map(\.id), [c])
    }

    func testNeighbourSkipsClosedTabsAtTheEnd() {
        var (map, ids) = fiveInARow()
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        map.close(b, now: at(10))
        map.close(d, now: at(20))
        XCTAssertEqual(map.neighbor(of: a, .right), c)
        XCTAssertEqual(map.neighbor(of: c, .right), e)
        XCTAssertNil(map.neighbor(of: e, .right))
        XCTAssertEqual(map.neighbor(of: e, .left), c)
    }

    func testClosedTabsArePurgedEventually() {
        var map = TabMap()
        map.settings.closeAfter = 100
        map.settings.purgeAfter = 1000
        let old = map.openRoot(url: u("old"), now: t0)
        _ = map.openRoot(url: u("cur"), now: at(1))
        _ = map.sweep(now: at(200))
        XCTAssertNotNil(map.tab(old))
        let result = map.sweep(now: at(1300))
        XCTAssertEqual(result.purged, [old])
        XCTAssertNil(map.tab(old))
        XCTAssertEqual(map.trails.count, 1)
    }

    func testSleepPicksIdleAndOverflowTabsButNeverTheActiveOne() {
        var map = TabMap()
        map.settings.sleepAfter = 100
        map.settings.maxLoadedTabs = 2
        let a = map.openRoot(url: u("a"), now: t0)
        let b = map.openRoot(url: u("b"), now: at(150))
        let c = map.openRoot(url: u("c"), now: at(160))
        let d = map.openRoot(url: u("d"), now: at(170))
        let sleeping = Set(map.tabsToSleep(loaded: [a, b, c, d], now: at(180)))
        // a is idle too long, b is the overflow beyond two loaded pages, d is active.
        XCTAssertEqual(sleeping, [a, b])
    }

    // MARK: Closing and restoring

    func testRestoringAClosedTabBringsItsRowBackToTheTop() {
        var map = TabMap()
        map.settings.closeAfter = 100
        let old = map.openRoot(url: u("old"), now: t0)
        let cur = map.openRoot(url: u("cur"), now: at(90))
        _ = map.sweep(now: at(150))
        let result = map.activate(old, now: at(200))
        XCTAssertTrue(result.reopened)
        XCTAssertFalse(map.tab(old)!.isClosed)
        XCTAssertEqual(map.layout().open.map { $0.tabs[0].id }, [old, cur])
        XCTAssertTrue(map.layout().archived.isEmpty)
    }

    func testClosingTheActiveTabMovesToANeighbour() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let b = map.openChild(of: a, url: u("b"), now: at(1), activate: true)!
        let c = map.openChild(of: b, url: u("c"), now: at(2), activate: false)!
        XCTAssertEqual(map.close(b, now: at(3)), c)
        XCTAssertEqual(map.close(c, now: at(4)), a)
        XCTAssertNil(map.close(a, now: at(5)))
        XCTAssertNil(map.activeTabID)
    }

    func testReopenLastClosed() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let b = map.openRoot(url: u("b"), now: at(1))
        map.close(a, now: at(2))
        map.close(b, now: at(3))
        XCTAssertEqual(map.reopenLastClosed(now: at(4)), b)
        XCTAssertEqual(map.activeTabID, b)
        XCTAssertEqual(map.reopenLastClosed(now: at(5)), a)
        XCTAssertNil(map.reopenLastClosed(now: at(6)))
    }

    func testBlankTabIsDiscardedWhenYouLeaveIt() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let blank = map.openRoot(url: nil, now: at(1))
        let result = map.activate(a, now: at(2))
        XCTAssertEqual(result.discarded, blank)
        XCTAssertNil(map.tab(blank))
        XCTAssertEqual(map.trails.count, 1)
    }

    // MARK: Moving around

    func testNeighbourMovesWithinRowAndBetweenRows() {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let a2 = map.openChild(of: a, url: u("a2"), now: at(1), activate: true)!
        let b = map.openRoot(url: u("b"), now: at(10))
        map.touch(b, now: at(11))
        // Rows: [b] on top, [a, a2] below, with a2 the last active tab of its row.
        XCTAssertEqual(map.neighbor(of: b, .down), a2)
        XCTAssertEqual(map.neighbor(of: a2, .left), a)
        XCTAssertEqual(map.neighbor(of: a, .right), a2)
        XCTAssertEqual(map.neighbor(of: a, .up), b)
        XCTAssertNil(map.neighbor(of: b, .up))
        XCTAssertNil(map.neighbor(of: a2, .right))
    }

    func testGridNavClampsColumns() {
        let a = TabID(), b = TabID(), c = TabID(), d = TabID()
        let rows = [[a, b, c], [d]]
        XCTAssertEqual(GridNav.move(from: c, .down, in: rows), d)
        XCTAssertEqual(GridNav.move(from: d, .up, in: rows), a)
        XCTAssertEqual(GridNav.move(from: a, .left, in: rows), a)
        XCTAssertEqual(GridNav.move(from: nil, .down, in: rows), a)
    }

    // MARK: Search, persistence, addresses

    func testLayoutFilterKeepsRowOrder() {
        var map = TabMap()
        let a = map.openRoot(url: u("apple"), title: "Apple pie", now: t0)
        _ = map.openRoot(url: u("b"), title: "Bread", now: at(1))
        let layout = map.layout(matching: "pie")
        XCTAssertEqual(layout.open.flatMap { $0.tabs.map(\.id) }, [a])
    }

    func testRoundTripsThroughJSON() throws {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), title: "A", now: t0)
        _ = map.openChild(of: a, url: u("b"), now: at(1), activate: false)
        map.close(a, now: at(2))
        let data = try JSONEncoder().encode(map)
        XCTAssertEqual(try JSONDecoder().decode(TabMap.self, from: data), map)
    }

    func testAddressInterpreter() {
        let s = "https://search.example/?q=%s"
        XCTAssertEqual(AddressInterpreter.url(from: "example.com", searchTemplate: s)?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressInterpreter.url(from: "https://a.b/c?d=1", searchTemplate: s)?.absoluteString, "https://a.b/c?d=1")
        XCTAssertEqual(AddressInterpreter.url(from: "localhost:3000/x", searchTemplate: s)?.absoluteString, "http://localhost:3000/x")
        XCTAssertEqual(AddressInterpreter.url(from: "192.168.1.1", searchTemplate: s)?.absoluteString, "http://192.168.1.1")
        XCTAssertEqual(AddressInterpreter.url(from: "swift ui & tabs", searchTemplate: s)?.absoluteString,
                       "https://search.example/?q=swift%20ui%20%26%20tabs")
        XCTAssertEqual(AddressInterpreter.url(from: "tabmap", searchTemplate: s)?.absoluteString, "https://search.example/?q=tabmap")
        XCTAssertNil(AddressInterpreter.url(from: "   ", searchTemplate: s))
    }

    func testTimeBands() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 15))!
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        XCTAssertEqual(TimeBand.band(for: ago(0.5), now: now, calendar: cal), .lastHour)
        XCTAssertEqual(TimeBand.band(for: ago(5), now: now, calendar: cal), .today)
        XCTAssertEqual(TimeBand.band(for: ago(20), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(TimeBand.band(for: ago(80), now: now, calendar: cal), .thisWeek)
        XCTAssertEqual(TimeBand.band(for: ago(300), now: now, calendar: cal), .older)
    }
}
