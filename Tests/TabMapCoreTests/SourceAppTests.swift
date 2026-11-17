import XCTest
@testable import TabMapCore

final class SourceAppTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let claude = SourceApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude")
    private let slack = SourceApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    func testLinkFromAppStartsNewRowOnTop() {
        var map = TabMap()
        let first = map.openRoot(url: URL(string: "https://a.com")!, now: t0)
        let opened = map.openFromApp(url: URL(string: "https://docs.swift.org")!, app: claude, now: t0.addingTimeInterval(60))

        XCTAssertEqual(map.trails.count, 2)
        XCTAssertEqual(map.activeTabID, opened.id)
        XCTAssertNil(opened.discarded)
        XCTAssertEqual(map.tab(opened.id)?.sourceApp, claude)
        XCTAssertNil(map.tab(opened.id)?.openerID)
        let top = map.layout().open.first
        XCTAssertEqual(top?.tabs.map(\.id), [opened.id])
        XCTAssertNotEqual(top?.tabs.first?.id, first)
    }

    func testBlankTabIsReplacedNotKept() {
        var map = TabMap()
        let blank = map.openRoot(url: nil, now: t0)
        let opened = map.openFromApp(url: URL(string: "https://a.com")!, app: claude, now: t0)
        XCTAssertEqual(opened.discarded, blank)
        XCTAssertNil(map.tab(blank))
        XCTAssertEqual(map.trails.count, 1)
    }

    func testSearchFindsTabByAppName() {
        var map = TabMap()
        map.openRoot(url: URL(string: "https://news.com")!, title: "News", now: t0)
        let opened = map.openFromApp(url: URL(string: "https://docs.swift.org")!, app: claude, now: t0)
        map.update(opened.id, url: nil, title: "The Swift Programming Language")

        let ids = map.layout(matching: "claude").open.flatMap { $0.tabs.map(\.id) }
        XCTAssertEqual(ids, [opened.id])
        // Words can mix the app name with the page.
        XCTAssertEqual(map.layout(matching: "claude swift").open.flatMap { $0.tabs.map(\.id) }, [opened.id])
        XCTAssertTrue(map.layout(matching: "slack").isEmpty)
    }

    func testTabsOpenedFromAnAppLinkShareItsContext() {
        var map = TabMap()
        let opened = map.openFromApp(url: URL(string: "https://docs.swift.org")!, app: claude, now: t0)
        let child = map.openChild(of: opened.id, url: URL(string: "https://swift.org/blog")!, now: t0, activate: false)!
        let grandchild = map.openChild(of: child, url: URL(string: "https://forums.swift.org")!, now: t0, activate: false)!
        // A tab added to the row by hand is not part of the Claude context.
        let typed = map.openRoot(url: URL(string: "https://example.com")!, now: t0, activate: false)

        let found = Set(map.layout(matching: "claude").open.flatMap { $0.tabs.map(\.id) })
        XCTAssertEqual(found, [opened.id, child, grandchild])
        XCTAssertFalse(found.contains(typed))
        XCTAssertEqual(map.originApp(of: grandchild), claude)
        XCTAssertNil(map.tab(grandchild)?.sourceApp, "only the tab the app opened carries the icon")
    }

    func testClosedTabsKeepTheirApp() {
        var map = TabMap()
        let a = map.openFromApp(url: URL(string: "https://a.com")!, app: slack, now: t0)
        map.openRoot(url: URL(string: "https://b.com")!, now: t0)
        map.close(a.id, now: t0)
        let found = map.layout(matching: "slack").archived.flatMap { $0.tabs.map(\.id) }
        XCTAssertEqual(found, [a.id])
    }

    func testOldSavedMapsStillLoad() throws {
        var map = TabMap()
        map.openRoot(url: URL(string: "https://a.com")!, now: t0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as! [String: Any]
        // Strip the new field the way a file saved by an older build would look.
        var trails = json["trails"] as! [[String: Any]]
        var tabs = trails[0]["tabs"] as! [[String: Any]]
        tabs[0].removeValue(forKey: "sourceApp")
        trails[0]["tabs"] = tabs
        json["trails"] = trails
        let decoded = try JSONDecoder().decode(TabMap.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.trails[0].tabs[0].sourceApp)
    }

    func testAppSurvivesSaveAndLoad() throws {
        var map = TabMap()
        let opened = map.openFromApp(url: URL(string: "https://a.com")!, app: claude, now: t0)
        let decoded = try JSONDecoder().decode(TabMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded.tab(opened.id)?.sourceApp, claude)
    }
}
