import AppKit
import SwiftUI
import TabMapCore

// The optional Safari-style tab bar (Settings, or View > Show Tab Bar). Off by default.
//
// The map has no single list of tabs, so the bar shows the current row: its open tabs, left to right.
// Moving to another row swaps the bar's contents, sliding the same way the page does.
// Tabs share the bar's width like Safari's compact tabs (see `TabBarLayout`).
//
// With the bar on:
//   - the traffic lights stay visible and sit centred in the bar (unless the map sidebar is pinned,
//     which already has room for them)
//   - the island no longer pops out at the top edge or while loading; loading shows in the tab.
//     Clicking the current tab (or ⌘L) brings the island out just below the bar to type an address
//   - the bar's empty ends drag the window; double-click zooms, like a title bar

enum TabBarStyle {
    static let height: CGFloat = 38
    static let tabHeight: CGFloat = 28
    static let corner: CGFloat = 8
    /// Room for the close, minimise and zoom buttons at the left.
    static let trafficLightRoom: CGFloat = 76
    static let metrics = TabBarLayout.Metrics(activeMinimum: 200, inactiveMinimum: 36, titleMinimum: 76)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

extension BrowserStore {
    /// The tabs the tab bar shows: the open tabs of the current row, in order.
    var tabBarRow: Trail? {
        let id = map.activeTabID ?? overviewSelection
        guard let id, let place = map.locate(id) else { return nil }
        return map.trails[place.trail]
    }

    /// ⌃1 to ⌃8 pick that tab of the current row; ⌃9 picks the last one (⌘1-9 belong to the app dock).
    func selectTabInRow(_ number: Int) {
        guard let tabs = tabBarRow?.openTabs, !tabs.isEmpty else { return }
        let tab = number >= 9 ? tabs[tabs.count - 1] : (number - 1 < tabs.count ? tabs[number - 1] : nil)
        if let tab { choose(tab.id) }
    }

    /// Closes every other open tab in the row of `id`.
    func closeOtherTabs(inRowOf id: TabID) {
        guard let place = map.locate(id) else { return }
        for tab in map.trails[place.trail].openTabs where tab.id != id && !tab.pinned {
            closeTab(tab.id)
        }
    }
}

struct TabBar: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var dock = AppDock.shared
    @ObservedObject private var hud = GestureNavigator.shared.hud
    @ObservedObject private var chrome = TabBarChrome.shared
    /// Remembers the previous row so a row change can slide in from the right side.
    @StateObject private var rowMotion = RowMotion()

    var body: some View {
        let row = store.tabBarRow
        let tabs = row?.openTabs ?? []
        let order = store.map.layout().open.map(\.id)
        let edge = rowMotion.edge(for: row?.id, order: order)
        let activeID = dock.isFront ? nil : store.map.activeTabID
        let split = store.map.split(containing: activeID)
        let partner = split.map { $0.left == activeID ? $0.right : $0.left }
        // While swiping between tabs, the tab you would land on lights up before you let go.
        let preview = hud.visible ? hud.target : nil

        HStack(spacing: 0) {
            WindowDragArea()
                .frame(width: leadingRoom)
            NavButtons(page: store.activeWebTab)
                .padding(.trailing, 6)

            GeometryReader { geometry in
                ZStack {
                    TabStrip(tabs: tabs, activeID: activeID, partnerID: partner, previewID: preview,
                             width: geometry.size.width)
                        .id(row?.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: edge).combined(with: .opacity),
                            removal: .move(edge: edge == .top ? .bottom : .top).combined(with: .opacity)))
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .animation(TabBarStyle.spring, value: row?.id)
            }

            WindowDragArea()
                .frame(width: 10)
            HStack(spacing: 2) {
                BarButton(symbol: "plus", help: "New tab in this row (⌥⌘T)", enabled: true) {
                    store.newTabInTrail()
                }
                BarButton(symbol: "square.grid.3x2", help: "Show the tab map (⌘E)", enabled: true) {
                    store.toggleOverview()
                }
            }
            WindowDragArea()
                .frame(width: 8)
        }
        .frame(height: TabBarStyle.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { chrome.barShown(true, sidebarPinned: store.sidebarShown) }
        .onDisappear { chrome.barShown(false, sidebarPinned: store.sidebarShown) }
        .onChange(of: store.sidebarShown) { pinned in chrome.barShown(true, sidebarPinned: pinned) }
    }

