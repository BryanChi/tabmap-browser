import XCTest
@testable import TabMapCore

final class RehomeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func u(_ s: String) -> URL { URL(string: "https://\(s).example")! }
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Two rows: [a, b, c] and [x, y]. y is active.
    func fixture() -> (TabMap, a: TabID, b: TabID, c: TabID, x: TabID, y: TabID) {
        var map = TabMap()
        let a = map.openRoot(url: u("a"), now: t0)
        let b = map.openChild(of: a, url: u("b"), now: at(1), activate: false)!
        let c = map.openChild(of: b, url: u("c"), now: at(2), activate: false)!
        let x = map.openRoot(url: u("x"), now: at(3))
        let y = map.openChild(of: x, url: u("y"), now: at(4), activate: true)!
        return (map, a, b, c, x, y)
    }

    func row(_ map: TabMap, containing id: TabID) -> [TabID] {
        map.locate(id).map { map.trails[$0.trail].tabs.map(\.id) } ?? []
    }

    func testMoveIntoAnotherRowBeforeAndAfter() {
        var (map, a, b, c, x, y) = fixture()
        XCTAssertTrue(map.moveTab(b, to: .before(y), now: at(10)))
        XCTAssertEqual(row(map, containing: a), [a, c])
        XCTAssertEqual(row(map, containing: x), [x, b, y])
        XCTAssertTrue(map.moveTab(c, to: .after(y), now: at(11)))
        XCTAssertEqual(row(map, containing: x), [x, b, y, c])
        XCTAssertEqual(row(map, containing: a), [a])
    }

    func testMoveToEndOfRow() {
        var (map, a, b, c, x, y) = fixture()
        let target = map.trails[map.locate(x)!.trail].id
        XCTAssertTrue(map.moveTab(a, to: .endOfTrail(target), now: at(10)))
        XCTAssertEqual(row(map, containing: x), [x, y, a])
        XCTAssertEqual(row(map, containing: b), [b, c])
    }

    func testEmptiedRowDisappears() {
        var (map, a, b, c, x, y) = fixture()
        XCTAssertTrue(map.moveTab(x, to: .after(a), now: at(10)))
        XCTAssertTrue(map.moveTab(y, to: .after(c), now: at(11)))
        XCTAssertEqual(map.trails.count, 1)
        XCTAssertEqual(map.trails[0].tabs.map(\.id), [a, x, b, c, y])
        XCTAssertEqual(map.activeTabID, y, "moving the active tab keeps it active")
        XCTAssertEqual(map.trails[0].lastActiveTabID, y)
    }

    func testMoveToNewRow() {
        var (map, a, b, c, _, _) = fixture()
        XCTAssertTrue(map.moveTab(b, to: .newTrail, now: at(10)))
        XCTAssertEqual(map.trails.count, 3)
        XCTAssertEqual(row(map, containing: b), [b])
        XCTAssertEqual(row(map, containing: a), [a, c])
        XCTAssertNil(map.tab(b)?.openerID)
    }

    func testReorderInsideARow() {
        var (map, a, b, c, _, _) = fixture()
        XCTAssertTrue(map.moveTab(c, to: .before(a), now: at(10)))
        XCTAssertEqual(row(map, containing: a), [c, a, b])
        XCTAssertTrue(map.moveTab(c, to: .after(b), now: at(11)))
        XCTAssertEqual(row(map, containing: a), [a, b, c])
    }

    func testMovesThatGoNowhereChangeNothing() {
        let (map, a, b, c, x, y) = fixture()
        var copy = map
        let rowA = map.trails[map.locate(a)!.trail].id
        XCTAssertFalse(copy.moveTab(b, to: .before(b), now: at(10)))
        XCTAssertFalse(copy.moveTab(b, to: .before(c), now: at(10)))
        XCTAssertFalse(copy.moveTab(b, to: .after(a), now: at(10)))
        XCTAssertFalse(copy.moveTab(c, to: .endOfTrail(rowA), now: at(10)))
        XCTAssertFalse(copy.moveTab(TabID(), to: .after(a), now: at(10)))
        XCTAssertFalse(copy.moveTab(a, to: .after(TabID()), now: at(10)))
        XCTAssertFalse(copy.moveTab(a, to: .endOfTrail(TrailID()), now: at(10)))
        XCTAssertEqual(copy, map)
        // A tab alone in its row cannot be given a new row of its own.
        XCTAssertTrue(copy.moveTab(y, to: .after(a), now: at(10)))
        XCTAssertFalse(copy.moveTab(x, to: .newTrail, now: at(11)))
    }

    func testMoveKeepsRecencyAndMarksTheTab() {
        var (map, _, b, _, _, y) = fixture()
        let before = map.tab(b)!.lastAccessedAt
        XCTAssertNil(map.tab(b)?.movedByHandAt)
        map.moveTab(b, to: .after(y), now: at(99))
        XCTAssertEqual(map.tab(b)?.lastAccessedAt, before, "dragging a tab is not using it")
        XCTAssertEqual(map.tab(b)?.movedByHandAt, at(99))
    }

    func testOpenerIsForgottenWhenItStaysBehind() {
        var (map, a, b, c, _, y) = fixture()
        // c was opened from b. Reordering inside the row keeps that link.
        map.moveTab(c, to: .before(a), now: at(10))
        XCTAssertEqual(map.tab(c)?.openerID, b)
        // Leaving the row drops it.
        map.moveTab(c, to: .after(y), now: at(11))
        XCTAssertNil(map.tab(c)?.openerID)
    }

    func testSourceRowRemembersANeighbourAsLastActive() {
        var (map, a, b, c, x, y) = fixture()
        map.activate(b, now: at(5))
        map.activate(y, now: at(6))
        let rowA = map.locate(a)!.trail
        XCTAssertEqual(map.trails[rowA].lastActiveTabID, b)
        map.moveTab(b, to: .after(x), now: at(10))
        XCTAssertEqual(map.trails[map.locate(a)!.trail].lastActiveTabID, c)
        XCTAssertEqual(map.trails[map.locate(x)!.trail].lastActiveTabID, y, "the target row keeps its own place")
    }

    func testClosedTabStaysClosedWhenMoved() {
        var (map, _, b, _, x, _) = fixture()
        map.close(b, now: at(5))
        XCTAssertTrue(map.moveTab(b, to: .after(x), now: at(10)))
        XCTAssertEqual(map.tab(b)?.isClosed, true)
    }

    func testOldSavedMapsStillDecode() throws {
        let (map, _, _, _, _, _) = fixture()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as! [String: Any]
        var trails = json["trails"] as! [[String: Any]]
        for i in trails.indices {
            var tabs = trails[i]["tabs"] as! [[String: Any]]
            for j in tabs.indices { tabs[j].removeValue(forKey: "movedByHandAt") }
            trails[i]["tabs"] = tabs
        }
        json["trails"] = trails
        let decoded = try JSONDecoder().decode(TabMap.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, map)
    }
}
