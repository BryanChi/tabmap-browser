import XCTest
@testable import TabMapCore

final class TabBarLayoutTests: XCTestCase {
    let m = TabBarLayout.Metrics(activeMinimum: 200, inactiveMinimum: 36, titleMinimum: 76)

    func testNoTabs() {
        let layout = TabBarLayout.make(count: 0, active: nil, available: 800, metrics: m)
        XCTAssertEqual(layout.widths, [])
        XCTAssertFalse(layout.scrolls)
    }

    func testOneTabFillsTheBar() {
        let layout = TabBarLayout.make(count: 1, active: 0, available: 800, metrics: m)
        XCTAssertEqual(layout.widths, [800])
    }

    func testFewTabsShareEqually() {
        let layout = TabBarLayout.make(count: 4, active: 2, available: 800, metrics: m)
        XCTAssertEqual(layout.widths, [200, 200, 200, 200])
        XCTAssertFalse(layout.scrolls)
    }

    func testCrowdedTabsKeepTheCurrentOneReadable() {
        let layout = TabBarLayout.make(count: 9, active: 3, available: 800, metrics: m)
        XCTAssertEqual(layout.widths[3], 200)
        XCTAssertEqual(layout.widths[0], 75, accuracy: 0.001)
        XCTAssertEqual(layout.totalWidth, 800, accuracy: 0.001)
        XCTAssertFalse(layout.scrolls)
    }

    func testManyTabsScroll() {
        let layout = TabBarLayout.make(count: 40, active: 0, available: 800, metrics: m)
        XCTAssertEqual(layout.widths[0], 200)
        XCTAssertEqual(layout.widths[1], 36)
        XCTAssertTrue(layout.scrolls)
        XCTAssertEqual(layout.totalWidth, 200 + 39 * 36, accuracy: 0.001)
    }

    func testNoCurrentTabShrinksEvenly() {
        let layout = TabBarLayout.make(count: 10, active: nil, available: 800, metrics: m)
        XCTAssertEqual(layout.widths, Array(repeating: 80, count: 10))
        let many = TabBarLayout.make(count: 30, active: nil, available: 800, metrics: m)
        XCTAssertTrue(many.scrolls)
        XCTAssertEqual(many.widths.first, 36)
    }

    func testNarrowWindowNeverGoesNegative() {
        let layout = TabBarLayout.make(count: 3, active: 1, available: 120, metrics: m)
        XCTAssertEqual(layout.widths[1], 120)
        XCTAssertEqual(layout.widths[0], 36)
        XCTAssertTrue(layout.scrolls)
    }
}