    private var leadingRoom: CGFloat {
        store.sidebarShown || chrome.fullScreen ? 8 : TabBarStyle.trafficLightRoom
    }
}

/// Back and forward, following the current page's history.
private struct NavButtons: View {
    @EnvironmentObject private var store: BrowserStore
    let page: WebTab?

    var body: some View {
        if let page { Live(page: page) } else { buttons(back: false, forward: false) }
    }

    private struct Live: View {
        @EnvironmentObject private var store: BrowserStore
        @ObservedObject var page: WebTab
        var body: some View { NavButtons.row(store: store, back: page.canGoBack, forward: page.canGoForward) }
    }

    private func buttons(back: Bool, forward: Bool) -> some View {
        Self.row(store: store, back: back, forward: forward)
    }

    static func row(store: BrowserStore, back: Bool, forward: Bool) -> some View {
        HStack(spacing: 2) {
            BarButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: back) { store.goBack() }
            BarButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: forward) { store.goForward() }
        }
    }
}

/// Decides which way the bar's contents slide when the row changes: rows further down the map
/// come in from below, rows further up from above, like the page during a vertical swipe.
@MainActor
private final class RowMotion: ObservableObject {
    private var lastRow: TrailID?
    private var lastOrder: [TrailID] = []
    private var lastEdge: Edge = .bottom

    func edge(for row: TrailID?, order: [TrailID]) -> Edge {
        defer { lastOrder = order }
        guard row != lastRow else { return lastEdge }
        if let row, let old = lastRow,
           let newIndex = lastOrder.firstIndex(of: row), let oldIndex = lastOrder.firstIndex(of: old) {
            lastEdge = newIndex > oldIndex ? .bottom : .top
        } else {
            // A brand-new row goes to the top of the map.
            lastEdge = .top
        }
        lastRow = row
        return lastEdge
    }
}

private struct TabStrip: View {
    let tabs: [MapTab]
    let activeID: TabID?
    let partnerID: TabID?
    let previewID: TabID?
    let width: CGFloat

    var body: some View {
        let activeIndex = tabs.firstIndex { $0.id == activeID }
        let layout = TabBarLayout.make(count: tabs.count, active: activeIndex,
                                       available: Double(width), metrics: TabBarStyle.metrics)
        Group {
            if layout.scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        row(layout, activeIndex: activeIndex)
                    }
                    .onAppear { if let activeID { proxy.scrollTo(activeID, anchor: .center) } }
                    .onChange(of: activeID) { id in
                        guard let id else { return }
                        withAnimation(TabBarStyle.spring) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            } else {
                row(layout, activeIndex: activeIndex)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func row(_ layout: TabBarLayout, activeIndex: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let tabWidth = CGFloat(layout.widths[index])
                TabBarItem(
                    tab: tab,
                    isActive: tab.id == activeID,
                    isPartner: tab.id == partnerID,
                    isPreview: tab.id == previewID && tab.id != activeID,
                    showsTitle: tab.id == activeID || tabWidth >= CGFloat(TabBarStyle.metrics.titleMinimum),
                    // No divider beside the raised current tab, or after the last tab.
                    showsDivider: index < tabs.count - 1 && index != activeIndex && index + 1 != activeIndex)
                    .frame(width: tabWidth)
                    .id(tab.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
            }
        }
        .frame(height: TabBarStyle.height)
        .animation(TabBarStyle.spring, value: tabs.map(\.id))
        .animation(TabBarStyle.spring, value: activeID)
    }
}

private struct TabBarItem: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.colorScheme) private var colorScheme
    let tab: MapTab
    let isActive: Bool
    let isPartner: Bool
    let isPreview: Bool
    let showsTitle: Bool
    let showsDivider: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TabBarStyle.corner, style: .continuous)
                .fill(fill)
                .shadow(color: .black.opacity(isActive ? (colorScheme == .dark ? 0.35 : 0.12) : 0),
                        radius: 1.5, y: 0.5)
            content
            if isActive, let page = store.page(for: tab.id) {
                LoadLine(page: page)
            }
        }
        .frame(height: TabBarStyle.tabHeight)
        .padding(.horizontal, 2)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 16)
                .opacity(showsDivider && !hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // Like Safari's compact tabs: clicking the current tab is how you get to the address.
            if isActive { store.focusAddress() } else { store.choose(tab.id) }
        }
        .help(helpText)
        .contextMenu {
            Button("Close Tab") { store.closeTab(tab.id) }
            Button("Close Other Tabs in This Row") { store.closeOtherTabs(inRowOf: tab.id) }
            Divider()
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab (Never Auto-Close)") { store.togglePin(tab.id) }
            if let url = tab.url {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if showsTitle {
            HStack(spacing: 6) {
                closeOrIcon
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundColor(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: isActive ? .center : .leading)
                // Balances the icon so a centred title sits in the middle of the tab.
                Color.clear.frame(width: isActive ? 16 : 0, height: 1)
            }
            .padding(.horizontal, 8)
        } else {
            closeOrIcon
        }
    }

    @ViewBuilder private var closeOrIcon: some View {
        if hovering && !tab.pinned {
            Button { store.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Close Tab (⌘W)")
        } else if let page = store.page(for: tab.id) {
            TabIcon(page: page, url: tab.url, pinned: tab.pinned)
        } else {
            TabIcon.still(url: tab.url, pinned: tab.pinned)
        }
    }

    private var fill: Color {
        if isActive { return colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.95) }
        if isPreview { return Color.accentColor.opacity(0.18) }
        if isPartner { return Color.primary.opacity(0.08) }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var helpText: String {
        var lines = [tab.displayTitle]
        if let url = tab.url { lines.append(url.absoluteString) }
        if tab.pinned { lines.append("Pinned: never closes on its own") }
        return lines.joined(separator: "\n")
    }
}

/// The favicon, or a small spinner while the page loads.
private struct TabIcon: View {
    @ObservedObject var page: WebTab
    let url: URL?
    let pinned: Bool

    var body: some View {
        if page.isLoading && page.progress < 1 {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        } else {
            Self.still(url: url, pinned: pinned)
        }
    }

    static func still(url: URL?, pinned: Bool) -> some View {
        FaviconView(url: url, size: 14)
            .frame(width: 16, height: 16)
            .overlay(alignment: .bottomTrailing) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.secondary)
                        .offset(x: 3, y: 3)
                }
            }
    }
}

