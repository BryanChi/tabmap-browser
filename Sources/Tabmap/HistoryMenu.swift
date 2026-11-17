import AppKit
import SwiftUI
import WebKit
import TabMapCore

// The branching history, shown as a dropdown that falls from the island's back button
// when it is right-clicked (or control-clicked). While it is open the back arrow turns to
// point down at it. Each row is a page; the graph in the left gutter shows how they connect:
// the straight line is the way to the page you are on, and side branches are detours you
// backed out of, which a normal back list would have thrown away.

/// What the dropdown shows: a tree, and how to go to one of its pages.
struct HistoryMenuModel {
    var tree: HistoryTree
    /// Shows the page in the front web view.
    var open: (Int) -> Void
    /// The map tab this history belongs to, when it is one (not a dock app).
    var tab: TabID?

    /// For a page whose branching history is not known (a dock app, or a tab from before the
    /// tree existed): WebKit's own back/forward list, as a straight line.
    static func linear(_ webView: WKWebView) -> HistoryMenuModel? {
        let list = webView.backForwardList
        guard let current = list.currentItem else { return nil }
        let items = list.backList + [current] + list.forwardList
        guard items.count > 1 else { return nil }
        var tree = HistoryTree()
        var itemFor: [Int: WKBackForwardListItem] = [:]
        var currentNode: Int?
        let start = Date().addingTimeInterval(-Double(items.count))
        for (i, item) in items.enumerated() {
            let node = tree.visit(url: item.url, title: item.title ?? "", now: start.addingTimeInterval(Double(i)))
            itemFor[node] = item
            if item === current { currentNode = node }
        }
        if let currentNode { tree.move(to: currentNode, now: Date()) }
        guard tree.count > 1 else { return nil }
        return HistoryMenuModel(tree: tree, open: { [weak webView] node in
            if let item = itemFor[node], item !== webView?.backForwardList.currentItem { webView?.go(to: item) }
        }, tab: nil)
    }
}

@MainActor
extension BrowserStore {
    /// The history of whatever page is in front, or nil when there is nowhere to go.
    func historyMenuModel() -> HistoryMenuModel? {
        if !AppDock.shared.isFront, let id = map.activeTabID,
           let tree = HistoryStore.shared.tree(for: id), tree.count > 1 {
            return HistoryMenuModel(tree: tree, open: { [weak self] node in self?.openHistoryNode(node, in: id) }, tab: id)
        }
        guard let webView = frontWebView else { return nil }
        return HistoryMenuModel.linear(webView)
    }

    func toggleHistoryMenu() {
        if historyMenuShown { closeHistoryMenu(); return }
        guard historyMenuModel() != nil else { NSSound.beep(); return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { historyMenuShown = true }
    }

    func closeHistoryMenu() {
        guard historyMenuShown else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { historyMenuShown = false }
    }
}

// MARK: The dropdown

struct HistoryMenu: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var dock = AppDock.shared
    /// Where the caret meets the panel, measured from the panel's leading edge.
    let caretX: CGFloat

    @State private var highlighted: Int?
    @State private var appeared = false
    @State private var keyMonitor: Any?

    private let rowHeight: CGFloat = 34
    private let laneWidth: CGFloat = 12
    private let gutterLeading: CGFloat = 18
    private let width: CGFloat = 380
    private let maxListHeight: CGFloat = 440
    private let caretHeight: CGFloat = 7

    var body: some View {
        Group {
            if let model = store.historyMenuModel() {
                panel(model)
            }
        }
        .onAppear {
            appeared = true
            installKeys()
        }
        .onDisappear {
            removeKeys()
            // Gone because the island hid (the map opened, say): make sure it stays shut.
            Task { @MainActor in if store.historyMenuShown { store.historyMenuShown = false } }
        }
        .onChange(of: store.map.activeTabID) { _ in store.closeHistoryMenu() }
        .onChange(of: dock.isFront) { _ in store.closeHistoryMenu() }
    }

