import AppKit
import WebKit
import TabMapCore

/// What Claude can do in Tabmap, as MCP tools. Pages are read with a script in its own content world
/// (pages can't see it or tamper with it). Clicks, typing and scrolling are real mouse, keyboard and
/// wheel events handed to the web view, moved and paced the way a person's hand would.
/// One action runs at a time; the person's Stop takes effect between any two steps.
@MainActor
final class AgentTools {
    static let shared = AgentTools()

    struct Outcome {
        var content: [[String: Any]]
        var isError: Bool
    }

    enum Failure: Error {
        case message(String)
    }

    private var tail: Task<Void, Never>?
    private let world = WKContentWorld.world(name: "tabmap-agent")
    /// CSS pixels per pixel of the last screenshot, for clicks by position.
    private var shotFactor: Double = 1
    private var eventNumber = 1

    // MARK: Entry

    func call(_ name: String, _ arguments: [String: Any]) async -> Outcome {
        let previous = tail
        let task = Task { @MainActor () -> Outcome in
            await previous?.value
            return await self.run(name, arguments)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func run(_ name: String, _ args: [String: Any]) async -> Outcome {
        guard AgentControl.shared.enabled else {
            return fail("Claude control is turned off in Tabmap's Settings.")
        }
        do {
            // Once the person has stopped Claude, nothing moves, not even the map.
            if name != "wait_for_user" && name != "list_tabs" { try AgentControl.shared.checkAllowed() }
            switch name {
            case "list_tabs": return text(listTabs())
            case "switch_tab": return text(try await switchTab(args))
            case "open_url": return text(try await openURL(args))
            case "go": return text(try await go(args))
            case "read_page": return text(try await readPage(args))
            case "screenshot": return try await screenshot()
            case "click": return text(try await click(args, hoverOnly: false))
            case "hover": return text(try await click(args, hoverOnly: true))
            case "type_text": return text(try await typeText(args))
            case "press_key": return text(try await pressKey(args))
            case "scroll": return text(try await scroll(args))
            case "select_option": return text(try await selectOption(args))
            case "wait_for": return text(try await waitFor(args))
            case "wait_for_user": return text(try await waitForUser(args))
            default: return fail("Unknown tool: \(name)")
            }
        } catch AgentControl.Refusal.stopped {
            return fail("The user stopped you and took back control of the browser. Don't do anything more in Tabmap until they ask you to.")
        } catch AgentControl.Refusal.needsYou(let reason) {
            return fail("Paused: \(reason). The user has been sent a notification and will handle it themselves. Do not try to get past it. Call wait_for_user to wait for them, then carry on.")
        } catch Failure.message(let message) {
            return fail(message)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func text(_ string: String) -> Outcome {
        Outcome(content: [["type": "text", "text": string]], isError: false)
    }

    private func fail(_ string: String) -> Outcome {
        Outcome(content: [["type": "text", "text": string]], isError: true)
    }

    // MARK: Tabs

    private func shortID(_ id: TabID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    private func rowName(_ trail: Trail) -> String {
        if let name = trail.name, !name.isEmpty { return name }
        return trail.openTabs.first?.displayTitle ?? "Untitled row"
    }

    private func isClaudeRow(_ trail: Trail) -> Bool {
        trail.tabs.contains { $0.sourceApp == AgentControl.laneApp }
    }

    private func listTabs() -> String {
        let map = BrowserStore.shared.map
        var lines: [String] = []
        for trail in map.trails.filter(\.hasOpenTabs).sorted(by: { $0.recency > $1.recency }) {
            lines.append("Row: \(rowName(trail))\(isClaudeRow(trail) ? " (your row)" : "")")
            for tab in trail.openTabs {
                let mark = tab.id == map.activeTabID ? "* " : "  "
                lines.append("\(mark)\(shortID(tab.id))  \(tab.displayTitle) — \(tab.url?.absoluteString ?? "blank tab")")
            }
        }
        if lines.isEmpty { return "No tabs are open." }
        lines.append("")
        lines.append("* is the tab in front. Use switch_tab with the 8-character id to go to one.")
        return lines.joined(separator: "\n")
    }

    private func switchTab(_ args: [String: Any]) async throws -> String {
        guard let given = (args["tab"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !given.isEmpty else {
            throw Failure.message("Give the tab's id from list_tabs.")
        }
        let store = BrowserStore.shared
        guard let tab = store.map.allTabs.first(where: { !$0.isClosed && $0.id.uuidString.lowercased().hasPrefix(given) }) else {
            throw Failure.message("No open tab has the id \(given). Use list_tabs.")
        }
        try AgentControl.shared.begin("Switching to \(tab.displayTitle)")
        store.choose(tab.id)
        let (page, view) = try await frontPage()
        await waitForLoad(view, timeout: 15)
        try await afterAction(page, view)
        return "Now in front: \(pageLine(view))"
    }

    // MARK: Pages

    /// The page in front of the map, made visible (dock app sent back, map overview closed).
    private func frontPage() async throws -> (WebTab, WKWebView) {
        let store = BrowserStore.shared
        if AppDock.shared.isFront { AppDock.shared.sendToBack() }
        if store.overviewShown {
            GestureNavigator.shared.closeOverview(showing: store.map.activeTabID)
            try await sleep(ms: 450)
        }
        guard let page = store.activeWebTab else {
            throw Failure.message("No page is open in front. Use open_url or switch_tab first.")
        }
        var waited = 0
        while page.webView.window == nil && waited < 20 {
            try await sleep(ms: 50)
            waited += 1
        }
        guard page.webView.window != nil else {
            throw Failure.message("The page isn't on screen. Try again in a moment.")
        }
        if page.webView.magnification != 1 { page.webView.magnification = 1 }
        AgentControl.shared.notePage(page.webView)
        return (page, page.webView)
    }

    private func pageLine(_ view: WKWebView) -> String {
        let title = (view.title?.isEmpty == false) ? view.title! : "Untitled"
        return "\(title) — \(view.url?.absoluteString ?? "")"
    }

    private func openURL(_ args: [String: Any]) async throws -> String {
        guard let raw = args["url"] as? String, !raw.isEmpty else { throw Failure.message("Give a url.") }
        let store = BrowserStore.shared
        guard let url = AddressInterpreter.url(from: raw, searchTemplate: store.map.settings.searchTemplate) else {
            throw Failure.message("\(raw) isn't an address Tabmap can open.")
        }
        try AgentControl.shared.begin("Opening \(url.host ?? raw)")
        let newTab = args["new_tab"] as? Bool ?? true
        if newTab {
            let rows = store.map.trails.filter { $0.hasOpenTabs && isClaudeRow($0) }.sorted { $0.recency > $1.recency }
            if let last = rows.first?.openTabs.last {
                store.openChild(of: last.id, url: url, activate: true)
            } else {
                store.openFromApp(url, app: AgentControl.laneApp)
            }
        } else {
            if AppDock.shared.isFront { AppDock.shared.sendToBack() }
            store.open(url)
        }
        let (page, view) = try await frontPage()
        await waitForLoad(view, timeout: 20)
        try await afterAction(page, view)
        return "Opened: \(pageLine(view))"
    }

    private func go(_ args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "").lowercased()
        let (page, view) = try await frontPage()
        switch action {
        case "back":
            guard view.canGoBack else { throw Failure.message("There is no earlier page in this tab.") }
            try AgentControl.shared.begin("Going back")
            view.goBack()
        case "forward":
            guard view.canGoForward else { throw Failure.message("There is no later page in this tab.") }
            try AgentControl.shared.begin("Going forward")
            view.goForward()
        case "reload":
            try AgentControl.shared.begin("Reloading")
            view.reload()
        default:
            throw Failure.message("action must be back, forward or reload.")
        }
        await waitForLoad(view, timeout: 20)
        try await afterAction(page, view)
        return "Now showing: \(pageLine(view))"
    }

    private func waitForLoad(_ view: WKWebView, timeout: Double) async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let start = Date()
        while view.isLoading && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: Reading

    private func readPage(_ args: [String: Any]) async throws -> String {
        let (page, view) = try await frontPage()
        try AgentControl.shared.begin("Reading the page")
        let maxChars = min(max(int(args["max_chars"]) ?? 20000, 1000), 100_000)
        let interactiveOnly = args["interactive_only"] as? Bool ?? false
        let result = try await js(Self.readScript, ["maxChars": maxChars, "interactiveOnly": interactiveOnly], in: view)
        try await afterAction(page, view)
        guard let dict = result as? [String: Any], let text = dict["text"] as? String else {
            throw Failure.message("The page couldn't be read.")
        }
        return text + "\n\nUse the [numbers] with click, type_text, hover, scroll or select_option."
    }

    private func screenshot() async throws -> Outcome {
        let (page, view) = try await frontPage()
        try AgentControl.shared.begin("Looking at the page")
        try await afterAction(page, view)
        let viewport = try await viewportSize(view)
        let width = min(viewport.width, 1600)
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: width)
        let image = try await view.takeSnapshot(configuration: configuration)
        guard image.size.width > 0 else { throw Failure.message("The screenshot came back empty.") }
        let pixelsWide = Int(width.rounded())
        let pixelsHigh = Int((Double(image.size.height) / Double(image.size.width) * width).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure.message("The screenshot couldn't be made.")
        }
        rep.size = NSSize(width: pixelsWide, height: pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            throw Failure.message("The screenshot couldn't be encoded.")
        }
        shotFactor = viewport.width / width
        return Outcome(content: [
            ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"],
            ["type": "text", "text": "Screenshot of \(pageLine(view)), \(pixelsWide)×\(pixelsHigh). To click or hover a spot, pass x and y in this image's pixels (read_page refs are more reliable)."],
        ], isError: false)
    }

    // MARK: Pointer

    private struct Target {
        var x: Double
        var y: Double
        var viewportWidth: Double
        var viewportHeight: Double
        var description: String
        var role: String
        var type: String
        var covered: String?
    }

    /// Where an element (by ref) or a screenshot position is, scrolled into view with the wheel if needed.
    private func findTarget(_ args: [String: Any], in view: WKWebView) async throws -> Target {
        if let ref = int(args["ref"]) {
            var info = try await locate(ref, in: view)
            if !(info["inView"] as? Bool ?? false) {
                // Scroll to it the way a person would: with the wheel, a screen at a time.
                for _ in 0..<8 {
                    let top = double(info["top"]) ?? 0, h = double(info["h"]) ?? 0
                    let vh = double(info["vh"]) ?? 800, vw = double(info["vw"]) ?? 1200
                    let dy = (top + h / 2) - vh / 2
                    let scale = view.bounds.width / max(1, vw)
                    let center = windowPoint(cssX: vw / 2, cssY: vh / 2, viewportWidth: vw, viewportHeight: vh, in: view)
                    try await movePointer(to: center, in: view)
                    try await wheel(dx: 0, dy: max(-vh * 1.5, min(vh * 1.5, dy)) * scale, at: center, in: view)
                    try await sleep(ms: 220)
                    info = try await locate(ref, in: view)
                    if info["inView"] as? Bool == true { break }
                }
                if info["inView"] as? Bool != true {
                    _ = try await js("const el = elOf(args.ref); if (el) el.scrollIntoView({block: 'center', inline: 'center'});",
                                     ["ref": ref], in: view)
                    try await sleep(ms: 150)
                    info = try await locate(ref, in: view)
                }
            }
            let role = info["role"] as? String ?? ""
            let name = info["name"] as? String ?? ""
            return Target(x: double(info["x"]) ?? 0, y: double(info["y"]) ?? 0,
                          viewportWidth: double(info["vw"]) ?? 1, viewportHeight: double(info["vh"]) ?? 1,
                          description: "[\(ref)] \(role)\(name.isEmpty ? "" : " \"\(name)\"")",
                          role: role, type: info["type"] as? String ?? "", covered: info["covered"] as? String)
        }
        if let x = double(args["x"]), let y = double(args["y"]) {
            let viewport = try await viewportSize(view)
            return Target(x: x * shotFactor, y: y * shotFactor, viewportWidth: viewport.width, viewportHeight: viewport.height,
                          description: "the spot at \(Int(x)), \(Int(y))", role: "", type: "", covered: nil)
        }
        throw Failure.message("Give a ref from read_page, or x and y from a screenshot.")
    }

    /// Pointer-arrival events at a viewport point, for when the window is in the background.
    private static let hoverScript = """
        let el = document.elementFromPoint(args.x, args.y);
        while (el && el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(args.x, args.y);
            if (!inner || inner === el) break;
            el = inner;
        }
        if (!el) return false;
        const at = {clientX: args.x, clientY: args.y, view: window, composed: true};
        const fire = (target, type, bubbles, Kind) =>
            target.dispatchEvent(new Kind(type, Object.assign({bubbles, cancelable: bubbles}, at)));
        fire(el, 'pointerover', true, PointerEvent);
        fire(el, 'mouseover', true, MouseEvent);
        for (let n = el; n && n.nodeType === 1; n = n.parentElement || (n.getRootNode() && n.getRootNode().host)) {
            fire(n, 'pointerenter', false, PointerEvent);
            fire(n, 'mouseenter', false, MouseEvent);
        }
        fire(el, 'pointermove', true, PointerEvent);
        fire(el, 'mousemove', true, MouseEvent);
        return true;
        """

    private func locate(_ ref: Int, in view: WKWebView) async throws -> [String: Any] {
        let result = try await js(Self.locateScript, ["ref": ref], in: view)
        guard let info = result as? [String: Any], info["missing"] == nil else {
            throw Failure.message("Element [\(ref)] is gone from the page. Call read_page again for fresh numbers.")
        }
        return info
    }

    private func click(_ args: [String: Any], hoverOnly: Bool) async throws -> String {
        let (page, view) = try await frontPage()
        try AgentControl.shared.begin(hoverOnly ? "Pointing" : "Clicking")
        let target = try await findTarget(args, in: view)
        if !hoverOnly {
            if target.role == "select" {
                throw Failure.message("\(target.description) is a drop-down menu. Use select_option instead of clicking it.")
            }
            if target.type == "file" {
                throw Failure.message("\(target.description) picks a file from the Mac. Claude can't choose files; ask the user to do it.")
            }
        }
        AgentControl.shared.noteStatus((hoverOnly ? "Pointing at " : "Clicking ") + target.description)
        let point = windowPoint(cssX: target.x, cssY: target.y, viewportWidth: target.viewportWidth,
                                viewportHeight: target.viewportHeight, in: view)
        let beforeURL = view.url
        let beforeTab = BrowserStore.shared.map.activeTabID
        try await movePointer(to: point, in: view)
        if hoverOnly {
            var note = ""
            if !(NSApp.isActive && view.window?.isKeyWindow == true) {
                // WebKit only hit-tests mouse moves while the window is active; in a background window
                // they just update scrollbars. Tell the page the pointer arrived with DOM events instead.
                _ = try await js(Self.hoverScript, ["x": target.x, "y": target.y], in: view)
                note = " Tabmap is in the background, so the page got hover events but CSS hover styles may not show."
            }
            try await sleep(ms: 350)
            return "Pointer is over \(target.description).\(note)"
        }
        try await press(at: point, in: view, double: args["double"] as? Bool ?? false)
        try await sleep(ms: 400)
        var notes: [String] = []
        if let covered = target.covered {
            notes.append("Something else (\(covered)) was on top of it, so the click may have landed there.")
        }
        if BrowserStore.shared.map.activeTabID != beforeTab {
            let (newPage, newView) = try await frontPage()
            await waitForLoad(newView, timeout: 15)
            try await afterAction(newPage, newView)
            notes.append("It opened a new tab, now in front: \(pageLine(newView))")
        } else {
            if view.isLoading { await waitForLoad(view, timeout: 15) }
            try await afterAction(page, view)
            if view.url != beforeURL { notes.append("The page is now: \(pageLine(view))") }
        }
        return (["Clicked \(target.description)."] + notes).joined(separator: " ")
    }

    // MARK: Keyboard

    private func typeText(_ args: [String: Any]) async throws -> String {
        guard let text = args["text"] as? String else { throw Failure.message("Give the text to type.") }
        let (page, view) = try await frontPage()
        try AgentControl.shared.begin("Typing")
        if args["ref"] != nil {
            let target = try await findTarget(args, in: view)
            if target.type == "password" || target.role == "password" { try handOverPassword(page, view) }
            AgentControl.shared.noteStatus("Typing into \(target.description)")
            let point = windowPoint(cssX: target.x, cssY: target.y, viewportWidth: target.viewportWidth,
                                    viewportHeight: target.viewportHeight, in: view)
            try await movePointer(to: point, in: view)
            try await press(at: point, in: view, double: false)
            try await sleep(ms: 150)
        }
        if try await js("const a = deepActive(); return !!(a && a.type === 'password');", in: view) as? Bool == true {
            try handOverPassword(page, view)
        }
        if args["clear"] as? Bool == true {
            try await key(AgentKey(keyCode: 0, characters: "a", modifiers: [.command]), in: view)
            try await sleep(ms: 60)
            try await key(AgentKey(keyCode: 51, characters: "\u{8}"), in: view)
        }
        for ch in text {
            var modifiers: Set<AgentKey.Modifier> = []
            if ch.isUppercase { modifiers.insert(.shift) }
            let characters = ch == "\n" ? "\r" : String(ch)
            try await key(AgentKey(keyCode: AgentKey.keyCode(forTyped: ch), characters: characters, modifiers: modifiers), in: view)
            try await sleep(ms: text.count > 200 ? 4 : 30)
        }
        var reply = "Typed \(text.count) characters."
        let value = try await js("""
            const a = deepActive();
            if (!a || a.type === 'password') return null;
            return a.isContentEditable ? a.innerText : (typeof a.value === 'string' ? a.value : null);
            """, in: view) as? String
        if let value { reply += " The field now reads: \"\(String(value.prefix(300)))\"" }
        if args["submit"] as? Bool == true {
            let before = view.url
            try await key(AgentKey(keyCode: 36, characters: "\r"), in: view)
            try await sleep(ms: 400)
            await waitForLoad(view, timeout: 15)
            reply += " Pressed Enter."
            if view.url != before { reply += " The page is now: \(pageLine(view))" }
        }
        try await afterAction(page, view)
        return reply
    }

    private func handOverPassword(_ page: WebTab, _ view: WKWebView) throws -> Never {
        AgentControl.shared.handOver("Sign-in needs your password", tab: page.id, site: view.url?.host, clearsItself: false)
        throw AgentControl.Refusal.needsYou("this is a password field, and Claude never types passwords. The user has been asked to sign in")
    }

    private func pressKey(_ args: [String: Any]) async throws -> String {
        guard let spec = args["key"] as? String, let parsed = AgentKey.parse(spec) else {
            throw Failure.message("Unknown key. Use names like Enter, Tab, Escape, Backspace, ArrowDown, PageDown, or combos like cmd+a.")
        }
        let (page, view) = try await frontPage()
        try AgentControl.shared.begin("Pressing \(spec)")
        let before = view.url
        try await key(parsed, in: view)
        try await sleep(ms: 300)
        if view.isLoading { await waitForLoad(view, timeout: 15) }
        try await afterAction(page, view)
        return "Pressed \(spec)." + (view.url != before ? " The page is now: \(pageLine(view))" : "")
    }

    private func selectOption(_ args: [String: Any]) async throws -> String {
        guard let ref = int(args["ref"]), let option = args["option"] as? String else {
            throw Failure.message("Give the drop-down's ref and the option to pick.")
        }
        let (page, view) = try await frontPage()
        try AgentControl.shared.begin("Choosing \(option)")
        let target = try await findTarget(["ref": ref], in: view)
        let point = windowPoint(cssX: target.x, cssY: target.y, viewportWidth: target.viewportWidth,
                                viewportHeight: target.viewportHeight, in: view)
        try await movePointer(to: point, in: view)
        // A real click would open the system menu, which holds up everything until it closes.
        let result = try await js(Self.selectScript, ["ref": ref, "option": option], in: view) as? [String: Any] ?? [:]
        if let error = result["error"] as? String {
            let options = (result["options"] as? [String])?.joined(separator: " | ") ?? ""
            throw Failure.message("Couldn't choose \"\(option)\": \(error).\(options.isEmpty ? "" : " Options: \(options)")")
        }
        try await sleep(ms: 300)
        try await afterAction(page, view)
        return "Chose \"\(result["chosen"] as? String ?? option)\" in \(target.description)."
    }

    // MARK: Scrolling

    private func scroll(_ args: [String: Any]) async throws -> String {
        let (page, view) = try await frontPage()
        let direction = (args["direction"] as? String ?? "down").lowercased()
        try AgentControl.shared.begin("Scrolling \(direction)")
        let amount = min(max(double(args["amount"]) ?? 0.8, 0.1), 10)
        let viewport = try await viewportSize(view)
        let scale = view.bounds.width / max(1, viewport.width)
        var point = windowPoint(cssX: viewport.width / 2, cssY: viewport.height / 2,
                                viewportWidth: viewport.width, viewportHeight: viewport.height, in: view)
        if args["ref"] != nil {
            let target = try await findTarget(args, in: view)
            point = windowPoint(cssX: target.x, cssY: target.y, viewportWidth: target.viewportWidth,
                                viewportHeight: target.viewportHeight, in: view)
        }
        try await movePointer(to: point, in: view)
        let before = try await js("return [scrollX, scrollY];", in: view) as? [Double]
        let distance = amount * (direction == "left" || direction == "right" ? viewport.width : viewport.height) * scale
        switch direction {
        case "down": try await wheel(dx: 0, dy: distance, at: point, in: view)
        case "up": try await wheel(dx: 0, dy: -distance, at: point, in: view)
        case "right": try await wheel(dx: distance, dy: 0, at: point, in: view)
        case "left": try await wheel(dx: -distance, dy: 0, at: point, in: view)
        default: throw Failure.message("direction must be up, down, left or right.")
        }
        try await sleep(ms: 250)
        try await afterAction(page, view)
        let after = try await js("return [scrollX, scrollY, document.documentElement.scrollHeight, innerHeight];", in: view) as? [Double]
        guard let after, after.count == 4 else { return "Scrolled \(direction)." }
        let moved = before.map { $0 != Array(after.prefix(2)) } ?? true
        let position = "Page is at \(Int(after[1])) of \(Int(max(0, after[2] - after[3]))) px."
        if !moved && args["ref"] == nil {
            return "Scrolled \(direction), but the page didn't move (it may be at the end, or only a part of the page scrolls: pass that part's ref). \(position)"
        }
        return "Scrolled \(direction). \(position)"
    }

    // MARK: Waiting

    private func waitFor(_ args: [String: Any]) async throws -> String {
        let (page, view) = try await frontPage()
        let wanted = args["text"] as? String
        try AgentControl.shared.begin(wanted.map { "Waiting for “\($0)”" } ?? "Waiting for the page")
        let timeout = min(max(double(args["seconds"]) ?? 10, 0.5), 60)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try AgentControl.shared.checkAllowed()
            if !view.isLoading {
                guard let wanted else { break }
                let found = try await js("return !!(document.body && document.body.innerText.includes(args.t));",
                                         ["t": wanted], in: view) as? Bool ?? false
                if found {
                    try await afterAction(page, view)
                    return "Found “\(wanted)” on \(pageLine(view))."
                }
            }
            try await sleep(ms: 250)
        }
        try await afterAction(page, view)
        if let wanted { return "“\(wanted)” didn't appear within \(Int(timeout)) seconds. Page: \(pageLine(view))" }
        return view.isLoading ? "Still loading after \(Int(timeout)) seconds." : "Page has loaded: \(pageLine(view))"
    }

    private func waitForUser(_ args: [String: Any]) async throws -> String {
        let control = AgentControl.shared
        if control.phase == .stopped { throw AgentControl.Refusal.stopped }
        guard control.isWaitingForPerson else { return "Nothing is waiting on the user. Carry on." }
        let timeout = min(max(double(args["seconds"]) ?? 300, 5), 900)
        let start = Date()
        var clearChecks = 0
        while Date().timeIntervalSince(start) < timeout {
            if !control.isWaitingForPerson {
                if control.phase == .stopped { throw AgentControl.Refusal.stopped }
                return "The user is done. Carry on (read the page again first)."
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // A human check that has gone away by itself (solved) lets Claude carry on without Done.
            if control.handOverClearsItself, let page = BrowserStore.shared.activeWebTab {
                if try await detectHumanCheck(page.webView) == nil {
                    clearChecks += 1
                    if clearChecks >= 2 { control.personDone() }
                } else {
                    clearChecks = 0
                }
            }
        }
        return "Still waiting for the user after \(Int(timeout)) seconds. Call wait_for_user again, or ask them."
    }

    // MARK: After each action

    /// Stops and hands the page to the person when it asks whether they're human.
    private func afterAction(_ page: WebTab, _ view: WKWebView) async throws {
        if let kind = try await detectHumanCheck(view) {
            let reason = "Human check (\(kind))"
            AgentControl.shared.handOver(reason, tab: page.id, site: view.url?.host, clearsItself: true)
            throw AgentControl.Refusal.needsYou("the page shows a \(kind), which only the user can answer")
        }
        try AgentControl.shared.checkAllowed()
    }

    private func detectHumanCheck(_ view: WKWebView) async throws -> String? {
        guard let raw = try? await js("return humanSignals();", in: view) as? [String: Any] else { return nil }
        let frames = raw["frames"] as? [String] ?? []
        let markers = raw["markers"] as? [String] ?? []
        let signals = PageSignals(title: raw["title"] as? String ?? view.title ?? "",
                                  url: raw["url"] as? String ?? view.url?.absoluteString ?? "",
                                  frameURLs: frames, markers: markers,
                                  visibleWidget: !frames.isEmpty || !markers.isEmpty)
        return HumanCheck.detect(signals)
    }

    // MARK: Input events

    private func windowPoint(cssX: Double, cssY: Double, viewportWidth: Double, viewportHeight: Double,
                             in view: WKWebView) -> NSPoint {
        let scale = Double(view.bounds.width) / max(1, viewportWidth)
        // Anything above the page's top edge inside the web view (an inset under the window's title bar).
        let topInset = max(0, Double(view.bounds.height) - viewportHeight * scale)
        let x = cssX * scale
        let fromTop = topInset + cssY * scale
        let local = NSPoint(x: x, y: view.isFlipped ? fromTop : Double(view.bounds.height) - fromTop)
        return view.convert(local, to: nil)
    }

    private func viewportSize(_ view: WKWebView) async throws -> (width: Double, height: Double) {
        let size = try await js("return [innerWidth, innerHeight];", in: view) as? [Double] ?? []
        guard size.count == 2, size[0] > 0 else {
            return (Double(view.bounds.width), Double(view.bounds.height))
        }
        return (size[0], size[1])
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: WKWebView, clicks: Int = 1) {
        guard let window = view.window else { return }
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: eventNumber, clickCount: clicks,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { return }
        AgentControl.shared.noteOwnEvent(event)
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }

    /// Glides Claude's pointer to `target` (window coordinates) along a gentle curve.
    private func movePointer(to target: NSPoint, in view: WKWebView) async throws {
        let control = AgentControl.shared
        let start = control.pointer ?? view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let path = PointerPath.points(from: (x: Double(start.x), y: Double(start.y)),
                                      to: (x: Double(target.x), y: Double(target.y)))
        for step in path {
            let point = NSPoint(x: step.x, y: step.y)
            mouse(.mouseMoved, at: point, in: view)
            control.movePointer(to: point, in: view)
            try await sleep(ms: 12)
        }
    }

    private func press(at point: NSPoint, in view: WKWebView, double: Bool) async throws {
        try await sleep(ms: 70)
        if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        let clicks = double ? 2 : 1
        for count in 1...clicks {
            mouse(.leftMouseDown, at: point, in: view, clicks: count)
            try await sleep(ms: 65)
            mouse(.leftMouseUp, at: point, in: view, clicks: count)
            if count < clicks { try await sleep(ms: 90) }
        }
    }

    private func key(_ key: AgentKey, in view: WKWebView) async throws {
        guard let window = view.window else { return }
        if (window.firstResponder as? NSView)?.isDescendant(of: view) != true { window.makeFirstResponder(view) }
        var flags: NSEvent.ModifierFlags = []
        if key.modifiers.contains(.command) { flags.insert(.command) }
        if key.modifiers.contains(.shift) { flags.insert(.shift) }
        if key.modifiers.contains(.option) { flags.insert(.option) }
        if key.modifiers.contains(.control) { flags.insert(.control) }
        if let scalar = key.characters.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) {
            flags.insert(.function)
            if (0xF700...0xF703).contains(scalar.value) { flags.insert(.numericPad) }
        }
        let ignoring = flags.contains(.shift) ? key.characters.lowercased() : key.characters
        func make(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: key.characters, charactersIgnoringModifiers: ignoring,
                             isARepeat: false, keyCode: key.keyCode)
        }
        guard let down = make(.keyDown), let up = make(.keyUp) else { return }
        AgentControl.shared.noteOwnEvent(down)
        AgentControl.shared.noteOwnEvent(up)
        if flags.contains(.command), view.performKeyEquivalent(with: down) {
            try await sleep(ms: 40)
            view.keyUp(with: up)
            return
        }
        view.keyDown(with: down)
        try await sleep(ms: 40)
        view.keyUp(with: up)
    }

    /// Wheel events, in steps, like a mouse wheel or a trackpad flick. Positive `dy` scrolls down.
    private func wheel(dx: Double, dy: Double, at point: NSPoint, in view: WKWebView) async throws {
        let total = max(abs(dx), abs(dy))
        guard total >= 1 else { return }
        let steps = max(1, min(40, Int(total / 40)))
        // A wheel event made this way has no window, so AppKit reports its location in screen terms.
        // Placing it so those come out as the window position puts it over the right part of the page.
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        for _ in 0..<steps {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32((-dy / Double(steps)).rounded()),
                                   wheel2: Int32((-dx / Double(steps)).rounded()), wheel3: 0) else { return }
            cg.location = CGPoint(x: Double(point.x), y: primaryHeight - Double(point.y))
            if let event = NSEvent(cgEvent: cg) { view.scrollWheel(with: event) }
            try await sleep(ms: 16)
        }
    }

    // MARK: Helpers

    private func sleep(ms: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        try AgentControl.shared.checkAllowed()
    }

    private func js(_ body: String, _ arguments: [String: Any] = [:], in view: WKWebView) async throws -> Any? {
        do {
            return try await view.callAsyncJavaScript(Self.prelude + body, arguments: ["args": arguments],
                                                      in: nil, contentWorld: world)
        } catch {
            throw Failure.message("The page didn't answer: \(error.localizedDescription)")
        }
    }

    private func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) }
        return nil
    }

    private func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: Tool list

    static let definitions: [[String: Any]] = [
        tool("list_tabs", "List the open tabs in Tabmap's map, row by row, with ids for switch_tab. The tab in front is marked *.", [:]),
        tool("switch_tab", "Bring an open tab to the front.", ["tab": ["type": "string", "description": "The tab's id from list_tabs (the first few characters are enough)."]], required: ["tab"]),
        tool("open_url", "Open an address (or search words) and wait for it to load. By default it opens in a new tab in your own row of the map, so the user's tabs are left alone.",
             ["url": ["type": "string", "description": "An address, or words to search for."],
              "new_tab": ["type": "boolean", "description": "false loads it in the tab in front instead. Default true."]], required: ["url"]),
        tool("go", "Back, forward or reload in the tab in front.", ["action": ["type": "string", "enum": ["back", "forward", "reload"]] as [String: Any]], required: ["action"]),
        tool("read_page", "Read the page in front as text: headings, text, and numbered [ref] elements you can click, type into, hover, scroll or choose from. Password fields are shown but never their contents.",
             ["interactive_only": ["type": "boolean", "description": "Only list the elements you can act on. Default false."],
              "max_chars": ["type": "integer", "description": "Longest answer, default 20000."]]),
        tool("screenshot", "See what the page in front looks like right now.", [:]),
        tool("click", "Click an element (by ref from read_page) or a spot (x, y in the last screenshot's pixels) with a real mouse click. Scrolls it into view first.",
             ["ref": ["type": "integer"], "x": ["type": "number"], "y": ["type": "number"],
              "double": ["type": "boolean", "description": "Double-click. Default false."]]),
        tool("hover", "Move the pointer over an element or spot without clicking (opens hover menus and tooltips).",
             ["ref": ["type": "integer"], "x": ["type": "number"], "y": ["type": "number"]]),
        tool("type_text", "Type text with real key presses, into the element given by ref (clicked first) or else into whatever has focus. Never use it for passwords: the user is asked to sign in themselves.",
             ["text": ["type": "string"], "ref": ["type": "integer"],
              "clear": ["type": "boolean", "description": "Select all and delete what is there first. Default false."],
              "submit": ["type": "boolean", "description": "Press Enter afterwards. Default false."]], required: ["text"]),
        tool("press_key", "Press one key or shortcut: Enter, Tab, Escape, Backspace, ArrowUp/Down/Left/Right, PageUp/PageDown, Home, End, Space, or combos like cmd+a, shift+Tab.",
             ["key": ["type": "string"]], required: ["key"]),
        tool("scroll", "Scroll with the mouse wheel, over the page or over a part of it given by ref.",
             ["direction": ["type": "string", "enum": ["up", "down", "left", "right"]] as [String: Any],
              "amount": ["type": "number", "description": "How far, in screens. Default 0.8."],
              "ref": ["type": "integer", "description": "Scroll inside this element (a list or panel) instead of the page."]]),
        tool("select_option", "Choose an option in a drop-down (<select>) by its text or value.",
             ["ref": ["type": "integer"], "option": ["type": "string"]], required: ["ref", "option"]),
        tool("wait_for", "Wait for the page to finish loading, or for some text to appear on it.",
             ["text": ["type": "string"], "seconds": ["type": "number", "description": "Give up after this long. Default 10, at most 60."]]),
        tool("wait_for_user", "When a tool said the user is needed (a human check, a password, a question from the page), wait here until they finish.",
             ["seconds": ["type": "number", "description": "Give up after this long. Default 300."]]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    // MARK: Page scripts

    /// Shared helpers. Element numbers live in this content world only, so pages can't read or change them.
    static let prelude = #"""
    const A = window.__tmAgent || (window.__tmAgent = { next: 1, byEl: new WeakMap(), byRef: new Map() });
    function refOf(el) {
      let r = A.byEl.get(el);
      if (!r) { r = A.next++; A.byEl.set(el, r); A.byRef.set(r, new WeakRef(el)); }
      return r;
    }
    function elOf(r) {
      const w = A.byRef.get(Number(r));
      const el = w && w.deref();
      return el && el.isConnected ? el : null;
    }
    function styleOf(el) { return el.ownerDocument.defaultView.getComputedStyle(el); }
    function rectOf(el) {
      const r = el.getBoundingClientRect();
      let x = r.left, y = r.top, win = el.ownerDocument.defaultView;
      while (win && win !== window && win.frameElement) {
        const fe = win.frameElement, f = fe.getBoundingClientRect();
        x += f.left + fe.clientLeft; y += f.top + fe.clientTop;
        win = win.parent;
      }
      return { x: x, y: y, w: r.width, h: r.height };
    }
    function shown(el) {
      const s = styleOf(el);
      if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse' || parseFloat(s.opacity) === 0) return false;
      const r = el.getBoundingClientRect();
      return r.width > 1 && r.height > 1;
    }
    function clean(t, n) {
      t = (t || '').replace(/\s+/g, ' ').trim();
      return t.length > n ? t.slice(0, n - 1) + '…' : t;
    }
    function labelOf(el) {
      const doc = el.ownerDocument;
      let t = el.getAttribute('aria-label');
      if (!t) {
        const ids = el.getAttribute('aria-labelledby');
        if (ids) t = ids.split(/\s+/).map(function (i) { const n = doc.getElementById(i); return n ? n.textContent : ''; }).join(' ');
      }
      if (!t && el.labels && el.labels.length) t = Array.from(el.labels).map(function (l) { return l.textContent; }).join(' ');
      if (!t) t = el.getAttribute('alt') || el.getAttribute('title') || el.getAttribute('placeholder');
      if (!t && el.tagName === 'INPUT' && /^(submit|button|reset)$/i.test(el.type)) t = el.value;
      if (!t && el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA' && el.tagName !== 'SELECT') t = el.innerText || el.textContent;
      if (!t && el.querySelector) {
        const img = el.querySelector('img[alt],[aria-label]');
        if (img) t = img.getAttribute('alt') || img.getAttribute('aria-label');
      }
      if (!t && el.name) t = el.name;
      return clean(t, 100);
    }
    function roleOf(el) {
      const role = (el.getAttribute('role') || '').toLowerCase();
      if (role) return role;
      const tag = el.tagName.toLowerCase();
      if (tag === 'a') return 'link';
      if (tag === 'button' || tag === 'summary') return 'button';
      if (tag === 'select') return 'select';
      if (tag === 'textarea') return 'textbox';
      if (tag === 'input') {
        const t = (el.type || 'text').toLowerCase();
        if (t === 'password') return 'password';
        if (t === 'hidden') return null;
        if (['checkbox', 'radio', 'range', 'file', 'color', 'date', 'time', 'datetime-local', 'month', 'week'].indexOf(t) >= 0) return t;
        if (['submit', 'button', 'reset', 'image'].indexOf(t) >= 0) return 'button';
        return 'textbox';
      }
      if (el.isContentEditable) return 'textbox';
      return 'clickable';
    }
    const INTERACTIVE = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=option],[role=switch],[role=combobox],[role=textbox],[role=searchbox],[role=slider],[contenteditable=""],[contenteditable=true],[onclick],[tabindex]:not([tabindex="-1"])';
    function isInteractive(el) { try { return el.matches(INTERACTIVE); } catch (e) { return false; } }
    function deepActive() {
      let a = document.activeElement;
      for (let i = 0; a && i < 10; i++) {
        if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
        if (a.tagName === 'IFRAME') { try { const d = a.contentDocument; if (d && d.activeElement) { a = d.activeElement; continue; } } catch (e) {} }
        break;
      }
      return a;
    }
    function humanSignals() {
      const frames = [], markers = [];
      const vis = function (el) { try { return shown(el); } catch (e) { return false; } };
      document.querySelectorAll('iframe').forEach(function (f) { if (vis(f)) frames.push(f.src || ''); });
      document.querySelectorAll('[id*="captcha" i],[class*="captcha" i],[class*="turnstile" i],#challenge-form,[id*="cf-challenge" i]').forEach(function (e) {
        if (vis(e)) markers.push((e.id || '') + ' ' + (typeof e.className === 'string' ? e.className : ''));
      });
      return { title: document.title, url: location.href, frames: frames.slice(0, 40), markers: markers.slice(0, 20) };
    }

    """#

    static let readScript = #"""
    const maxChars = args.maxChars, interactiveOnly = args.interactiveOnly;
    const vw = innerWidth, vh = innerHeight;
    const out = [];
    let size = 0, truncated = false;
    function push(line) {
      if (truncated || !line) return;
      if (size + line.length > maxChars) { truncated = true; return; }
      out.push(line); size += line.length + 1;
    }
    function offscreen(el) {
      const r = rectOf(el);
      return r.y + r.h < 0 || r.y > vh || r.x + r.w < 0 || r.x > vw;
    }
    function describe(el) {
      const role = roleOf(el);
      if (!role) return null;
      let line = '[' + refOf(el) + '] ' + role;
      let name;
      if (role === 'password') {
        name = clean(el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].textContent) || el.placeholder || el.name, 60);
      } else {
        name = labelOf(el);
      }
      if (name) line += ' "' + name.replace(/"/g, "'") + '"';
      if (role === 'password') {
        line += el.value ? ' (filled in; hidden from Claude)' : ' (empty; the user fills in passwords)';
      } else if (role === 'textbox' || role === 'searchbox' || role === 'combobox') {
        const v = el.isContentEditable ? el.innerText : el.value;
        if (v) line += ' value="' + clean(v, 200).replace(/"/g, "'") + '"';
      } else if (role === 'checkbox' || role === 'radio' || role === 'switch' || role === 'menuitemcheckbox') {
        const c = typeof el.checked === 'boolean' ? el.checked : el.getAttribute('aria-checked') === 'true';
        line += c ? ' checked' : ' unchecked';
      } else if (role === 'select' && el.options) {
        const sel = el.options[el.selectedIndex];
        if (sel) line += ' selected="' + clean(sel.text, 60) + '"';
        const opts = Array.from(el.options).slice(0, 15).map(function (o) { return clean(o.text, 40); });
        line += ' options: ' + opts.join(' | ') + (el.options.length > 15 ? ' | …' : '');
      } else if (role === 'link') {
        const h = el.getAttribute('href');
        if (h && h.indexOf('javascript:') !== 0) line += ' → ' + clean(h, 120);
      }
      if (el.getAttribute('aria-expanded')) line += el.getAttribute('aria-expanded') === 'true' ? ' expanded' : ' collapsed';
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' disabled';
      if (offscreen(el)) line += ' (off-screen)';
      return line;
    }
    const BLOCKS = INTERACTIVE + ',h1,h2,h3,h4,h5,h6,p,div,li,ul,ol,table,tr,section,article,form,img,iframe,header,footer,nav,main,aside';
    function ownText(el) {
      let t = '';
      for (const n of el.childNodes) if (n.nodeType === 3) t += n.textContent;
      return clean(t, 300);
    }
    const SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, svg: 1, SVG: 1, HEAD: 1, LINK: 1, META: 1 };
    function walk(root) {
      for (const el of Array.from(root.children)) {
        if (truncated) return;
        const tag = el.tagName;
        if (SKIP[tag]) continue;
        const s = styleOf(el);
        if (s.display === 'none' || s.visibility === 'hidden') continue;
        const r = el.getBoundingClientRect();
        const box = r.width > 1 && r.height > 1 && parseFloat(s.opacity) !== 0;
        if (box && isInteractive(el) && roleOf(el)) {
          push(describe(el));
          if (/^(A|BUTTON|SELECT|TEXTAREA|INPUT|SUMMARY)$/.test(tag)) continue;
        } else if (!interactiveOnly && box) {
          if (/^H[1-6]$/.test(tag)) { push('#'.repeat(Number(tag[1])) + ' ' + clean(el.innerText, 200)); continue; }
          if (tag === 'IMG') { const alt = el.getAttribute('alt'); if (alt) push('image: ' + clean(alt, 120)); continue; }
          if (!el.querySelector(BLOCKS)) {
            const t = clean(el.innerText, 1000);
            if (t.length > 1) push(t);
            if (!el.shadowRoot) continue;
          } else {
            const t = ownText(el);
            if (t.length > 1) push(t);
          }
        }
        if (el.shadowRoot) walk(el.shadowRoot);
        if (tag === 'IFRAME') { try { const d = el.contentDocument; if (d && d.body) walk(d.body); } catch (e) {} }
        walk(el);
      }
    }
    push('Title: ' + document.title);
    push('URL: ' + location.href);
    push('Viewport ' + vw + '×' + vh + ', scrolled to ' + Math.round(scrollY) + ' of ' + Math.max(0, document.documentElement.scrollHeight - vh) + ' px');
    push('');
    if (document.body) walk(document.body);
    if (truncated) out.push('… (cut at ' + maxChars + ' characters: scroll, use interactive_only, or raise max_chars)');
    return { text: out.join('\n') };
    """#

    static let locateScript = #"""
    const el = elOf(args.ref);
    if (!el) return { missing: true };
    const r = rectOf(el);
    const vw = innerWidth, vh = innerHeight;
    let cx = r.x + r.w / 2, cy = r.y + r.h / 2;
    const inView = r.w > 0 && r.h > 0 && cx >= 0 && cy >= 0 && cx <= vw && cy <= vh;
    let covered = null;
    if (inView && el.ownerDocument === document) {
      const hit = document.elementFromPoint(cx, cy);
      if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) {
        let ok = false;
        for (const p of [[0.25, 0.5], [0.75, 0.5], [0.5, 0.25], [0.5, 0.75], [0.1, 0.5]]) {
          const x = r.x + r.w * p[0], y = r.y + r.h * p[1];
          const h = document.elementFromPoint(x, y);
          if (h && (h === el || el.contains(h))) { cx = x; cy = y; ok = true; break; }
        }
        if (!ok) covered = hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '');
      }
    }
    return { x: cx, y: cy, w: r.w, h: r.h, top: r.y, vw: vw, vh: vh, inView: inView, covered: covered,
             tag: el.tagName.toLowerCase(), type: (typeof el.type === 'string' ? el.type : '').toLowerCase(),
             role: roleOf(el) || '', name: roleOf(el) === 'password' ? '' : labelOf(el) };
    """#

    static let selectScript = #"""
    const el = elOf(args.ref);
    if (!el) return { error: 'it is gone from the page' };
    if (el.tagName !== 'SELECT') return { error: 'it is not a drop-down (click it instead)' };
    const want = String(args.option).trim().toLowerCase();
    const options = Array.from(el.options);
    const opt = options.find(function (o) { return o.value.toLowerCase() === want || o.text.trim().toLowerCase() === want; })
             || options.find(function (o) { return o.text.toLowerCase().indexOf(want) >= 0; });
    if (!opt) return { error: 'no such option', options: options.slice(0, 40).map(function (o) { return o.text.trim(); }) };
    el.focus();
    el.value = opt.value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return { chosen: opt.text.trim() };
    """#
}
