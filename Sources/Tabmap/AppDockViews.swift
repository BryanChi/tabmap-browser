import AppKit
import Combine
import SwiftUI
import WebKit
import TabMapCore

// Goes in Sources/Tabmap. The dock's three faces:
//   AppDockStrip  a row of app icons at the top of the map sidebar
//   AppDockPill   the same icons in a floating pill at the bottom edge of the window
//   AppLayer      the app in front of the map, with any peeks stacked on top of it

/// Hosts a dock page's web view. Web views are kept alive by the dock, not by this view.
struct DockWebHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        if webView.superview === container, container.subviews.count == 1 { return }
        for view in container.subviews where view !== webView { view.removeFromSuperview() }
        if webView.superview !== container {
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
    }
}

// MARK: Icons

/// One app icon with its unread badge. Observes the page so the badge follows the title.
struct DockIcon: View {
    @ObservedObject var page: DockPage
    let app: DockApp
    let isFront: Bool
    var size: CGFloat = 26
    var onDark = false
    /// The page open on top of this app, if any, and how many are stacked.
    var peek: DockPage?
    var peekCount = 0

    var body: some View {
        let badge = UnreadBadge.parse(page.title)
        FaviconView(url: app.home, size: size * 0.72)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill((onDark ? Color.white : Color.primary).opacity(isFront ? 0.2 : 0.07))
            )
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge == "•" ? " " : badge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, badge == "•" ? 0 : 3.5)
                        .frame(minWidth: badge == "•" ? 8 : 14, minHeight: badge == "•" ? 8 : 14)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 5, y: -4)
                }
            }
            .overlay(alignment: .bottom) {
                if page.isLoading {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: size * 0.5, height: 2)
                        .offset(y: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let peek {
                    PeekMarker(peek: peek, size: max(12, size * 0.46), onDark: onDark)
                        .offset(x: 5, y: 5)
                }
            }
            .contentShape(Rectangle())
    }
}

/// The small icon of the site that is open on top of an app, tucked into the corner of the app's icon.
private struct PeekMarker: View {
    @ObservedObject var peek: DockPage
    let size: CGFloat
    let onDark: Bool

    var body: some View {
        FaviconView(url: peek.url, size: size - 4)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(onDark ? Color.black : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1)
            )
    }
}

/// Spells out what is open on top of an app: used in the full map, where there is room.
private struct PeekChip: View {
    @ObservedObject var peek: DockPage
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.on.square")
                .font(.system(size: 9, weight: .semibold))
            Text(peek.displayTitle)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            if count > 1 {
                Text("+\(count - 1)")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: 190)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
    }
}

/// The icons themselves, shared by the sidebar strip and the floating pill.
struct DockIcons: View {
    @ObservedObject private var dock = AppDock.shared
    var size: CGFloat = 26
    var onDark = false
    /// Also name the page open on top of an app, beside its icon.
    var namesPeek = false

    var body: some View {
        ForEach(Array(dock.shelf.apps.enumerated()), id: \.element.id) { index, app in
            if let page = dock.page(app.id) {
                let stack = dock.peekStack(app.id)
                HStack(spacing: 7) {
                    DockIcon(page: page, app: app, isFront: dock.frontID == app.id, size: size, onDark: onDark,
                             peek: stack.last, peekCount: stack.count)
                    if namesPeek, let top = stack.last {
                        PeekChip(peek: top, count: stack.count)
                    }
                }
                    .contentShape(Rectangle())
                    .onTapGesture { dock.show(app.id) }
                    .help(tooltip(app, page: page, index: index, peek: stack.last))
                    .contextMenu {
                        Button("Reload") { dock.reload(app.id) }
                        Button("Go to \(app.home.host ?? "Home")") { dock.goHome(app.id) }
                        Divider()
                        Button("Move Left") { dock.moveApp(app.id, by: -1) }
                            .disabled(index == 0)
                        Button("Move Right") { dock.moveApp(app.id, by: 1) }
                            .disabled(index == dock.shelf.apps.count - 1)
                        Divider()
                        Button("Move Back to the Map") { dock.removeApp(app.id, keepAsTab: true) }
                        Button("Remove from Dock") { dock.removeApp(app.id, keepAsTab: false) }
                    }
            }
        }
    }

    private func tooltip(_ app: DockApp, page: DockPage, index: Int, peek: DockPage?) -> String {
        var name = UnreadBadge.stripping(page.displayTitle)
        if let peek { name += ", with \(peek.displayTitle) open on top" }
        return index < 9 ? "\(name) (⌘\(index + 1))" : name
    }
}

