import XCTest
@testable import TabMapCore

final class DuplicateDetectionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    func key(_ s: String) -> PageKey? { PageKey(URL(string: s)) }
    func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: What counts as the same page

    func testCosmeticDifferencesAreTheSamePage() {
        let base = key("https://example.com/docs")
        XCTAssertNotNil(base)
        XCTAssertEqual(key("http://example.com/docs"), base)
        XCTAssertEqual(key("https://www.example.com/docs"), base)
        XCTAssertEqual(key("https://EXAMPLE.com/docs"), base)
        XCTAssertEqual(key("https://example.com:443/docs"), base)
        XCTAssertEqual(key("https://example.com/docs/"), base)
        XCTAssertEqual(key("https://example.com/docs#install"), base)
        XCTAssertEqual(key("https://example.com/docs?utm_source=mail&fbclid=abc"), base)
        XCTAssertEqual(key("https://example.com"), key("https://example.com/"))
    }

    func testQueryOrderDoesNotMatterButValuesDo() {
        XCTAssertEqual(key("https://example.com/s?a=1&b=2"), key("https://example.com/s?b=2&a=1"))
        XCTAssertNotEqual(key("https://example.com/s?a=1"), key("https://example.com/s?a=2"))
        XCTAssertNotEqual(key("https://example.com/watch?v=one"), key("https://example.com/watch?v=two"))
        XCTAssertNotEqual(key("https://example.com/s?a=1"), key("https://example.com/s"))
    }

    func testRealDifferencesAreDifferentPages() {
        XCTAssertNotEqual(key("https://example.com/a"), key("https://example.com/b"))
        XCTAssertNotEqual(key("https://example.com/Docs"), key("https://example.com/docs"))
        XCTAssertNotEqual(key("https://docs.example.com/"), key("https://example.com/"))
        XCTAssertNotEqual(key("http://localhost:3000/"), key("http://localhost:8080/"))
        XCTAssertNotEqual(key("https://example.com/app#/inbox"), key("https://example.com/app#/sent"))
        XCTAssertNotEqual(key("https://example.com/app#!/inbox"), key("https://example.com/app"))
    }

    func testOnlyWebPagesHaveAKey() {
        XCTAssertNil(PageKey(nil))
        XCTAssertNil(key("about:blank"))
        XCTAssertNil(key("file:///Users/b/notes.html"))
        XCTAssertNil(key("data:text/html,hello"))
    }

    // MARK: Finding the tab

    func testFindsTheTabAlreadyShowingThePage() {
        var map = TabMap()
        let a = map.openRoot(url: url("https://www.example.com/docs/"), now: t0)
        let b = map.openRoot(url: url("https://other.example/"), now: at(1))
        XCTAssertEqual(map.duplicate(of: url("http://example.com/docs?utm_source=x#top"), from: b), a)
        XCTAssertNil(map.duplicate(of: url("https://example.com/elsewhere"), from: b))
    }

    func testTypingTheCurrentAddressIsNotADuplicate() {
        var map = TabMap()
        let a = map.openRoot(url: url("https://example.com/"), now: t0)
        _ = map.openRoot(url: url("https://example.com/"), now: at(1), activate: false)
        XCTAssertNil(map.duplicate(of: url("https://example.com/"), from: a))
    }

    func testBlankTabsNeverMatch() {
        var map = TabMap()
        let a = map.openRoot(url: url("https://example.com/"), now: t0)
        _ = map.openRoot(url: nil, now: at(1), activate: false)
        XCTAssertNil(map.duplicate(of: url("about:blank"), from: a))
    }

    func testOpenTabWinsOverClosedThenMostRecent() {
        var map = TabMap()
        let page = url("https://example.com/p")
        let old = map.openRoot(url: page, now: t0)
        let closed = map.openRoot(url: page, now: at(1))
        let recent = map.openRoot(url: page, now: at(2))
        let here = map.openRoot(url: url("https://other.example/"), now: at(3))
        map.touch(closed, now: at(10))
        map.close(closed, now: at(11))
        XCTAssertEqual(map.duplicate(of: page, from: here), recent)
        map.touch(old, now: at(20))
        XCTAssertEqual(map.duplicate(of: page, from: here), old)
    }

    func testClosedTabIsFoundAndComesBackWhenActivated() {
        var map = TabMap()
        let page = url("https://example.com/p")
        let a = map.openRoot(url: page, now: t0)
        let here = map.openRoot(url: url("https://other.example/"), now: at(1))
        map.close(a, now: at(2))
        let found = map.duplicate(of: page, from: here)
        XCTAssertEqual(found, a)
        let result = map.activate(a, now: at(3))
        XCTAssertTrue(result.reopened)
        XCTAssertEqual(map.activeTabID, a)
    }

    func testBackgroundScopeOnlyLooksAtOpenTabsInTheSameRow() {
        var map = TabMap()
        let page = url("https://example.com/p")
        let elsewhere = map.openRoot(url: page, now: t0)
        let parent = map.openRoot(url: url("https://other.example/"), now: at(1))
        XCTAssertNil(map.duplicate(of: page, from: parent, scope: .openTabsInTrail),
                     "a copy in another row does not stop a background open here")
        XCTAssertEqual(map.duplicate(of: page, from: parent, scope: .wholeMap), elsewhere)

        let child = map.openChild(of: parent, url: page, now: at(2), activate: false)!
        XCTAssertEqual(map.duplicate(of: page, from: parent, scope: .openTabsInTrail), child)
        map.close(child, now: at(3))
        XCTAssertNil(map.duplicate(of: page, from: parent, scope: .openTabsInTrail))
    }

    func testJumpingFromABlankTabThrowsTheBlankAway() {
        var map = TabMap()
        let page = url("https://example.com/p")
        let a = map.openRoot(url: page, now: t0)
        let blank = map.openRoot(url: nil, now: at(1))
        let found = map.duplicate(of: page, from: blank)
        XCTAssertEqual(found, a)
        let result = map.activate(a, now: at(2))
        XCTAssertEqual(result.discarded, blank)
        XCTAssertEqual(map.trails.count, 1)
    }
}
