import AppKit
import SwiftUI
import TabMapCore

// Picking several tabs at once in the map overview (⌘E), then acting on them together.
//
//   drag on empty map space        → a selection rectangle; the cards it touches are selected
//   ⌘- or ⇧-drag                   → the rectangle adds to what is already selected
//   ⌘-click a card                 → adds it to the selection, or takes it out
//   ⇧-click a card                 → adds every card from the last one picked up to this one
//   plain click on empty space     → clears the selection (a click on a row's empty slot still opens a tab)
//   drag a selected card           → the whole selection moves (TabDrag.swift calls `moveDragged`)
//   esc                            → clears the selection; ⌘W closes the selected tabs
//
// The bar at the bottom of the overview and the menu on a selected card hold the group actions.
//
// The pointer is read with a local event monitor rather than SwiftUI gestures, so the cards keep
// their own click and drag handling untouched and a plain click on an empty slot still opens a tab.
// Positions are in window coordinates measured from the top left, the same as the card frames
// (CardFramesKey); the selection rectangle is kept in the map's own coordinates so it follows a scroll.

@MainActor
final class MapSelection: ObservableObject {
    static let shared = MapSelection()

    /// The selected tabs. Only open tabs are ever selected.
    @Published private(set) var selected: Set<TabID> = []

    /// Where the map's cards are, from CardFramesKey.
    fileprivate var cardFrames: [TabID: CGRect] = [:]
    /// The scrolling area of the overview, in window coordinates.
    fileprivate var viewport: CGRect = .zero {
        didSet { if viewport.height != viewportHeight { viewportHeight = viewport.height } }
    }
    /// The map content is at least this tall, so a rectangle can start below the last row.
    @Published fileprivate private(set) var viewportHeight: CGFloat = 0
    /// The top left of the map content, in window coordinates. Moves as the map scrolls.
    fileprivate var contentOrigin: CGPoint = .zero {
        didSet { if press?.dragging == true { updateMarquee() } }
    }
    /// The action bar, whose clicks are its own.
    fileprivate var barFrame: CGRect = .zero

    /// The last card picked by a click: one end of a ⇧-click range.
    private var anchor: TabID?
    private var press: Press?
    private var monitor: Any?
    private var autoscroll: Timer?
    private var lastPoint: CGPoint = .zero

    private struct Press {
        /// Where the mouse went down, in map content coordinates.
        var start: CGPoint
        /// What stays selected whatever the rectangle covers (⌘/⇧-drag adds to the selection).
        var base: Set<TabID>
        var dragging = false
        /// A ⌘/⇧-click on a card: the card never hears about it.
        var swallowed = false
    }

    private init() {}

    /// Starts listening to the mouse. Called when the overview appears.
    fileprivate func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    // MARK: Selection

    func isSelected(_ id: TabID) -> Bool { selected.contains(id) }

    func clear() {
        if !selected.isEmpty { selected = [] }
        anchor = nil
    }

    /// The selected tabs in the order they appear in the map: rows top to bottom, tabs left to right.
    var ordered: [TabID] { Self.order(selected, frames: cardFrames, map: BrowserStore.shared.map) }

    /// The tabs to move when `id` is dropped somewhere: the whole selection when `id` is part of it.
    func group(dragging id: TabID) -> [TabID] {
        guard selected.count > 1, selected.contains(id) else { return [id] }
        return ordered
    }

    /// Takes out tabs that have closed or gone.
    fileprivate func prune(_ map: TabMap) {
        let kept = selected.filter { map.tab($0)?.isClosed == false }
        if kept != selected { selected = kept }
    }

    private func set(_ ids: Set<TabID>) {
        if ids != selected { selected = ids }
    }

    private func toggle(_ id: TabID) {
        var ids = selected
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        set(ids)
        anchor = id
    }

    /// ⇧-click: everything from the anchor to `id`, in map order, joins the selection.
    private func extend(to id: TabID) {
        guard let anchor, anchor != id else { toggle(id); return }
        let all = Self.order(Set(openCards.keys), frames: cardFrames, map: BrowserStore.shared.map)
        guard let a = all.firstIndex(of: anchor), let b = all.firstIndex(of: id) else { toggle(id); return }
        set(selected.union(all[min(a, b)...max(a, b)]))
        self.anchor = id
    }

    static func order(_ ids: Set<TabID>, frames: [TabID: CGRect], map: TabMap) -> [TabID] {
        ids.sorted { a, b in
            if let fa = frames[a], let fb = frames[b] {
                if abs(fa.minY - fb.minY) > 4 { return fa.minY < fb.minY }
                return fa.minX < fb.minX
            }
            // Not on screen (filtered out by a search): fall back to the map's own order.
            let la = map.locate(a).map { [$0.trail, $0.tab] } ?? [Int.max, Int.max]
            let lb = map.locate(b).map { [$0.trail, $0.tab] } ?? [Int.max, Int.max]
            return la.lexicographicallyPrecedes(lb)
        }
    }

