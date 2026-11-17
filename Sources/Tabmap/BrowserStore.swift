import AppKit
import SwiftUI
import WebKit
import TabMapCore

/// The single source of truth for the window: the tab map, the loaded pages, and everything the UI can do.
@MainActor
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()

    @Published private(set) var map: TabMap
    /// Tabs whose page is currently in memory.
    @Published private(set) var loadedIDs: Set<TabID> = []
    /// Bumped per tab whenever its thumbnail changes, so cards redraw.
    @Published private(set) var snapshotVersions: [TabID: Int] = [:]

    /// The map sidebar is pinned open beside the page. Otherwise it only floats in from the left edge.
    @Published var sidebarShown = UserDefaults.standard.bool(forKey: "sidebarPinned") {
        didSet {
            UserDefaults.standard.set(sidebarShown, forKey: "sidebarPinned")
            if sidebarShown { sidebarPeek = false }
            updateWindowButtons()
        }
    }
    /// The optional Safari-style tab bar along the top, showing the current row's tabs (TabBar.swift).
    @Published var tabBarShown = UserDefaults.standard.bool(forKey: "tabBarShown") {
        didSet {
            UserDefaults.standard.set(tabBarShown, forKey: "tabBarShown")
            if tabBarShown { chromeHover = false }
            // The dropdown hangs from whichever back button is showing; switching bars shuts it.
            if historyMenuShown { historyMenuShown = false }
            updateWindowButtons()
        }
    }
    @Published var overviewShown = false {
        didSet {
            updateWindowButtons()
            if overviewShown != oldValue { GestureNavigator.shared.overviewFlagChanged(overviewShown) }
        }
    }
    /// The pointer is at the top edge of the window, so the island shows in full.
    @Published var chromeHover = false {
        didSet {
            guard chromeHover != oldValue else { return }
            updateWindowButtons()
            if chromeHover { watchPointer() }
        }
    }
    /// The branching history is dropping down from the back button. Keeps the island open
    /// (unless the tab bar is on, when it drops from the bar's back button instead).
    @Published var historyMenuShown = false { didSet { updateWindowButtons() } }
    /// The address field is being edited.
    @Published var addressEditing = false {
        didSet {
            guard addressEditing != oldValue else { return }
            // Leaving the field without submitting puts the real address back.
            if !addressEditing { syncAddress() }
            updateWindowButtons()
        }
    }
    /// The pointer is at the left edge of the window, so the map sidebar floats in over the page.
    @Published var sidebarPeek = false {
        didSet { if sidebarPeek && !oldValue { watchPointer() } }
    }
    @Published var overviewQuery = ""
    @Published var overviewSelection: TabID?
    @Published var addressText = ""
    /// Incremented to ask the toolbar to focus the address field.
    @Published var addressFocusRequest = 0

    let favicons = FaviconStore()
    /// Names rows of the map (on-device model, or page titles as a fallback).
    let trailNamer = TrailNamer()
    /// Offers to join rows that are about the same thing.
    let mergeAdvisor = MergeAdvisor()
    private var labelTask: Task<Void, Never>?
    private var labelling = false
    private var labelAgain = false
    private let persistence = Persistence()
    private var webTabs: [TabID: WebTab] = [:]
    private var dwellTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var sweepTimer: Timer?
    private var monitors: [Any] = []
    private(set) weak var window: NSWindow?
    private var pointerWatch: Task<Void, Never>?

    /// How long a tab must stay in front before it counts as used and its row rises.
    /// Short enough to feel immediate, long enough that stepping past a tab leaves the map alone.
    private let dwell: TimeInterval = 1.5

    private init() {
        map = persistence.loadMap()
        age()
        if let active = map.activeTabID {
            if map.tab(active)?.isBlank == false { ensureLoaded(active) }
            map.touch(active, now: Date())
        }
        syncAddress()
        scheduleLabelling()

        sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in BrowserStore.shared.age() }
        }
        addMonitor(.keyDown) { $0.handleOverviewKey($1) }
        addMonitor([.mouseMoved, .leftMouseDragged]) { $0.handleMouseMoved($1) }
        addMonitor(.magnify) { _, event in GestureNavigator.shared.handleMagnify(event) }
        addMonitor(.scrollWheel) { _, event in GestureNavigator.shared.handleScroll(event) }
        addMonitor(.swipe) { _, event in GestureNavigator.shared.handleSwipe(event) }
        mergeAdvisor.store = self
        mergeAdvisor.mapChanged()
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (BrowserStore, NSEvent) -> NSEvent?) {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return handler(self, event)
        }
        if let monitor { monitors.append(monitor) }
    }

    // MARK: Window

    /// Called once the SwiftUI window exists: lets the page fill it, title bar included.
    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        SplitMapSupport.install()
        window.acceptsMouseMovedEvents = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Not movable by its background: a mouse-down on the map would move the window instead of
        // starting a tab drag. `WindowDragArea` strips at the top move it instead.
        window.isMovableByWindowBackground = false
        updateWindowButtons()
        AppDock.shared.start(window: window)
        TabBarChrome.shared.attach(window)
        BookmarkStore.shared.start(window: window)
    }

    /// The island shows in full: the pointer is at the top, the address is being edited, or there is no page.
    var chromeExpanded: Bool {
        if chromeHover || addressEditing || (historyMenuShown && !tabBarShown) { return true }
        // A dock app in front always has a page, whatever the map's own tab is.
        if AppDock.shared.isFront { return false }
        return map.activeTab == nil || map.activeTab?.isBlank == true
    }

    /// Close, minimise and zoom only show while some chrome is showing.
    private func updateWindowButtons() {
        guard let window else { return }
        let shown = chromeExpanded || sidebarShown || overviewShown || tabBarShown
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = !shown
        }
    }

    // MARK: Derived state

    var activeWebTab: WebTab? {
        guard let id = map.activeTabID else { return nil }
        return webTabs[id]
    }

    var windowTitle: String {
        map.activeTab?.displayTitle ?? "Tabmap"
    }

    func isLoaded(_ id: TabID) -> Bool { loadedIDs.contains(id) }

    /// The page in memory for `id`, if any.
    func page(for id: TabID) -> WebTab? { webTabs[id] }

    func snapshot(for id: TabID) -> NSImage? { persistence.snapshot(for: id) }

    // MARK: Opening

    /// Cmd+T: a blank tab in a new row at the top of the map.
    func newTrail() {
        leaveActiveTab()
        let activation = map.openRootDiscardingBlank(now: Date())
        if let discarded = activation { dropPage(discarded, forget: true) }
        overviewShown = false
        syncAddress()
        addressFocusRequest += 1
        scheduleSave()
    }

    /// A blank tab to the right of the current one, in the same row.
    func newTabInTrail() {
        guard let active = map.activeTabID, map.activeTab?.isBlank == false else { newTrail(); return }
        leaveActiveTab()
        if map.openChild(of: active, url: nil, now: Date(), activate: true) != nil {
            overviewShown = false
            syncAddress()
            addressFocusRequest += 1
            scheduleSave()
        }
    }

    /// A link opened from `parent` (cmd-click). Lands to the parent's right.
    /// When the page is already in the map: with `activate`, go to it instead; in the background,
    /// skip the copy only if the page is already open in this row.
    func openChild(of parent: TabID, url: URL, activate: Bool) {
        if jumpToDuplicates {
            if activate, let existing = map.duplicate(of: url, from: parent) {
                choose(existing)
                return
            }
            if !activate, map.duplicate(of: url, from: parent, scope: .openTabsInTrail) != nil { return }
        }
        guard let id = map.openChild(of: parent, url: url, now: Date(), activate: false) else { return }
        ensureLoaded(id)
        if activate { self.activate(id, commit: true) }
        scheduleSave()
    }

    /// A window the page itself asked for (target=_blank, window.open). WebKit needs the web view back.
    func adoptPopup(from parent: TabID, configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        let placeholder = url ?? URL(string: "about:blank")
        guard let id = map.openChild(of: parent, url: placeholder, now: Date(), activate: false) else { return nil }
        let page = WebTab(id: id, store: self, configuration: configuration)
        webTabs[id] = page
        loadedIDs.insert(id)
        activate(id, commit: true)
        return page.webView
    }

    /// Return in the address field.
    func submitAddress() {
        guard let url = AddressInterpreter.url(from: addressText, searchTemplate: map.settings.searchTemplate) else { return }
        // Option+Return opens the page even if it is already in the map.
        let copy = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        open(url, allowDuplicate: copy)
    }

    static let jumpToDuplicatesKey = "jumpToDuplicates"

    /// Opening a page that is already in the map goes to that tab. Off means always open a copy.
    var jumpToDuplicates: Bool {
        UserDefaults.standard.object(forKey: Self.jumpToDuplicatesKey) as? Bool ?? true
    }

    /// A deliberate copy of the current tab, to its right.
    func duplicateActiveTab() {
        guard let active = map.activeTabID, let url = map.activeTab?.url, map.activeTab?.isBlank == false else { return }
        leaveActiveTab()
        guard let id = map.openChild(of: active, url: url, now: Date(), activate: false) else { return }
        ensureLoaded(id)
        activate(id, commit: true)
        scheduleSave()
    }

    /// Loads `url` in the current tab, or in a new row when there is no current tab.
    func open(_ url: URL, allowDuplicate: Bool = false) {
        if !allowDuplicate, jumpToDuplicates,
           let existing = map.duplicate(of: url, from: AppDock.shared.isFront ? nil : map.activeTabID) {
            // Going there from a blank tab discards the blank, so nothing is left behind.
            choose(existing)
            return
        }
        let now = Date()
        let id: TabID
        if AppDock.shared.isFront {
            // An address typed over a dock app starts a new trail; it never replaces the hidden map tab.
            leaveActiveTab()
            id = map.openRoot(url: url, now: now, activate: true)
            AppDock.shared.sendToBack()
        } else if let active = map.activeTabID {
            id = active
            map.update(id, url: url, title: "")
        } else {
            id = map.openRoot(url: url, now: now, activate: true)
        }
        let page = ensureLoaded(id, loadStoredPage: false)
        page?.load(url)
        map.touch(id, now: now)
        dwellTask?.cancel()
        syncAddress()
        focusPage()
        scheduleSave()
    }

    /// A link another app handed to Tabmap (Claude, Slack, Mail...). It starts a new row at the top of the
    /// map and remembers which app sent it, for the icon on the tab and for search.
    func openFromApp(_ url: URL, app: SourceApp?) {
        leaveActiveTab()
        AppDock.shared.sendToBack()
        let now = Date()
        let opened = map.openFromApp(url: url, app: app, now: now)
        if let discarded = opened.discarded { dropPage(discarded, forget: true) }
        ensureLoaded(opened.id)
        dwellTask?.cancel()
        if overviewShown { GestureNavigator.shared.closeOverview(showing: opened.id) }
        syncAddress()
        focusPage()
        scheduleSave()
    }

    // MARK: Switching

    /// Makes `id` the current tab. `commit` counts it as used straight away (a deliberate pick from the map);
    /// otherwise it only counts once you have stayed on it for a moment.
    func activate(_ id: TabID, commit: Bool) {
        guard map.tab(id) != nil else { return }
        if map.activeTabID != id { leaveActiveTab() }
        let now = Date()
        let result = map.activate(id, now: now)
        if let discarded = result.discarded { dropPage(discarded, forget: true) }
        if map.tab(id)?.isBlank == false { ensureLoaded(id) }
        dwellTask?.cancel()
        if commit {
            map.touch(id, now: now)
        } else {
            dwellTask = Task { @MainActor [weak self, dwell] in
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                guard !Task.isCancelled, let self, self.map.activeTabID == id else { return }
                self.map.touch(id, now: Date())
                self.scheduleSave()
            }
        }
        syncAddress()
        scheduleSave()
    }

    /// Option+Cmd+arrows: move through the map without opening it.
    func move(_ direction: MapDirection) {
        GestureNavigator.shared.animateMove(direction)
    }

    private func leaveActiveTab() {
        guard let current = map.activeTabID else { return }
        captureSnapshot(current)
        saveSession(current)
    }

    // MARK: Closing and restoring

    func closeTab(_ id: TabID) {
        guard map.tab(id) != nil else { return }
        captureSnapshot(id)
        saveSession(id)
        let wasBlank = map.tab(id)?.isBlank == true
        let next = map.close(id, now: Date())
        dropPage(id, forget: wasBlank)
        if let next, map.tab(next)?.isBlank == false { ensureLoaded(next) }
        if overviewSelection == id { overviewSelection = map.activeTabID }
        syncAddress()
        scheduleSave()
    }

    func closeActiveTab() {
        if let id = map.activeTabID { closeTab(id) }
    }

    func reopenLastClosed() {
        leaveActiveTab()
        guard let id = map.reopenLastClosed(now: Date()) else { return }
        ensureLoaded(id)
        syncAddress()
        scheduleSave()
    }

    /// Moves a tab that was dragged in the map. Only its place changes; the page is untouched.
    func moveTab(_ id: TabID, to placement: TabPlacement) {
        var changed = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            changed = map.moveTab(id, to: placement, now: Date())
        }
        if changed { scheduleSave() }
    }

    func togglePin(_ id: TabID) {
        guard let tab = map.tab(id) else { return }
        map.setPinned(id, !tab.pinned)
        scheduleSave()
    }

    /// Removes a closed tab from the map for good.
    func forgetTab(_ id: TabID) {
        map.remove(id)
        dropPage(id, forget: true)
        syncAddress()
        scheduleSave()
    }

    // MARK: Joining rows

    /// Moves every tab of `source` to the right-hand end of `target`. Tabs keep their ids,
    /// so loaded pages, the dock and the overview selection are unaffected.
    func joinTrails(_ source: TrailID, into target: TrailID) -> MergeRecord? {
        guard let record = map.mergeTrail(source, into: target) else { return nil }
        scheduleSave()
        return record
    }

    func undoJoin(_ record: MergeRecord) -> Bool {
        guard map.undoMerge(record) else { return false }
        scheduleSave()
        return true
    }

    // MARK: Page controls

    func goBack() { frontWebView?.goBack() }
    func goForward() { frontWebView?.goForward() }
    func reload() { frontWebView?.reload() }
    func stopLoading() { frontWebView?.stopLoading() }

    func focusAddress() {
        overviewShown = false
        addressFocusRequest += 1
    }

    /// Esc in the address field: put the real address back and return to the page.
    func cancelAddress() {
        syncAddress()
        focusPage()
    }

    /// Gives keyboard focus to the page, or to nothing when there is no page.
    func focusPage() {
        // Wait a beat so the web view is in the window before it takes focus.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let webView = self.frontWebView, let window = webView.window {
                window.makeFirstResponder(webView)
            } else {
                self.window?.makeFirstResponder(nil)
            }
        }
    }

    // MARK: Map overview

    func toggleOverview() { GestureNavigator.shared.toggleOverview() }

    /// Gets the overview ready to be shown: a fresh thumbnail of the current page, no search, current tab selected.
    func prepareOverview() {
        if let active = map.activeTabID { captureSnapshot(active) }
        overviewQuery = ""
        overviewSelection = map.activeTabID ?? map.layout().open.first?.tabs.first?.id
    }

    /// Pick a tab in the map (sidebar or overview).
    func choose(_ id: TabID) {
        // Picking the tab that is already current would not tell the dock by itself.
        AppDock.shared.sendToBack()
        let fromOverview = overviewShown
        activate(id, commit: true)
        if fromOverview { GestureNavigator.shared.closeOverview(showing: id) }
        focusPage()
    }

    /// Go to a page picked from a tab's history tree.
    func openHistoryNode(_ node: Int, in id: TabID) {
        guard map.tab(id) != nil else { return }
        AppDock.shared.sendToBack()
        let fromOverview = overviewShown
        activate(id, commit: true)
        guard let page = ensureLoaded(id) else { return }
        HistoryStore.shared.jump(to: node, tab: id, webView: page.webView)
        if fromOverview { GestureNavigator.shared.closeOverview(showing: id) }
        focusPage()
    }

    private func overviewRows() -> [[TabID]] {
        let layout = mapLayout(matching: overviewQuery)
        // Only the tabs the rows draw: closed tabs behind a row's "+N" button are skipped.
        let open = layout.open.map { trail -> [TabID] in
            let parts = TrailRow.parts(of: trail, archived: false)
            return (parts.leading + parts.closed).map(\.id)
        }
        return open + layout.archived.map { $0.tabs.map(\.id) }
    }

    func overviewQueryChanged() {
        let rows = overviewRows()
        if let selection = overviewSelection, rows.contains(where: { $0.contains(selection) }) { return }
        overviewSelection = rows.first?.first
    }

    private func handleOverviewKey(_ event: NSEvent) -> NSEvent? {
        guard overviewShown, !BookmarkStore.shared.boardShown else { return event }
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: // escape
            GestureNavigator.shared.closeOverview(showing: map.activeTabID)
            return nil
        case 36, 76: // return, enter
            if let selection = overviewSelection { choose(selection) }
            return nil
        case 126:
            overviewSelection = GridNav.move(from: overviewSelection, .up, in: overviewRows())
            return nil
        case 125:
            overviewSelection = GridNav.move(from: overviewSelection, .down, in: overviewRows())
            return nil
        case 123 where overviewQuery.isEmpty && !command:
            overviewSelection = GridNav.move(from: overviewSelection, .left, in: overviewRows())
            return nil
        case 124 where overviewQuery.isEmpty && !command:
            overviewSelection = GridNav.move(from: overviewSelection, .right, in: overviewRows())
            return nil
        case 51 where command: // cmd-delete closes the selected tab
            if let selection = overviewSelection, map.tab(selection)?.isClosed == false {
                let rows = overviewRows()
                let fallback = GridNav.move(from: selection, .right, in: rows)
                closeTab(selection)
                overviewSelection = fallback
            }
            return nil
        default:
            return event
        }
    }

    // MARK: Pointer

    /// Reveals the island at the top edge and the sidebar at the left edge, without covering the page.
    private func handleMouseMoved(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, let content = window.contentView else { return event }
        let point = event.locationInWindow
        if content.frame.height - point.y <= 5, !tabBarShown, !chromeHover {
            chromeHover = true
        }
        if point.x <= 3, !sidebarShown, !overviewShown, !sidebarPeek {
            sidebarPeek = true
        }
        return event
    }

    /// While the island or the floating sidebar is out, checks where the pointer is and puts them away
    /// once it has moved off them. Polling also catches the pointer leaving the window.
    private func watchPointer() {
        guard pointerWatch == nil else { return }
        pointerWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.checkPointer()
                if !self.chromeHover && !self.sidebarPeek { break }
            }
            self?.pointerWatch = nil
        }
    }

    private func checkPointer() {
        guard let window else {
            chromeHover = false
            sidebarPeek = false
            return
        }
        let point = NSEvent.mouseLocation
        let frame = window.frame
        let inside = frame.contains(point)
        if chromeHover, !inside || point.y < frame.maxY - 80 { chromeHover = false }
        if sidebarPeek, !inside || point.x > frame.minX + 300 { sidebarPeek = false }
    }

    // MARK: Settings

    func updateSettings(_ change: (inout MapSettings) -> Void) {
        var settings = map.settings
        change(&settings)
        map.settings = settings
        age()
        scheduleSave()
    }

    // MARK: Callbacks from pages

    func tabMetaChanged(_ id: TabID, url: URL?, title: String?) {
        guard let tab = map.tab(id) else { return }
        // Ignore the empty state of a page that has not committed yet.
        let newURL = (url?.absoluteString == "about:blank" && tab.url != nil) ? nil : url
        let newTitle = (title?.isEmpty == false) ? title : nil
        let urlChanged = newURL != nil && newURL != tab.url
        let titleChanged = newTitle != nil && newTitle != tab.title
        guard urlChanged || titleChanged else { return }
        map.update(id, url: newURL, title: urlChanged && newTitle == nil ? "" : newTitle)
        if urlChanged, id == map.activeTabID, !addressEditing { syncAddress() }
        scheduleSave()
    }

    func tabDidNavigate(_ id: TabID) {
        // Navigating in the tab you are looking at is use; a background tab loading is not.
        if id == map.activeTabID { map.touch(id, now: Date()) }
    }

    func tabDidFinishLoading(_ id: TabID) {
        saveSession(id)
        guard id == map.activeTabID else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, self.map.activeTabID == id else { return }
            self.captureSnapshot(id)
        }
    }

    // MARK: Pages in memory

    @discardableResult
    private func ensureLoaded(_ id: TabID, loadStoredPage: Bool = true) -> WebTab? {
        if let existing = webTabs[id] { return existing }
        guard let tab = map.tab(id) else { return nil }
        let page = WebTab(id: id, store: self, configuration: nil)
        webTabs[id] = page
        loadedIDs.insert(id)
        if loadStoredPage {
            if let session = persistence.session(for: id) {
                // Restores back/forward history and scroll position along with the page.
                page.webView.interactionState = session
            } else if let url = tab.url {
                page.load(url)
            }
        }
        return page
    }

    /// Unloads a tab's page. With `forget`, also deletes its thumbnail and session.
    private func dropPage(_ id: TabID, forget: Bool) {
        if let page = webTabs.removeValue(forKey: id) {
            page.webView.stopLoading()
            page.webView.removeFromSuperview()
        }
        loadedIDs.remove(id)
        if forget {
            persistence.forget(id)
            snapshotVersions[id] = nil
        }
    }

    private func saveSession(_ id: TabID) {
        guard let page = webTabs[id], let data = page.webView.interactionState as? Data else { return }
        persistence.saveSession(data, for: id)
    }

    private func captureSnapshot(_ id: TabID) {
        guard let page = webTabs[id], page.webView.window != nil, page.webView.bounds.width > 10 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 480)
        page.webView.takeSnapshot(with: config) { image, _ in
            guard let image else { return }
            Task { @MainActor in
                let store = BrowserStore.shared
                guard store.map.tab(id) != nil else { return }
                store.persistence.saveSnapshot(image, for: id)
                store.snapshotVersions[id, default: 0] += 1
            }
        }
    }

    // MARK: Ageing

    /// Runs every minute: closes tabs that are too old, forgets ones that are older still,
    /// and unloads pages that have been idle.
    private func age() {
        let now = Date()
        map.pruneSplits()
        // The other half of a split is in use for as long as it is on screen.
        for id in map.onScreen where id != map.activeTabID { map.touch(id, now: now) }
        let result = map.sweep(now: now)
        for id in result.closed {
            saveSession(id)
            dropPage(id, forget: false)
        }
        for id in result.purged { dropPage(id, forget: true) }

        for id in map.tabsToSleep(loaded: Array(webTabs.keys), now: now) {
            sleepUnlessPlaying(id)
        }
        if !result.isEmpty { scheduleSave() }
    }

    /// Puts a page to sleep unless it is playing audio or video right now.
    private func sleepUnlessPlaying(_ id: TabID) {
        guard let page = webTabs[id] else { return }
        let script = "Array.from(document.querySelectorAll('audio,video')).some(function(m){return !m.paused && !m.ended})"
        page.webView.evaluateJavaScript(script) { result, _ in
            let playing = (result as? Bool) ?? false
            Task { @MainActor in
                let store = BrowserStore.shared
                guard !playing, id != store.map.activeTabID, store.webTabs[id] != nil else { return }
                store.saveSession(id)
                store.dropPage(id, forget: false)
            }
        }
    }

    // MARK: Split view

    var activeSplit: SplitPair? { map.split(containing: map.activeTabID) }

    /// Shows two neighbouring tabs side by side, with `a` as the current one.
    func splitTabs(_ a: TabID, with b: TabID) {
        guard map.canSplit(a, b) else { return }
        map.split(a, with: b)
        choose(a)
        scheduleSave()
    }

    /// Ends the split `id` is in. Both tabs stay open; `keep` becomes the current one if given.
    func unsplit(_ id: TabID, keep: TabID? = nil) {
        guard let pair = map.split(containing: id) else { return }
        map.unsplit(id)
        if let keep, pair.contains(keep), pair.contains(map.activeTabID), map.activeTabID != keep {
            activate(keep, commit: false)
        }
        syncAddress()
        scheduleSave()
    }

    func setSplitFraction(_ fraction: Double, for id: TabID) {
        map.setSplitFraction(fraction, for: id)
        scheduleSave()
    }

    /// Makes the other half of the split on screen the current tab.
    func focusPane(_ id: TabID, takeKeyboard: Bool = true) {
        guard id != map.activeTabID, map.sameScreen(id, map.activeTabID) else { return }
        activate(id, commit: false)
        if takeKeyboard { focusPage() }
    }

    /// Cmd-backslash: split the current tab with the next one (or the previous one), or end the split.
    func toggleSplit() {
        guard let active = map.activeTabID else { return }
        if map.split(containing: active) != nil {
            unsplit(active, keep: active)
            return
        }
        for direction in [MapDirection.right, .left] {
            if let other = map.neighbor(of: active, direction), map.canSplit(active, other) {
                splitTabs(active, with: other)
                return
            }
        }
    }

    /// Both halves of a split need their page in memory.
    private func syncScreen() {
        for id in map.onScreen where webTabs[id] == nil && map.tab(id)?.isBlank == false {
            ensureLoaded(id)
        }
    }

    // MARK: Saving

    private func syncAddress() {
        syncScreen()
        let text = frontURL.map { $0.scheme == "about" ? "" : $0.absoluteString } ?? ""
        if addressText != text { addressText = text }
        updateWindowButtons()
    }

    private func scheduleSave() {
        mergeAdvisor.mapChanged()
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistence.saveMap(self.map)
        }
        scheduleLabelling()
    }

    // MARK: Row names

    /// Names rows that have changed, about 3 seconds after things settle. Never runs twice at once:
    /// a request during a run queues one more pass for afterwards.
    private func scheduleLabelling() {
        if labelling { labelAgain = true; return }
        labelTask?.cancel()
        labelTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runLabelling()
        }
    }

    private func runLabelling() async {
        labelling = true
        if map.clearStaleLabels() { scheduleSave() }
        for trail in map.trailsNeedingLabels().prefix(5) {
            let signature = trail.contentSignature
            let label = await trailNamer.label(for: trail)
            applyLabel(trailID: trail.id, name: label.name, summary: label.summary, signature: signature)
        }
        labelling = false
        // Applying a label saves, which asks for another pass; that pass finds nothing left
        // (label fields are not part of a row's signature) unless more rows are waiting.
        if labelAgain {
            labelAgain = false
            scheduleLabelling()
        }
    }

    /// Stores a row's name only if the row still holds the pages it was made for.
    func applyLabel(trailID: TrailID, name: String, summary: String, signature: String) {
        guard map.setLabel(trail: trailID, name: name, summary: summary, signature: signature) else { return }
        scheduleSave()
    }

    /// Called when the app quits.
    func persistEverything() {
        saveTask?.cancel()
        for id in webTabs.keys { saveSession(id) }
        persistence.saveMap(map)
        AppDock.shared.saveNow()
        HistoryStore.shared.saveNow()
        BookmarkStore.shared.saveNow()
    }

    // MARK: App dock

    /// The page in front: a dock app or its top peek when one is showing, otherwise the map's tab.
    var frontWebView: WKWebView? { AppDock.shared.frontWebView ?? activeWebTab?.webView }

    /// The address of whatever is in front.
    var frontURL: URL? {
        if let page = AppDock.shared.frontPage { return page.url }
        return map.activeTab?.url
    }

    /// The dock changed what is in front.
    func dockChanged() {
        if !addressEditing { syncAddress() } else { updateWindowButtons() }
    }

    /// A page that already exists (a promoted peek, an app leaving the dock) becomes a new trail.
    func adoptPage(_ webView: WKWebView, url: URL?, title: String) {
        leaveActiveTab()
        let now = Date()
        let previous = map.activeTabID
        let wasBlank = map.activeTab?.isBlank == true
        let id = map.openRoot(url: url ?? URL(string: "about:blank"), title: title, now: now, activate: true)
        if wasBlank, let previous { dropPage(previous, forget: true) }
        webTabs[id] = WebTab(id: id, store: self, configuration: nil, adopting: webView)
        loadedIDs.insert(id)
        map.touch(id, now: now)
        dwellTask?.cancel()
        if overviewShown { overviewShown = false }
        AppDock.shared.sendToBack()
        syncAddress()
        focusPage()
        scheduleSave()
    }

    /// Takes a tab out of the map for the dock, handing over its page if it is loaded.
    func releaseForDock(_ id: TabID) -> (tab: MapTab, webView: WKWebView?)? {
        guard let tab = map.tab(id), !tab.isBlank, !tab.isClosed else { return nil }
        let webView = webTabs.removeValue(forKey: id)?.release()
        loadedIDs.remove(id)
        let next = map.close(id, now: Date())
        map.remove(id)
        persistence.forget(id)
        snapshotVersions[id] = nil
        if let next, map.tab(next)?.isBlank == false { ensureLoaded(next) }
        syncAddress()
        scheduleSave()
        return (tab, webView)
    }
}

