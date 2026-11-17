import SwiftUI
import TabMapCore

// How split pairs show up in the tab map, and how they are made from it.
//
// Dragging itself belongs to TabDrag.swift (one drag source and one drop target per tab cell).
// Dropping a tab on the middle of its neighbour is handed to the two hooks set in `install()`.

@MainActor
enum SplitMapSupport {
    private static var installed = false

    /// Call once at startup (from `BrowserStore.attach(window:)`).
    static func install() {
        guard !installed else { return }
        installed = true
        let drag = TabDragState.shared
        // Only two open neighbours in the same row can be joined; anything else stays a move.
        drag.splitAccepts = { dragged, target in
            BrowserStore.shared.map.canSplit(dragged, target)
        }
        drag.splitHandler = { dragged, target in
            let store = BrowserStore.shared
            guard store.map.canSplit(dragged, target) else { return false }
            store.splitTabs(dragged, with: target)
            return true
        }
    }
}

/// Marks the two tabs of a split pair in the map with an accent line underneath, joined across
/// the gap when they sit next to each other, so the pair reads as one thing.
struct SplitMarker: ViewModifier {
    @EnvironmentObject private var store: BrowserStore
    let tab: MapTab
    let trail: Trail
    let style: MapStyle

    func body(content: Content) -> some View {
        let pair = store.map.split(containing: tab.id)
        content.overlay(alignment: .bottom) {
            if let pair {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.trailing, reachesPartner(pair) ? -gap : 0)
                    .offset(y: style == .cards ? 5 : 3)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Spacing between cells in a row; must match `TrailRow`.
    private var gap: CGFloat { style == .cards ? 10 : 4 }

    /// True for the left tab of a pair whose right tab is the very next cell.
    private func reachesPartner(_ pair: SplitPair) -> Bool {
        guard pair.left == tab.id,
              let i = trail.tabs.firstIndex(where: { $0.id == tab.id }),
              i + 1 < trail.tabs.count else { return false }
        return trail.tabs[i + 1].id == pair.right
    }
}

/// Context menu entries for a tab in the map.
struct SplitMenuItems: View {
    let tab: MapTab

    var body: some View {
        // Menus do not reliably inherit environment objects, so this reads the store directly.
        let store = BrowserStore.shared
        if store.map.split(containing: tab.id) != nil {
            Button("Separate Side-by-Side Tabs") { store.unsplit(tab.id) }
        } else if !tab.isClosed {
            if let right = store.map.neighbor(of: tab.id, .right), store.map.canSplit(tab.id, right) {
                Button("View Side by Side with Tab on the Right") { store.splitTabs(tab.id, with: right) }
            }
            if let left = store.map.neighbor(of: tab.id, .left), store.map.canSplit(tab.id, left) {
                Button("View Side by Side with Tab on the Left") { store.splitTabs(tab.id, with: left) }
            }
        }
    }
}
