import XCTest
@testable import TabMapCore

// Goes in Tests/TabMapCoreTests.
final class AppShelfTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func u(_ s: String) -> URL { URL(string: s)! }

    func testShortcutsFollowDockOrder() {
        var shelf = AppShelf()
        let mail = shelf.add(home: u("https://mail.google.com/"), now: t0)
        let chat = shelf.add(home: u("https://app.slack.com/"), now: t0)
        XCTAssertEqual(shelf.app(atShortcut: 1)?.id, mail.id)
        XCTAssertEqual(shelf.app(atShortcut: 2)?.id, chat.id)
        XCTAssertNil(shelf.app(atShortcut: 3))
        XCTAssertNil(shelf.app(atShortcut: 0))
        shelf.move(chat.id, by: -1)
        XCTAssertEqual(shelf.app(atShortcut: 1)?.id, chat.id)
        shelf.move(chat.id, by: -5)
        XCTAssertEqual(shelf.apps.map(\.id), [chat.id, mail.id])
    }

    func testUpdateKeepsHomeAndIgnoresNonWebAddresses() {
        var shelf = AppShelf()
        let mail = shelf.add(home: u("https://mail.google.com/"), now: t0)
        XCTAssertTrue(shelf.update(mail.id, url: u("https://mail.google.com/mail/u/0/#inbox"), title: "Inbox (3)"))
        XCTAssertFalse(shelf.update(mail.id, url: u("about:blank"), title: ""))
        XCTAssertEqual(shelf.app(mail.id)?.home, u("https://mail.google.com/"))
        XCTAssertEqual(shelf.app(mail.id)?.url, u("https://mail.google.com/mail/u/0/#inbox"))
        XCTAssertEqual(shelf.remove(mail.id)?.id, mail.id)
        XCTAssertTrue(shelf.apps.isEmpty)
    }

    func testUnreadBadgeFromTitles() {
        XCTAssertEqual(UnreadBadge.parse("Inbox (3) - me@example.com - Gmail"), "3")
        XCTAssertEqual(UnreadBadge.parse("(12) Home / X"), "12")
        XCTAssertEqual(UnreadBadge.parse("[4] Chat"), "4")
        XCTAssertEqual(UnreadBadge.parse("Inbox (1,234) - Gmail"), "99+")
        XCTAssertEqual(UnreadBadge.parse("(20+) Facebook"), "20+")
        XCTAssertEqual(UnreadBadge.parse("* Slack"), "•")
        XCTAssertEqual(UnreadBadge.parse("• Discord | #general"), "•")
        XCTAssertNil(UnreadBadge.parse("Inbox - me@example.com - Gmail"))
        XCTAssertNil(UnreadBadge.parse("Inbox (0)"))
        XCTAssertNil(UnreadBadge.parse("*bold* ideas"))
    }

    func testStrippingBadgeLeavesTheName() {
        XCTAssertEqual(UnreadBadge.stripping("(12) Home / X"), "Home / X")
        XCTAssertEqual(UnreadBadge.stripping("Inbox (3) - Gmail"), "Inbox - Gmail")
        XCTAssertEqual(UnreadBadge.stripping("* Slack"), "Slack")
    }

    func testLinksThatLeaveTheApp() {
        let gmail = u("https://mail.google.com/mail/u/0/")
        XCTAssertFalse(SiteMatch.leavesApp(home: gmail, link: u("https://mail.google.com/mail/u/0/#sent")))
        XCTAssertFalse(SiteMatch.leavesApp(home: gmail, link: u("https://accounts.google.com/signin")))
        XCTAssertTrue(SiteMatch.leavesApp(home: gmail, link: u("https://github.com/notifications")))
        XCTAssertFalse(SiteMatch.leavesApp(home: gmail, link: u("mailto:someone@example.com")))
        XCTAssertEqual(SiteMatch.site("192.168.0.1"), "192.168.0.1")
        XCTAssertEqual(SiteMatch.site("localhost"), "localhost")
    }
}
