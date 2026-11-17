import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TabMapCore

/// SwiftUI also declares a `TabPlacement`; inside the app, the name means the map's one.
typealias TabPlacement = TabMapCore.TabPlacement

// Dragging tabs around the map.
//
// Every tab cell (chip or card) can be picked up. Where it is dropped decides what happens:
//   left or right edge of another tab   → lands beside that tab, in that tab's row
//   empty space in a row                → lands at the end of that row
//   the "New row" strip                 → gets a row of its own
//   the middle of another tab           → handed to `splitHandler` (split view), when `splitAccepts` says yes
//
// This file owns the one drag source and the drop targets, so features that also drag tabs
// plug in through `TabDragState` instead of adding their own onDrag/onDrop to the cells.

/// What the tab being dragged is hovering over right now.
enum TabDropTarget: Equatable {
    case before(TabID)
    case after(TabID)
    /// The middle of a tab: "put these two together".
    case onto(TabID)
    case endOfTrail(TrailID)
    case newTrail
}

@MainActor
final class TabDragState: ObservableObject {
    static let shared = TabDragState()

    /// The tab in the air, if any.
    @Published private(set) var dragging: TabID?
    /// Where it would land if let go now. Drives the insertion marks.
    @Published var target: TabDropTarget?

    /// Set by split view. Called when a tab is dropped on the middle of another tab:
    /// `(dragged, target)`. Return true if the drop was used; false lets it fall back to a move.
    var splitHandler: ((TabID, TabID) -> Bool)?
    /// Set by split view. Asked while hovering: could `dragged` be split with `target`?
    /// The middle of a tab only becomes a drop zone of its own when this says yes,
    /// so the ring never promises a split that would not happen.
    var splitAccepts: ((_ dragged: TabID, _ target: TabID) -> Bool)?

    static let payloadPrefix = "tabmap-tab:"
    static let dropTypes: [UTType] = [.plainText]

    private var monitor: Any?

    private init() {
        // SwiftUI never says when a drag was abandoned (dropped outside, or Esc). Mouse movement
        // and clicks are not delivered while a drag is in the air, so the first one to arrive
        // afterwards means the drag is over.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            if let self, self.dragging != nil { self.end() }
            return event
        }
    }

    func begin(_ id: TabID) -> NSItemProvider {
        dragging = id
        target = nil
        return NSItemProvider(object: (Self.payloadPrefix + id.uuidString) as NSString)
    }

    func end() {
        if dragging != nil { dragging = nil }
        if target != nil { target = nil }
    }

    func hover(_ newTarget: TabDropTarget) {
        if target != newTarget { target = newTarget }
    }

    func leave(_ oldTarget: (TabDropTarget) -> Bool) {
        if let target, oldTarget(target) { self.target = nil }
    }
}

// MARK: Tab cells

private struct TabCellDropDelegate: DropDelegate {
    let tab: MapTab
    let width: CGFloat
    let drag: TabDragState
    let store: BrowserStore

    /// The middle of the cell belongs to split view when it is listening; the rest inserts.
    private func zone(_ info: DropInfo) -> TabDropTarget {
        let x = info.location.x
        let w = max(width, 1)
        if x > w * 0.3, x < w * 0.7, drag.splitHandler != nil,
           let dragged = drag.dragging, let accepts = drag.splitAccepts, accepts(dragged, tab.id) {
            return .onto(tab.id)
        }
        return x < w / 2 ? .before(tab.id) : .after(tab.id)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragging = drag.dragging else { return false }
        return dragging != tab.id
    }

    func dropEntered(info: DropInfo) {
        drag.hover(zone(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        drag.hover(zone(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        let id = tab.id
        drag.leave { $0 == .before(id) || $0 == .after(id) || $0 == .onto(id) }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = drag.dragging, dragged != tab.id else { drag.end(); return false }
        let landed = zone(info)
        drag.end()
        switch landed {
        case .onto:
            if let split = drag.splitHandler, split(dragged, tab.id) { return true }
            store.moveTab(dragged, to: info.location.x < width / 2 ? .before(tab.id) : .after(tab.id))
        case .before:
            store.moveTab(dragged, to: .before(tab.id))
        default:
            store.moveTab(dragged, to: .after(tab.id))
        }
        return true
    }
}

private struct TabDragDrop: ViewModifier {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var drag = TabDragState.shared
    let tab: MapTab
    let cornerRadius: CGFloat
    /// False for cells that can be picked up but not dropped beside (the trailing closed tabs).
    let acceptsDrops: Bool
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = geo.size.width }
                        .onChange(of: geo.size.width) { width = $0 }
                }
            )
            .opacity(drag.dragging == tab.id ? 0.35 : 1)
            .overlay(alignment: .leading) { if drag.target == .before(tab.id) { mark.offset(x: -3) } }
            .overlay(alignment: .trailing) { if drag.target == .after(tab.id) { mark.offset(x: 3) } }
            .overlay {
                if drag.target == .onto(tab.id) {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .onDrag { drag.begin(tab.id) }
            .modifier(CellDrop(enabled: acceptsDrops,
                               delegate: TabCellDropDelegate(tab: tab, width: width, drag: drag, store: store)))
    }

    /// The line showing where the tab will slot in.
    private var mark: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2)
            .padding(.vertical, 1)
            .allowsHitTesting(false)
    }
}

