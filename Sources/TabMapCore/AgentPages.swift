import Foundation

// Plain rules behind Claude working in several Tabmap tabs at once, and behind reading a page from
// WebKit's accessibility tree. No AppKit here, so all of it is unit tested.

/// Where Claude acts on a tab: on the page the person sees, or on a page kept off screen.
public enum AgentPlacement: Equatable {
    /// The tab is on screen in Tabmap's window (the page in front, or either half of a split).
    /// Actions there share one queue, Claude's pointer shows, and the page glows.
    case front
    /// Everything else: the page is held in an off-screen window of its own, so the person can keep
    /// using Tabmap while Claude works. Each background tab has its own queue.
    case background

    public static func decide(tabIsOnScreen: Bool, overviewShown: Bool, dockAppInFront: Bool) -> AgentPlacement {
        tabIsOnScreen && !overviewShown && !dockAppInFront ? .front : .background
    }

    /// Actions with the same key run one after another; different keys run side by side.
    public static func queueKey(for tab: String, placement: AgentPlacement) -> String {
        placement == .front ? "front" : "tab:" + tab
    }
}

extension TabMap {
    /// Marks a tab as opened by another app (Claude), the way links from that app are marked.
    @discardableResult
    public mutating func markOpened(_ id: TabID, by app: SourceApp) -> Bool {
        guard let loc = locate(id) else { return false }
        trails[loc.trail].tabs[loc.tab].sourceApp = app
        return true
    }
}

/// One node of a page's accessibility tree as WebKit reports it (AXRole, AXTitle and so on).
public struct AXNode: Equatable {
    public var role: String
    public var subrole: String
    public var title: String
    public var label: String
    public var value: String
    public var placeholder: String
    public var enabled: Bool
    public var focused: Bool
    /// nil when the element has no such state.
    public var checked: Bool?
    public var expanded: Bool?
    /// Heading level, when the role is AXHeading.
    public var level: Int?
    public var url: String
    /// In the page's own coordinates (CSS pixels, from the top of the viewport). Used to tell what is off screen.
    public var frame: (x: Double, y: Double, w: Double, h: Double)?
    public var children: [AXNode]
    /// The reader's own number for the element behind this node, to find it again.
    public var tag: Int = 0

    public init(role: String, subrole: String = "", title: String = "", label: String = "", value: String = "",
                placeholder: String = "", enabled: Bool = true, focused: Bool = false, checked: Bool? = nil,
                expanded: Bool? = nil, level: Int? = nil, url: String = "",
                frame: (x: Double, y: Double, w: Double, h: Double)? = nil, children: [AXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.enabled = enabled
        self.focused = focused
        self.checked = checked
        self.expanded = expanded
        self.level = level
        self.url = url
        self.frame = frame
        self.children = children
    }

    public static func == (a: AXNode, b: AXNode) -> Bool {
        a.role == b.role && a.subrole == b.subrole && a.title == b.title && a.label == b.label && a.value == b.value
            && a.children == b.children
    }

    /// The name a screen reader would read out.
    public var name: String {
        for candidate in [title, label] where !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
        if role == "AXStaticText" { return value }
        return ""
    }
}

/// Turns an accessibility tree into the short text Claude reads: one line per thing worth knowing,
/// numbered [a12] when Claude can act on it.
public enum AXOutline {
    /// Claude's word for an accessibility role, or nil when the node only groups others.
    public static func roleName(_ role: String, subrole: String) -> String? {
        if subrole == "AXSecureTextField" { return "password" }
        switch subrole {
        case "AXTabButton": return "tab"
        case "AXSwitch": return "switch"
        case "AXSearchField": return "searchbox"
        case "AXApplicationDialog", "AXApplicationAlertDialog": return "dialog"
        case "AXApplicationAlert": return "alert"
        case "AXLandmarkNavigation": return "navigation"
        case "AXLandmarkMain": return "main"
        case "AXLandmarkBanner": return "banner"
        case "AXLandmarkContentInfo": return "footer"
        case "AXLandmarkSearch": return "search"
        case "AXLandmarkComplementary": return "aside"
        default: break
        }
        switch role {
        case "AXButton", "AXMenuButton", "AXDisclosureTriangle": return "button"
        case "AXLink": return "link"
        case "AXTextField", "AXTextArea": return "textbox"
        case "AXComboBox": return "combobox"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXPopUpButton": return "select"
        case "AXSlider", "AXIncrementor": return "slider"
        case "AXMenuItem": return "menuitem"
        case "AXTab": return "tab"
        case "AXHeading": return "heading"
        case "AXStaticText": return "text"
        case "AXImage": return "image"
        case "AXList": return "list"
        case "AXTable", "AXGrid": return "table"
        case "AXRow": return "row"
        case "AXCell": return "cell"
        case "AXWebArea": return "frame"
        case "AXSheet", "AXDialog": return "dialog"
        default: return nil
        }
    }

    public static func isActionable(_ name: String) -> Bool {
        ["button", "link", "textbox", "searchbox", "combobox", "checkbox", "radio", "select", "slider",
         "menuitem", "tab", "switch", "password"].contains(name)
    }

