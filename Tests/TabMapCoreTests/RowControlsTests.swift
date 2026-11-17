import XCTest
@testable import TabMapCore

final class RowControlsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func url(_ s: String) -> URL { URL(string: "https://\(s).example.com/")! }

    /// One row a → b → c with c current, and a second, older row x.
    private func makeMap() -> (TabMap, TrailID, [TabID], TabID) {
        var map = TabMap()
        let x = map.openRoot(url: url("x"), now: now.addingTimeInterval(-100))
        let a = map.openRoot(url: url("a"), now: now)
        let b = map.openChild(of: a, url: url("b"), now: now, activate: false)!
        let c = map.openChild(of: b, url: url("c"), now: now, activate: true)!
        let trail = map.locate(a)!.trail
        return (map, map.trails[trail].id, [a, b, c], x)
    }

    func testClosingOrderPutsCurrentTabLast() {
        var (map, row, ids, _) = makeMap()
        map.activate(ids[1], now: now)
        XCTAssertEqual(map.closingOrder(ofTrail: row), [ids[0], ids[2], ids[1]])
    }

    func testCloseRowThenReopenRestoresPlaceWithoutActivating() {
        var (map, row, ids, x) = makeMap()
        let before = map.trail(row)!.tabs.map(\.id)
        for id in map.closingOrder(ofTrail: row) { map.close(id, now: now) }
        XCTAssertFalse(map.trail(row)!.hasOpenTabs)
        XCTAssertEqual(map.activeTabID, x)

        let record = ClosedRow(trailID: row, tabIDs: ids, activeTabID: ids[2], closedAt: now)
        XCTAssertTrue(map.isLatestClose(record))
        XCTAssertTrue(map.reopen(ids))
        XCTAssertTrue(map.trail(row)!.tabs.allSatisfy { !$0.isClosed })
        XCTAssertEqual(map.trail(row)!.tabs.map(\.id), before)
        XCTAssertEqual(map.activeTabID, x, "reopening alone does not switch tabs")
        XCTAssertEqual(map.layout().open.first?.id, row, "row goes back to its old place by recency")
    }

    func testLaterCloseElsewhereIsNotLatest() {
        var (map, row, ids, x) = makeMap()
        for id in map.closingOrder(ofTrail: row) { map.close(id, now: now) }
        let record = ClosedRow(trailID: row, tabIDs: ids, activeTabID: nil, closedAt: now)
        map.close(x, now: now.addingTimeInterval(5))
        XCTAssertFalse(map.isLatestClose(record))
    }

    func testToggleKeepPinsAndUnpinsOpenPages() {
        var (map, row, ids, _) = makeMap()
        XCTAssertFalse(map.trail(row)!.isKept)
        XCTAssertTrue(map.toggleKeep(trail: row))
        XCTAssertTrue(ids.allSatisfy { map.tab($0)!.pinned })
        XCTAssertTrue(map.trail(row)!.isKept)
        XCTAssertFalse(map.toggleKeep(trail: row))
        XCTAssertTrue(ids.allSatisfy { !map.tab($0)!.pinned })
    }

    func testHandNameSticksAndBlankNameHandsBack() {
        var (map, row, _, _) = makeMap()
        let sig = map.trail(row)!.contentSignature
        XCTAssertTrue(map.trail(row)!.needsLabel)
        map.rename(trail: row, to: "  Trip plans  ")
        XCTAssertEqual(map.trail(row)!.name, "Trip plans")
        XCTAssertFalse(map.trail(row)!.needsLabel)
        XCTAssertFalse(map.setLabel(trail: row, name: "Auto", summary: "s", signature: sig))
        XCTAssertEqual(map.trail(row)!.name, "Trip plans")

        map.rename(trail: row, to: "")
        XCTAssertNil(map.trail(row)!.name)
        XCTAssertTrue(map.trail(row)!.needsLabel)
        XCTAssertTrue(map.setLabel(trail: row, name: "Auto", summary: "s", signature: sig))
    }

    func testHandNameSurvivesShrinkingRow() {
        var (map, row, ids, _) = makeMap()
        map.rename(trail: row, to: "Mine")
        map.remove(ids[0]); map.remove(ids[1])
        map.clearStaleLabels()
        XCTAssertEqual(map.trail(row)?.name, "Mine")
    }

    func testForgetOnlyRemovesClosedRows() {
        var (map, row, _, _) = makeMap()
        XCTAssertEqual(map.forget(trail: row), [])
        for id in map.closingOrder(ofTrail: row) { map.close(id, now: now) }
        XCTAssertEqual(map.forget(trail: row).count, 3)
        XCTAssertNil(map.trail(row))
    }

    func testHandNamedFlagRoundTrips() throws {
        var (map, row, _, _) = makeMap()
        map.rename(trail: row, to: "Mine")
        let data = try JSONEncoder().encode(map)
        let back = try JSONDecoder().decode(TabMap.self, from: data)
        XCTAssertEqual(back.trail(row)?.namedByHand, true)
    }

    // MARK: Marks

    func testStarTogglesAndSetMarkClears() {
        var (map, row, _, _) = makeMap()
        XCTAssertNil(map.trail(row)!.mark)
        XCTAssertEqual(map.toggleStar(trail: row), TabMap.starMark)
        XCTAssertEqual(map.trail(row)!.mark, TabMap.starMark)
        XCTAssertNil(map.toggleStar(trail: row))
        XCTAssertNil(map.trail(row)!.mark)

        XCTAssertEqual(map.setMark(trail: row, " 🔥 "), "🔥")
        XCTAssertEqual(map.setMark(trail: row, "🧪 lab notes"), "🧪", "only the first character is kept")
        XCTAssertNil(map.setMark(trail: row, "   "))
        map.setMark(trail: row, "📚")
        XCTAssertNil(map.setMark(trail: row, nil))
        XCTAssertNil(map.trail(row)!.mark)
    }

    func testMarkKeepsEmojiWithModifiers() {
        var (map, row, _, _) = makeMap()
        XCTAssertEqual(map.setMark(trail: row, "👍🏽"), "👍🏽")
        XCTAssertEqual(map.setMark(trail: row, "❤️"), "❤️")
    }

    func testMarkSurvivesCodableRoundTripAndOldDataDecodes() throws {
        var (map, row, _, _) = makeMap()
        map.setMark(trail: row, "💡")
        let back = try JSONDecoder().decode(TabMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(back.trail(row)?.mark, "💡")

        // A row saved before marks existed decodes as unmarked.
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Trail(tabs: [MapTab(url: url("a"), now: now)])))
        var dict = old as! [String: Any]
        dict.removeValue(forKey: "mark")
        let trail = try JSONDecoder().decode(Trail.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(trail.mark)
    }

    func testMarkSurvivesRelabelRenameAndClose() {
        var (map, row, ids, _) = makeMap()
        map.setMark(trail: row, "✈️")
        let signature = map.trail(row)!.contentSignature
        XCTAssertTrue(map.setLabel(trail: row, name: "Trip", summary: "Flights", signature: signature))
        XCTAssertEqual(map.trail(row)!.mark, "✈️")
        map.rename(trail: row, to: "Holiday")
        map.rename(trail: row, to: "")
        XCTAssertEqual(map.trail(row)!.mark, "✈️")
        for id in ids { map.close(id, now: now) }
        XCTAssertEqual(map.trail(row)!.mark, "✈️")
    }

    func testSearchMatchesRowByMark() {
        var (map, row, ids, _) = makeMap()
        map.setMark(trail: row, "🛒")
        let layout = map.layout(matching: "🛒")
        XCTAssertEqual(layout.open.map(\.id), [row])
        XCTAssertEqual(layout.open.first?.tabs.count, ids.count, "a row matched by its mark shows whole")
    }

    // MARK: New tab in a row, sleeping a row

    func testNewTabParentPrefersLastActiveThenLastOpen() {
        var (map, row, ids, x) = makeMap()
        map.activate(ids[1], now: now)
        XCTAssertEqual(map.newTabParent(inTrail: row), ids[1])
        map.activate(x, now: now)
        XCTAssertEqual(map.newTabParent(inTrail: row), ids[1], "the row remembers where you left off")
        map.close(ids[1], now: now)
        XCTAssertEqual(map.newTabParent(inTrail: row), ids[2])
        map.close(ids[0], now: now)
        map.close(ids[2], now: now)
        XCTAssertNil(map.newTabParent(inTrail: row))
    }

    func testNewTabGoesIntoThatRowNotTheCurrentOne() {
        var (map, row, ids, x) = makeMap()
        map.activate(x, now: now)
        let parent = map.newTabParent(inTrail: row)!
        let blank = map.openChild(of: parent, url: nil, now: now, activate: true)!
        XCTAssertEqual(map.locate(blank)?.trail, map.locate(ids[0])?.trail)
        XCTAssertEqual(map.openBlank(inTrail: row), blank, "a second + reuses the blank tab")
    }

    func testTabsToSleepSkipsWhatIsOnScreenAndUnloaded() {
        var (map, row, ids, x) = makeMap()
        map.activate(ids[2], now: now)
        let loaded: Set<TabID> = [ids[0], ids[2], x]
        XCTAssertEqual(map.tabsToSleep(inTrail: row, loaded: loaded), [ids[0]])
        map.activate(x, now: now)
        XCTAssertEqual(map.tabsToSleep(inTrail: row, loaded: loaded), [ids[0], ids[2]])
        map.close(ids[0], now: now)
        XCTAssertEqual(map.tabsToSleep(inTrail: row, loaded: loaded), [ids[2]])
    }
}