private struct CellDrop: ViewModifier {
    let enabled: Bool
    let delegate: TabCellDropDelegate

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: TabDragState.dropTypes, delegate: delegate)
        } else {
            content
        }
    }
}

// MARK: Rows

private struct TrailDropDelegate: DropDelegate {
    let trail: Trail
    let drag: TabDragState
    let store: BrowserStore

    /// The tab a dropped one lands after: the last open tab on screen, so the newcomer joins the
    /// open tabs rather than hiding among closed ones. Relative to a tab on screen so it also
    /// works while the map is filtered by a search.
    private var anchor: MapTab? {
        trail.tabs.last(where: { !$0.isClosed }) ?? trail.tabs.last
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragging = drag.dragging else { return false }
        // Already at the end of this row: nothing to do.
        return anchor?.id != dragging
    }

    func dropEntered(info: DropInfo) {
        drag.hover(.endOfTrail(trail.id))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        drag.hover(.endOfTrail(trail.id))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        let id = trail.id
        drag.leave { $0 == .endOfTrail(id) }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = drag.dragging else { drag.end(); return false }
        drag.end()
        if let anchor {
            store.moveTab(dragged, to: .after(anchor.id))
        } else {
            store.moveTab(dragged, to: .endOfTrail(trail.id))
        }
        return true
    }
}

private struct TrailDrop: ViewModifier {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var drag = TabDragState.shared
    let trail: Trail
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if drag.target == .endOfTrail(trail.id) {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: TabDragState.dropTypes,
                    delegate: TrailDropDelegate(trail: trail, drag: drag, store: store))
    }
}

// MARK: New row

private struct NewTrailDropDelegate: DropDelegate {
    let drag: TabDragState
    let store: BrowserStore

    func validateDrop(info: DropInfo) -> Bool { drag.dragging != nil }
    func dropEntered(info: DropInfo) { drag.hover(.newTrail) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { drag.leave { $0 == .newTrail } }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = drag.dragging else { drag.end(); return false }
        drag.end()
        store.moveTab(dragged, to: .newTrail)
        return true
    }
}

/// Floats at the bottom of the map while a tab is in the air. Dropping on it starts a new row.
struct NewTrailDropStrip: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var drag = TabDragState.shared
    let style: MapStyle

    var body: some View {
        if drag.dragging != nil {
            let targeted = drag.target == .newTrail
            HStack(spacing: 6) {
                Image(systemName: "plus.rectangle.on.rectangle")
                Text("New row")
            }
            .font(.system(size: style == .cards ? 13 : 11, weight: .medium))
            .foregroundColor(targeted ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: style == .cards ? 56 : 34)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Material.thick))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(targeted ? 0 : 0.5),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .contentShape(Rectangle())
            .onDrop(of: TabDragState.dropTypes, delegate: NewTrailDropDelegate(drag: drag, store: store))
            .padding(style == .cards ? 20 : 8)
        }
    }
}

extension View {
    /// Makes a tab cell draggable, and a place other tabs can be dropped beside.
    func tabDragDrop(tab: MapTab, cornerRadius: CGFloat = 6, acceptsDrops: Bool = true) -> some View {
        modifier(TabDragDrop(tab: tab, cornerRadius: cornerRadius, acceptsDrops: acceptsDrops))
    }

    /// Lets tabs be dropped on the empty part of a row, to join it at the end.
    func trailDrop(trail: Trail, cornerRadius: CGFloat) -> some View {
        modifier(TrailDrop(trail: trail, cornerRadius: cornerRadius))
    }
}
