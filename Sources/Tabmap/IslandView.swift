import Combine
import SwiftUI
import TabMapCore

/// The only browser chrome: a black capsule floating at the top centre of the page.
///   hidden   nothing to show; invisible and lets clicks through
///   loading  a small pill with the site and a progress ring while the page loads
///   full     back, forward, reload, the address field and the map buttons
struct Island: View {
    @EnvironmentObject private var store: BrowserStore
    /// Re-renders the island when the current page's loading state changes. A relay rather than
    /// switching between an observing and a non-observing view, so the address field keeps its
    /// identity (and its focus) when a blank tab turns into a page.
    @StateObject private var relay = PageRelay()
    /// A dock app in front takes over the island from the map's tab.
    @ObservedObject private var dock = AppDock.shared

    enum Mode { case hidden, loading, full }

    var body: some View {
        let page: IslandPage?
        if let front = dock.frontPage { page = front } else { page = store.activeWebTab }
        relay.follow(page)
        return ZStack(alignment: .top) {
            // While the history menu is open, a click anywhere else closes it, like a menu.
            if store.historyMenuShown {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { store.closeHistoryMenu() }
            }
            IslandBody(mode: mode(page), page: page)
        }
    }

    private func mode(_ page: IslandPage?) -> Mode {
        if store.overviewShown { return .hidden }
        if store.chromeExpanded { return .full }
        return page?.isLoading == true ? .loading : .hidden
    }
}

/// Forwards the current page's changes, so the island redraws when it loads.
@MainActor
final class PageRelay: ObservableObject {
    private weak var page: IslandPage?
    private var subscription: AnyCancellable?

    func follow(_ page: IslandPage?) {
        guard page !== self.page else { return }
        self.page = page
        subscription = page?.islandChanges.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

private struct IslandBody: View {
    @EnvironmentObject private var store: BrowserStore
    let mode: Island.Mode
    let page: IslandPage?

    private let fullWidth: CGFloat = 640
    private let fullHeight: CGFloat = 40

    var body: some View {
        let isFull = mode == .full
        ZStack {
            loadingContent
                .opacity(mode == .loading ? 1 : 0)
                .allowsHitTesting(false)
            fullContent
                .frame(width: fullWidth, height: fullHeight)
                .opacity(isFull ? 1 : 0)
                .allowsHitTesting(isFull)
        }
        .frame(width: isFull ? fullWidth : 210, height: isFull ? fullHeight : 28)
        .background(Color.black)
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: fullWidth * CGFloat(page?.progress ?? 0), height: 2)
                .opacity(isFull && page?.isLoading == true ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: page?.progress)
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture {
            if mode == .loading { store.focusAddress() }
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .foregroundColor(.white)
        .scaleEffect(mode == .hidden ? 0.5 : 1, anchor: .top)
        .opacity(mode == .hidden ? 0 : 1)
        .allowsHitTesting(mode != .hidden)
        .animation(.spring(response: 0.36, dampingFraction: 0.76), value: mode)
        .environment(\.colorScheme, .dark)
        .padding(.top, 7)
        // The branching history drops down from the back button, its caret under the arrow.
        .overlay(alignment: .topLeading) {
            if store.historyMenuShown && isFull {
                HistoryMenu(caretX: backButtonCenter)
                    .offset(y: 7 + fullHeight + 3)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.5, anchor: UnitPoint(x: backButtonCenter / 380, y: 0))
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: UnitPoint(x: backButtonCenter / 380, y: 0))
                            .combined(with: .opacity)))
            }
        }
    }

    /// Distance from the island's leading edge to the middle of the back arrow.
    private let backButtonCenter: CGFloat = 21

    private var loadingContent: some View {
        HStack(spacing: 7) {
            FaviconView(url: store.frontURL, size: 14)
            Text(host)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            ProgressRing(progress: page?.progress ?? 0)
                .frame(width: 12, height: 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 210, height: 28)
    }

    private var fullContent: some View {
        HStack(spacing: 12) {
            Button {
                store.closeHistoryMenu()
                store.goBack()
            } label: {
                // Turns to point down at the history while it is open.
                Image(systemName: "chevron.left")
                    .rotationEffect(.degrees(store.historyMenuShown ? -90 : 0))
                    .animation(.spring(response: 0.34, dampingFraction: 0.62), value: store.historyMenuShown)
            }
            .disabled(page?.canGoBack != true && !store.historyMenuShown)
            .overlay(SecondaryClickCatcher { store.toggleHistoryMenu() })
            .help("Back · right-click for history")
            Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(page?.canGoForward != true)
                .help("Forward")
            if page?.isLoading == true {
                Button { store.stopLoading() } label: { Image(systemName: "xmark") }
                    .help("Stop")
            } else {
                Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(page == nil)
                    .help("Reload")
            }

            NativeTextField(
                text: $store.addressText,
                placeholder: "Search or enter address",
                fontSize: 13,
                textColor: .white,
                placeholderColor: NSColor.white.withAlphaComponent(0.45),
                focusToken: store.addressFocusRequest,
                onSubmit: { store.submitAddress() },
                onCancel: { store.cancelAddress() },
                onFocusChange: { focused in
                    // Not during the view update that may have caused it.
                    Task { @MainActor in store.addressEditing = focused }
                })
                .frame(height: 26)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.white.opacity(0.1)))

            Button { store.sidebarShown.toggle() } label: {
                Image(systemName: store.sidebarShown ? "sidebar.left" : "sidebar.leading")
            }
            .help(store.sidebarShown ? "Unpin the map sidebar (⇧⌘S)" : "Pin the map sidebar open (⇧⌘S)")
            Button { store.toggleOverview() } label: { Image(systemName: "square.grid.3x2") }
                .help("Show the tab map (⌘E)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
    }

    private var host: String {
        guard var host = store.frontURL?.host else { return "Loading" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.05, progress))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}
