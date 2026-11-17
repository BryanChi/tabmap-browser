import AppKit
import SwiftUI
import WebKit
import TabMapCore

// The branching history, shown as a dropdown that falls from the island's back button
// when it is right-clicked (or control-clicked). While it is open the back arrow turns to
// point down at it. Each row is a page; the graph in the left gutter shows how they connect:
// one straight line from where Forward leads, through the page you are on, back to the first
// page. Pages you backed out of are never mixed into it: each side trip is folded into one row
// just above the page it left from, and unfolds in its own lane.

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

    static let panelWidth: CGFloat = 380

    @State private var highlighted: String?
    /// Side trips the user has unfolded, by the id of their first page.
    @State private var expanded: Set<Int> = []
    @State private var appeared = false
    @State private var keyMonitor: Any?

    private let rowHeight: CGFloat = 34
    private let laneWidth: CGFloat = 14
    private let gutterLeading: CGFloat = 18
    private var width: CGFloat { Self.panelWidth }
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
        let rows = model.tree.menuRows(expanded: expanded)
        let maxLane = rows.map(\.lane).max() ?? 0
        let gutter = gutterLeading + CGFloat(maxLane) * laneWidth + 10
        let listHeight = min(CGFloat(rows.count) * rowHeight, maxListHeight)

        return VStack(alignment: .leading, spacing: 0) {
            header(model)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: CGFloat(rows.count) * rowHeight > maxListHeight) {
                    ZStack(alignment: .topLeading) {
                        graph(rows, main: false)
                            .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: []))
                        graph(rows, main: true)
                            .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                rowView(row, index: index, model: model, gutter: gutter)
                                    .id(row.id)
                                    .transition(.opacity.combined(with: .offset(y: 10)))
                            }
                        }
                    }
                    .frame(width: width, height: CGFloat(rows.count) * rowHeight, alignment: .topLeading)
                }
                .frame(height: listHeight)
                .onAppear {
                    if let current = model.tree.currentID { proxy.scrollTo("p\(current)", anchor: .center) }
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

    private func header(_ model: HistoryMenuModel) -> some View {
        let folded = model.tree.menuRows().filter { if case .branch = $0.kind { return true } else { return false } }.count
        return HStack(spacing: 6) {
            Text("HISTORY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            if folded > 0 {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                Text(folded == 1 ? "1 side trip" : "\(folded) side trips")
                    .font(.system(size: 10))
            }
        }
        .foregroundColor(.white.opacity(0.4))
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 5)
    }

    // MARK: Rows

    private func laneX(_ lane: Int) -> CGFloat { gutterLeading + CGFloat(lane) * laneWidth }

    @ViewBuilder
    private func rowView(_ row: HistoryMenuRow, index: Int, model: HistoryMenuModel, gutter: CGFloat) -> some View {
        let isHighlighted = highlighted == row.id
        let content = HStack(spacing: 10) {
            Color.clear.frame(width: gutter)
            switch row.kind {
            case .page(let id):
                pageContent(row, node: model.tree.node(id))
            case .branch(let start, let pages, let open):
                branchContent(first: model.tree.node(start), pages: pages, open: open)
            }
        }
        .padding(.trailing, 14)
        .frame(width: width, height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowFill(row, highlighted: isHighlighted))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        )
        .overlay(alignment: .topLeading) {
            dot(row).position(x: laneX(row.lane), y: rowHeight / 2)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { highlighted = row.id } else if highlighted == row.id { highlighted = nil }
        }
        .onTapGesture { activate(row, model) }
        // Rows slide down into place one after another as the menu opens.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -10)
        .animation(.spring(response: 0.36, dampingFraction: 0.82).delay(Double(min(index, 14)) * 0.018), value: appeared)

        if case .page(let id) = row.kind, let node = model.tree.node(id) {
            content
                .contextMenu {
                    Button("Go to This Page") { activate(row, model) }
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
                .help(node.url.absoluteString)
        } else {
            content
        }
    }

    private func pageContent(_ row: HistoryMenuRow, node: HistoryNode?) -> some View {
        let strong = row.onCurrentPath || row.isAhead
        return HStack(spacing: 10) {
            FaviconView(url: node?.url, size: 16)
                .opacity(strong ? 1 : 0.65)
            VStack(alignment: .leading, spacing: 1) {
                Text(node?.displayTitle ?? "")
                    .font(.system(size: 12.5, weight: row.isCurrent ? .semibold : .regular))
                    .foregroundColor(.white.opacity(row.onCurrentPath ? 0.95 : (row.isAhead ? 0.7 : 0.6)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle(node, row))
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if row.isCurrent {
                Text("Now")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
            } else if row.isAhead {
                Text("Forward")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    /// A folded side trip: how many pages, and where it started.
    private func branchContent(first: HistoryNode?, pages: Int, open: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 16)
            Group {
                Text(pages == 1 ? "1 page you left" : "\(pages) pages you left")
                    .foregroundColor(.white.opacity(0.7))
                + Text(open ? "" : "  ·  \(first?.displayTitle ?? "")")
                    .foregroundColor(.white.opacity(0.4))
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private func rowFill(_ row: HistoryMenuRow, highlighted: Bool) -> Color {
        if highlighted { return Color.white.opacity(0.12) }
        if row.isCurrent { return Color.accentColor.opacity(0.22) }
        return .clear
    }

    @ViewBuilder
    private func dot(_ row: HistoryMenuRow) -> some View {
        switch row.kind {
        case .branch:
            // A fold is a hollow ring, so it reads as "more in here".
            Circle()
                .fill(Color.black)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.6])))
        case .page:
            if row.isCurrent {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.4), lineWidth: 3).padding(-2.5))
            } else if row.onCurrentPath {
                Circle().fill(Color.white.opacity(0.85)).frame(width: 7, height: 7)
            } else {
                Circle()
                    .fill(Color.black)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.white.opacity(row.isAhead ? 0.6 : 0.45), lineWidth: 1.5))
            }
        }
    }

    /// Each row's line runs down to the row it came from. Within a lane it is straight; where a
    /// side trip leaves the main line it bends right out of the page it left from.
    private func graph(_ rows: [HistoryMenuRow], main: Bool) -> Path {
        var index: [String: Int] = [:]
        for (i, r) in rows.enumerated() { index[r.id] = i }
        var path = Path()
        for (i, row) in rows.enumerated() where (row.lane == 0 && !row.inBranch) == main {
            guard let link = row.link, let j = index[link] else { continue }
            let target = rows[j]
            let from = CGPoint(x: laneX(row.lane), y: (CGFloat(i) + 0.5) * rowHeight)
            let to = CGPoint(x: laneX(target.lane), y: (CGFloat(j) + 0.5) * rowHeight)
            path.move(to: from)
            if row.lane == target.lane {
                path.addLine(to: to)
            } else {
                // Down the side lane, then a rounded turn into the parent's dot.
                let r = min(8, (to.y - from.y) / 2, abs(from.x - to.x))
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

    private func subtitle(_ node: HistoryNode?, _ row: HistoryMenuRow) -> String {
        guard let node else { return "" }
        var host = node.url.host ?? node.url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if row.isCurrent { return host }
        let when = Self.relative.localizedString(for: node.visitedAt, relativeTo: Date())
        return "\(host) · \(when)"
    }

    // MARK: Acting on rows

    private func activate(_ row: HistoryMenuRow, _ model: HistoryMenuModel) {
        switch row.kind {
        case .page(let id):
            store.closeHistoryMenu()
            model.open(id)
        case .branch(let start, _, let open):
            setExpanded(start, !open)
        }
    }

    private func setExpanded(_ start: Int, _ open: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            if open {
                expanded.insert(start)
            } else {
                // Folding a side trip folds everything opened inside it too.
                expanded.remove(start)
                if let tree = store.historyMenuModel()?.tree {
                    expanded = expanded.filter { !isInside($0, start, tree) }
                }
                highlighted = "b\(start)"
            }
        }
    }

    private func isInside(_ id: Int, _ ancestor: Int, _ tree: HistoryTree) -> Bool {
        tree.ancestors(of: id).contains(ancestor)
    }

    // MARK: Keys

    /// Esc closes; up and down move the highlight; right unfolds a side trip and left folds the
    /// one you are in; Return goes to the highlighted page or toggles the highlighted fold.
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
        let rows = model.tree.menuRows(expanded: expanded)
        let ids = rows.map(\.id)
        let current = highlighted ?? model.tree.currentID.map { "p\($0)" }
        let position = current.flatMap { ids.firstIndex(of: $0) }
        let row = position.map { rows[$0] }
        switch event.keyCode {
        case 53: // escape
            store.closeHistoryMenu()
            return nil
        case 126: // up
            highlighted = position.map { ids[max($0 - 1, 0)] } ?? ids.first
            return nil
        case 125: // down
            highlighted = position.map { ids[min($0 + 1, ids.count - 1)] } ?? ids.first
            return nil
        case 124: // right
            if let row, case .branch(let start, _, false) = row.kind { setExpanded(start, true) }
            return nil
        case 123: // left
            guard let row else { return nil }
            if case .branch(let start, _, true) = row.kind {
                setExpanded(start, false)
            } else if row.inBranch {
                // Fold the innermost open side trip this row belongs to.
                let chain = [row.node] + model.tree.ancestors(of: row.node)
                if let start = chain.first(where: { expanded.contains($0) }) { setExpanded(start, false) }
            }
            return nil
        case 36, 76: // return, enter
            if let row { activate(row, model) }
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
