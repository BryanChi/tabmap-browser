import AppKit
import ApplicationServices
import WebKit
import TabMapCore

/// Reads a page the way VoiceOver does: WebKit's own accessibility tree, with its computed roles and
/// names, including text inside frames from other sites that page scripts can't reach.
///
/// macOS only hands that tree to apps the person has allowed under Privacy & Security > Accessibility.
/// Without that, `read_page` reads the page's DOM instead (AgentTools.readScript).
/// WebKit builds the tree the first time something asks for it, which takes a second or two.
@MainActor
final class AgentAccessibility {
    static let shared = AgentAccessibility()

    var isAvailable: Bool { AXIsProcessTrusted() }

    /// Elements from the last read of each tab, by number ("a12" is 12).
    private var elements: [TabID: [Int: AXUIElement]] = [:]
    private var next: [TabID: Int] = [:]
    private var warmed = Set<ObjectIdentifier>()

    /// Asks for the permission, showing macOS's own prompt. Nothing changes until the person allows it.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The page's tree as text, or nil when it can't be had (no permission, or WebKit didn't build it).
    func read(_ page: WebTab, maxChars: Int, interactiveOnly: Bool) async -> String? {
        guard isAvailable else { return nil }
        let view = page.webView
        guard let area = await webArea(of: view) else { return nil }
        let viewportOrigin = screenTopLeft(of: view)
        let viewport = (w: Double(view.bounds.width), h: Double(view.bounds.height))
        var budget = 6000
        let root = node(area, origin: viewportOrigin, budget: &budget)
        var refs: [Int: AXUIElement] = [:]
        var number = next[page.id] ?? 1
        // Numbers keep growing across reads of the same tab, so an old number never means a new element.
        let (text, truncated) = AXOutline.render(root.node, maxChars: maxChars, interactiveOnly: interactiveOnly,
                                                 viewport: viewport) { node in
            let n = number
            number += 1
            if let element = root.lookup[node.tag] { refs[n] = element }
            return n
        }
        next[page.id] = number
        elements[page.id] = refs
        return text + (truncated ? "\n… (cut at \(maxChars) characters: scroll, use interactive_only, or raise max_chars)" : "")
    }

    /// Where element "a<n>" is now, in the web view's own coordinates (top-left origin), and what it is.
    func locate(_ ref: Int, in page: WebTab) -> (point: NSPoint, size: NSSize, role: String, subrole: String)? {
        guard let element = elements[page.id]?[ref],
              let position: CGPoint = value(element, kAXPositionAttribute),
              let size: CGSize = value(element, kAXSizeAttribute) else { return nil }
        let origin = screenTopLeft(of: page.webView)
        let center = NSPoint(x: position.x + size.width / 2 - origin.x, y: position.y + size.height / 2 - origin.y)
        return (center, size, string(element, kAXRoleAttribute), string(element, kAXSubroleAttribute))
    }

    /// Asks WebKit to scroll the element into view (used only when the mouse wheel didn't get it there).
    func scrollToVisible(_ ref: Int, in page: WebTab) {
        guard let element = elements[page.id]?[ref] else { return }
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
    }

    func forget(_ id: TabID) {
        elements[id] = nil
    }

    // MARK: Finding the page