private extension TabMap {
    /// Opens a blank root tab and returns the blank tab that was discarded by leaving it, if any.
    mutating func openRootDiscardingBlank(now: Date) -> TabID? {
        let previous = activeTabID
        let wasBlank = activeTab?.isBlank == true
        openRoot(url: nil, now: now, activate: true)
        return wasBlank ? previous : nil
    }
}

// MARK: Bookmarks

extension BrowserStore {
    /// Opens pages as a new row at the top of the map, left to right, and shows the first.
    /// The others load when you go to them.
    func openTrail(_ urls: [URL]) {
        guard let first = urls.first else { return }
        AppDock.shared.sendToBack()
        leaveActiveTab()
        let now = Date()
        let previous = map.activeTabID
        let wasBlank = map.activeTab?.isBlank == true
        let root = map.openRoot(url: first, now: now, activate: true)
        if wasBlank, let previous, previous != root { dropPage(previous, forget: true) }
        var parent = root
        for url in urls.dropFirst() {
            if let id = map.openChild(of: parent, url: url, now: now, activate: false) { parent = id }
        }
        ensureLoaded(root)
        map.touch(root, now: now)
        dwellTask?.cancel()
        if overviewShown { overviewShown = false }
        syncAddress()
        focusPage()
        scheduleSave()
    }
}