/// Sits at the top of the map sidebar, above the rows, so apps never drift down the time axis.
struct AppDockStrip: View {
    @ObservedObject private var dock = AppDock.shared

    var body: some View {
        if !dock.shelf.apps.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    DockIcons()
                }
                .padding(.horizontal, 12)
                .padding(.top, 5)
                .padding(.bottom, 8)
            }
            Divider()
                .padding(.bottom, 8)
        }
    }
}

/// The dock in the full map (⌘E): a row of larger icons above the rows, under the search field.
struct AppDockOverviewRow: View {
    @ObservedObject private var dock = AppDock.shared

    var body: some View {
        if !dock.shelf.apps.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    DockIcons(size: 40, namesPeek: true)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 2)
            Divider()
        }
    }
}

/// The floating dock: slides up when the pointer or a swipe reaches the bottom edge.
struct AppDockPill: View {
    @ObservedObject private var dock = AppDock.shared

    var body: some View {
        let shown = dock.pillShown && !dock.shelf.apps.isEmpty
        HStack(spacing: 9) {
            if dock.isFront {
                Button { dock.sendToBack() } label: {
                    Image(systemName: "square.grid.3x2")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .help("Back to the map")
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 18)
            }
            DockIcons(size: 30, onDark: true)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .padding(.bottom, 10)
        .offset(y: shown ? 0 : 70)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(.spring(response: 0.36, dampingFraction: 0.76), value: shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: The app in front

/// Covers the map's page with the app in front. Peeks sit on top of the app, dimming it.
struct AppLayer: View {
    @ObservedObject private var dock = AppDock.shared

    var body: some View {
        if let app = dock.frontApp, let page = dock.page(app.id) {
            let stack = dock.peekStack(app.id)
            ZStack {
                DockWebHost(webView: page.webView)
                    .id(app.id)

                if let top = stack.last {
                    Color.black.opacity(0.38)
                        .contentShape(Rectangle())
                        .onTapGesture { dock.closeTopPeek() }
                        .transition(.opacity)

                    VStack(spacing: 0) {
                        // Peeks underneath the top one show as slim tabs you can drop back to.
                        ForEach(stack.dropLast()) { lower in
                            PeekCrumb(peek: lower)
                        }
                        PeekSheet(peek: top)
                            .id(top.id)
                    }
                    .padding(.top, 44)
                    .padding(.horizontal, 34)
                    .transition(.move(edge: .bottom))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: stack.map(\.id))
        }
    }
}

/// A peek buried under the top one.
private struct PeekCrumb: View {
    @ObservedObject var peek: DockPage

    var body: some View {
        HStack(spacing: 6) {
            FaviconView(url: peek.url, size: 12)
            Text(peek.displayTitle)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        .clipShape(RoundedCorners(radius: 10))
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { AppDock.shared.popToPeek(peek.id) }
        .help("Go back to this page")
    }
}

/// The page on top of the app: a header you can act on, and the page itself.
private struct PeekSheet: View {
    @ObservedObject var peek: DockPage
    @State private var drag: CGFloat = 0

    private var dock: AppDock { AppDock.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            DockWebHost(webView: peek.webView)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedCorners(radius: 12))
        .shadow(color: .black.opacity(0.35), radius: 18, y: -2)
        .offset(y: max(drag, -30))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dock.closePeek(peek.id) } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
            Button { peek.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!peek.canGoBack)
                .help("Back")
            Button { peek.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!peek.canGoForward)
                .help("Forward")

            FaviconView(url: peek.url, size: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(peek.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let host = peek.url?.host {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            Button { dock.promote(peek.id) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open as Tab")
                    Text("⌘↩").foregroundColor(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .help("Move this page into the map as its own tab")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * CGFloat(peek.progress), height: 2)
                    .opacity(peek.isLoading ? 1 : 0)
            }
            .frame(height: 2)
        }
        .contentShape(Rectangle())
        // Drag the header down to dismiss, up to open as a tab.
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    let moved = value.translation.height
                    if moved > 90 {
                        dock.closePeek(peek.id)
                    } else if moved < -24 {
                        dock.promote(peek.id)
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = 0 }
                }
        )
    }
}

/// Rounded on the top two corners only: the sheet runs off the bottom of the window.
private struct RoundedCorners: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// What the island needs from whichever page is in front: a map tab or a dock page.
@MainActor
protocol IslandPage: AnyObject {
    var isLoading: Bool { get }
    var progress: Double { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var islandChanges: AnyPublisher<Void, Never> { get }
}

extension WebTab: IslandPage {
    var islandChanges: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
}

extension DockPage: IslandPage {
    var islandChanges: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
}
