import AppKit
import SwiftUI
import TabMapCore

// Controls for a whole row of the map, shown in the row's header when the pointer is over it:
// star or mark it with an emoji, open a new tab in it, put its pages to sleep, keep the row open,
// save it as a bookmark, rename it, close it (with undo). A closed row's header offers to bring it back.
// Also ⌘W in the map overview, which closes the card under the pointer.

@MainActor
final class RowControls: ObservableObject {
    static let shared = RowControls()

    /// The row just closed, while its "Undo" is on screen.
    struct Banner: Equatable {
        var record: ClosedRow
        var name: String
    }

    @Published private(set) var banner: Banner?
    /// The row whose name is being edited in place.
    @Published private(set) var renaming: TrailID?
    /// The row whose "Other Emoji…" field is open.
    @Published var pickingMark: TrailID?

    /// The last row closed as a whole, for ⇧⌘T. Outlives the banner.
    private var lastRow: ClosedRow?
    private var bannerExpiry: Task<Void, Never>?
    private let bannerLife: TimeInterval = 10

    private var store: BrowserStore { BrowserStore.shared }

    // MARK: Closing and reopening

    /// Closes every open tab in the row. The row sinks below the horizon and can be brought back
    /// with "Undo", ⇧⌘T, or the reopen button on its header.
    func closeRow(_ id: TrailID) {
        let map = store.map
        guard let trail = map.trail(id) else { return }
        let order = map.closingOrder(ofTrail: id)
        guard !order.isEmpty else { return }
        let active = map.activeTabID.flatMap { order.contains($0) ? $0 : nil }
        let pages = order.filter { map.tab($0)?.isBlank == false }
        let name = Self.name(of: trail)
        if renaming == id { renaming = nil }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            for tab in order { store.closeTab(tab) }
        }
        guard !pages.isEmpty else { return }
        let record = ClosedRow(trailID: id, tabIDs: pages, activeTabID: active, closedAt: Date())
        lastRow = record
        show(Banner(record: record, name: name))
    }

    /// "Undo" on the banner: the row comes back where it was, and its tab is current again if it was before.
    func undoClose() {
        guard let record = banner?.record else { return }
        restore(record)
    }

    /// ⇧⌘T: if the most recent close was a whole row, bring the whole row back. Returns false otherwise,
    /// so the usual "reopen the last closed tab" runs.
    func reopenRowIfLatest() -> Bool {
        guard let record = lastRow, store.map.isLatestClose(record) else { return false }
        restore(record)
        return true
    }

    private func restore(_ record: ClosedRow) {
        hideBanner()
        lastRow = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            store.editMap { $0.reopen(record.tabIDs) }
        }
        let back = record.activeTabID ?? record.tabIDs.last
        if let back, store.map.tab(back)?.isClosed == false {
            if store.overviewShown {
                store.overviewSelection = back
            } else {
                store.activate(back, commit: true)
                store.focusPage()
            }
        }
    }

    /// The reopen button on a closed row: every tab comes back and you land on the one you used last.
    func reopenRow(_ id: TrailID) {
        guard let trail = store.map.trail(id) else { return }
        let closed = trail.tabs.filter(\.isClosed).map(\.id)
        guard !closed.isEmpty else { return }
        let landing = trail.lastActiveTabID.flatMap { closed.contains($0) ? $0 : nil } ?? closed.first!
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            store.editMap { $0.reopen(closed.filter { $0 != landing }) }
        }
        store.choose(landing)
    }

    /// Removes a closed row from the map for good.
    func forgetRow(_ id: TrailID) {
        guard let trail = store.map.trail(id), !trail.hasOpenTabs else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            for tab in trail.tabs { store.forgetTab(tab.id) }
        }
    }

    // MARK: Keeping, naming

    func toggleKeep(_ id: TrailID) {
        store.editMap { map in
            map.toggleKeep(trail: id)
            return true
        }
    }

    func startRename(_ id: TrailID) {
        renaming = id
    }

    func finishRename(_ id: TrailID, _ text: String) {
        guard renaming == id else { return }
        renaming = nil
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = store.map.trail(id)?.name ?? ""
        guard clean != current else { return }
        store.editMap { $0.rename(trail: id, to: clean) }
    }

    func cancelRename() {
        renaming = nil
    }

    /// Lets the generated name come back.
    func nameAutomatically(_ id: TrailID) {
        store.editMap { $0.rename(trail: id, to: "") }
    }

    // MARK: New tab, sleep

    func newTab(in id: TrailID) {
        store.newTab(inRow: id)
    }

    func sleepRow(_ id: TrailID) {
        store.sleepRow(id)
    }

    // MARK: Marks

    func toggleStar(_ id: TrailID) {
        store.editMap { map in
            map.toggleStar(trail: id)
            return true
        }
    }

    func setMark(_ id: TrailID, _ mark: String?) {
        if pickingMark == id { pickingMark = nil }
        store.editMap { map in
            map.setMark(trail: id, mark)
            return true
        }
    }

    // MARK: ⌘W in the overview

    /// Closes the card under the pointer; with the pointer on no card, the selected one
    /// (which starts out as the current tab).
    func closeFromOverview() {
        if let id = cardUnderPointer() {
            if store.map.tab(id)?.isClosed == false { store.closeTab(id) }
            return
        }
        guard let id = store.overviewSelection ?? store.map.activeTabID,
              store.map.tab(id)?.isClosed == false else { return }
        store.closeTab(id)
    }

    /// The overview card the pointer is on, worked out from where the cards were last laid out,
    /// so it stays right when cards slide under a pointer that has not moved.
    private func cardUnderPointer() -> TabID? {
        guard let window = store.window, let content = window.contentView else { return nil }
        let p = window.mouseLocationOutsideOfEventStream
        // Card frames are measured from the top-left of the window.
        let point = CGPoint(x: p.x, y: content.bounds.height - p.y)
        guard content.bounds.contains(point), point.y > Self.overviewHeaderHeight else { return nil }
        let titleLine: CGFloat = 24 // the title under each thumbnail belongs to the card too
        return GestureNavigator.shared.cardFrames.first { _, frame in
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + titleLine).contains(point)
        }?.key
    }

    /// The search bar at the top of the overview. Cards scrolled up under it do not count.
    private static let overviewHeaderHeight: CGFloat = 76

    // MARK: Banner

    private func show(_ banner: Banner) {
        bannerExpiry?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { self.banner = banner }
        bannerExpiry = Task { @MainActor [weak self, bannerLife] in
            try? await Task.sleep(nanoseconds: UInt64(bannerLife * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hideBanner()
        }
    }

    private func hideBanner() {
        bannerExpiry?.cancel()
        guard banner != nil else { return }
        withAnimation(.easeOut(duration: 0.2)) { banner = nil }
    }

    static func name(of trail: Trail) -> String {
        if let name = trail.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return trail.openTabs.first?.displayTitle ?? trail.tabs.first?.displayTitle ?? "Row"
    }
}

// MARK: Views

/// A row with its name above it. With the pointer over the row, its controls show at the end of the name line
/// (or over the row's top-right corner when it has no name yet). Double-click the name to rename it.
struct RowFrame<Row: View>: View {
    @ObservedObject private var controls = RowControls.shared
    let trail: Trail
    let style: MapStyle
    let archived: Bool
    /// The row's name as drawn by the map; nil when the row has none.
    let label: AnyView?
    let row: () -> Row
    @State private var hovering = false

    /// A marked row always gets a name line, so its mark shows; an unnamed one uses its first tab's title.
    private var nameLine: AnyView? {
        if let label { return label }
        guard trail.mark != nil else { return nil }
        return AnyView(
            Text(RowControls.name(of: trail))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)
        )
    }

    var body: some View {
        let line = nameLine
        VStack(alignment: .leading, spacing: style == .cards ? 4 : 2) {
            if controls.renaming == trail.id {
                RowNameField(trail: trail, style: style)
            } else if let line {
                HStack(spacing: 6) {
                    if let mark = trail.mark {
                        RowMarkBadge(trail: trail, mark: mark, style: style)
                    }
                    line
                    Spacer(minLength: 0)
                    RowButtons(trail: trail, style: style, archived: archived, hovering: hovering)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { controls.startRename(trail.id) }
                .contextMenu { RowMenuItems(trail: trail, archived: archived) }
            }
            row()
                .overlay(alignment: style == .cards ? .topTrailing : .trailing) {
                    if line == nil, controls.renaming != trail.id, hovering {
                        RowButtons(trail: trail, style: style, archived: archived, hovering: hovering)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.regularMaterial))
                            .padding(style == .cards ? 8 : 4)
                            .transition(.opacity)
                    }
                }
        }
        .padding(trail.mark == nil ? 0 : (style == .cards ? 6 : 3))
        .background(markTint)
        .padding(trail.mark == nil ? 0 : (style == .cards ? -6 : -3))
        .popover(isPresented: Binding(get: { controls.pickingMark == trail.id },
                                      set: { if !$0, controls.pickingMark == trail.id { controls.pickingMark = nil } }),
                 arrowEdge: .bottom) {
            RowEmojiField(trail: trail)
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
    }

    /// A light accent wash and edge on a marked row, so it is easy to spot while scrolling.
    @ViewBuilder
    private var markTint: some View {
        if trail.mark != nil {
            let shape = RoundedRectangle(cornerRadius: style == .cards ? 12 : 8, style: .continuous)
            shape.fill(Color.accentColor.opacity(0.07))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1))
        }
    }
}