    /// The web view's top-left corner in the accessibility API's screen coordinates (top-left origin).
    private func screenTopLeft(of view: WKWebView) -> CGPoint {
        guard let window = view.window else { return .zero }
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: onScreen.minX, y: primaryHeight - onScreen.maxY)
    }

    private func webArea(of view: WKWebView) async -> AXUIElement? {
        let id = ObjectIdentifier(view)
        for attempt in 0..<15 {
            if let found = findWebArea(of: view) { warmed.insert(id); return found }
            // Asking for the view's children is what makes WebKit build the tree.
            _ = view.accessibilityChildren()
            if attempt == 0 && warmed.contains(id) { warmed.remove(id) }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private func findWebArea(of view: WKWebView) -> AXUIElement? {
        guard let window = view.window else { return nil }
        let app = AXUIElementCreateApplication(getpid())
        let target = screenTopLeft(of: view)
        let windows: [AXUIElement] = value(app, kAXWindowsAttribute) ?? []
        let windowNumber = window.windowNumber
        for axWindow in windows {
            var number: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &number) == .success, Int(number) != windowNumber { continue }
            if let area = search(axWindow, near: target, depth: 0) { return area }
        }
        return nil
    }

    /// The outermost web area whose corner is where the web view's is (split view has two).
    private func search(_ element: AXUIElement, near target: CGPoint, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        if string(element, kAXRoleAttribute) == "AXWebArea" {
            if let position: CGPoint = value(element, kAXPositionAttribute),
               abs(position.x - target.x) < 3, abs(position.y - target.y) < 3 {
                return element
            }
            return nil
        }
        for child in (value(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let found = search(child, near: target, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: Building the tree

    private func node(_ element: AXUIElement, origin: CGPoint, budget: inout Int) -> (node: AXNode, lookup: [Int: AXUIElement]) {
        var lookup: [Int: AXUIElement] = [:]
        var counter = 0
        func build(_ element: AXUIElement, depth: Int) -> AXNode? {
            guard budget > 0, depth < 60 else { return nil }
            budget -= 1
            let role = string(element, kAXRoleAttribute)
            let subrole = string(element, kAXSubroleAttribute)
            var node = AXNode(role: role, subrole: subrole)
            node.title = string(element, kAXTitleAttribute)
            node.label = string(element, kAXDescriptionAttribute)
            if subrole != "AXSecureTextField" {
                if let text: String = value(element, kAXValueAttribute) { node.value = text }
                else if let number: NSNumber = value(element, kAXValueAttribute) {
                    if role == "AXCheckBox" || role == "AXRadioButton" { node.checked = number.intValue != 0 }
                    else if role == "AXHeading" { node.level = number.intValue }
                    else { node.value = number.stringValue }
                }
            } else if let text: String = value(element, kAXValueAttribute), !text.isEmpty {
                // Only whether it is filled in; the characters themselves never leave here.
                node.value = "•"
            }
            node.placeholder = string(element, kAXPlaceholderValueAttribute)
            if let enabled: Bool = value(element, kAXEnabledAttribute) { node.enabled = enabled }
            if let focused: Bool = value(element, kAXFocusedAttribute) { node.focused = focused }
            if let expanded: Bool = value(element, kAXExpandedAttribute) { node.expanded = expanded }
            if role == "AXLink", let url: URL = value(element, kAXURLAttribute) { node.url = url.absoluteString }
            if let position: CGPoint = value(element, kAXPositionAttribute), let size: CGSize = value(element, kAXSizeAttribute) {
                node.frame = (Double(position.x - origin.x), Double(position.y - origin.y), Double(size.width), Double(size.height))
            }
            // Text runs inside a link or button are its name already; skip reading them.
            let leaf = ["AXStaticText", "AXImage", "AXTextField", "AXTextArea", "AXPopUpButton", "AXSlider"].contains(role)
                || ((role == "AXButton" || role == "AXLink") && !node.name.isEmpty)
            if !leaf {
                for child in (value(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    if let built = build(child, depth: depth + 1) { node.children.append(built) }
                }
            }
            counter += 1
            node.tag = counter
            lookup[counter] = element
            return node
        }
        let root = build(element, depth: 0) ?? AXNode(role: "AXWebArea")
        return (root, lookup)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        (value(element, attribute) as String?) ?? ""
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        if T.self == CGPoint.self || T.self == CGSize.self {
            guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let axValue = raw as! AXValue
            if T.self == CGPoint.self {
                var point = CGPoint.zero
                return AXValueGetValue(axValue, .cgPoint, &point) ? point as? T : nil
            }
            var size = CGSize.zero
            return AXValueGetValue(axValue, .cgSize, &size) ? size as? T : nil
        }
        if T.self == AXUIElement.self || T.self == [AXUIElement].self { return raw as? T }
        return raw as? T
    }
}

/// The window number behind an accessibility window element (used by every screen reader on macOS).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