/// A thin progress line along the bottom of the current tab while its page loads.
private struct LoadLine: View {
    @ObservedObject var page: WebTab

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * CGFloat(page.progress), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(page.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: page.progress)
                .animation(.easeOut(duration: 0.3), value: page.isLoading)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 1)
        .allowsHitTesting(false)
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundColor(enabled ? .secondary : .secondary.opacity(0.4))
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Traffic lights

/// Keeps the window's close, minimise and zoom buttons centred in the tab bar while it shows.
/// AppKit puts them back in the title bar spot whenever it lays the title bar out (resize, key change,
/// full screen), so this follows their frame changes and moves them again.
@MainActor
final class TabBarChrome: ObservableObject {
    static let shared = TabBarChrome()

    @Published private(set) var fullScreen = false

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var centred = false
    private var placing = false

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        fullScreen = window.styleMask.contains(.fullScreen)
        let center = NotificationCenter.default
        let windowEvents: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
        ]
        for name in windowEvents {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                Task { @MainActor in TabBarChrome.shared.windowChanged() }
            })
        }
        for button in buttons {
            button.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { _ in
                Task { @MainActor in TabBarChrome.shared.place() }
            })
        }
        place()
    }

    /// The bar appeared or went away, or the sidebar was pinned or unpinned.
    func barShown(_ shown: Bool, sidebarPinned: Bool) {
        let want = shown && !sidebarPinned
        guard want != centred else { return }
        centred = want
        if want {
            place()
        } else {
            // Let AppKit put the buttons back where it wants them.
            buttons.first?.superview?.needsLayout = true
            buttons.first?.superview?.superview?.needsLayout = true
        }
    }

    private func windowChanged() {
        if let window { fullScreen = window.styleMask.contains(.fullScreen) }
        place()
        // AppKit may lay the title bar out again after telling us; catch that too.
        DispatchQueue.main.async { TabBarChrome.shared.place() }
    }

    private func place() {
        guard centred, !fullScreen, !placing, let titlebar = buttons.first?.superview else { return }
        placing = true
        defer { placing = false }
        for button in buttons {
            let height = button.frame.height
            // `TabBarStyle.height / 2` below the top of the title bar view, which starts at the top of the window.
            let y = titlebar.isFlipped
                ? TabBarStyle.height / 2 - height / 2
                : titlebar.bounds.height - TabBarStyle.height / 2 - height / 2
            if abs(button.frame.origin.y - y) > 0.5 {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y.rounded()))
            }
        }
    }
}
