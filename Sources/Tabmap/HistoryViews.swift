import AppKit
import SwiftUI
import TabMapCore

/// The tiny history tree drawn under a row of the map.
///
/// It shows the history of one tab in the row: the selected tab in the overview, otherwise the
/// current tab, otherwise the tab last used there. Each dot is a page. The line along the top is
/// the way to the page you are on; anything hanging below is a detour you backed out of.
/// Click a dot to go to that page. Nothing is drawn until the tab has been to a second page.
struct HistoryStrip: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var history = HistoryStore.shared
    let trail: Trail
    let style: MapStyle
    let selection: TabID?

    var body: some View {
        if let tab = focusTab, let tree = history.trees[tab.id], tree.count > 1 {
            HStack(alignment: .top, spacing: style == .cards ? 6 : 4) {
                // With several tabs in the row, say whose history this is.
                if trail.tabs.count > 1 {
                    FaviconView(url: tab.url, size: style == .cards ? 12 : 9)
                        .opacity(0.8)
                        .padding(.top, 1)
                        .help("History of “\(tab.displayTitle)”")
                }
                HistoryTreeView(tab: tab, tree: tree, style: style)
            }
            .padding(.horizontal, style == .cards ? 10 : 6)
            .padding(.bottom, style == .cards ? 8 : 5)
            .padding(.top, style == .cards ? 0 : 1)
        }
    }

    private var focusTab: MapTab? {
        let candidates = [selection, store.map.activeTabID, trail.lastActiveTabID]
        for case let id? in candidates {
            if let tab = trail.tabs.first(where: { $0.id == id }) { return tab }
        }
        return nil
    }
}

struct HistoryTreeView: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: MapTab
    let tree: HistoryTree
    let style: MapStyle

    private var step: CGFloat { style == .cards ? 16 : 11 }
    private var laneHeight: CGFloat { style == .cards ? 12 : 9 }
    private var dot: CGFloat { style == .cards ? 7 : 5 }

    var body: some View {
        let layout = tree.layout()
        let width = CGFloat(layout.columns) * step
        let height = CGFloat(layout.lanes) * laneHeight

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    edges(layout, onPath: false)
                        .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    edges(layout, onPath: true)
                        .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    ForEach(layout.nodes) { placed in
                        dotView(placed)
                            .frame(width: step, height: laneHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { store.openHistoryNode(placed.id, in: tab.id) }
                            .contextMenu { menu(placed) }
                            .help(tooltip(placed))
                            .id(placed.id)
                            .position(center(placed))
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }
            .frame(height: height)
            .onAppear { if let id = tree.currentID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: tree.currentID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .opacity(tab.isClosed ? 0.55 : 1)
    }

    private func center(_ n: PlacedHistoryNode) -> CGPoint {
        CGPoint(x: (CGFloat(n.column) + 0.5) * step, y: (CGFloat(n.lane) + 0.5) * laneHeight)
    }

    /// The lines from each page to the page it came from. A detour drops down from its parent
    /// and turns right with a small rounded corner.
    private func edges(_ layout: HistoryLayout, onPath: Bool) -> Path {
        var byID: [Int: PlacedHistoryNode] = [:]
        for n in layout.nodes { byID[n.id] = n }
        var path = Path()
        for n in layout.nodes where n.onCurrentPath == onPath {
            guard let parentID = n.parent, let parent = byID[parentID] else { continue }
            let from = center(parent)
            let to = center(n)
            path.move(to: from)
            if parent.lane == n.lane {
                path.addLine(to: to)
            } else {
                let r = min(4, laneHeight / 2)
                path.addLine(to: CGPoint(x: from.x, y: to.y - r))
                path.addQuadCurve(to: CGPoint(x: from.x + r, y: to.y), control: CGPoint(x: from.x, y: to.y))
                path.addLine(to: to)
            }
        }
        return path
    }

    @ViewBuilder
    private func dotView(_ n: PlacedHistoryNode) -> some View {
        if n.isCurrent {
            Circle()
                .fill(Color.accentColor)
                .frame(width: dot + 2, height: dot + 2)
                .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 2).padding(-2))
        } else if n.onCurrentPath {
            Circle().fill(Color.primary.opacity(0.7)).frame(width: dot, height: dot)
        } else {
            // Drawn opaque first so the line behind does not show through the dot.
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: dot, height: dot)
                .overlay(Circle().fill(Color.primary.opacity(0.35)))
        }
    }

    @ViewBuilder
    private func menu(_ n: PlacedHistoryNode) -> some View {
        if let node = tree.node(n.id) {
            Button("Go to This Page") { store.openHistoryNode(n.id, in: tab.id) }
            Button("Open in a New Tab Beside This One") {
                store.openChild(of: tab.id, url: node.url, activate: true)
            }
            Divider()
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.absoluteString, forType: .string)
            }
        }
    }

    private func tooltip(_ n: PlacedHistoryNode) -> String {
        guard let node = tree.node(n.id) else { return "" }
        var lines = [node.displayTitle]
        let address = node.url.absoluteString
        if address != node.displayTitle { lines.append(address) }
        if n.isCurrent { lines.append("You are here.") }
        else if !n.onCurrentPath { lines.append("Click to go back to this page.") }
        return lines.joined(separator: "\n")
    }
}