    // MARK: Pointer

    /// The open cards that can be seen in the overview, with the title line under each thumbnail.
    private var openCards: [TabID: CGRect] {
        let map = BrowserStore.shared.map
        var cards: [TabID: CGRect] = [:]
        for (id, frame) in cardFrames where map.tab(id)?.isClosed == false {
            let card = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + Self.titleLine)
            // A card scrolled out of its row, or under the search bar, cannot be picked.
            guard card.intersects(viewport) else { continue }
            cards[id] = card
        }
        return cards
    }

    private static let titleLine: CGFloat = 24

    private func card(at point: CGPoint) -> TabID? {
        openCards.first { $0.value.contains(point) }?.key
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let store = BrowserStore.shared
        guard store.overviewShown, !BookmarkStore.shared.boardShown,
              let window = store.window, event.window === window, let content = window.contentView else {
            if event.type == .leftMouseUp { finish() }
            return event
        }
        let p = event.locationInWindow
        let point = CGPoint(x: p.x, y: content.bounds.height - p.y)

        switch event.type {
        case .leftMouseDown:
            press = nil
            guard event.clickCount == 1, viewport.contains(point), !barFrame.contains(point),
                  RowControls.shared.renaming == nil else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift])
            if let id = card(at: point) {
                // A plain click opens the card and a plain drag picks it up, as before.
                guard !flags.isEmpty else { return event }
                if flags.contains(.shift) { extend(to: id) } else { toggle(id) }
                press = Press(start: .zero, base: [], swallowed: true)
                return nil
            }
            press = Press(start: toContent(point), base: flags.isEmpty ? [] : selected)
            return event

        case .leftMouseDragged:
            guard var current = press else { return event }
            if current.swallowed { return nil }
            lastPoint = point
            if !current.dragging {
                let start = fromContent(current.start)
                guard hypot(point.x - start.x, point.y - start.y) > 4 else { return event }
                current.dragging = true
                press = current
                if current.base.isEmpty { clear() }
            }
            updateMarquee()
            updateAutoscroll()
            return nil

        case .leftMouseUp:
            guard let current = press else { return event }
            finish()
            if current.swallowed { return nil }
            if current.dragging {
                // Let go somewhere the press can't count as a click, so an empty slot the rectangle
                // started on doesn't open a tab.
                return NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: -10_000, y: -10_000),
                                          modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                          windowNumber: event.windowNumber, context: nil,
                                          eventNumber: event.eventNumber, clickCount: event.clickCount,
                                          pressure: 0) ?? event
            }
            // A plain click on empty space lets go of the selection.
            if current.base.isEmpty, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
                clear()
            }
            return event

        default:
            return event
        }
    }

    private func finish() {
        press = nil
        autoscroll?.invalidate()
        autoscroll = nil
        if MarqueeState.shared.rect != nil { MarqueeState.shared.rect = nil }
    }

    private func toContent(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - contentOrigin.x, y: p.y - contentOrigin.y) }
    private func fromContent(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + contentOrigin.x, y: p.y + contentOrigin.y) }

    private func updateMarquee() {
        guard let current = press, current.dragging else { return }
        let a = current.start
        let b = toContent(lastPoint)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        MarqueeState.shared.rect = rect
        let inWindow = rect.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
        let hits = openCards.filter { $0.value.intersects(inWindow) }.map(\.key)
        set(current.base.union(hits))
        if let last = Self.order(Set(hits), frames: cardFrames, map: BrowserStore.shared.map).last { anchor = last }
    }

    /// Holding the rectangle past the top or bottom of the map scrolls it.
    private func updateAutoscroll() {
        let edge: CGFloat = 28
        let outside = lastPoint.y < viewport.minY + edge || lastPoint.y > viewport.maxY - edge
        if outside, autoscroll == nil {
            autoscroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                Task { @MainActor in MapSelection.shared.scrollStep() }
            }
        } else if !outside {
            autoscroll?.invalidate()
            autoscroll = nil
        }
    }

    private func scrollStep() {
        guard press?.dragging == true, let scrollView = mapScrollView() else {
            autoscroll?.invalidate()
            autoscroll = nil
            return
        }
        let edge: CGFloat = 28
        var dy: CGFloat = 0
        if lastPoint.y < viewport.minY + edge { dy = -min(24, (viewport.minY + edge - lastPoint.y) / 2 + 2) }
        if lastPoint.y > viewport.maxY - edge { dy = min(24, (lastPoint.y - viewport.maxY + edge) / 2 + 2) }
        guard dy != 0, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        // SwiftUI's scroll views are flipped: y grows downwards, as on screen.
        let flipped = clip.isFlipped
        origin.y += flipped ? dy : -dy
        let maxY = max(0, document.frame.height - clip.bounds.height)
        origin.y = min(max(origin.y, 0), maxY)
        guard origin.y != clip.bounds.origin.y else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The overview's vertical scroll view: the one around the middle of the map that scrolls up and down.
    private func mapScrollView() -> NSScrollView? {
        guard let content = BrowserStore.shared.window?.contentView else { return nil }
        // hitTest takes a point in the superview's (the window frame's) coordinates, measured from the bottom.
        var view = content.hitTest(CGPoint(x: content.frame.minX + viewport.midX,
                                           y: content.frame.maxY - viewport.midY))
        while let v = view {
            if let scroll = v as? NSScrollView ?? v.enclosingScrollView {
                if let doc = scroll.documentView, doc.frame.height > scroll.contentView.bounds.height + 1 { return scroll }
                view = scroll.superview
            } else {
                return nil
            }
        }
        return nil
    }

    // MARK: Keys

    /// Esc lets go of the selection; ⌘W closes the selected tabs. Called from the overview's key handler.
    func handleKey(_ event: NSEvent) -> Bool {
        guard !selected.isEmpty else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, flags.isEmpty {
            clear()
            return true
        }
        if event.keyCode == 13, flags == .command { // ⌘W
            BrowserStore.shared.closeTabs(ordered)
            return true
        }
        return false
    }
}

