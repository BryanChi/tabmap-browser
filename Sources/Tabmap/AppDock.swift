import AppKit
import Combine
import SwiftUI
import WebKit
import TabMapCore

// Goes in Sources/Tabmap. Dock apps live outside the tab map: always loaded, never aged out.
// A link that leaves an app opens on top of it as a "peek" and only becomes a map tab when promoted.

/// One page owned by the dock: an app itself, or a peek opened from it.
@MainActor
final class DockPage: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    enum Role: Equatable {
        case app
        /// A link opened on top of the app with this id.
        case peek(of: TabID)
    }

    let id: TabID
    let role: Role
    let webView: WKWebView

    @Published var title = ""
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false

    private var observations: [NSKeyValueObservation] = []
    private var dock: AppDock { AppDock.shared }

    /// `configuration` is supplied by WebKit when a page opens a new window; it must be used as given.
    /// `adopting` takes over a web view that already exists (a map tab moving into the dock).
    init(id: TabID = TabID(), role: Role, configuration: WKWebViewConfiguration? = nil, adopting: WKWebView? = nil) {
        self.id = id
        self.role = role
        self.webView = adopting ?? WKWebView(frame: .zero, configuration: configuration ?? WebTab.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observations = [
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor [weak self] in self?.sync() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor [weak self] in self?.sync() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor [weak self] in self?.sync() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor [weak self] in self?.sync() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor [weak self] in self?.sync() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor [weak self] in self?.sync() } },
        ]
        sync()
    }

    var appID: TabID {
        if case .peek(let app) = role { return app }
        return id
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url?.host ?? "Loading"
    }

    func load(_ url: URL) {
        self.url = url
        webView.load(URLRequest(url: url))
    }

    /// Lets go of the web view so a map tab can take it over. The page object is dead afterwards.
    func release() -> WKWebView {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        return webView
    }

    func shutDown() {
        let view = release()
        view.stopLoading()
    }

    private func sync() {
        let newTitle = webView.title ?? ""
        if title != newTitle, !newTitle.isEmpty || webView.url != url { title = newTitle }
        if let newURL = webView.url, newURL.absoluteString != "about:blank", url != newURL { url = newURL }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if progress != webView.estimatedProgress { progress = webView.estimatedProgress }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
        if role == .app { dock.appPageChanged(self) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let link = navigationAction.request.url else { return .allow }

        let scheme = (link.scheme ?? "").lowercased()
        let inApp: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
        if !scheme.isEmpty, !inApp.contains(scheme) {
            NSWorkspace.shared.open(link)
            return .cancel
        }

        guard navigationAction.navigationType == .linkActivated else { return .allow }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true

        // Cmd-click always opens on top, from an app or from a peek.
        if navigationAction.modifierFlags.contains(.command) {
            dock.openPeek(over: appID, url: link)
            return .cancel
        }
        // A plain click in an app that leads somewhere else opens on top instead of replacing the app.
        if role == .app, mainFrame, let home = dock.shelf.app(id)?.home, SiteMatch.leavesApp(home: home, link: link) {
            dock.openPeek(over: id, url: link)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: WKUIDelegate

    /// target=_blank and window.open: the new page opens on top of the app.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        dock.adoptPeek(over: appID, configuration: configuration, url: navigationAction.request.url)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if role != .app { dock.closePeek(id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

/// The dock: which apps exist, which one is in front of the map, and the peeks stacked on each.
@MainActor
final class AppDock: ObservableObject {
    static let shared = AppDock()

    @Published private(set) var shelf = AppShelf()
    /// The app shown in front of the map, or nil while the map's own tab is showing.
    @Published private(set) var frontID: TabID?
    /// Peeks stacked on each app, oldest first. The last one is on top.
    @Published private(set) var peeks: [TabID: [DockPage]] = [:]
    /// The floating dock at the bottom edge of the window.
    @Published var pillShown = false

    private var pages: [TabID: DockPage] = [:]
    private var monitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var saveTask: Task<Void, Never>?
    private var pillWatch: Task<Void, Never>?
    private weak var window: NSWindow?
    private var started = false

    private var store: BrowserStore { BrowserStore.shared }

    private let fileURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("Tabmap", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("apps.json")
    }()

    /// Must not touch BrowserStore: the two singletons would otherwise build each other.
    private init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(AppShelf.self, from: data) {
            shelf = saved
        }
    }

    /// Called once the window exists (from BrowserStore.attach).
    func start(window: NSWindow) {
        self.window = window
        guard !started else { return }
        started = true

        // Apps stay warm: load every one now, and keep them loaded.
        for app in shelf.apps { ensurePage(app) }

        // Anything that changes the map's current tab means the user went back to the map.
        store.$map
            .map(\.activeTabID)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.sendToBack() }
            .store(in: &subscriptions)
        // The full map is drawn underneath the pages, so an app in front would hide it.
        store.$overviewShown
            .filter { $0 }
            .sink { [weak self] _ in self?.sendToBack() }
            .store(in: &subscriptions)

        addMonitor(.keyDown) { dock, event in dock.handleKey(event) }
        addMonitor([.mouseMoved, .leftMouseDragged]) { dock, event in
            dock.handlePointerMoved(event)
            return event
        }
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (AppDock, NSEvent) -> NSEvent?) {
        let token = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return handler(self, event)
        }
        if let token { monitors.append(token) }
    }

    // MARK: Derived state

    var isFront: Bool { frontID != nil }
    var frontApp: DockApp? { shelf.app(frontID) }

    func page(_ id: TabID) -> DockPage? { pages[id] }

    func peekStack(_ appID: TabID?) -> [DockPage] {
        guard let appID else { return [] }
        return peeks[appID] ?? []
    }

    var topPeek: DockPage? { peekStack(frontID).last }

    /// The page the user is looking at when an app is in front: its top peek, or the app itself.
    var frontPage: DockPage? {
        guard let frontID else { return nil }
        return topPeek ?? pages[frontID]
    }

    var frontWebView: WKWebView? { frontPage?.webView }

    // MARK: Apps

    @discardableResult
    private func ensurePage(_ app: DockApp) -> DockPage {
        if let page = pages[app.id] { return page }
        let page = DockPage(id: app.id, role: .app)
        pages[app.id] = page
        page.load(app.url)
        return page
    }

    /// Adds a site to the dock. `webView` hands over a page that is already loaded.
    @discardableResult
    func addApp(home: URL, title: String, webView: WKWebView? = nil, show: Bool) -> TabID {
        let app = shelf.add(home: home, title: title, now: Date())
        if let webView {
            let page = DockPage(id: app.id, role: .app, adopting: webView)
            pages[app.id] = page
        } else {
            ensurePage(app)
        }
        scheduleSave()
        if show { self.show(app.id) }
        return app.id
    }

    /// ⇧⌘P on a map tab: the tab leaves the map and becomes an app.
    func keepCurrentTabInDock() {
        guard !isFront, let id = store.map.activeTabID,
              let released = store.releaseForDock(id), let url = released.tab.url else { return }
        addApp(home: url, title: released.tab.title, webView: released.webView, show: true)
    }

    /// ⇧⌘P: a map tab moves into the dock; an app in front moves back into the map.
    func toggleDockForFront() {
        if let frontID { removeApp(frontID) } else { keepCurrentTabInDock() }
    }

    /// Takes an app out of the dock and puts its page back in the map as a new trail.
    func removeApp(_ id: TabID, keepAsTab: Bool = true) {
        guard shelf.app(id) != nil else { return }
        for peek in peeks[id] ?? [] { peek.shutDown() }
        peeks[id] = nil
        let page = pages.removeValue(forKey: id)
        shelf.remove(id)
        if frontID == id { frontID = nil }
        scheduleSave()
        if let page {
            if keepAsTab {
                let url = page.url, title = page.title
                store.adoptPage(page.release(), url: url, title: title)
            } else {
                page.shutDown()
            }
        }
        store.dockChanged()
    }

    func moveApp(_ id: TabID, by offset: Int) {
        shelf.move(id, by: offset)
        scheduleSave()
    }

    func goHome(_ id: TabID) {
        guard let app = shelf.app(id) else { return }
        pages[id]?.load(app.home)
    }

    func reload(_ id: TabID) {
        pages[id]?.webView.reload()
    }

    func appPageChanged(_ page: DockPage) {
        if shelf.update(page.id, url: page.url, title: page.title) { scheduleSave() }
        if page.id == frontID, topPeek == nil { store.dockChanged() }
    }

    // MARK: Front and back

    /// Brings an app in front of the map. Asking for the app already in front goes back to the map.
    func show(_ id: TabID) {
        guard let app = shelf.app(id) else { return }
        if frontID == id {
            sendToBack()
            return
        }
        ensurePage(app)
        if store.overviewShown { store.overviewShown = false }
        frontID = id
        store.dockChanged()
        focusFront()
    }

    func showApp(atShortcut number: Int) -> Bool {
        guard let app = shelf.app(atShortcut: number) else { return false }
        show(app.id)
        return true
    }

    /// Back to the map. The app and its peeks stay loaded behind the scenes.
    func sendToBack() {
        guard frontID != nil else { return }
        frontID = nil
        store.dockChanged()
    }

    private func focusFront() {
        let webView = frontWebView
        Task { @MainActor in
            if let webView, webView.window != nil { webView.window?.makeFirstResponder(webView) }
        }
    }

    // MARK: Peeks

    func openPeek(over appID: TabID, url: URL) {
        guard shelf.app(appID) != nil else { return }
        let peek = DockPage(role: .peek(of: appID))
        peek.load(url)
        peeks[appID, default: []].append(peek)
        peekStackChanged()
    }

    /// A window the page itself asked for. WebKit needs the web view back.
    func adoptPeek(over appID: TabID, configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        guard shelf.app(appID) != nil else { return nil }
        let peek = DockPage(role: .peek(of: appID), configuration: configuration)
        peek.url = url
        peeks[appID, default: []].append(peek)
        peekStackChanged()
        return peek.webView
    }

    private func takePeek(_ id: TabID) -> DockPage? {
        for (appID, stack) in peeks {
            if let i = stack.firstIndex(where: { $0.id == id }) {
                var stack = stack
                let peek = stack.remove(at: i)
                peeks[appID] = stack.isEmpty ? nil : stack
                return peek
            }
        }
        return nil
    }

    func closePeek(_ id: TabID) {
        takePeek(id)?.shutDown()
        peekStackChanged()
    }

    func closeTopPeek() {
        if let top = topPeek { closePeek(top.id) }
    }

    /// Closes every peek above `id`, leaving it on top.
    func popToPeek(_ id: TabID) {
        guard let frontID, var stack = peeks[frontID], let i = stack.firstIndex(where: { $0.id == id }) else { return }
        for peek in stack[(i + 1)...] { peek.shutDown() }
        stack.removeSubrange((i + 1)...)
        peeks[frontID] = stack
        peekStackChanged()
    }

    /// Turns a peek into a real tab: it leaves the app and starts a new trail at the top of the map.
    func promote(_ id: TabID) {
        guard let peek = takePeek(id) else { return }
        let url = peek.url, title = peek.title
        // Adopting changes the map's current tab, which sends the app to the back.
        store.adoptPage(peek.release(), url: url, title: title)
    }

    func promoteTopPeek() {
        if let top = topPeek { promote(top.id) }
    }

    private func peekStackChanged() {
        store.dockChanged()
        focusFront()
    }

    // MARK: Keys

    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // ⌘1 to ⌘9 switch to an app from anywhere.
        if flags == .command, let number = Self.digitKeys[event.keyCode] {
            return showApp(atShortcut: number) ? nil : event
        }
        guard isFront else { return event }

        switch event.keyCode {
        case 53 where flags.isEmpty && !store.addressEditing: // escape closes the top peek
            guard topPeek != nil else { return event }
            closeTopPeek()
            return nil
        case 36 where flags == .command, 76 where flags == .command: // cmd-return opens the peek as a tab
            guard topPeek != nil else { return event }
            promoteTopPeek()
            return nil
        case 13 where flags == .command: // cmd-w closes the peek, or leaves the app. It never closes the app.
            if topPeek != nil { closeTopPeek() } else { sendToBack() }
            return nil
        default:
            return event
        }
    }

    // MARK: Pointer and gestures

    /// The floating dock appears when the pointer reaches the bottom edge of the window.
    private func handlePointerMoved(_ event: NSEvent) {
        guard !pillShown, !shelf.apps.isEmpty, !store.overviewShown,
              let window, event.window === window, let content = window.contentView else { return }
        let p = event.locationInWindow
        guard p.x >= 0, p.x <= content.bounds.width, p.y >= 0, p.y <= 3 else { return }
        showPill()
    }

    func showPill() {
        guard !shelf.apps.isEmpty else { return }
        pillShown = true
        guard pillWatch == nil else { return }
        pillWatch = Task { @MainActor [weak self] in
            // Give a swipe a moment before the pointer has to be near the dock.
            try? await Task.sleep(nanoseconds: 900_000_000)
            while true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                guard self.pillShown, let window = self.window else { break }
                let mouse = NSEvent.mouseLocation
                let frame = window.frame
                if !frame.contains(mouse) || mouse.y - frame.minY > 110 { break }
            }
            self?.pillShown = false
            self?.pillWatch = nil
        }
    }

    private static let bottomStrip: CGFloat = 14
    private var swipeClaimed = false
    private var swipeMomentum = false
    private var swipeTotal: CGFloat = 0

    /// Two-finger swipe up that starts in the strip along the bottom edge shows the dock; swiping down hides it.
    /// Returns true when the event belongs to the dock and nothing else should see it.
    func handleScroll(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !shelf.apps.isEmpty, !store.overviewShown else { return false }

        if !event.momentumPhase.isEmpty {
            guard swipeMomentum else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swipeMomentum = false }
            return true
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipeMomentum = false
            swipeTotal = 0
            let p = event.locationInWindow
            let width = window.contentView?.bounds.width ?? 0
            swipeClaimed = p.y >= 0 && p.y <= Self.bottomStrip && p.x >= 0 && p.x <= width
            return swipeClaimed
        }
        guard swipeClaimed else { return false }

        // Negative means the fingers moved up, whichever scroll direction the user has chosen.
        let flip: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipeTotal += event.scrollingDeltaY * flip
        if swipeTotal < -24, !pillShown { showPill() }
        if swipeTotal > 24, pillShown { pillShown = false }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipeClaimed = false
            swipeMomentum = true
        }
        return true
    }

    private var pinchTotal: CGFloat = 0
    private var pinchFired = false
    private var pinchClaimed = false
    /// A pinch on an app with nothing on top: watched, not swallowed, so the page can still zoom in.
    private var pinchWatching = false

    /// With a peek on top: pinch out opens it as a tab, pinch in closes it.
    /// With only the app in front: pinch in goes back to the map and opens the full map, as on any tab.
    /// Returns true when the event belongs to the dock.
    func handleMagnify(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        if event.phase.contains(.began) {
            pinchTotal = 0
            pinchFired = false
            // A zoomed-in page keeps ordinary pinch zooming.
            let zoomed = (frontWebView?.magnification ?? 1) > 1.001
            pinchClaimed = isFront && topPeek != nil && !zoomed
            pinchWatching = isFront && topPeek == nil && !zoomed
        }
        if pinchWatching {
            // Once the map has opened, the rest of this pinch is spent.
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                pinchWatching = false
                return pinchFired
            }
            if pinchFired { return true }
            pinchTotal += event.magnification
            if pinchTotal < -0.25 {
                pinchFired = true
                sendToBack()
                GestureNavigator.shared.openOverview()
                return true
            }
            return false
        }
        guard pinchClaimed else { return false }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            pinchClaimed = false
            return true
        }
        pinchTotal += event.magnification
        guard !pinchFired, let top = topPeek else { return true }
        if pinchTotal > 0.3 {
            pinchFired = true
            promote(top.id)
        } else if pinchTotal < -0.3 {
            pinchFired = true
            closePeek(top.id)
        }
        return true
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    /// Also called when the app quits.
    func saveNow() {
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shelf) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