/// A row's star or emoji, always shown at the start of its name line. Click to remove it,
/// right-click to pick another.
struct RowMarkBadge: View {
    let trail: Trail
    let mark: String
    let style: MapStyle

    var body: some View {
        Button { RowControls.shared.setMark(trail.id, nil) } label: {
            Text(mark)
                .font(.system(size: style == .cards ? 13 : 11))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove the mark (right-click for another emoji)")
        .contextMenu { RowMarkMenuItems(trail: trail) }
        .padding(.leading, 2)
    }
}

/// The small icon buttons at the end of a row's name line.
struct RowButtons: View {
    @ObservedObject private var controls = RowControls.shared
    let trail: Trail
    let style: MapStyle
    let archived: Bool
    /// The buttons are on screen. The sleep button, which watches every page load, is only built then.
    let hovering: Bool

    var body: some View {
        HStack(spacing: style == .cards ? 10 : 7) {
            if archived {
                icon("arrow.uturn.backward", help: "Reopen this row") { controls.reopenRow(trail.id) }
            } else {
                if trail.mark == nil {
                    icon("star", help: "Star this row (right-click for an emoji)") { controls.toggleStar(trail.id) }
                        .contextMenu { RowMarkMenuItems(trail: trail) }
                }
                icon("plus", help: "New tab in this row") { controls.newTab(in: trail.id) }
                if hovering {
                    RowSleepButton(trail: trail, style: style)
                }
                icon(trail.isKept ? "pin.fill" : "pin",
                     help: trail.isKept ? "Let this row close on its own again"
                                        : "Keep this row open (its tabs never close on their own)") {
                    controls.toggleKeep(trail.id)
                }
                if RowMenuItems.canBookmark(trail) {
                    icon("bookmark", help: "Save this row as a bookmark") {
                        BookmarkStore.shared.bookmarkCurrentRow(trail.id)
                    }
                }
                Menu {
                    RowMenuItems(trail: trail, archived: archived)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More for this row")
                icon("xmark", help: "Close this row (⇧⌘T brings it back)") { controls.closeRow(trail.id) }
            }
        }
        .font(.system(size: style == .cards ? 11 : 10, weight: .semibold))
        .foregroundColor(.secondary)
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The moon button: shown only while the row has pages in memory besides the one on screen.
struct RowSleepButton: View {
    @ObservedObject private var store = BrowserStore.shared
    let trail: Trail
    let style: MapStyle

    var body: some View {
        if !store.map.tabsToSleep(inTrail: trail.id, loaded: store.loadedIDs).isEmpty {
            Button { RowControls.shared.sleepRow(trail.id) } label: {
                Image(systemName: "moon")
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sleep this row (free memory, keep the tabs)")
        }
    }
}

/// The emoji choices for a row's mark: from a right-click on the star or the mark, and the row menu.
struct RowMarkMenuItems: View {
    let trail: Trail

    static let choices = ["⭐️", "🔥", "📌", "💡", "✅", "❤️", "📚", "🛒", "✈️", "💼", "🎵", "🎮", "🧪", "📝", "🏠", "💰"]

    var body: some View {
        ForEach(Self.choices, id: \.self) { emoji in
            Button(trail.mark == emoji ? "\(emoji)  ✓" : emoji) { RowControls.shared.setMark(trail.id, emoji) }
        }
        Divider()
        Button("Other Emoji…") { RowControls.shared.pickingMark = trail.id }
        if trail.mark != nil {
            Button("Remove Mark") { RowControls.shared.setMark(trail.id, nil) }
        }
    }
}

/// "Other Emoji…": a one-character field with the system Character Viewer open beside it.
/// The first emoji typed or picked becomes the row's mark.
struct RowEmojiField: View {
    let trail: Trail
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type or pick an emoji")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("🙂", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 18))
                .frame(width: 120)
                .focused($focused)
                .onChange(of: text) { value in
                    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { RowControls.shared.setMark(trail.id, clean) }
                }
                .onExitCommand { RowControls.shared.pickingMark = nil }
        }
        .padding(12)
        .onAppear {
            DispatchQueue.main.async {
                focused = true
                NSApp.orderFrontCharacterPalette(nil)
            }
        }
    }
}

/// The row's menu: from the "…" button, or a right-click on the row's name.
struct RowMenuItems: View {
    @ObservedObject private var controls = RowControls.shared
    let trail: Trail
    let archived: Bool

    static func canBookmark(_ trail: Trail) -> Bool {
        trail.openTabs.filter { BookmarkStore.isSaveable($0.url) }.count >= 2
    }

    var body: some View {
        if archived {
            Button("Reopen Row") { controls.reopenRow(trail.id) }
            Button("Rename Row…") { controls.startRename(trail.id) }
            Menu("Mark with Emoji") { RowMarkMenuItems(trail: trail) }
            Divider()
            Button("Forget Row") { controls.forgetRow(trail.id) }
        } else {
            Button("New Tab in Row") { controls.newTab(in: trail.id) }
            Button("Sleep Row") { controls.sleepRow(trail.id) }
            Divider()
            Button(trail.mark == nil ? "Star Row" : "Remove Mark") { controls.toggleStar(trail.id) }
            Menu("Mark with Emoji") { RowMarkMenuItems(trail: trail) }
            Button("Rename Row…") { controls.startRename(trail.id) }
            if trail.namedByHand == true {
                Button("Name Automatically") { controls.nameAutomatically(trail.id) }
            }
            Button(trail.isKept ? "Let Row Close on Its Own" : "Keep Row Open") { controls.toggleKeep(trail.id) }
            if Self.canBookmark(trail) {
                Button("Save Row as Bookmark") { BookmarkStore.shared.bookmarkCurrentRow(trail.id) }
            }
            Divider()
            Button("Close Row") { controls.closeRow(trail.id) }
        }
    }
}

/// Edits a row's name in place. Return saves, Esc cancels, clicking away saves.
/// Clearing the name hands the row back to automatic naming.
struct RowNameField: View {
    let trail: Trail
    let style: MapStyle
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name this row", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .focused($focused)
            .onSubmit { RowControls.shared.finishRename(trail.id, text) }
            .onExitCommand { RowControls.shared.cancelRename() }
            .onChange(of: focused) { isFocused in
                if !isFocused { RowControls.shared.finishRename(trail.id, text) }
            }
            .onAppear {
                text = trail.name ?? ""
                DispatchQueue.main.async { focused = true }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
    }
}

/// "Closed <row> · Undo", at the top of the sidebar and the overview for a few seconds after a row is closed.
struct RowClosedBanner: View {
    @ObservedObject private var controls = RowControls.shared
    let compact: Bool

    var body: some View {
        if let banner = controls.banner {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                Text("Closed “\(banner.name)”")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button("Undo") { controls.undoClose() }
                    .controlSize(.small)
                    .help("Bring the row back (⇧⌘T)")
            }
            .padding(compact ? 10 : 12)
            .background(RoundedRectangle(cornerRadius: compact ? 9 : 12).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, compact ? 8 : 20)
            .padding(.top, compact ? 0 : 14)
            .padding(.bottom, compact ? 8 : 0)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