/// The rectangle being dragged, kept apart from the selection so cards don't redraw as it grows.
@MainActor
final class MarqueeState: ObservableObject {
    static let shared = MarqueeState()
    /// In map content coordinates.
    @Published var rect: CGRect?
}

// MARK: Group actions

extension BrowserStore {
    /// A tab dropped in the map (TabDrag.swift). A selected tab brings the rest of the selection with it.
    func moveDragged(_ id: TabID, to placement: TabPlacement) {
        let group = MapSelection.shared.group(dragging: id)
        if group.count > 1 { moveTabs(group, to: placement) } else { moveTab(id, to: placement) }
    }

    /// Moves tabs together, in the order given, to one place: the first goes where `placement` says
    /// and each of the others lands just to the right of the one before.
    func moveTabs(_ ids: [TabID], to placement: TabPlacement) {
        var ids = ids
        // Dropped beside one of the group: that tab stays put and the others gather around it.
        switch placement {
        case .before(let target), .after(let target): ids.removeAll { $0 == target }
        default: break
        }
        guard !ids.isEmpty else { return }
        let now = Date()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            editMap { map in
                var changed = false
                var previous: TabID?
                for id in ids {
                    let place = previous.map { TabPlacement.after($0) } ?? placement
                    if map.moveTab(id, to: place, now: now) { changed = true }
                    previous = id
                }
                return changed
            }
        }
    }

    func closeTabs(_ ids: [TabID]) {
        for id in ids where map.tab(id)?.isClosed == false { closeTab(id) }
    }

    /// Unloads the pages, except the one on screen and anything playing.
    func sleepTabs(_ ids: [TabID]) {
        for id in ids where isLoaded(id) && id != map.activeTabID { sleepUnlessPlaying(id) }
    }

    /// Pins them all, or unpins them all when every one is already pinned.
    func pinTabs(_ ids: [TabID]) {
        let pin = !ids.allSatisfy { map.tab($0)?.pinned == true }
        for id in ids where map.tab(id)?.pinned != pin { togglePin(id) }
    }
}

// MARK: Views

extension View {
    /// The map content in the overview: draws the selection rectangle and keeps track of where things are.
    func mapSelectionContent() -> some View { modifier(MapSelectionContent()) }

    /// A card's selected look: a ring, and faded while the group is being dragged.
    func mapSelectionMark(_ id: TabID, style: MapStyle) -> some View { modifier(MapSelectionMark(id: id, style: style)) }
}

private struct MapSelectionContent: ViewModifier {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var marquee = MarqueeState.shared
    @ObservedObject private var selection = MapSelection.shared

