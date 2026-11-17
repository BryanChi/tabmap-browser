import AppKit
import SwiftUI
import WebKit

/// Find in page (⌘F). Everything for the feature lives in this file; the only hook elsewhere is
/// `FindIsland()` in ContentView. Shortcuts are caught here: ⌘F opens, Return or ⌘G goes to the
/// next match, ⇧Return or ⇧⌘G to the previous one, Escape closes.
@MainActor
final class FindController: ObservableObject {
    static let shared = FindController()

    @Published private(set) var shown = false
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    /// "3 of 12", "Not found", or empty.
    @Published private(set) var status = ""
    @Published private(set) var hasMatches = false
    /// Changing this gives the find field keyboard focus.
    @Published private(set) var focusToken = 0

    private var monitor: Any?
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    /// The page that currently carries highlights.
    private weak var markedView: WKWebView?
    /// A script world of our own, so pages cannot see or break the find script.
    private let world = WKContentWorld.world(name: "TabmapFind")

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// The page being looked at: a dock app in front, else whichever page in a split has focus,
    /// else the current tab's page.
    private var pageView: WKWebView? {
        if AppDock.shared.isFront { return AppDock.shared.frontWebView }
        let tabView = BrowserStore.shared.activeWebTab?.webView
        var view = tabView?.window?.firstResponder as? NSView
        while let current = view {
            if let webView = current as? WKWebView { return webView }
            view = current.superview
        }
        return tabView
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let store = BrowserStore.shared
        guard !store.overviewShown, let webView = pageView, event.window === webView.window else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == [.command], key == "f" {
            open()
            return true
        }
        if flags == [.command] || flags == [.command, .shift], key == "g", !query.isEmpty {
            if !shown { open() }
            step(forward: !flags.contains(.shift))
            return true
        }
        if shown, flags.isEmpty, event.keyCode == 53, !store.addressEditing { // escape
            close()
            return true
        }
        return false
    }

    // MARK: Actions

    func open() {
        let wasShown = shown
        shown = true
        focusToken += 1
        // Reopening with the last search still in the field brings its highlights back.
        if !wasShown, !query.isEmpty { run("search") }
    }

    func close() {
        guard shown else { return }
        shown = false
        searchTask?.cancel()
        generation += 1
        clearMarks()
        if let webView = pageView, webView.window != nil {
            webView.window?.makeFirstResponder(webView)
        }
    }

    func step(forward: Bool) {
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        run("step", forward: forward)
    }

    /// The tab was switched or the page finished loading: search the new content, without moving it.
    func pageChanged() {
        guard shown, !query.isEmpty else { return }
        run("search", scroll: false)
    }

    // MARK: Searching