    private func panel(_ model: HistoryMenuModel) -> some View {
        let layout = model.tree.layout()
        let rows = Self.rows(layout)
        let listHeight = min(CGFloat(rows.count) * rowHeight, maxListHeight)
        let gutter = gutterLeading + CGFloat(max(layout.lanes - 1, 0)) * laneWidth + 10

        return VStack(alignment: .leading, spacing: 0) {
            header(model, rows: rows)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: CGFloat(rows.count) * rowHeight > maxListHeight) {
                    ZStack(alignment: .topLeading) {
                        graph(rows, onPath: false)
                            .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        graph(rows, onPath: true)
                            .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, placed in
                                row(placed, index: index, model: model, gutter: gutter)
                                    .id(placed.id)
                            }
                        }
                    }
                    .frame(width: width, height: CGFloat(rows.count) * rowHeight, alignment: .topLeading)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.18).delay(0.04), value: appeared)
                }
                .frame(height: listHeight)
                .onAppear {
                    if let current = model.tree.currentID { proxy.scrollTo(current, anchor: .center) }
                }
                .onChange(of: highlighted) { id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .padding(.bottom, 6)
        }
        .padding(.top, caretHeight)
        .frame(width: width)
        .background(DropdownShape(caretX: caretX, caretHeight: caretHeight).fill(Color.black))
        .overlay(DropdownShape(caretX: caretX, caretHeight: caretHeight).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private func header(_ model: HistoryMenuModel, rows: [PlacedHistoryNode]) -> some View {
        let detours = rows.filter { !$0.onCurrentPath }.count
        return HStack(spacing: 6) {
            Text("HISTORY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            if detours > 0 {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                Text(detours == 1 ? "1 page off the path" : "\(detours) pages off the path")
                    .font(.system(size: 10))
            }
        }
        .foregroundColor(.white.opacity(0.4))
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 5)
    }

    // MARK: Rows

    /// Deepest pages at the top, so the list reads like time going up: what you went forward
    /// to, then the page you are on, then the pages that led to it. Within one depth, the main
    /// line comes before the detours.
    static func rows(_ layout: HistoryLayout) -> [PlacedHistoryNode] {
        layout.nodes.sorted { a, b in
            if a.column != b.column { return a.column > b.column }
            return a.lane < b.lane
        }
    }

    private func laneX(_ lane: Int) -> CGFloat { gutterLeading + CGFloat(lane) * laneWidth }

    private func row(_ placed: PlacedHistoryNode, index: Int, model: HistoryMenuModel, gutter: CGFloat) -> some View {
        let node = model.tree.node(placed.id)
        let isHighlighted = highlighted == placed.id
        return HStack(spacing: 10) {
            Color.clear.frame(width: gutter)
            FaviconView(url: node?.url, size: 16)
                .opacity(placed.onCurrentPath ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(node?.displayTitle ?? "")
                    .font(.system(size: 12.5, weight: placed.isCurrent ? .semibold : .regular))
                    .foregroundColor(.white.opacity(placed.onCurrentPath ? 0.95 : 0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle(node, placed))
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if placed.isCurrent {
                Text("Now")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
            }
        }
        .padding(.trailing, 14)
        .frame(width: width, height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowFill(placed, highlighted: isHighlighted))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        )
        .overlay(alignment: .topLeading) {
            dot(placed).position(x: laneX(placed.lane), y: rowHeight / 2)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { highlighted = placed.id } else if highlighted == placed.id { highlighted = nil }
        }
        .onTapGesture { choose(placed.id, model) }
        .contextMenu {
            if let node {
                Button("Go to This Page") { choose(placed.id, model) }
                if let tab = model.tab {
                    Button("Open in a New Tab Beside This One") {
                        store.closeHistoryMenu()
                        store.openChild(of: tab, url: node.url, activate: true)
                    }
                }
                Divider()
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.url.absoluteString, forType: .string)
                }
            }
        }
        .help(node?.url.absoluteString ?? "")
        // Rows slide down into place one after another as the menu opens.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -10)
        .animation(.spring(response: 0.36, dampingFraction: 0.82).delay(Double(min(index, 14)) * 0.018), value: appeared)
    }

    private func rowFill(_ placed: PlacedHistoryNode, highlighted: Bool) -> Color {
        if highlighted { return Color.white.opacity(0.12) }
        if placed.isCurrent { return Color.accentColor.opacity(0.22) }
        return .clear
    }

    @ViewBuilder
    private func dot(_ placed: PlacedHistoryNode) -> some View {
        if placed.isCurrent {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.accentColor.opacity(0.4), lineWidth: 3).padding(-2.5))
        } else if placed.onCurrentPath {
            Circle().fill(Color.white.opacity(0.85)).frame(width: 7, height: 7)
        } else {
            Circle()
                .fill(Color.black)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1.5))
        }
    }

    /// Lines from each page down to the page it came from. A detour runs down its own lane,
    /// then bends left into its parent's dot.
    private func graph(_ rows: [PlacedHistoryNode], onPath: Bool) -> Path {
        var index: [Int: Int] = [:]
        for (i, n) in rows.enumerated() { index[n.id] = i }
        var path = Path()
        for (i, n) in rows.enumerated() where n.onCurrentPath == onPath {
            guard let parentID = n.parent, let j = index[parentID] else { continue }
            let parent = rows[j]
            let from = CGPoint(x: laneX(n.lane), y: (CGFloat(i) + 0.5) * rowHeight)
            let to = CGPoint(x: laneX(parent.lane), y: (CGFloat(j) + 0.5) * rowHeight)
            path.move(to: from)
            if n.lane == parent.lane {
                path.addLine(to: to)
            } else {
                let r = min(8, (to.y - from.y) / 2, (from.x - to.x) / 2)
                path.addLine(to: CGPoint(x: from.x, y: to.y - r))
                path.addQuadCurve(to: CGPoint(x: from.x - r, y: to.y), control: CGPoint(x: from.x, y: to.y))
                path.addLine(to: to)
            }
        }
        return path
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func subtitle(_ node: HistoryNode?, _ placed: PlacedHistoryNode) -> String {
        guard let node else { return "" }
        var host = node.url.host ?? node.url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if placed.isCurrent { return host }
        let when = Self.relative.localizedString(for: node.visitedAt, relativeTo: Date())
        return "\(host) · \(when)"
    }

    private func choose(_ id: Int, _ model: HistoryMenuModel) {
        store.closeHistoryMenu()
        model.open(id)
    }

    // MARK: Keys

    /// Esc closes; up and down move the highlight; Return goes to the highlighted page.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        // Local monitors run on the main thread, and the closure inherits the view's main-actor isolation.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handleKey(event) }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard store.historyMenuShown, let model = store.historyMenuModel() else { return event }
        let rows = Self.rows(model.tree.layout()).map(\.id)
        let current = highlighted ?? model.tree.currentID
        let position = current.flatMap { rows.firstIndex(of: $0) }
        switch event.keyCode {
        case 53: // escape
            store.closeHistoryMenu()
            return nil
        case 126: // up
            if let position { highlighted = rows[max(position - 1, 0)] } else { highlighted = rows.first }
            return nil
        case 125: // down
            if let position { highlighted = rows[min(position + 1, rows.count - 1)] } else { highlighted = rows.first }
            return nil
        case 36, 76: // return, enter
            if let highlighted { choose(highlighted, model) }
            return nil
        default:
            return event
        }
    }
}