    func body(content: Content) -> some View {
        content
            // Fill the visible map, so a rectangle can start below the last row.
            .frame(minHeight: max(0, selection.viewportHeight - 1), alignment: .top)
            .background(GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                Color.clear
                    .onAppear { MapSelection.shared.contentOrigin = origin }
                    .onChange(of: origin) { MapSelection.shared.contentOrigin = $0 }
            })
            .overlay(alignment: .topLeading) {
                if let rect = marquee.rect {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(CardFramesKey.self) { frames in
                Task { @MainActor in MapSelection.shared.cardFrames = frames }
            }
            .onAppear { MapSelection.shared.install() }
            .onDisappear { MapSelection.shared.clear() }
            .onChange(of: store.overviewShown) { shown in if !shown { MapSelection.shared.clear() } }
            .onReceive(store.$map) { MapSelection.shared.prune($0) }
    }
}

private struct MapSelectionMark: ViewModifier {
    @ObservedObject private var selection = MapSelection.shared
    @ObservedObject private var drag = TabDragState.shared
    let id: TabID
    let style: MapStyle

    func body(content: Content) -> some View {
        let picked = style == .cards && selection.selected.contains(id)
        // The dragged card fades itself (TabDrag.swift); the rest of its group fades with it.
        let carried = picked && selection.selected.count > 1 && drag.dragging != id
            && drag.dragging.map { selection.selected.contains($0) } == true
        content
            .overlay {
                if picked {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor, lineWidth: 2.5))
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if picked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: -9, y: -9)
                        .allowsHitTesting(false)
                }
            }
            .opacity(carried ? 0.35 : 1)
    }
}

/// Sits over the overview's scrolling map: measures it, and shows the action bar while tabs are selected.
struct MapSelectionLayer: View {
    @ObservedObject private var selection = MapSelection.shared
    @ObservedObject private var drag = TabDragState.shared

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            ZStack(alignment: .bottom) {
                Color.clear
                    .allowsHitTesting(false)
                    .onAppear { MapSelection.shared.viewport = frame }
                    .onChange(of: frame) { MapSelection.shared.viewport = $0 }
                if !selection.selected.isEmpty && drag.dragging == nil {
                    MapSelectionBar(ids: selection.ordered)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: selection.selected.isEmpty)
    }
}

private struct MapSelectionBar: View {
    let ids: [TabID]

    var body: some View {
        let store = BrowserStore.shared
        let allPinned = ids.allSatisfy { store.map.tab($0)?.pinned == true }
        HStack(spacing: 4) {
            Text(ids.count == 1 ? "1 tab" : "\(ids.count) tabs")
                .font(.system(size: 12, weight: .semibold))
                .padding(.leading, 8)
                .padding(.trailing, 6)
            action("New Row", "plus.rectangle.on.rectangle", "Move the selected tabs into a row of their own. To put them in another row, drag one of them there.") {
                store.moveTabs(ids, to: .newTrail)
            }
            action("Bookmark", "bookmark", "Save the selected tabs as one bookmark") {
                BookmarkStore.shared.bookmarkTabs(ids)
            }
            action("Sleep", "moon", "Unload the selected pages; they reload when you come back") {
                store.sleepTabs(ids)
            }
            action(allPinned ? "Unpin" : "Pin", allPinned ? "pin.slash" : "pin", "Pinned tabs never close by themselves") {
                store.pinTabs(ids)
            }
            action("Close", "xmark.square", "Close the selected tabs (⌘W)") {
                store.closeTabs(ids)
            }
            Divider().frame(height: 18).padding(.horizontal, 2)
            Button { MapSelection.shared.clear() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Deselect (esc)")
        }
        .padding(6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
        .background(GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onAppear { MapSelection.shared.barFrame = frame }
                .onChange(of: frame) { MapSelection.shared.barFrame = $0 }
                .onDisappear { MapSelection.shared.barFrame = .zero }
        })
    }

    private func action(_ title: String, _ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(MapSelectionButtonStyle())
        .help(help)
    }
}

private struct MapSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.0001)))
    }
}

/// The group actions at the top of a selected card's menu, when more than one tab is selected.
struct MapSelectionMenuItems: View {
    let tab: MapTab

    var body: some View {
        let selection = MapSelection.shared
        if selection.selected.count > 1, selection.isSelected(tab.id) {
            let ids = selection.ordered
            let store = BrowserStore.shared
            let n = ids.count
            Button("Move \(n) Tabs to New Row") { store.moveTabs(ids, to: .newTrail) }
            Button("Bookmark \(n) Tabs") { BookmarkStore.shared.bookmarkTabs(ids) }
            Button("Sleep \(n) Tabs") { store.sleepTabs(ids) }
            Button(ids.allSatisfy { store.map.tab($0)?.pinned == true } ? "Unpin \(n) Tabs" : "Pin \(n) Tabs") {
                store.pinTabs(ids)
            }
            Button("Close \(n) Tabs") { store.closeTabs(ids) }
            Button("Deselect All") { selection.clear() }
            Divider()
        }
    }
}