    static func clean(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// `ref` is called for each node Claude can act on and returns its number.
    /// `viewport` (width, height) marks elements outside it as off-screen.
    public static func render(_ root: AXNode, maxChars: Int, interactiveOnly: Bool,
                              viewport: (w: Double, h: Double)?, ref: (AXNode) -> Int) -> (text: String, truncated: Bool) {
        var lines: [String] = []
        var size = 0
        var truncated = false
        var pendingText: [String] = []
        var pendingDepth = 0

        func push(_ line: String) {
            guard !truncated else { return }
            if size + line.count > maxChars { truncated = true; return }
            lines.append(line)
            size += line.count + 1
        }
        func flushText() {
            guard !pendingText.isEmpty else { return }
            let joined = clean(pendingText.joined(separator: " "), 1000)
            if joined.count > 1 { push(String(repeating: "  ", count: pendingDepth) + joined) }
            pendingText = []
        }
        func offscreen(_ node: AXNode) -> Bool {
            guard let viewport, let f = node.frame else { return false }
            return f.y + f.h < 0 || f.y > viewport.h || f.x + f.w < 0 || f.x > viewport.w
        }
        func describe(_ node: AXNode, _ kind: String) -> String {
            var line = "[a\(ref(node))] \(kind)"
            let name = kind == "password" ? clean(node.title.isEmpty ? node.placeholder : node.title, 60) : clean(node.name, 100)
            if !name.isEmpty { line += " \"\(name.replacingOccurrences(of: "\"", with: "'"))\"" }
            switch kind {
            case "password":
                line += node.value.isEmpty ? " (empty; the user fills in passwords)" : " (filled in; hidden from Claude)"
            case "textbox", "searchbox", "combobox":
                if !node.value.isEmpty { line += " value=\"\(clean(node.value, 200).replacingOccurrences(of: "\"", with: "'"))\"" }
                else if !node.placeholder.isEmpty && node.placeholder != name { line += " placeholder=\"\(clean(node.placeholder, 60))\"" }
            case "select":
                if !node.value.isEmpty { line += " selected=\"\(clean(node.value, 60))\"" }
            case "slider":
                if !node.value.isEmpty { line += " value=\(clean(node.value, 20))" }
            case "link":
                if !node.url.isEmpty, !node.url.hasPrefix("javascript:") { line += " → \(clean(node.url, 120))" }
            default: break
            }
            if let checked = node.checked { line += checked ? " checked" : " unchecked" }
            if let expanded = node.expanded { line += expanded ? " expanded" : " collapsed" }
            if !node.enabled { line += " disabled" }
            if node.focused { line += " focused" }
            if offscreen(node) { line += " (off-screen)" }
            return line
        }
        func walk(_ node: AXNode, depth: Int) {
            guard !truncated else { return }
            let kind = roleName(node.role, subrole: node.subrole)
            let indent = String(repeating: "  ", count: min(depth, 8))
            if let kind, isActionable(kind) {
                flushText()
                push(indent + describe(node, kind))
                // A link's or button's own text is already its name.
                if kind != "textbox" && kind != "combobox" { return }
            }
            switch kind {
            case "text":
                if !interactiveOnly {
                    if pendingText.isEmpty { pendingDepth = min(depth, 8) }
                    pendingText.append(node.name)
                }
                return
            case "heading":
                flushText()
                if !interactiveOnly {
                    let text = node.name.isEmpty ? flatText(node) : node.name
                    push(indent + String(repeating: "#", count: max(1, min(6, node.level ?? 2))) + " " + clean(text, 200))
                }
                // A heading that holds a link still lists the link.
                for child in node.children where containsActionable(child) { walk(child, depth: depth + 1) }
                return
            case "image":
                flushText()
                if !interactiveOnly, !node.name.isEmpty { push(indent + "image: " + clean(node.name, 120)) }
                return
            case "dialog", "alert", "navigation", "main", "banner", "footer", "search", "aside", "list", "table", "frame":
                flushText()
                if kind != "frame" || depth > 0 {
                    let name = clean(node.name, 80)
                    if !interactiveOnly || kind == "dialog" || kind == "alert" {
                        push(indent + "— \(kind!)" + (name.isEmpty ? "" : " \"\(name)\""))
                    }
                }
            case "row":
                flushText()
            default:
                break
            }
            let childDepth = (kind == nil || (kind == "frame" && depth == 0)) ? depth : depth + 1
            for child in node.children { walk(child, depth: childDepth) }
            if kind == "row" || kind == "cell" || kind == "list" { flushText() }
        }
        func flatText(_ node: AXNode) -> String {
            if node.role == "AXStaticText" { return node.name }
            return node.children.map(flatText).joined(separator: " ")
        }
        func containsActionable(_ node: AXNode) -> Bool {
            if let kind = roleName(node.role, subrole: node.subrole), isActionable(kind) { return true }
            return node.children.contains(where: containsActionable)
        }
        walk(root, depth: 0)
        flushText()
        return (lines.joined(separator: "\n"), truncated)
    }
}
