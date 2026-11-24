import AppKit
import WebKit
import TabMapCore

/// What Claude can do in Tabmap, as MCP tools. Pages are read from WebKit's accessibility tree (when
/// macOS allows it, AgentAccessibility.swift) or with a script in its own content world (pages can't
/// see it or tamper with it). Clicks, typing and scrolling are real mouse, keyboard and wheel events
/// handed to the page's web view, moved and paced the way a person's hand would.
///
/// Claude can work in several tabs at once. Tabs on screen (the page in front, or both halves of a
/// split) share one queue and show Claude's pointer; every other tab is held off screen
/// (AgentStage.swift) and has a queue of its own, so the person can keep using Tabmap meanwhile.
/// The person's Stop takes effect between any two steps, in every tab.
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

    /// A page Claude is about to act on, and whether the person can see it.
    struct Page {
        let tab: WebTab
        let view: WKWebView
        let placement: AgentPlacement
        var id: TabID { tab.id }
        var front: Bool { placement == .front }
    }

    private enum Ref {
        case dom(Int)
        case ax(Int)
    }

    private var queues: [String: Task<Void, Never>] = [:]
    private let world = WKContentWorld.world(name: "tabmap-agent")
    /// CSS pixels per pixel of each tab's last screenshot, for clicks by position.
    private var shotFactor: [TabID: Double] = [:]
    /// Claude's pointer in background tabs (window coordinates of their off-screen window).
    private var pointers: [TabID: NSPoint] = [:]
    /// The tab Claude works in when a tool doesn't name one: the last one it opened or switched to.
    private var currentTab: TabID?
    private var eventNumber = 1

    // MARK: Entry

    func call(_ name: String, _ arguments: [String: Any]) async -> Outcome {
        guard AgentControl.shared.enabled else {
            return fail("Claude control is turned off in Tabmap's Settings.")
        }
        guard let key = queueKey(name, arguments) else { return await run(name, arguments) }
        let previous = queues[key]
        let task = Task { @MainActor () -> Outcome in
            await previous?.value
            return await self.run(name, arguments)
        }
        let done = Task { _ = await task.value }
        queues[key] = done
        let outcome = await task.value
        if queues[key] == done { queues[key] = nil }
        return outcome
    }

    /// Tools that only look run at once; tools that change the map run one at a time; page tools queue per page.
    private func queueKey(_ name: String, _ args: [String: Any]) -> String? {
        switch name {
        case "list_tabs", "list_downloads", "wait_for_user": return nil
        case "open_url", "switch_tab", "close_tab", "name_row", "show_side_by_side": return "map"
        default:
            guard let id = try? targetID(args) else { return "front" }
            return AgentPlacement.queueKey(for: id.uuidString, placement: placement(of: id))
        }
    }

    private func run(_ name: String, _ args: [String: Any]) async -> Outcome {
        do {
            // Once the person has stopped Claude, nothing moves, not even the map.
            if !["wait_for_user", "list_tabs", "list_downloads"].contains(name) { try AgentControl.shared.checkAllowed() }
            switch name {
            case "list_tabs": return text(listTabs())
            case "switch_tab": return text(try await switchTab(args))
            case "open_url": return text(try await openURL(args))
            case "close_tab": return text(try closeTab(args))
            case "name_row": return text(try nameRow(args))
            case "show_side_by_side": return text(try await sideBySide(args))
            case "list_downloads": return text(listDownloads(args))
            case "go": return text(try await go(args))
            case "read_page": return text(try await readPage(args))
            case "screenshot": return try await screenshot(args)
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

    private func claudeRows() -> [Trail] {
        BrowserStore.shared.map.trails.filter { $0.hasOpenTabs && isClaudeRow($0) }.sorted { $0.recency > $1.recency }
    }

    private func isClaudeTab(_ id: TabID) -> Bool {
        BrowserStore.shared.map.trails.contains { trail in isClaudeRow(trail) && trail.tabs.contains { $0.id == id } }
    }

    /// The tab a tool is about: the one named by `tab`, else Claude's current tab, else the one in front.
    private func targetID(_ args: [String: Any]) throws -> TabID {
        let map = BrowserStore.shared.map
        if let given = (args["tab"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !given.isEmpty {
            guard let tab = map.allTabs.first(where: { !$0.isClosed && $0.id.uuidString.lowercased().hasPrefix(given) }) else {
                throw Failure.message("No open tab has the id \(given). Use list_tabs.")
            }
            return tab.id
        }
        if let current = currentTab, map.tab(current)?.isClosed == false { return current }
        if let active = map.activeTabID, map.activeTab?.isBlank == false { return active }
        throw Failure.message("No page is open. Use open_url first.")
    }

    private func placement(of id: TabID) -> AgentPlacement {
        let store = BrowserStore.shared
        return AgentPlacement.decide(tabIsOnScreen: store.map.onScreen.contains(id), overviewShown: store.overviewShown,
                                     dockAppInFront: AppDock.shared.isFront)
    }

    private func listTabs() -> String {
        let store = BrowserStore.shared
        let map = store.map
        var lines: [String] = []
        for trail in map.trails.filter(\.hasOpenTabs).sorted(by: { $0.recency > $1.recency }) {
            lines.append("Row: \(rowName(trail))\(isClaudeRow(trail) ? " (your row)" : "")")
            for tab in trail.openTabs {
                var marks = ""
                if map.onScreen.contains(tab.id) && !store.overviewShown { marks += tab.id == map.activeTabID ? "* " : "| " } else { marks += "  " }
                var notes: [String] = []
                if tab.id == currentTab { notes.append("your current tab") }
                if AgentStage.shared.holds(tab.id) && !map.onScreen.contains(tab.id) { notes.append("you are working in it in the background") }
                let note = notes.isEmpty ? "" : "  [\(notes.joined(separator: "; "))]"
                lines.append("\(marks)\(shortID(tab.id))  \(tab.displayTitle) — \(tab.url?.absoluteString ?? "blank tab")\(note)")
            }
        }
        if lines.isEmpty { return "No tabs are open." }
        lines.append("")
        lines.append("* is the tab in front, | the other half of a split view. Every page tool takes `tab` (the 8-character id) to work in any tab, in front or not; without it, tools use your current tab.")
        return lines.joined(separator: "\n")
    }

    private func switchTab(_ args: [String: Any]) async throws -> String {
        guard args["tab"] != nil else { throw Failure.message("Give the tab's id from list_tabs.") }
        let id = try targetID(args)
        let store = BrowserStore.shared
        let title = store.map.tab(id)?.displayTitle ?? "the tab"
        currentTab = id
        if args["bring_to_front"] as? Bool ?? true {
            try AgentControl.shared.begin("Switching to \(title)")
            if AppDock.shared.isFront { AppDock.shared.sendToBack() }
            if store.overviewShown {
                GestureNavigator.shared.closeOverview(showing: id)
                try await sleep(ms: 450)
            } else {
                store.choose(id)
            }
            try await sleep(ms: 150)
        }
        let page = try await prepare(id)
        try AgentControl.shared.begin("Working in \(title)", tab: id, front: page.front)
        let settled = await settle(page, max: 15)
        try await afterAction(page)
        return (page.front ? "Now in front: " : "Now working in (in the background): ") + pageLine(page.view) + busyNote(settled)
    }

    // MARK: Pages

    /// Gets the tab's page ready: loaded, and either on screen (front) or held off screen (background).
    private func prepare(_ id: TabID) async throws -> Page {
        let store = BrowserStore.shared
        let wasLoaded = store.isLoaded(id)
        guard store.map.tab(id)?.isClosed == false, let tab = store.pageForAgent(id) else {
            throw Failure.message("That tab is closed. Use list_tabs.")
        }
        var placement = placement(of: id)
        if placement == .front {
            // The page stage may take a moment to put a freshly chosen page in the window.
            var waited = 0
            while tab.webView.window !== store.window && waited < 20 {
                try await sleep(ms: 50)
                waited += 1
            }
            if tab.webView.window === store.window {
                AgentStage.shared.noteOnScreen(tab)
                if tab.webView.magnification != 1 { tab.webView.magnification = 1 }
                AgentControl.shared.notePage(tab.webView)
            } else {
                placement = .background
            }
        }
        if placement == .background {
            AgentStage.shared.host(tab, size: stageSize())
        }
        AgentStage.shared.touch(id)
        let page = Page(tab: tab, view: tab.webView, placement: placement)
        // A tab that was asleep (or still loading) gets its page back before Claude looks at it.
        if !wasLoaded || tab.webView.isLoading { _ = await settle(page, max: 15) }
        return page
    }

    /// Background pages get the size the person's own page has, so layouts match what they'd see.
    private func stageSize() -> NSSize {
        let store = BrowserStore.shared
        if let view = store.activeWebTab?.webView, view.window != nil, view.bounds.width > 400, view.bounds.height > 300 {
            return view.bounds.size
        }
        if let size = store.window?.contentView?.bounds.size, size.width > 400 { return size }
        return NSSize(width: 1280, height: 800)
    }

    private func pageLine(_ view: WKWebView) -> String {
        let title = (view.title?.isEmpty == false) ? view.title! : "Untitled"
        return "\(title) — \(view.url?.absoluteString ?? "")"
    }

    private func begin(_ what: String, _ page: Page) throws {
        try AgentControl.shared.begin(what, tab: page.id, front: page.front)
    }

    private func note(_ what: String, _ page: Page) {
        AgentControl.shared.noteStatus(what, tab: page.id, front: page.front)
    }

    private func openURL(_ args: [String: Any]) async throws -> String {
        guard let raw = args["url"] as? String, !raw.isEmpty else { throw Failure.message("Give a url.") }
        let store = BrowserStore.shared
        guard let url = AddressInterpreter.url(from: raw, searchTemplate: store.map.settings.searchTemplate) else {
            throw Failure.message("\(raw) isn't an address Tabmap can open.")
        }
        let newTab = args["new_tab"] as? Bool ?? true
        let background = args["background"] as? Bool ?? false
        let id: TabID
        if newTab && background {
            try AgentControl.shared.begin("Opening \(url.host ?? raw) in the background", tab: nil, front: false)
            let row = claudeRows().first
            guard let opened = store.openForAgent(url, inRow: row?.id) else {
                throw Failure.message("Tabmap couldn't open a tab.")
            }
            if row == nil { store.editMap { $0.markOpened(opened, by: AgentControl.laneApp) } }
            id = opened
        } else if newTab {
            try AgentControl.shared.begin("Opening \(url.host ?? raw)")
            if let last = claudeRows().first?.openTabs.last {
                store.openChild(of: last.id, url: url, activate: true)
            } else {
                store.openFromApp(url, app: AgentControl.laneApp)
            }
            guard let active = store.map.activeTabID else { throw Failure.message("Tabmap couldn't open a tab.") }
            id = active
        } else {
            let target = try targetID(args)
            let page = try await prepare(target)
            try begin("Opening \(url.host ?? raw)", page)
            page.tab.load(url)
            id = target
        }
        currentTab = id
        let page = try await prepare(id)
        try begin("Loading \(url.host ?? raw)", page)
        let settled = await settle(page, max: 20)
        try await afterAction(page)
        let place = page.front ? "" : " (in the background, tab \(shortID(id)); the user can keep using Tabmap)"
        return "Opened\(place): \(pageLine(page.view))" + busyNote(settled)
    }

    private func go(_ args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "").lowercased()
        let page = try await prepare(try targetID(args))
        let view = page.view
        switch action {
        case "back":
            guard view.canGoBack else { throw Failure.message("There is no earlier page in this tab.") }
            try begin("Going back", page)
            view.goBack()
        case "forward":
            guard view.canGoForward else { throw Failure.message("There is no later page in this tab.") }
            try begin("Going forward", page)
            view.goForward()
        case "reload":
            try begin("Reloading", page)
            view.reload()
        default:
            throw Failure.message("action must be back, forward or reload.")
        }
        let settled = await settle(page, max: 20)
        try await afterAction(page)
        return "Now showing: \(pageLine(view))" + busyNote(settled)
    }

    // MARK: Waiting for the page

    /// Waits for the page to load, then for it to settle: no new network requests finishing and no
    /// content changing for `quiet` ms. Returns false when it was still busy at `max` seconds.
    /// (Requests that never finish, like live updates, don't hold it up: only finished ones count.)
    private func settle(_ page: Page, max: Double, quiet: Int = 500) async -> Bool {
        let start = Date()
        try? await Task.sleep(nanoseconds: 120_000_000)
        while page.view.isLoading && Date().timeIntervalSince(start) < max {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for _ in 0..<3 {
            let left = max - Date().timeIntervalSince(start)
            guard left > 0.2 else { return !page.view.isLoading }
            let result = try? await page.view.callAsyncJavaScript(Self.settleScript,
                                                                  arguments: ["args": ["quiet": quiet, "max": Int(left * 1000)]],
                                                                  in: nil, contentWorld: world) as? [String: Any]
            if let result { return result["settled"] as? Bool ?? false }
            // The page navigated mid-wait: wait for the new one.
            while page.view.isLoading && Date().timeIntervalSince(start) < max {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return !page.view.isLoading
    }

    private func busyNote(_ settled: Bool) -> String {
        settled ? "" : " (The page was still loading or changing when this returned; wait_for can wait longer.)"
    }

    // MARK: Reading

    private func readPage(_ args: [String: Any]) async throws -> String {
        let page = try await prepare(try targetID(args))
        try begin("Reading the page", page)
        let maxChars = min(max(int(args["max_chars"]) ?? 20000, 1000), 100_000)
        let interactiveOnly = args["interactive_only"] as? Bool ?? false
        let mode = (args["mode"] as? String ?? "auto").lowercased()
        let find = (args["find"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces)
        var body: String?
        var how = "the page's HTML"
        if mode != "dom", AgentAccessibility.shared.isAvailable {
            body = await AgentAccessibility.shared.read(page.tab, maxChars: maxChars, interactiveOnly: interactiveOnly)
            if body != nil { how = "the accessibility tree" }
        } else if mode == "accessibility" {
            how = "the page's HTML (Tabmap isn't allowed to use macOS accessibility; the user can allow it in Tabmap's Settings)"
        }
        if body == nil {
            let result = try await js(Self.readScript, ["maxChars": maxChars, "interactiveOnly": interactiveOnly], in: page.view)
            guard let dict = result as? [String: Any], let text = dict["text"] as? String else {
                throw Failure.message("The page couldn't be read.")
            }
            // The script starts with its own title, address and viewport lines; the header below has them.
            body = text.components(separatedBy: "\n").enumerated().filter { index, line in
                !(index < 3 && (line.hasPrefix("Title: ") || line.hasPrefix("URL: ") || line.hasPrefix("Viewport ")))
            }.map(\.element).joined(separator: "\n")
        }
        try await afterAction(page)
        var lines = body!.components(separatedBy: "\n")
        if let find, !find.isEmpty {
            lines = lines.filter { $0.lowercased().contains(find) }
            if lines.isEmpty { lines = ["Nothing on the page matches “\(find)”."] }
        }
        let viewport = try await js("return [innerWidth, innerHeight, Math.round(scrollY), Math.max(0, document.documentElement.scrollHeight - innerHeight)];", in: page.view) as? [Double] ?? []
        var head = ["Tab \(shortID(page.id))\(page.front ? "" : " (background)"): \(pageLine(page.view))"]
        if viewport.count == 4 { head.append("Viewport \(Int(viewport[0]))×\(Int(viewport[1])), scrolled to \(Int(viewport[2])) of \(Int(viewport[3])) px. Read from \(how).") }
        return (head + [""] + lines).joined(separator: "\n")
            + "\n\nUse the [numbers] with click, type_text, hover, scroll or select_option (pass the same tab)."
    }

    private func screenshot(_ args: [String: Any]) async throws -> Outcome {
        let page = try await prepare(try targetID(args))
        let view = page.view
        try begin("Looking at the page", page)
        try await afterAction(page)
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
        shotFactor[page.id] = viewport.width / width
        return Outcome(content: [
            ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"],
            ["type": "text", "text": "Screenshot of tab \(shortID(page.id)): \(pageLine(view)), \(pixelsWide)×\(pixelsHigh). It shows only this page, not the user's screen. To click or hover a spot, pass x and y in this image's pixels (read_page refs are more reliable)."],
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

    private func parseRef(_ value: Any?) -> Ref? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
            if t.hasPrefix("a"), let n = Int(t.dropFirst()) { return .ax(n) }
            if let n = Int(t) { return .dom(n) }
            return nil
        }
        if let n = int(value) { return .dom(n) }
        return nil
    }

    /// Where an element (by ref) or a screenshot position is, scrolled into view with the wheel if needed.
    private func findTarget(_ args: [String: Any], in page: Page) async throws -> Target {
        let view = page.view
        switch parseRef(args["ref"]) {
        case .dom(let ref)?:
            var info = try await locate(ref, in: view)
            if !(info["inView"] as? Bool ?? false) {
                // Scroll to it the way a person would: with the wheel, a screen at a time.
                for _ in 0..<8 {
                    let top = double(info["top"]) ?? 0, h = double(info["h"]) ?? 0
                    let vh = double(info["vh"]) ?? 800, vw = double(info["vw"]) ?? 1200
                    let dy = (top + h / 2) - vh / 2
                    let scale = view.bounds.width / max(1, vw)
                    let center = windowPoint(cssX: vw / 2, cssY: vh / 2, viewportWidth: vw, viewportHeight: vh, in: view)
                    try await movePointer(to: center, in: page)
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
        case .ax(let ref)?:
            let ax = AgentAccessibility.shared
            guard var found = ax.locate(ref, in: page.tab) else {
                throw Failure.message("Element [a\(ref)] is gone from the page. Call read_page again for fresh numbers.")
            }
            let bounds = view.bounds
            func inView(_ p: NSPoint) -> Bool { p.x >= 0 && p.y >= 0 && p.x <= bounds.width && p.y <= bounds.height }
            if !inView(found.point) {
                let viewport = try await viewportSize(view)
                let center = windowPoint(cssX: viewport.width / 2, cssY: viewport.height / 2,
                                         viewportWidth: viewport.width, viewportHeight: viewport.height, in: view)
                for _ in 0..<8 where !inView(found.point) {
                    let dy = found.point.y - bounds.height / 2
                    try await movePointer(to: center, in: page)
                    try await wheel(dx: 0, dy: max(-bounds.height * 1.5, min(bounds.height * 1.5, dy)), at: center, in: view)
                    try await sleep(ms: 220)
                    guard let again = ax.locate(ref, in: page.tab) else { break }
                    found = again
                }
                if !inView(found.point) {
                    ax.scrollToVisible(ref, in: page.tab)
                    try await sleep(ms: 200)
                    if let again = ax.locate(ref, in: page.tab) { found = again }
                }
            }
            let viewport = try await viewportSize(view)
            let toCSS = viewport.width / max(1, Double(bounds.width))
            let kind = AXOutline.roleName(found.role, subrole: found.subrole) ?? "element"
            return Target(x: Double(found.point.x) * toCSS, y: Double(found.point.y) * toCSS,
                          viewportWidth: viewport.width, viewportHeight: viewport.height,
                          description: "[a\(ref)] \(kind)", role: kind,
                          type: found.subrole == "AXSecureTextField" ? "password" : "", covered: nil)
        case nil:
            break
        }
        if let x = double(args["x"]), let y = double(args["y"]) {
            let viewport = try await viewportSize(view)
            let factor = shotFactor[page.id] ?? 1
            return Target(x: x * factor, y: y * factor, viewportWidth: viewport.width, viewportHeight: viewport.height,
                          description: "the spot at \(Int(x)), \(Int(y))", role: "", type: "", covered: nil)
        }
        throw Failure.message("Give a ref from read_page, or x and y from a screenshot.")
    }

    /// Pointer-arrival events at a viewport point, for when the window isn't active (background tabs).
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
        let page = try await prepare(try targetID(args))
        let view = page.view
        try begin(hoverOnly ? "Pointing" : "Clicking", page)
        let target = try await findTarget(args, in: page)
        if !hoverOnly {
            if target.role == "select" {
                throw Failure.message("\(target.description) is a drop-down menu. Use select_option instead of clicking it.")
            }
            if target.type == "file" {
                throw Failure.message("\(target.description) picks a file from the Mac. Claude can't choose files; ask the user to do it.")
            }
        }
        note((hoverOnly ? "Pointing at " : "Clicking ") + target.description, page)
        let point = windowPoint(cssX: target.x, cssY: target.y, viewportWidth: target.viewportWidth,
                                viewportHeight: target.viewportHeight, in: view)
        let beforeURL = view.url
        let beforeTabs = Set(BrowserStore.shared.map.allTabs.filter { !$0.isClosed }.map(\.id))
        let beforeActive = BrowserStore.shared.map.activeTabID
        try await movePointer(to: point, in: page)
        if hoverOnly {
            var note = ""
            if !(page.front && NSApp.isActive && view.window?.isKeyWindow == true) {
                // WebKit only hit-tests mouse moves while the window is active; in a background window
                // they just update scrollbars. Tell the page the pointer arrived with DOM events instead.
                _ = try await js(Self.hoverScript, ["x": target.x, "y": target.y], in: view)
                note = " The page got hover events, but CSS hover styles may not show because \(page.front ? "Tabmap is in the background" : "this tab is out of sight")."
            }
            try await sleep(ms: 350)
            return "Pointer is over \(target.description).\(note)"
        }
        try await press(at: point, in: view, double: args["double"] as? Bool ?? false)
        try await sleep(ms: 150)
        var notes: [String] = []
        if let covered = target.covered {
            notes.append("Something else (\(covered)) was on top of it, so the click may have landed there.")
        }
        let store = BrowserStore.shared
        let opened = store.map.allTabs.filter { !$0.isClosed && !beforeTabs.contains($0.id) }.map(\.id)
        if let newTab = opened.last {
            // A link that opens a new tab: carry on there.
            currentTab = newTab
            let newPage = try await prepare(newTab)
            let settled = await settle(newPage, max: 15)
            try await afterAction(newPage)
            let place = newPage.front ? "now in front" : "in the background"
            notes.append("It opened a new tab \(shortID(newTab)) (\(place), now your current tab): \(pageLine(newPage.view))" + busyNote(settled))
        } else {
            if store.map.activeTabID != beforeActive && page.front { notes.append("The tab in front changed.") }
            let settled = await settle(page, max: 8, quiet: 400)
            try await afterAction(page)
            if view.url != beforeURL { notes.append("The page is now: \(pageLine(view))") }
            if !settled { notes.append(busyNote(false).trimmingCharacters(in: .whitespaces)) }
        }
        return (["Clicked \(target.description)."] + notes).joined(separator: " ")
    }

    // MARK: Keyboard

    private func typeText(_ args: [String: Any]) async throws -> String {
        guard let text = args["text"] as? String else { throw Failure.message("Give the text to type.") }
        let page = try await prepare(try targetID(args))
        let view = page.view
        try begin("Typing", page)
        if args["ref"] != nil {
            let target = try await findTarget(args, in: page)
            if target.type == "password" || target.role == "password" { try handOverPassword(page) }
            note("Typing into \(target.description)", page)
            let point = windowPoint(cssX: target.x, cssY: target.y, viewportWidth: target.viewportWidth,
                                    viewportHeight: target.viewportHeight, in: view)
            try await movePointer(to: point, in: page)
            try await press(at: point, in: view, double: false)
            try await sleep(ms: 150)
        }
        if try await js("const a = deepActive(); return !!(a && a.type === 'password');", in: view) as? Bool == true {
            try handOverPassword(page)
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
            let settled = await settle(page, max: 15)
            reply += " Pressed Enter."
            if view.url != before { reply += " The page is now: \(pageLine(view))" }
            reply += busyNote(settled)
        }
        try await afterAction(page)
        return reply
    }

    private func handOverPassword(_ page: Page) throws -> Never {
        let host = page.view.url?.host
        let saved = host.map { PasswordStore.shared.candidates(forHost: $0).count } ?? 0
        let reason = saved > 0 ? "Sign-in needs your password (Tabmap has \(saved) saved login\(saved == 1 ? "" : "s") for this site)"
                               : "Sign-in needs your password"
        AgentControl.shared.handOver(reason, tab: page.id, site: host, clearsItself: false)
        let hint = saved > 0 ? " Tabmap has a saved login for this site, so they can fill it from the password pill." : ""
        throw AgentControl.Refusal.needsYou("this is a password field, and Claude never types passwords. The user has been asked to sign in\(page.front ? "" : " (the tab is in the background; the notification and the pill's Show button bring it up)")\(hint)")
    }

    private func pressKey(_ args: [String: Any]) async throws -> String {
        guard let spec = args["key"] as? String, let parsed = AgentKey.parse(spec) else {
            throw Failure.message("Unknown key. Use names like Enter, Tab, Escape, Backspace, ArrowDown, PageDown, or combos like cmd+a.")
        }
        let page = try await prepare(try targetID(args))
        let view = page.view
        try begin("Pressing \(spec)", page)
        let before = view.url
        try await key(parsed, in: view)
        let settled = await settle(page, max: 8, quiet: 300)
        try await afterAction(page)
        return "Pressed \(spec)." + (view.url != before ? " The page is now: \(pageLine(view))" : "") + busyNote(settled)
    }

    private func selectOption(_ args: [String: Any]) async throws -> String {
        guard let ref = int(args["ref"]), let option = args["option"] as? String else {
            throw Failure.message("Give the drop-down's ref (a plain number from read_page with mode dom) and the option to pick.")
        }
        let page = try await prepare(try targetID(args))
        let view = page.view
        try begin("Choosing \(option)", page)
        let target = try await findTarget(["ref": ref], in: page)
        let point = windowPoint(cssX: target.x, cssY: target.y, viewportWidth: target.viewportWidth,
                                viewportHeight: target.viewportHeight, in: view)
        try await movePointer(to: point, in: page)
        // A real click would open the system menu, which holds up everything until it closes.
        let result = try await js(Self.selectScript, ["ref": ref, "option": option], in: view) as? [String: Any] ?? [:]
        if let error = result["error"] as? String {
            let options = (result["options"] as? [String])?.joined(separator: " | ") ?? ""
            throw Failure.message("Couldn't choose \"\(option)\": \(error).\(options.isEmpty ? "" : " Options: \(options)")")
        }
        _ = await settle(page, max: 5, quiet: 300)
        try await afterAction(page)
        return "Chose \"\(result["chosen"] as? String ?? option)\" in \(target.description)."
    }

    // MARK: Scrolling

    private func scroll(_ args: [String: Any]) async throws -> String {
        let page = try await prepare(try targetID(args))
        let view = page.view
        let direction = (args["direction"] as? String ?? "down").lowercased()
        try begin("Scrolling \(direction)", page)
        let amount = min(max(double(args["amount"]) ?? 0.8, 0.1), 10)
        let viewport = try await viewportSize(view)
        let scale = view.bounds.width / max(1, viewport.width)
        var point = windowPoint(cssX: viewport.width / 2, cssY: viewport.height / 2,
                                viewportWidth: viewport.width, viewportHeight: viewport.height, in: view)
        if args["ref"] != nil {
            let target = try await findTarget(args, in: page)
            point = windowPoint(cssX: target.x, cssY: target.y, viewportWidth: target.viewportWidth,
                                viewportHeight: target.viewportHeight, in: view)
        }
        try await movePointer(to: point, in: page)
        let before = try await js("return [scrollX, scrollY];", in: view) as? [Double]
        let distance = amount * (direction == "left" || direction == "right" ? viewport.width : viewport.height) * scale
        switch direction {
        case "down": try await wheel(dx: 0, dy: distance, at: point, in: view)
        case "up": try await wheel(dx: 0, dy: -distance, at: point, in: view)
        case "right": try await wheel(dx: distance, dy: 0, at: point, in: view)
        case "left": try await wheel(dx: -distance, dy: 0, at: point, in: view)
        default: throw Failure.message("direction must be up, down, left or right.")
        }
        // Long lists often load more when you reach their end.
        _ = await settle(page, max: 3, quiet: 300)
        try await afterAction(page)
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
        let page = try await prepare(try targetID(args))
        let view = page.view
        let wanted = (args["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let gone = (args["gone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        try begin(wanted.map { "Waiting for “\($0)”" } ?? gone.map { "Waiting for “\($0)” to go" } ?? "Waiting for the page to settle", page)
        let timeout = min(max(double(args["seconds"]) ?? 10, 0.5), 60)
        let start = Date()
        if wanted == nil && gone == nil {
            let settled = await settle(page, max: timeout)
            try await afterAction(page)
            return settled ? "The page has loaded and settled: \(pageLine(view))"
                           : "Still loading or changing after \(Int(timeout)) seconds: \(pageLine(view))"
        }
        while Date().timeIntervalSince(start) < timeout {
            try AgentControl.shared.checkAllowed()
            if !view.isLoading {
                let found = try? await js("""
                    const t = document.body ? document.body.innerText : '';
                    return [args.w === null || t.includes(args.w), args.g === null || !t.includes(args.g)];
                    """, ["w": wanted ?? NSNull(), "g": gone ?? NSNull()], in: view) as? [Bool]
                if let found, found.count == 2, found[0], found[1] {
                    try await afterAction(page)
                    if let wanted { return "Found “\(wanted)” on \(pageLine(view))." }
                    return "“\(gone!)” is gone from \(pageLine(view))."
                }
            }
            try await sleep(ms: 250)
        }
        try await afterAction(page)
        if let wanted { return "“\(wanted)” didn't appear within \(Int(timeout)) seconds. Page: \(pageLine(view))" }
        return "“\(gone!)” was still there after \(Int(timeout)) seconds. Page: \(pageLine(view))"
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
            if control.handOverClearsItself, let tab = control.waitingTab ?? BrowserStore.shared.map.activeTabID,
               let page = BrowserStore.shared.page(for: tab) {
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

    // MARK: The map, rows and downloads

    private func closeTab(_ args: [String: Any]) throws -> String {
        guard args["tab"] != nil else { throw Failure.message("Give the tab's id from list_tabs.") }
        let id = try targetID(args)
        guard isClaudeTab(id) else {
            throw Failure.message("That tab is in one of the user's own rows. You can only close tabs in your rows; ask the user about theirs.")
        }
        try AgentControl.shared.begin("Closing a tab")
        let title = BrowserStore.shared.map.tab(id)?.displayTitle ?? "the tab"
        BrowserStore.shared.closeTab(id)
        if currentTab == id { currentTab = nil }
        AgentAccessibility.shared.forget(id)
        return "Closed \(title). It can be reopened from the map like any closed tab."
    }

    private func nameRow(_ args: [String: Any]) throws -> String {
        guard let name = args["name"] as? String else { throw Failure.message("Give the row's new name.") }
        let id = try targetID(args)
        let store = BrowserStore.shared
        guard let trail = store.map.trails.first(where: { $0.tabs.contains { $0.id == id } }), isClaudeRow(trail) else {
            throw Failure.message("That tab is in one of the user's own rows. You can only name your rows.")
        }
        try AgentControl.shared.begin("Naming a row")
        store.editMap { $0.rename(trail: trail.id, to: name) }
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? "The row is named automatically again." : "Named the row “\(name)”."
    }

    private func sideBySide(_ args: [String: Any]) async throws -> String {
        let first = try targetID(args)
        let second = try targetID(["tab": args["other_tab"] as? String ?? ""])
        let store = BrowserStore.shared
        guard store.map.canSplit(first, second) else {
            throw Failure.message("Split view needs two neighbouring tabs in the same row. Open the second page from the first (open_url with new_tab true puts it next to your last tab).")
        }
        try AgentControl.shared.begin("Showing two tabs side by side")
        if AppDock.shared.isFront { AppDock.shared.sendToBack() }
        if store.overviewShown { GestureNavigator.shared.closeOverview(showing: first); try await sleep(ms: 450) }
        store.splitTabs(first, with: second)
        currentTab = first
        return "Showing \(shortID(first)) and \(shortID(second)) side by side. Both are on screen now; pass `tab` to act in either."
    }

    private func listDownloads(_ args: [String: Any]) -> String {
        let downloads = DownloadStore.shared
        let limit = min(max(int(args["limit"]) ?? 10, 1), 50)
        let records = downloads.ledger.records.sorted { $0.startedAt > $1.startedAt }.prefix(limit)
        if records.isEmpty { return "No downloads." }
        let formatter = ByteCountFormatter()
        return records.map { record in
            var line = "\(record.filename) — "
            switch record.state {
            case .inProgress:
                let share = downloads.progress[record.id].map { " \(Int($0 * 100))%" } ?? ""
                line += "downloading\(share)"
            case .finished: line += "finished" + (downloads.fileExists(record) ? "" : " (file since moved or deleted)")
            case .failed: line += "failed"
            case .cancelled: line += "cancelled"
            }
            if let bytes = record.byteCount { line += ", \(formatter.string(fromByteCount: bytes))" }
            if let path = record.filePath { line += ", saved at \(path)" }
            if let page = record.pageURL { line += ", from \(page.host ?? page.absoluteString)" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: After each action

    /// Stops and hands the page to the person when it asks whether they're human.
    private func afterAction(_ page: Page) async throws {
        if let kind = try await detectHumanCheck(page.view) {
            let reason = "Human check (\(kind))"
            AgentControl.shared.handOver(reason, tab: page.id, site: page.view.url?.host, clearsItself: true)
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

    /// Glides Claude's pointer to `target` (window coordinates) along a gentle curve. On screen, the
    /// person sees it move; in a background tab only the page does.
    private func movePointer(to target: NSPoint, in page: Page) async throws {
        let control = AgentControl.shared
        let view = page.view
        let middle = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let start = (page.front ? control.pointer : pointers[page.id]) ?? middle
        let path = PointerPath.points(from: (x: Double(start.x), y: Double(start.y)),
                                      to: (x: Double(target.x), y: Double(target.y)))
        for step in path {
            let point = NSPoint(x: step.x, y: step.y)
            mouse(.mouseMoved, at: point, in: view)
            if page.front { control.movePointer(to: point, in: view) } else { pointers[page.id] = point }
            try await sleep(ms: page.front ? 12 : 6)
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

    private static let tabParam: [String: Any] = [
        "type": "string",
        "description": "Which tab (its id from list_tabs or open_url). It can be in the background: you can work in several tabs at once while the user uses others. Default: your current tab.",
    ]
    private static let refParam: [String: Any] = [
        "type": ["integer", "string"],
        "description": "An element's number from read_page: 12 for [12], or \"a12\" for [a12].",
    ]

    private static func pageTool(_ name: String, _ description: String, _ properties: [String: Any],
                                 required: [String] = []) -> [String: Any] {
        var all = properties
        all["tab"] = tabParam
        return tool(name, description, all, required: required)
    }

    static let definitions: [[String: Any]] = [
        tool("list_tabs", "List the open tabs in Tabmap's map, row by row, with ids. Marks the tab in front, split view, your current tab and tabs you are working in out of sight.", [:]),
        tool("open_url", "Open an address (or search words) and wait until the page has loaded and settled. By default it opens in a new tab in your own row and brings it to the front. With background true, the tab opens out of sight so the user can keep using Tabmap, and you work in it by passing its id as `tab`; open several to work in parallel.",
             ["url": ["type": "string", "description": "An address, or words to search for."],
              "new_tab": ["type": "boolean", "description": "false loads it in your current tab (or `tab`) instead. Default true."],
              "background": ["type": "boolean", "description": "Open the new tab out of sight. Default false."],
              "tab": tabParam], required: ["url"]),
        tool("switch_tab", "Make a tab your current tab. By default it is also brought to the front for the user to see; with bring_to_front false you work in it out of sight.",
             ["tab": ["type": "string", "description": "The tab's id from list_tabs (the first few characters are enough)."],
              "bring_to_front": ["type": "boolean", "description": "Default true."]], required: ["tab"]),
        tool("show_side_by_side", "Show two neighbouring tabs of the same row in split view, so the user can watch you work in both. Only when the user wants to watch; otherwise work in background tabs.",
             ["tab": ["type": "string"], "other_tab": ["type": "string"]], required: ["tab", "other_tab"]),
        tool("close_tab", "Close one of the tabs in your own rows (never the user's).", ["tab": ["type": "string"]], required: ["tab"]),
        tool("name_row", "Name the row a tab of yours is in, so the user can find your work in the map. An empty name returns it to automatic naming.",
             ["name": ["type": "string"], "tab": tabParam], required: ["name"]),
        tool("list_downloads", "List Tabmap's recent downloads: file, progress or result, size, where it was saved and the site it came from.",
             ["limit": ["type": "integer", "description": "How many, newest first. Default 10."]]),
        pageTool("go", "Back, forward or reload.", ["action": ["type": "string", "enum": ["back", "forward", "reload"]] as [String: Any]], required: ["action"]),
        pageTool("read_page", "Read a page as text: headings, text, and numbered elements you can click, type into, hover, scroll or choose from. When the user has allowed Tabmap to use macOS accessibility it reads the accessibility tree (refs like [a12], includes frames from other sites); otherwise the page's HTML (refs like [12]). Password fields are shown but never their contents.",
                 ["interactive_only": ["type": "boolean", "description": "Only list the elements you can act on. Default false."],
                  "find": ["type": "string", "description": "Only return lines containing this text (to find one button or field on a long page)."],
                  "mode": ["type": "string", "enum": ["auto", "accessibility", "dom"], "description": "Default auto. Use dom for select_option refs."] as [String: Any],
                  "max_chars": ["type": "integer", "description": "Longest answer, default 20000."]]),
        pageTool("screenshot", "See what a page looks like right now (just that page, never the user's screen; works for background tabs too). Prefer read_page; use this only when the layout or an image matters.", [:]),
        pageTool("click", "Click an element (by ref from read_page) or a spot (x, y in the last screenshot's pixels) with a real mouse click, scrolling it into view first, then wait for the page to settle. If it opens a new tab, that becomes your current tab.",
                 ["ref": refParam, "x": ["type": "number"], "y": ["type": "number"],
                  "double": ["type": "boolean", "description": "Double-click. Default false."]]),
        pageTool("hover", "Move the pointer over an element or spot without clicking (opens hover menus and tooltips).",
                 ["ref": refParam, "x": ["type": "number"], "y": ["type": "number"]]),
        pageTool("type_text", "Type text with real key presses, into the element given by ref (clicked first) or else into whatever has focus. Never use it for passwords: the user is asked to sign in themselves.",
                 ["text": ["type": "string"], "ref": refParam,
                  "clear": ["type": "boolean", "description": "Select all and delete what is there first. Default false."],
                  "submit": ["type": "boolean", "description": "Press Enter afterwards and wait for the page. Default false."]], required: ["text"]),
        pageTool("press_key", "Press one key or shortcut: Enter, Tab, Escape, Backspace, ArrowUp/Down/Left/Right, PageUp/PageDown, Home, End, Space, or combos like cmd+a, shift+Tab.",
                 ["key": ["type": "string"]], required: ["key"]),
        pageTool("scroll", "Scroll with the mouse wheel, over the page or over a part of it given by ref, then wait briefly for anything it loads.",
                 ["direction": ["type": "string", "enum": ["up", "down", "left", "right"]] as [String: Any],
                  "amount": ["type": "number", "description": "How far, in screens. Default 0.8."],
                  "ref": refParam]),
        pageTool("select_option", "Choose an option in a drop-down (<select>) by its text or value. Needs a plain-number ref (read_page mode dom).",
                 ["ref": ["type": "integer"], "option": ["type": "string"]], required: ["ref", "option"]),
        pageTool("wait_for", "Wait until the page has loaded and settled (no network requests finishing and no content changing for half a second), or until some text appears, or until some text is gone (a spinner or \"Saving…\").",
                 ["text": ["type": "string"], "gone": ["type": "string"],
                  "seconds": ["type": "number", "description": "Give up after this long. Default 10, at most 60."]]),
        tool("wait_for_user", "When a tool said the user is needed (a human check, a password, a question from the page), wait here until they finish.",
             ["seconds": ["type": "number", "description": "Give up after this long. Default 300."]]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    /// Resolves once the page has been quiet for `args.quiet` ms (no resource finishing loading, no
    /// nodes or text changing), or at `args.max` ms. Runs in Claude's own content world.
    static let settleScript = #"""
    const quiet = args.quiet, max = args.max;
    const start = performance.now();
    let last = start;
    let count = performance.getEntriesByType('resource').length;
    const mark = function () { last = performance.now(); };
    const mo = new MutationObserver(mark);
    mo.observe(document, { subtree: true, childList: true, characterData: true });
    let po = null;
    try { po = new PerformanceObserver(mark); po.observe({ type: 'resource' }); } catch (e) {}
    return await new Promise(function (resolve) {
      function done(ok) {
        mo.disconnect(); if (po) po.disconnect();
        resolve({ settled: ok, waited: Math.round(performance.now() - start) });
      }
      function tick() {
        const now = performance.now();
        const n = performance.getEntriesByType('resource').length;
        if (n !== count) { count = n; last = now; }
        if (document.readyState === 'complete' && now - last >= quiet) return done(true);
        if (now - start >= max) return done(false);
        setTimeout(tick, 100);
      }
      tick();
    });
    """#

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
