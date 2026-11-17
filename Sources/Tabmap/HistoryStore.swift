import AppKit
import WebKit
import TabMapCore

/// Keeps a branching history for every tab and keeps it in step with what each page is doing.
///
/// WebKit's own back/forward list stays in charge of Back and Forward. This watches it, and
/// records every page in a tree that never drops a branch. It is saved beside the map in
/// ~/Library/Application Support/Tabmap/history.json.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var trees: [TabID: HistoryTree] = [:]

    /// Which tree page each entry of a live web view's back/forward list stands for.
    private struct Link {
        weak var webView: WKWebView?
        var entries: [ObjectIdentifier: (item: WKBackForwardListItem, node: Int)] = [:]
    }
    /// A page the tree asked the web view to load, waiting for the load to land.
    private struct PendingJump {
        var node: Int
        var url: URL
        var at: Date
    }

    private var links: [TabID: Link] = [:]
    private var pending: [TabID: PendingJump] = [:]
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("Tabmap", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: HistoryTree].self, from: data) {
            for (key, tree) in saved {
                if let id = TabID(uuidString: key) { trees[id] = tree }
            }
        }
    }

    func tree(for id: TabID) -> HistoryTree? { trees[id] }

    // MARK: Following the page

    /// Call whenever a page may have moved: on commit, and when its address or title changes.
    /// Calling it too often is harmless.
    func sync(tab: TabID, webView: WKWebView) {
        let list = webView.backForwardList
        guard let item = list.currentItem else { return }
        let url = item.url
        // The blank page a new window starts on is not somewhere you have been.
        if url.scheme == "about" { return }

        var link = links[tab] ?? Link(webView: webView)
        if link.webView !== webView { link = Link(webView: webView) }
        var tree = trees[tab] ?? HistoryTree()
        let before = tree
        let now = Date()
        // The page title belongs to this entry only once the page itself has caught up with it.
        let title = (webView.url == url ? webView.title : nil) ?? item.title ?? ""
        let key = ObjectIdentifier(item)

        if let known = link.entries[key], known.item === item, tree.node(known.node) != nil {
            // Back, forward, or the same page again.
            if tree.currentID != known.node { tree.move(to: known.node, now: now) }
            tree.update(known.node, url: url, title: title)
            if pending[tab]?.node == known.node { pending[tab] = nil }
        } else if let jump = pending[tab], now.timeIntervalSince(jump.at) < 30, tree.node(jump.node) != nil,
                  jump.url == url || jump.url == item.initialURL {
            // A page picked from the tree has arrived: this is that page, not a new one.
            tree.move(to: jump.node, now: now)
            tree.update(jump.node, url: url, title: title)
            link.entries[key] = (item, jump.node)
            pending[tab] = nil
        } else if tree.isEmpty {
            // First sight of a tab that already has history: take it over as one straight line.
            for back in list.backList where back.url.scheme != "about" {
                link.entries[ObjectIdentifier(back)] = (back, tree.visit(url: back.url, title: back.title ?? "", now: now))
            }
            let here = tree.visit(url: url, title: title, now: now)
            link.entries[key] = (item, here)
            for forward in list.forwardList where forward.url.scheme != "about" {
                link.entries[ObjectIdentifier(forward)] = (forward, tree.visit(url: forward.url, title: forward.title ?? "", now: now))
            }
            tree.move(to: here, now: now)
        } else if link.entries.isEmpty, let current = tree.current, current.url == url {
            // A sleeping page woke up where it left off. Line its list up with the tree again.
            link.entries[key] = (item, current.id)
            tree.update(current.id, title: title)
            for (back, node) in zip(list.backList.reversed(), tree.ancestors(of: current.id)) {
                guard tree.node(node)?.url == back.url else { break }
                link.entries[ObjectIdentifier(back)] = (back, node)
            }
            for (forward, node) in zip(list.forwardList, tree.forwardChain(from: current.id)) {
                guard tree.node(node)?.url == forward.url else { break }
                link.entries[ObjectIdentifier(forward)] = (forward, node)
            }
        } else {
            // A new page, reached from wherever the tab was.
            link.entries[key] = (item, tree.visit(url: url, title: title, now: now))
        }

        // Forget entries WebKit has dropped, and pages the tree has pruned.
        var live = Set(list.backList.map { ObjectIdentifier($0) })
        live.insert(key)
        live.formUnion(list.forwardList.map { ObjectIdentifier($0) })
        link.entries = link.entries.filter { live.contains($0.key) && tree.node($0.value.node) != nil }

        links[tab] = link
        if tree != before {
            trees[tab] = tree
            scheduleSave()
        }
    }

    // MARK: Jumping

    /// Shows a page from the tab's tree in `webView`. If WebKit still has the page in its own
    /// list it simply goes there; otherwise the page is loaded again and the tree moves to it
    /// without growing a new branch.
    func jump(to node: Int, tab: TabID, webView: WKWebView) {
        guard let tree = trees[tab], let target = tree.node(node) else { return }
        let list = webView.backForwardList
        if let link = links[tab], link.webView === webView {
            if let current = list.currentItem, link.entries[ObjectIdentifier(current)]?.node == node { return }
            let reachable = list.backList + list.forwardList
            if let item = reachable.first(where: { link.entries[ObjectIdentifier($0)]?.node == node }) {
                webView.go(to: item)
                return
            }
        }
        pending[tab] = PendingJump(node: node, url: target.url, at: Date())
        webView.load(URLRequest(url: target.url))
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the histories straight away. BrowserStore.persistEverything calls this when the app quits.
    func saveNow() {
        saveTask?.cancel()
        // Histories of tabs the map has forgotten go with them.
        let map = BrowserStore.shared.map
        let gone = trees.keys.filter { map.tab($0) == nil }
        if !gone.isEmpty {
            for id in gone {
                trees[id] = nil
                links[id] = nil
                pending[id] = nil
            }
        }
        var out: [String: HistoryTree] = [:]
        for (id, tree) in trees { out[id.uuidString] = tree }
        guard let data = try? JSONEncoder().encode(out) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
