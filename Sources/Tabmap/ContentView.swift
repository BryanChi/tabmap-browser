import SwiftUI
import WebKit
import TabMapCore

struct ContentView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        ZStack(alignment: .top) {
            OverviewLayer()
            HStack(spacing: 0) {
                if store.sidebarShown {
                    MapSidebar(floating: false)
                        .frame(width: 270)
                        .modifier(FadesIntoOverview())
                    Divider()
                        .modifier(FadesIntoOverview())
                }
                ZStack(alignment: .top) {
                    PageStage()
                    AppLayer()
                    Island()
                    MapHUD()
                    AppDockPill()
                    FindIsland()
                    PasswordIsland()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .zIndex(1)
            DownloadsLayer()
                .zIndex(2)
        }
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                if store.sidebarPeek && !store.sidebarShown && !store.overviewShown {
                    MapSidebar(floating: true)
                        .frame(width: 270)
                        .frame(maxHeight: .infinity)
                        .shadow(color: .black.opacity(0.25), radius: 18, x: 4)
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: store.sidebarPeek)
        }
        // A thin strip along the top edge moves the window, like a title bar. Shallow enough to
        // stay clear of the island, which sits 7 points down.
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: 6)
        }
        .background(WindowAccessor { store.attach(window: $0) })
        .ignoresSafeArea()
        .navigationTitle(store.windowTitle)
    }
}

/// Hands the hosting NSWindow to the store once the view is in it.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = onWindow
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onWindow = onWindow
    }
}

/// Moves the window when dragged, and zooms (or minimises, per the system setting) on a double-click,
/// like a title bar. The window is not movable by its background, so tab drags work everywhere else.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
                return
            }
            window.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

/// Shown when the current tab is blank or there are no open tabs at all.
struct StartView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.3x2")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            Text(store.map.activeTab == nil ? "No open tabs" : "New trail")
                .font(.title2)
            Text("Type an address or a search above.\nLinks you open from a page line up to its right. Rows you use rise to the top; rows you leave sink and close on their own.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 440)
            HStack(spacing: 18) {
                shortcut("⌘T", "New trail")
                shortcut("⌘E or pinch", "Tab map")
                shortcut("Swipe at a page edge, or ⌥ + swipe", "Move through the map")
                shortcut("⇧⌘T", "Reopen closed tab")
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(keys).font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}
