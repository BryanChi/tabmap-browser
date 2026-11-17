import XCTest
@testable import TabMapCore

final class TrailMergeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    func url(_ s: String) -> URL { URL(string: s)! }

    /// Opens a row of pages; returns the tab ids.
    @discardableResult
    func row(_ map: inout TabMap, at time: TimeInterval, _ pages: [(String, String)]) -> [TabID] {
        var ids: [TabID] = []
        for (i, page) in pages.enumerated() {
            if i == 0 {
                ids.append(map.openRoot(url: url(page.0), title: page.1, now: at(time)))
            } else {
                ids.append(map.openChild(of: ids[i - 1], url: url(page.0), title: page.1,
                                         now: at(time + Double(i)), activate: false)!)
            }
        }
        return ids
    }

    func trailID(_ map: TabMap, of tab: TabID) -> TrailID {
        map.trails[map.locate(tab)!.trail].id
    }

    // MARK: Joining

    func testMergeMovesTabsToTheRightAndRemovesTheRow() {
        var map = TabMap()
        let a = row(&map, at: 0, [("https://a.example/1", "A1"), ("https://a.example/2", "A2")])
        let b = row(&map, at: 10, [("https://b.example/1", "B1"), ("https://b.example/2", "B2")])
        let source = trailID(map, of: a[0])
        let target = trailID(map, of: b[0])

        let record = map.mergeTrail(source, into: target)
        XCTAssertNotNil(record)
        XCTAssertEqual(map.trails.count, 1)
        XCTAssertEqual(map.trails[0].id, target)
        XCTAssertEqual(map.trails[0].tabs.map(\.id), b + a)
        XCTAssertEqual(map.activeTabID, b[0], "joining must not change the tab in front")
        XCTAssertEqual(record?.movedTabIDs, a)
    }

    func testMergeKeepsTheActiveTabAsTheRowsLastActive() {
        var map = TabMap()
        let a = row(&map, at: 0, [("https://a.example/1", "A1")])
        let b = row(&map, at: 10, [("https://b.example/1", "B1")])
        // b[0] is in front; fold its row into a's.
        map.mergeTrail(trailID(map, of: b[0]), into: trailID(map, of: a[0]))
        XCTAssertEqual(map.trails.count, 1)
        XCTAssertEqual(map.trails[0].lastActiveTabID, b[0])
        XCTAssertEqual(map.activeTabID, b[0])
    }

    func testMergeRejectsUnknownOrIdenticalRows() {
        var map = TabMap()
        let a = row(&map, at: 0, [("https://a.example/1", "A1")])
        let id = trailID(map, of: a[0])
        XCTAssertNil(map.mergeTrail(id, into: id))
        XCTAssertNil(map.mergeTrail(TrailID(), into: id))
        XCTAssertNil(map.mergeTrail(id, into: TrailID()))
        XCTAssertEqual(map.trails.count, 1)
    }

    func testUndoPutsBothRowsBack() {
        var map = TabMap()
        let a = row(&map, at: 0, [("https://a.example/1", "A1"), ("https://a.example/2", "A2")])
        let b = row(&map, at: 10, [("https://b.example/1", "B1")])
        let source = trailID(map, of: a[0])
        let target = trailID(map, of: b[0])
        let record = map.mergeTrail(source, into: target)!

        XCTAssertTrue(map.undoMerge(record))
        XCTAssertEqual(map.trails.count, 2)
        XCTAssertEqual(map.trails.first { $0.id == target }?.tabs.map(\.id), b)
        XCTAssertEqual(map.trails.first { $0.id == source }?.tabs.map(\.id), a)
        XCTAssertFalse(map.undoMerge(record), "a second undo has nothing to do")
    }

    func testUndoTakesTabsOpenedSinceBackWithTheirOpener() {
        var map = TabMap()
        let a = row(&map, at: 0, [("https://a.example/1", "A1")])
        let b = row(&map, at: 10, [("https://b.example/1", "B1")])
        let source = trailID(map, of: a[0])
        let target = trailID(map, of: b[0])
        let record = map.mergeTrail(source, into: target)!
        let fromA = map.openChild(of: a[0], url: url("https://a.example/9"), title: "A9", now: at(20), activate: false)!
        let fromB = map.openChild(of: b[0], url: url("https://b.example/9"), title: "B9", now: at(21), activate: false)!

        XCTAssertTrue(map.undoMerge(record))
        XCTAssertEqual(map.trails.first { $0.id == source }?.tabs.map(\.id), [a[0], fromA])
        XCTAssertEqual(map.trails.first { $0.id == target }?.tabs.map(\.id), [b[0], fromB])
    }

    func testUndoSurvivesAForgottenTab() {
        var map = TabMap()
        let a = row(&map, at: 0, [("https://a.example/1", "A1"), ("https://a.example/2", "A2")])
        let b = row(&map, at: 10, [("https://b.example/1", "B1")])
        let source = trailID(map, of: a[0])
        let record = map.mergeTrail(source, into: trailID(map, of: b[0]))!
        map.remove(a[0])
        XCTAssertTrue(map.undoMerge(record))
        XCTAssertEqual(map.trails.first { $0.id == source }?.tabs.map(\.id), [a[1]])
        XCTAssertEqual(map.trails.first { $0.id == source }?.lastActiveTabID, a[1])
    }

    // MARK: Clues

    func testWordsDropNoiseAndSiteNames() {
        XCTAssertEqual(TrailSimilarity.words(in: "The Best Ryokan in Kyōto, 2026!"), ["ryokan", "kyoto"])

        let tab = MapTab(url: url("https://www.github.com/apple/swift/issues/1"),
                         title: "Crash in actor isolation · apple/swift · GitHub", now: t0)
        let clues = TrailSimilarity.clues(of: Trail(tabs: [tab]))
        XCTAssertNil(clues.words["github"])
        XCTAssertNotNil(clues.words["actor"])
        XCTAssertEqual(clues.sections, ["github.com/apple/swift"])
        XCTAssertEqual(clues.hosts, ["github.com"])
    }

    func testSearchQueriesCountAndSearchEnginesDoNot() {
        let tab = MapTab(url: url("https://www.google.com/search?q=kyoto+ryokan+onsen"), title: "", now: t0)
        let clues = TrailSimilarity.clues(of: Trail(tabs: [tab]))
        XCTAssertEqual(Set(clues.words.keys), ["kyoto", "ryokan", "onsen"])
        XCTAssertTrue(clues.hosts.isEmpty)
        XCTAssertTrue(clues.sections.isEmpty)
    }

    // MARK: Finding

    func testRowsAboutTheSameThingAreFound() {
        var map = TabMap()
        let trip1 = row(&map, at: 0, [
            ("https://stays.example/a", "Best ryokan in Kyoto with onsen"),
            ("https://stays.example/b", "Kyoto ryokan guide"),
        ])
        let code = row(&map, at: 100, [
            ("https://dev.example/a", "Swift concurrency: actors explained"),
            ("https://dev.example/b", "Async await in Swift"),
        ])
        let trip2 = row(&map, at: 200, [
            ("https://travel.example/a", "Kyoto ryokan booking"),
            ("https://baths.example/b", "Onsen etiquette in a Kyoto ryokan"),
        ])

        let found = map.mergeCandidates(minimumScore: 0.42)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.targetID, trailID(map, of: trip2[0]), "the more recently used row stays")
        XCTAssertEqual(found.first?.sourceID, trailID(map, of: trip1[0]))
        XCTAssertEqual(Set(found.first?.sharedWords.prefix(3) ?? []), ["kyoto", "ryokan", "onsen"])

        let loose = map.mergeCandidates(minimumScore: 0.05)
        let codeRow = trailID(map, of: code[0])
        XCTAssertFalse(loose.contains { $0.targetID == codeRow || $0.sourceID == codeRow })
    }

    func testOneSharedWordIsNotEnough() {
        var map = TabMap()
        row(&map, at: 0, [("https://one.example/a", "Kyoto weather")])
        row(&map, at: 10, [("https://two.example/b", "Kyoto protocol history")])
        XCTAssertTrue(map.mergeCandidates(minimumScore: 0.0).isEmpty)
    }

    func testSameCornerOfASiteCounts() {
        var map = TabMap()
        row(&map, at: 0, [("https://github.com/apple/swift/issues/10", "Crash in type checker")])
        row(&map, at: 10, [("https://github.com/apple/swift/pull/22", "Fix parser diagnostics")])
        row(&map, at: 20, [("https://github.com/rust-lang/rust/issues/5", "Borrow checker regression")])
        let found = map.mergeCandidates(minimumScore: 0.3)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.sharesSiteSection, true)
    }

    func testDismissedPairsAndClosedRowsAreLeftOut() {
        var map = TabMap()
        let a = row(&map, at: 0, [("https://one.example/a", "Kyoto ryokan onsen")])
        let b = row(&map, at: 10, [("https://two.example/b", "Kyoto ryokan onsen booking")])
        let key = MergeCandidate.pairKey(trailID(map, of: a[0]), trailID(map, of: b[0]))
        XCTAssertEqual(map.mergeCandidates(minimumScore: 0.42).first?.pairKey, key)
        XCTAssertTrue(map.mergeCandidates(minimumScore: 0.42, excluding: [key]).isEmpty)

        map.close(a[0], now: at(20))
        XCTAssertTrue(map.mergeCandidates(minimumScore: 0.42).isEmpty, "a row below the horizon is never offered")
    }

    func testEachRowIsOfferedOnce() {
        var map = TabMap()
        row(&map, at: 0, [("https://one.example/a", "Kyoto ryokan onsen")])
        row(&map, at: 10, [("https://two.example/b", "Kyoto ryokan onsen")])
        row(&map, at: 20, [("https://three.example/c", "Kyoto ryokan onsen")])
        XCTAssertEqual(map.mergeCandidates(minimumScore: 0.42).count, 1)
    }
}