/// A rounded panel with a small caret on top pointing up at the back button.
struct DropdownShape: Shape {
    var caretX: CGFloat
    var caretWidth: CGFloat = 16
    var caretHeight: CGFloat = 7
    var radius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + caretHeight
        let r = radius
        let cx = min(max(caretX, rect.minX + r + caretWidth / 2), rect.maxX - r - caretWidth / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: top))
        p.addLine(to: CGPoint(x: cx - caretWidth / 2, y: top))
        p.addQuadCurve(to: CGPoint(x: cx, y: rect.minY), control: CGPoint(x: cx - caretWidth / 4, y: top))
        p.addQuadCurve(to: CGPoint(x: cx + caretWidth / 2, y: top), control: CGPoint(x: cx + caretWidth / 4, y: top))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: top + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX + r, y: top), radius: r)
        p.closeSubpath()
        return p
    }
}

// MARK: Right-click on the back button

/// Sits over a button and takes only right-clicks and control-clicks; ordinary clicks pass
/// straight through to the button underneath.
struct SecondaryClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary: Bool
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                secondary = true
            case .leftMouseDown, .leftMouseUp:
                secondary = event.modifierFlags.contains(.control)
            default:
                secondary = false
            }
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?() }
        /// Only reached with control held, thanks to `hitTest`.
        override func mouseDown(with event: NSEvent) { action?() }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}