    private func scheduleSearch() {
        searchTask?.cancel()
        guard shown else { return }
        // A short pause so fast typing searches once, not once per letter.
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.run("search")
        }
    }

    private func clearMarks() {
        guard let view = markedView else { return }
        markedView = nil
        view.callAsyncJavaScript(Self.script, arguments: ["action": "clear", "query": "", "forward": true, "scroll": false],
                                 in: nil, in: world, completionHandler: nil)
    }

    private func run(_ action: String, forward: Bool = true, scroll: Bool = true) {
        generation += 1
        let token = generation
        guard let webView = pageView else {
            show(count: 0, index: 0)
            return
        }
        if markedView !== webView { clearMarks() }
        guard !query.isEmpty else {
            clearMarks()
            status = ""
            hasMatches = false
            return
        }
        markedView = webView
        let query = self.query
        let arguments: [String: Any] = ["action": action, "query": query, "forward": forward, "scroll": scroll]
        webView.callAsyncJavaScript(Self.script, arguments: arguments, in: nil, in: world) { [weak self, weak webView] result in
            let reply: [String: Any]
            if case .success(let value) = result, let dictionary = value as? [String: Any] {
                reply = dictionary
            } else {
                reply = [:]
            }
            let supported = (reply["supported"] as? Bool) ?? true
            let count = (reply["count"] as? NSNumber)?.intValue ?? 0
            let index = (reply["index"] as? NSNumber)?.intValue ?? 0
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if supported {
                    self.show(count: count, index: index)
                } else if let webView {
                    self.systemFind(query, forward: forward, in: webView, token: token)
                }
            }
        }
    }

    private func show(count: Int, index: Int) {
        hasMatches = count > 0
        if query.isEmpty {
            status = ""
        } else if count == 0 {
            status = "Not found"
        } else {
            status = "\(index) of \(count)"
        }
    }

    /// Older systems without CSS highlights: WebKit's own find, which selects one match at a time and gives no count.
    private func systemFind(_ query: String, forward: Bool, in webView: WKWebView, token: Int) {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(query, configuration: configuration) { [weak self] result in
            let found = result.matchFound
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.hasMatches = found
                self.status = found ? "" : "Not found"
            }
        }
    }

    private static let script = #"""
    // Body of an async function. Arguments: action ("search" | "step" | "clear"), query, forward, scroll.
    // Runs in Tabmap's own script world, so the page's scripts cannot see or disturb it.
    const state = window.__tabmapFind || (window.__tabmapFind = { ranges: [], index: -1, query: "" });
    if (!(window.CSS && CSS.highlights && window.Highlight)) return { supported: false, count: 0, index: 0 };

    const clear = () => {
        CSS.highlights.delete("tabmap-find");
        CSS.highlights.delete("tabmap-find-current");
        state.ranges = [];
        state.index = -1;
        state.query = "";
    };

    const installStyle = () => {
        const css = "::highlight(tabmap-find){background-color:rgba(255,214,10,.45);color:inherit}"
            + "::highlight(tabmap-find-current){background-color:#ff9f0a;color:#000}";
        try {
            if (!state.sheet) {
                state.sheet = new CSSStyleSheet();
                state.sheet.replaceSync(css);
            }
            if (!document.adoptedStyleSheets.includes(state.sheet)) {
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, state.sheet];
            }
        } catch (e) {
            if (!state.styleElement || !state.styleElement.isConnected) {
                state.styleElement = document.createElement("style");
                state.styleElement.textContent = css;
                (document.head || document.documentElement).appendChild(state.styleElement);
            }
        }
    };

    const showCurrent = (scroll) => {
        const range = state.ranges[state.index];
        if (!range) {
            CSS.highlights.delete("tabmap-find-current");
            return;
        }
        const current = new Highlight(range);
        current.priority = 1;
        CSS.highlights.set("tabmap-find-current", current);
        if (!scroll) return;
        const rect = range.getBoundingClientRect();
        const visible = rect.top >= 60 && rect.bottom <= window.innerHeight - 20
            && rect.left >= 0 && rect.right <= window.innerWidth;
        if (!visible) {
            const node = range.startContainer;
            const element = node.nodeType === 1 ? node : node.parentElement;
            if (element) element.scrollIntoView({ block: "center", inline: "nearest" });
        }
    };

    const search = (query, scroll) => {
        clear();
        state.query = query;
        if (!query || !document.body) return;
        installStyle();

        // Collect the visible text as one string, remembering where each text node starts,
        // so a match can run across inline tags such as <b> or <a>.
        const skip = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "TEXTAREA", "SELECT", "OPTION"]);
        const shown = new Map();
        const blocks = new Map();
        const isShown = (el) => {
            let v = shown.get(el);
            if (v === undefined) {
                v = el.checkVisibility ? el.checkVisibility({ visibilityProperty: true }) : true;
                shown.set(el, v);
            }
            return v;
        };
        const blockOf = (el) => {
            if (blocks.has(el)) return blocks.get(el);
            const display = getComputedStyle(el).display;
            const block = display.startsWith("inline") && display !== "inline-block" && el.parentElement
                ? blockOf(el.parentElement) : el;
            blocks.set(el, block);
            return block;
        };
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
                const parent = node.parentElement;
                if (!parent || skip.has(parent.tagName) || !node.data) return NodeFilter.FILTER_REJECT;
                return isShown(parent) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
            },
        });
        const nodes = [];
        const starts = [];
        let text = "";
        let lastBlock = null;
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const block = blockOf(node.parentElement);
            // A line break between blocks stops "end" + "start" of two paragraphs matching "dst".
            if (lastBlock && block !== lastBlock) text += "\n";
            lastBlock = block;
            nodes.push(node);
            starts.push(text.length);
            text += node.data;
        }

        const locate = (offset, isEnd) => {
            let lo = 0, hi = nodes.length - 1;
            while (lo < hi) {
                const mid = (lo + hi + 1) >> 1;
                if (starts[mid] <= offset) lo = mid; else hi = mid - 1;
            }
            // An end that falls exactly on a node boundary belongs to the node before it.
            if (isEnd && lo > 0 && starts[lo] === offset) lo -= 1;
            return [nodes[lo], Math.min(offset - starts[lo], nodes[lo].data.length)];
        };

        // Spaces in the query match any run of white space, including non-breaking spaces.
        const pattern = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\s+/g, "[^\\S\\n]+");
        const regex = new RegExp(pattern, "gi");
        const limit = 2000;
        for (let m = regex.exec(text); m && state.ranges.length < limit; m = regex.exec(text)) {
            if (m[0].length === 0) { regex.lastIndex += 1; continue; }
            const range = document.createRange();
            const [startNode, startOffset] = locate(m.index, false);
            const [endNode, endOffset] = locate(m.index + m[0].length, true);
            range.setStart(startNode, startOffset);
            range.setEnd(endNode, endOffset);
            state.ranges.push(range);
        }
        if (state.ranges.length === 0) return;
        CSS.highlights.set("tabmap-find", new Highlight(...state.ranges));

        // Start at the first match at or below the top of what is on screen.
        state.index = 0;
        for (let i = 0; i < state.ranges.length; i += 1) {
            const rect = state.ranges[i].getBoundingClientRect();
            if (rect.bottom > 0 && (rect.width > 0 || rect.height > 0)) { state.index = i; break; }
        }
        showCurrent(scroll);
    };

    if (action === "clear") {
        clear();
    } else if (action === "search") {
        search(query, scroll);
    } else if (action === "step") {
        // The page may have changed since the search; search again if the matches have gone stale.
        const stale = state.query !== query || state.ranges.some((r) => !r.startContainer.isConnected || r.collapsed);
        if (stale) {
            search(query, true);
        } else if (state.ranges.length > 0) {
            const n = state.ranges.length;
            state.index = (state.index + (forward ? 1 : n - 1)) % n;
            showCurrent(true);
        }
    }
    return { supported: true, count: state.ranges.length, index: state.index + 1 };
    """#
}

// MARK: View

/// The find pill. Sits at the top right, in the same black island style as the address bar,
/// and moves down out of the way of the address bar and the downloads pill when they show.
struct FindIsland: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var find = FindController.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var dock = AppDock.shared

    private var topInset: CGFloat {
        var top: CGFloat = store.chromeExpanded ? 54 : 7
        if downloads.pillVisible { top += 38 }
        return top
    }

    private var visible: Bool { find.shown && !store.overviewShown }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.5))
            NativeTextField(
                text: $find.query,
                placeholder: "Find in page",
                fontSize: 13,
                textColor: .white,
                placeholderColor: NSColor.white.withAlphaComponent(0.45),
                focusToken: find.focusToken,
                onSubmit: {
                    let back = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    find.step(forward: !back)
                },
                onCancel: { find.close() }
            )
            .frame(maxWidth: .infinity)
            Text(find.status)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(find.hasMatches ? .white.opacity(0.55) : Color(red: 1, green: 0.45, blue: 0.4))
                .lineLimit(1)
                .fixedSize()
            Button { find.step(forward: false) } label: { Image(systemName: "chevron.up") }
                .disabled(!find.hasMatches)
                .help("Previous match (⇧⌘G)")
            Button { find.step(forward: true) } label: { Image(systemName: "chevron.down") }
                .disabled(!find.hasMatches)
                .help("Next match (⌘G)")
            Button { find.close() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .frame(width: 310, height: 32)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .scaleEffect(visible ? 1 : 0.5, anchor: .top)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.spring(response: 0.36, dampingFraction: 0.76), value: visible)
        .environment(\.colorScheme, .dark)
        .padding(.top, topInset)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.18), value: topInset)
        .onChange(of: store.map.activeTabID) { _ in find.pageChanged() }
        .onChange(of: dock.frontID) { _ in find.pageChanged() }
        .background {
            if let page = store.activeWebTab { FindPageWatcher(page: page) }
        }
    }
}

/// Searches again when the current page finishes loading, so the count stays true after a navigation.
private struct FindPageWatcher: View {
    @ObservedObject var page: WebTab

    var body: some View {
        Color.clear
            .onChange(of: page.isLoading) { loading in
                if !loading { FindController.shared.pageChanged() }
            }
    }
}
