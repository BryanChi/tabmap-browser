import XCTest
@testable import TabMapCore

final class SplitTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func u(_ s: String) -> URL { URL(string: "https://\(s).example")! }
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// One row a, b, c, d (a is current) and a second row with x.
    func makeMap() -> (TabMap, a: TabID, b: TabID, c: TabID, d: TabID, x: TabID) {
        var map = TabMap()
        let x = map.openRoot(url: u("x"), now: t0)
        let a = map.openRoot(url: u("a"), now: at(1))
        let b = map.openChild(of: a, url: u("b"), now: at(2), activate: false)!
        let c = map.openChild(of: b, url: u("c"), now: at(3), activate: false)!
        let d = map.openChild(of: c, url: u("d"), now: at(4), activate: false)!
        XCTAssertEqual(map.trails[1].tabs.map(\.id), [a, b, c, d])
        return (map, a, b, c, d, x)
    }

    func testNeighboursCanBeSplitAndOrderFollowsTheRow() {
        var (map, a, b, _, _, _) = makeMap()
        let pair = map.split(b, with: a)
        XCTAssertEqual(pair, SplitPair(left: a, right: b))
        XCTAssertEqual(map.split(containing: a), pair)
        XCTAssertEqual(map.split(containing: b), pair)
        XCTAssertEqual(map.splitPartner(of: a), b)
        XCTAssertEqual(map.screen(of: b), [a, b])
        XCTAssertEqual(map.screenID(of: b), a)
        XCTAssertTrue(map.sameScreen(a, b))
    }

    func testOnlyNeighboursInTheSameRowCanBeSplit() {
        var (map, a, _, c, _, x) = makeMap()
        XCTAssertFalse(map.canSplit(a, c), "b sits between them")
        XCTAssertFalse(map.canSplit(a, x), "different rows")
        XCTAssertFalse(map.canSplit(a, a))
        XCTAssertNil(map.split(a, with: c))
        XCTAssertTrue(map.splits.isEmpty)
    }

    func testClosedTabBetweenTwoTabsDoesNotKeepThemApart() {
        var (map, a, b, c, _, _) = makeMap()
        map.close(b, now: at(10))
        XCTAssertTrue(map.canSplit(a, c))
        XCTAssertFalse(map.canSplit(a, b), "a closed tab cannot be split")
    }

    func testBlankTabCannotBeSplit() {
        var (map, _, _, _, d, _) = makeMap()
        let blank = map.openChild(of: d, url: nil, now: at(5), activate: false)!
        XCTAssertTrue(map.areNeighbours(d, blank))
        XCTAssertFalse(map.canSplit(d, blank))
    }

    func testATabIsInOnePairAtATime() {
        var (map, a, b, c, _, _) = makeMap()
        map.split(a, with: b)
        map.split(b, with: c)
        XCTAssertNil(map.split(containing: a))
        XCTAssertEqual(map.split(containing: b), SplitPair(left: b, right: c))
        XCTAssertEqual(map.splits.count, 1)
    }

    func testUnsplitLeavesBothTabsOpen() {
        var (map, a, b, _, _, _) = makeMap()
        map.split(a, with: b)
        map.unsplit(b)
        XCTAssertNil(map.split(containing: a))
        XCTAssertEqual(map.screen(of: a), [a])
        XCTAssertEqual(map.tab(a)?.isClosed, false)
        XCTAssertEqual(map.tab(b)?.isClosed, false)
    }

    func testClosingOneHalfEndsThePairAndTheOtherHalfTakesOver() {
        var (map, a, b, _, _, _) = makeMap()
        map.split(a, with: b)
        let next = map.close(a, now: at(10))
        XCTAssertEqual(next, b)
        XCTAssertNil(map.split(containing: b))
        XCTAssertEqual(map.onScreen, [b])
        map.pruneSplits()
        XCTAssertTrue(map.splits.isEmpty)
    }

    func testFractionIsKeptWithinBounds() {
        var (map, a, b, _, _, _) = makeMap()
        map.split(a, with: b)
        map.setSplitFraction(0.6, for: b)
        XCTAssertEqual(map.split(containing: a)?.fraction, 0.6)
        map.setSplitFraction(0.01, for: a)
        XCTAssertEqual(map.split(containing: a)?.fraction, SplitPair.fractionRange.lowerBound)
    }

    func testSwipesTreatAPairAsOneStopButArrowsStepThroughIt() {
        var (map, a, b, c, d, _) = makeMap()
        map.split(b, with: c)
        XCTAssertEqual(map.neighbor(of: b, .right), c, "arrow keys move between the two halves")
        XCTAssertEqual(map.screenNeighbor(of: b, .right), d)
        XCTAssertEqual(map.screenNeighbor(of: c, .right), d)
        XCTAssertEqual(map.screenNeighbor(of: c, .left), a)
        XCTAssertEqual(map.screenNeighbor(of: b, .left), a)
        XCTAssertNil(map.screenNeighbor(of: d, .right))
        XCTAssertEqual(map.screenNeighbor(of: a, .right), b)
    }

    func testPartnerOfTheCurrentTabIsNotClosedOrPutToSleep() {
        var (map, a, b, c, _, _) = makeMap()
        map.split(a, with: b)
        XCTAssertEqual(map.activeTabID, a)
        XCTAssertEqual(map.onScreen, [a, b])
        let later = at(map.settings.closeAfter + 100)
        XCTAssertFalse(map.tabsToSleep(loaded: [a, b, c], now: later).contains(b))
        XCTAssertTrue(map.tabsToSleep(loaded: [a, b, c], now: later).contains(c))
        let result = map.sweep(now: later)
        XCTAssertFalse(result.closed.contains(b))
        XCTAssertTrue(result.closed.contains(c))
        XCTAssertNotNil(map.split(containing: a))
    }

    func testLinkOpenedFromTheLeftHalfLandsAfterThePair() {
        var (map, a, b, c, _, _) = makeMap()
        map.split(a, with: b)
        let n = map.openChild(of: a, url: u("n"), now: at(20), activate: false)!
        let row = map.trails[1].tabs.map(\.id)
        XCTAssertEqual(Array(row.prefix(3)), [a, b, n])
        XCTAssertTrue(row.contains(c))
        XCTAssertNotNil(map.split(containing: a))
        XCTAssertTrue(map.areNeighbours(a, b))
    }

    func testMapsSavedBeforeSplitViewStillLoad() throws {
        let (map, _, _, _, _, _) = makeMap()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as? [String: Any])
        json["splitStore"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(TabMap.self, from: old)
        XCTAssertEqual(decoded.trails.count, 2)
        XCTAssertTrue(decoded.splits.isEmpty)
    }

    func testPairsSurviveSavingAndLoading() throws {
        var (map, a, b, _, _, _) = makeMap()
        map.split(a, with: b)
        map.setSplitFraction(0.4, for: a)
        let decoded = try JSONDecoder().decode(TabMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded.split(containing: b), SplitPair(left: a, right: b, fraction: 0.4))
    }
}
