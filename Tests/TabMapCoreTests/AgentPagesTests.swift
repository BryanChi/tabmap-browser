import XCTest
@testable import TabMapCore

final class AgentPagesTests: XCTestCase {
    func testPlacement() {
        XCTAssertEqual(AgentPlacement.decide(tabIsOnScreen: true, overviewShown: false, dockAppInFront: false), .front)
        XCTAssertEqual(AgentPlacement.decide(tabIsOnScreen: false, overviewShown: false, dockAppInFront: false), .background)
        // The map overview or a dock app covers the page: Claude works on it out of sight instead.
        XCTAssertEqual(AgentPlacement.decide(tabIsOnScreen: true, overviewShown: true, dockAppInFront: false), .background)
        XCTAssertEqual(AgentPlacement.decide(tabIsOnScreen: true, overviewShown: false, dockAppInFront: true), .background)
    }

    func testQueueKeys() {
        XCTAssertEqual(AgentPlacement.queueKey(for: "a", placement: .front), AgentPlacement.queueKey(for: "b", placement: .front))
        XCTAssertNotEqual(AgentPlacement.queueKey(for: "a", placement: .background),
                          AgentPlacement.queueKey(for: "b", placement: .background))
    }

    func testMarkOpened() {
        var map = TabMap()
        let id = map.openRoot(url: URL(string: "https://example.com"), now: Date(), activate: false)
        let app = SourceApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude agent")
        XCTAssertTrue(map.markOpened(id, by: app))
        XCTAssertEqual(map.tab(id)?.sourceApp, app)
        XCTAssertFalse(map.markOpened(TabID(), by: app))
    }

    private func sample() -> AXNode {
        AXNode(role: "AXWebArea", title: "Shop", children: [
            AXNode(role: "AXGroup", subrole: "AXLandmarkNavigation", label: "Main menu", children: [
                AXNode(role: "AXLink", title: "Home", url: "https://shop.test/", children: [AXNode(role: "AXStaticText", value: "Home")]),
            ]),
            AXNode(role: "AXHeading", title: "Sign in", level: 1, children: [AXNode(role: "AXStaticText", value: "Sign in")]),
            AXNode(role: "AXGroup", children: [
                AXNode(role: "AXStaticText", value: "Welcome"),
                AXNode(role: "AXStaticText", value: "back."),
            ]),
            AXNode(role: "AXTextField", title: "Email", value: "me@example.com"),
            AXNode(role: "AXTextField", subrole: "AXSecureTextField", title: "Password", value: "••••••"),
            AXNode(role: "AXCheckBox", title: "Remember me", checked: true),
            AXNode(role: "AXButton", title: "Continue", enabled: false, frame: (x: 10, y: 2000, w: 100, h: 30)),
        ])
    }

    func testOutlineReadsLikeAPage() {
        var next = 0
        let (text, truncated) = AXOutline.render(sample(), maxChars: 10_000, interactiveOnly: false,
                                                 viewport: (w: 1200, h: 800)) { _ in next += 1; return next }
        XCTAssertFalse(truncated)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines, [
            "— navigation \"Main menu\"",
            "  [a1] link \"Home\" → https://shop.test/",
            "# Sign in",
            "Welcome back.",
            "[a2] textbox \"Email\" value=\"me@example.com\"",
            "[a3] password \"Password\" (filled in; hidden from Claude)",
            "[a4] checkbox \"Remember me\" checked",
            "[a5] button \"Continue\" disabled (off-screen)",
        ])
    }

    func testOutlineNeverShowsPasswords() {
        let (text, _) = AXOutline.render(sample(), maxChars: 10_000, interactiveOnly: true, viewport: nil) { _ in 1 }
        XCTAssertFalse(text.contains("••••••"))
        XCTAssertFalse(text.contains("Welcome"))
        XCTAssertTrue(text.contains("button \"Continue\""))
    }

    func testOutlineStopsAtTheLimit() {
        let (text, truncated) = AXOutline.render(sample(), maxChars: 60, interactiveOnly: false, viewport: nil) { _ in 1 }
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(text.count, 60)
    }

    func testRoleNames() {
        XCTAssertEqual(AXOutline.roleName("AXTextField", subrole: "AXSecureTextField"), "password")
        XCTAssertEqual(AXOutline.roleName("AXRadioButton", subrole: "AXTabButton"), "tab")
        XCTAssertEqual(AXOutline.roleName("AXPopUpButton", subrole: ""), "select")
        XCTAssertNil(AXOutline.roleName("AXGroup", subrole: ""))
    }
}
