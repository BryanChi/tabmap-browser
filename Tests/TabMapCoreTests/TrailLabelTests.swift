import XCTest
@testable import TabMapCore

final class TrailLabelTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    func url(_ s: String) -> URL { URL(string: s)! }

    /// One row: Swift concurrency pages; another row: bread.
    func twoRows() -> (TabMap, TrailID, TrailID) {
        var map = TabMap()
        let a = map.openRoot(url: url("https://docs.swift.org/actors"), title: "Actors in Swift", now: t0)
        _ = map.openChild(of: a, url: url("https://forums.swift.org/t/1"), title: "Sendable checking", now: at(1), activate: false)
        _ = map.openRoot(url: url("https://bread.example/sourdough"), title: "Sourdough starter", now: at(2))
        return (map, map.trails[0].id, map.trails[1].id)
    }

    // MARK: Signature

    func testSignatureChangesWhenATabIsAddedOrNavigates() {
        var map = TabMap()
        let a = map.openRoot(url: url("https://a.example/x"), title: "A", now: t0)
        let s1 = map.trails[0].contentSignature
        let b = map.openChild(of: a, url: url("https://b.example/y"), title: "B", now: at(1), activate: false)!
        let s2 = map.trails[0].contentSignature
        XCTAssertNotEqual(s1, s2, "adding a tab changes the signature")
        map.update(b, url: url("https://b.example/z"), title: nil)
        let s3 = map.trails[0].contentSignature
        XCTAssertNotEqual(s2, s3, "navigating changes the signature")
        map.update(b, url: nil, title: "B2")
        XCTAssertNotEqual(s3, map.trails[0].contentSignature, "a new title changes the signature")
    }

    func testSignatureIgnoresBlankTabsAndLabels() {
        var map = TabMap()
        let a = map.openRoot(url: url("https://a.example/x"), title: "A", now: t0)
        _ = map.openChild(of: a, url: url("https://b.example/y"), title: "B", now: at(1), activate: false)
        let before = map.trails[0].contentSignature
        _ = map.openChild(of: a, url: nil, now: at(2), activate: false)
        XCTAssertEqual(map.trails[0].contentSignature, before)
        XCTAssertTrue(map.setLabel(trail: map.trails[0].id, name: "N", summary: "S", signature: before))
        XCTAssertEqual(map.trails[0].contentSignature, before)
        XCTAssertFalse(map.trails[0].needsLabel, "applying a label must not ask for another one")
    }

    func testNeedsLabelOnlyForTwoOrMorePages() {
        var map = TabMap()
        let a = map.openRoot(url: url("https://a.example"), title: "A", now: t0)
        XCTAssertFalse(map.trails[0].needsLabel)
        _ = map.openChild(of: a, url: nil, now: at(1), activate: false)
        XCTAssertFalse(map.trails[0].needsLabel, "blank tabs do not count")
        _ = map.openChild(of: a, url: url("https://b.example"), title: "B", now: at(2), activate: false)
        XCTAssertTrue(map.trails[0].needsLabel)
        XCTAssertEqual(map.trailsNeedingLabels().map(\.id), [map.trails[0].id])
    }

    func testTrailsNeedingLabelsMostRecentFirst() {
        var map = TabMap()
        let a = map.openRoot(url: url("https://a.example"), title: "A", now: t0)
        _ = map.openChild(of: a, url: url("https://a2.example"), title: "A2", now: at(1), activate: false)
        let b = map.openRoot(url: url("https://b.example"), title: "B", now: at(2))
        _ = map.openChild(of: b, url: url("https://b2.example"), title: "B2", now: at(3), activate: false)
        map.touch(a, now: at(10))
        XCTAssertEqual(map.trailsNeedingLabels().map { $0.tabs[0].id }, [a, b])
    }

    // MARK: Setting and clearing

    func testSetLabelRefusesAStaleSignature() {
        var (map, swift, _) = twoRows()
        let old = map.trails[0].contentSignature
        _ = map.openChild(of: map.trails[0].tabs[0].id, url: url("https://c.example"), title: "C", now: at(5), activate: false)
        XCTAssertFalse(map.setLabel(trail: swift, name: "N", summary: "S", signature: old))
        XCTAssertNil(map.trails[0].name)
        XCTAssertFalse(map.setLabel(trail: TrailID(), name: "N", summary: "S", signature: old))
    }

    func testSetLabelRoundTripsThroughJSON() throws {
        var (map, swift, _) = twoRows()
        XCTAssertTrue(map.setLabel(trail: swift, name: "Swift Concurrency", summary: "Actors and sendability.",
                                   signature: map.trails[0].contentSignature))
        let decoded = try JSONDecoder().decode(TabMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded, map)
        XCTAssertEqual(decoded.trails[0].name, "Swift Concurrency")
        XCTAssertEqual(decoded.trails[0].summary, "Actors and sendability.")
        XCTAssertFalse(decoded.trails[0].needsLabel)
    }

    func testDecodesStateSavedBeforeLabelsExisted() throws {
        let json = """
        {"trails":[{"id":"7C1D5A4E-0000-4000-8000-000000000001","tabs":[
          {"id":"7C1D5A4E-0000-4000-8000-0000000000A1","url":"https://a.example","title":"A",
           "createdAt":0,"lastAccessedAt":0,"pinned":false}],
          "lastActiveTabID":"7C1D5A4E-0000-4000-8000-0000000000A1"}],
         "activeTabID":"7C1D5A4E-0000-4000-8000-0000000000A1","settings":{}}
        """
        let map = try JSONDecoder().decode(TabMap.self, from: Data(json.utf8))
        XCTAssertEqual(map.trails.count, 1)
        XCTAssertNil(map.trails[0].name)
        XCTAssertNil(map.trails[0].summary)
        XCTAssertNil(map.trails[0].labelSignature)
    }

    func testLabelIsClearedWhenARowDropsBelowTwoPages() {
        var (map, swift, _) = twoRows()
        map.setLabel(trail: swift, name: "N", summary: "S", signature: map.trails[0].contentSignature)
        XCTAssertFalse(map.clearStaleLabels())
        map.remove(map.trails[0].tabs[1].id)
        XCTAssertTrue(map.clearStaleLabels())
        XCTAssertNil(map.trails[0].name)
        XCTAssertNil(map.trails[0].summary)
        XCTAssertNil(map.trails[0].labelSignature)
    }

    // MARK: Search

    func testLabelMatchShowsTheWholeRow() {
        var (map, swift, _) = twoRows()
        map.setLabel(trail: swift, name: "Swift Concurrency", summary: "Reading about actors and data races.",
                     signature: map.trails[0].contentSignature)
        let layout = map.layout(matching: "CONCURRENCY races")
        XCTAssertEqual(layout.open.map(\.id), [swift])
        XCTAssertEqual(layout.open[0].tabs.count, 2, "a matching name shows every tab in the row")
    }

    func testLabelMatchIsDiacriticInsensitive() {
        var (map, swift, _) = twoRows()
        map.setLabel(trail: swift, name: "Café Research", summary: "S", signature: map.trails[0].contentSignature)
        XCTAssertEqual(map.layout(matching: "cafe").open.map(\.id), [swift])
    }

    func testTabMatchStillFilters() {
        var (map, swift, _) = twoRows()
        map.setLabel(trail: swift, name: "Swift Concurrency", summary: "Actors.", signature: map.trails[0].contentSignature)
        let layout = map.layout(matching: "sendable")
        XCTAssertEqual(layout.open.map(\.id), [swift])
        XCTAssertEqual(layout.open[0].tabs.map(\.title), ["Sendable checking"])
    }

    func testTabSearchNeedsEveryWord() {
        let (map, _, bread) = twoRows()
        XCTAssertEqual(map.layout(matching: "sourdough starter").open.map(\.id), [bread])
        XCTAssertEqual(map.layout(matching: "starter bread.example").open.map(\.id), [bread], "words can match title or address")
        XCTAssertTrue(map.layout(matching: "sourdough actors").isEmpty, "words in different tabs do not match")
        XCTAssertEqual(map.layout(matching: "   ").open.count, 2)
    }

    func testLabelWordsMustAllMatchToo() {
        var (map, swift, _) = twoRows()
        map.setLabel(trail: swift, name: "Swift Concurrency", summary: "Actors.", signature: map.trails[0].contentSignature)
        // "concurrency" is in the name but "sendable" only in one tab: no label match, and no tab has both.
        XCTAssertTrue(map.layout(matching: "concurrency sendable").isEmpty)
    }

    // MARK: Heuristic

    func trail(_ pages: [(String, String)]) -> Trail {
        Trail(tabs: pages.enumerated().map { i, p in MapTab(url: url(p.0), title: p.1, now: at(Double(i))) })
    }

    func testHeuristicNamesFromSharedTitleWords() {
        let t = trail([
            ("https://github.com/x/pulls", "Rebase conflicts · Pull Request #12 · GitHub"),
            ("https://stackoverflow.com/q/1", "How to resolve rebase conflicts - Stack Overflow"),
            ("https://www.git-scm.com/docs/rebase", "Git - git-rebase Documentation"),
        ])
        let label = TrailLabelHeuristic.label(for: t)
        XCTAssertEqual(label.name, "Rebase Conflicts")
        XCTAssertEqual(label.summary, "3 pages across github.com, stackoverflow.com and 1 other site")
    }

    func testHeuristicDropsSiteNamesAndFallsBackToTheSite() {
        let t = trail([
            ("https://www.youtube.com/watch?v=1", "Morning jazz - YouTube"),
            ("https://www.youtube.com/watch?v=2", "Bike repair basics - YouTube"),
        ])
        let label = TrailLabelHeuristic.label(for: t)
        XCTAssertEqual(label.name, "Youtube", "no shared topic word, so the site names the row")
        XCTAssertEqual(label.summary, "2 pages on youtube.com")
    }

    func testHeuristicSummaryForTwoSites() {
        let t = trail([
            ("https://a.example/1", "Tomato soup recipe"),
            ("https://b.example/2", "Easy tomato soup"),
            ("https://a.example/3", "Soup bowls"),
        ])
        let label = TrailLabelHeuristic.label(for: t)
        XCTAssertEqual(label.name, "Soup Tomato")
        XCTAssertEqual(label.summary, "3 pages across a.example and b.example")
    }

    func testReadableSiteName() {
        XCTAssertEqual(TrailLabelHeuristic.readableSiteName("docs.github.com"), "Github")
        XCTAssertEqual(TrailLabelHeuristic.readableSiteName("bbc.co.uk"), "Bbc")
    }

    // MARK: Model text

    func testParseModelReply() {
        let a = TrailLabelText.parse("Name: \"Swift Concurrency.\"\nDescription: Reading about actors and data races.")
        XCTAssertEqual(a?.name, "Swift Concurrency")
        XCTAssertEqual(a?.summary, "Reading about actors and data races.")

        let b = TrailLabelText.parse("**Name:** Trip Planning\n**Description:** Flights and hotels for Lisbon.")
        XCTAssertEqual(b?.name, "Trip Planning")
        XCTAssertEqual(b?.summary, "Flights and hotels for Lisbon.")

        let c = TrailLabelText.parse("Bread Baking\nSourdough starters and oven temperatures.")
        XCTAssertEqual(c?.name, "Bread Baking")
        XCTAssertEqual(c?.summary, "Sourdough starters and oven temperatures.")

        XCTAssertNil(TrailLabelText.parse("  \n \"\" "))
        let long = TrailLabelText.parse("Name: " + String(repeating: "word ", count: 20))
        XCTAssertLessThanOrEqual(long?.name.count ?? 99, TrailLabelText.maxNameLength)
    }

    func testPromptListsAtMostTwelvePages() {
        let pages = (0..<15).map { ("https://site\($0).example/p", String(repeating: "t", count: 100)) }
        let prompt = TrailLabelText.prompt(for: trail(pages))
        XCTAssertEqual(prompt.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 12)
        XCTAssertTrue(prompt.contains("— site0.example"))
        XCTAssertFalse(prompt.contains(String(repeating: "t", count: 81)))
    }
}
