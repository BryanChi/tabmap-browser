import XCTest
@testable import TabMapCore

final class HistoryTreeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func u(_ s: String) -> URL { URL(string: "https://\(s).example")! }
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// a → b → c, back to a, then a → d. The detour through b and c must survive.
    func makeDetour() -> (tree: HistoryTree, a: Int, b: Int, c: Int, d: Int) {
        var tree = HistoryTree()
        let a = tree.visit(url: u("a"), now: at(0))
        let b = tree.visit(url: u("b"), now: at(1))
        let c = tree.visit(url: u("c"), now: at(2))
        tree.move(to: a, now: at(3))
        let d = tree.visit(url: u("d"), now: at(4))
        return (tree, a, b, c, d)
    }

    func testStraightBrowsingIsOneLine() {
        var tree = HistoryTree()
        let a = tree.visit(url: u("a"), now: at(0))
        let b = tree.visit(url: u("b"), now: at(1))
        let c = tree.visit(url: u("c"), now: at(2))
        XCTAssertEqual(tree.pathToCurrent, [a, b, c])
        XCTAssertFalse(tree.hasBranches)
        let layout = tree.layout()
        XCTAssertEqual(layout.lanes, 1)
        XCTAssertEqual(layout.columns, 3)
    }

    func testGoingBackAndElsewhereKeepsTheDetour() {
        let (tree, a, b, c, d) = makeDetour()
        XCTAssertEqual(tree.count, 4)
        XCTAssertTrue(tree.hasBranches)
        XCTAssertEqual(tree.currentID, d)
        XCTAssertEqual(tree.pathToCurrent, [a, d])
        XCTAssertEqual(tree.node(a)?.children, [b, d])
        XCTAssertEqual(tree.node(b)?.children, [c])
    }

    func testCurrentPathRunsAlongTheTopAndDetoursHangBelow() {
        let (tree, a, b, c, d) = makeDetour()
        let layout = tree.layout()
        XCTAssertEqual(layout.lanes, 2)
        XCTAssertEqual(layout.node(a)?.lane, 0)
        XCTAssertEqual(layout.node(d)?.lane, 0)
        XCTAssertEqual(layout.node(b)?.lane, 1)
        XCTAssertEqual(layout.node(c)?.lane, 1)
        XCTAssertEqual(layout.node(c)?.column, 2)
        XCTAssertEqual(layout.node(d)?.isCurrent, true)
        XCTAssertEqual(layout.node(a)?.onCurrentPath, true)
        XCTAssertEqual(layout.node(b)?.onCurrentPath, false)
    }

    func testJumpingToADetourMakesItTheMainLine() {
        var (tree, a, b, c, d) = makeDetour()
        tree.move(to: c, now: at(5))
        XCTAssertEqual(tree.pathToCurrent, [a, b, c])
        XCTAssertEqual(tree.count, 4, "jumping must not add pages")
        let layout = tree.layout()
        XCTAssertEqual(layout.node(c)?.lane, 0)
        XCTAssertEqual(layout.node(d)?.lane, 1)
    }

    func testRevisitingAPageFromTheSamePlaceReusesItsBranch() {
        var (tree, a, b, _, _) = makeDetour()
        tree.move(to: a, now: at(5))
        let again = tree.visit(url: u("b"), now: at(6))
        XCTAssertEqual(again, b)
        XCTAssertEqual(tree.count, 4)
    }

    func testReloadDoesNotAddAPage() {
        var tree = HistoryTree()
        let a = tree.visit(url: u("a"), now: at(0))
        XCTAssertEqual(tree.visit(url: u("a"), title: "A", now: at(1)), a)
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree.node(a)?.title, "A")
    }

    func testForwardFollowsTheMostRecentBranch() {
        var (tree, a, b, c, d) = makeDetour()
        tree.move(to: a, now: at(5))
        XCTAssertEqual(tree.preferredChild(of: a), d)
        XCTAssertEqual(tree.forwardChain(from: a), [d])
        tree.move(to: b, now: at(6))
        tree.move(to: a, now: at(7))
        XCTAssertEqual(tree.forwardChain(from: a), [b, c])
        XCTAssertEqual(tree.ancestors(of: c), [b, a])
    }

    func testNoTwoPagesShareACell() {
        var tree = HistoryTree()
        let root = tree.visit(url: u("root"), now: at(0))
        var clock: TimeInterval = 1
        // Three detours of different lengths off the root, and one off the middle of a detour.
        for (name, length) in [("x", 3), ("y", 1), ("z", 4)] {
            tree.move(to: root, now: at(clock)); clock += 1
            for i in 0..<length {
                tree.visit(url: u("\(name)\(i)"), now: at(clock)); clock += 1
            }
        }
        let mid = tree.ancestors(of: tree.currentID)[1]
        tree.move(to: mid, now: at(clock)); clock += 1
        tree.visit(url: u("side"), now: at(clock))

        let layout = tree.layout()
        XCTAssertEqual(layout.nodes.count, tree.count)
        let cells = Set(layout.nodes.map { "\($0.column),\($0.lane)" })
        XCTAssertEqual(cells.count, layout.nodes.count)
        for n in layout.nodes {
            guard let p = n.parent, let parent = layout.node(p) else { continue }
            XCTAssertEqual(n.column, parent.column + 1)
            XCTAssertGreaterThanOrEqual(n.lane, parent.lane)
        }
    }

    func testOldDetoursAreForgottenFirstWhenTheTreeIsFull() {
        var (tree, a, b, c, _) = makeDetour()
        for i in 0..<(HistoryTree.maxNodes) {
            tree.visit(url: u("p\(i)"), now: at(10 + TimeInterval(i)))
        }
        XCTAssertEqual(tree.count, HistoryTree.maxNodes)
        XCTAssertNil(tree.node(c), "the oldest abandoned page goes first")
        XCTAssertNil(tree.node(b))
        XCTAssertNotNil(tree.current)
        XCTAssertEqual(tree.pathToCurrent.count, tree.count)
        XCTAssertNil(tree.node(a), "then the far end of the path")
        XCTAssertEqual(tree.pathToCurrent.first, tree.rootID)
    }

    func testSurvivesSavingAndLoading() throws {
        let (tree, _, _, _, _) = makeDetour()
        let data = try JSONEncoder().encode(tree)
        let back = try JSONDecoder().decode(HistoryTree.self, from: data)
        XCTAssertEqual(back, tree)
        var grown = back
        let e = grown.visit(url: u("e"), now: at(9))
        XCTAssertNil(tree.node(e), "ids must not be reused after a reload")
    }

    // MARK: Menu rows

    func ids(_ rows: [HistoryMenuRow]) -> [String] { rows.map(\.id) }

    func testMenuKeepsTheMainLineStraightAndFoldsTheDetour() {
        let (tree, a, b, _, d) = makeDetour()
        let rows = tree.menuRows()
        // Top to bottom: current page, the folded side trip that left from a, then a.
        XCTAssertEqual(ids(rows), ["p\(d)", "b\(b)", "p\(a)"])
        XCTAssertEqual(rows[1].kind, .branch(start: b, pages: 2, expanded: false))
        XCTAssertEqual(rows[1].lane, 1)
        XCTAssertEqual(rows[1].link, "p\(a)")
        XCTAssertEqual(rows[0].link, "p\(a)", "the main line runs past the fold to its own parent")
        XCTAssertTrue(rows[0].isCurrent)
    }

    func testExpandingADetourShowsItsPagesInTheirOwnLane() {
        let (tree, a, b, c, d) = makeDetour()
        let rows = tree.menuRows(expanded: [b])
        XCTAssertEqual(ids(rows), ["p\(d)", "p\(c)", "p\(b)", "b\(b)", "p\(a)"])
        XCTAssertEqual(rows[1].lane, 1)
        XCTAssertEqual(rows[2].link, "b\(b)")
        XCTAssertEqual(rows[1].link, "p\(b)")
        XCTAssertTrue(rows[1].inBranch)
        XCTAssertFalse(rows[1].onCurrentPath)
    }

    func testPagesAheadOfTheCurrentOneSitAboveIt() {
        var (tree, a, _, _, d) = makeDetour()
        tree.move(to: a, now: at(5))
        let rows = tree.menuRows()
        XCTAssertEqual(rows.first?.id, "p\(d)")
        XCTAssertTrue(rows.first?.isAhead == true)
        XCTAssertTrue(rows.last?.isCurrent == true)
    }

    func testMainLineNeverInterleavesBranches() {
        // A long main line with a side trip off its middle: main line rows must stay in order.
        var tree = HistoryTree()
        let p0 = tree.visit(url: u("p0"), now: at(0))
        let p1 = tree.visit(url: u("p1"), now: at(1))
        tree.visit(url: u("x0"), now: at(2))
        tree.visit(url: u("x1"), now: at(3))
        tree.move(to: p1, now: at(4))
        let p2 = tree.visit(url: u("p2"), now: at(5))
        let p3 = tree.visit(url: u("p3"), now: at(6))
        let main = tree.menuRows().filter { $0.lane == 0 }.map(\.node)
        XCTAssertEqual(main, [p3, p2, p1, p0])
        XCTAssertEqual(tree.menuRows().count, 5)
    }

    func testNestedDetourFoldsAgainInsideAnOpenOne() {
        var tree = HistoryTree()
        let a = tree.visit(url: u("a"), now: at(0))
        let b = tree.visit(url: u("b"), now: at(1))
        tree.visit(url: u("c"), now: at(2))
        tree.move(to: b, now: at(3))
        let e = tree.visit(url: u("e"), now: at(4))
        tree.move(to: a, now: at(5))
        tree.visit(url: u("d"), now: at(6))
        // b -> e is b's preferred line (newer); c is a side trip inside the side trip.
        let rows = tree.menuRows(expanded: [b])
        let fold = rows.first { if case .branch = $0.kind { return $0.lane == 2 } else { return false } }
        XCTAssertNotNil(fold)
        XCTAssertEqual(rows.first { $0.id == "p\(e)" }?.lane, 1)
        XCTAssertEqual(tree.subtreeSize(b), 3)
    }
}

