import SwiftUI
import TabMapCore

// The tab map is drawn the same way in two sizes:
//   the sidebar, always in view, with tabs as small chips
//   the overview (⌘E), full window, with tabs as thumbnail cards
// In both, each row is a trail (X axis: what opened from what) and rows are ordered by
// how recently they were used (Y axis). Below the horizon line are rows that have closed.

enum MapStyle {
    case chips, cards
}

/// One group of rows under a time label.
private struct MapSection: Identifiable {
    let band: TimeBand
    var trails: [Trail]
    var id: Int { band.rawValue }
}

struct TabMapView: View {
    @EnvironmentObject private var store: BrowserStore
    let style: MapStyle
    var query: String = ""
    var selection: TabID?

    var body: some View {
        let layout = store.mapLayout(matching: query)
        let now = Date()
        let sections = Self.sections(layout.open, map: store.map, now: now)

        VStack(alignment: .leading, spacing: style == .cards ? 18 : 10) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: style == .cards ? 10 : 5) {
                    bandLabel(section.band.label)
                    ForEach(section.trails) { trail in
                        labelled(trail) {
                            TrailRow(trail: trail, style: style, archived: false, selection: selection)
                        }
                    }
                }
            }

            if !layout.archived.isEmpty {
                horizon
                ForEach(layout.archived) { trail in
                    labelled(trail) {
                        TrailRow(trail: trail, style: style, archived: true, selection: selection)
                    }
                }
            }

            if layout.isEmpty {
                Text(query.isEmpty ? "Nothing here yet. Press ⌘T to start a trail." : "No tabs match “\(query)”.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: layout.open.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: layout.archived.map(\.id))
    }

    /// The row's generated name (and, in the overview, its summary) just above the row.
    private func labelled<Row: View>(_ trail: Trail, @ViewBuilder row: () -> Row) -> some View {
        VStack(alignment: .leading, spacing: style == .cards ? 4 : 2) {
            if let name = trail.name, !name.isEmpty {
                trailLabel(name: name, summary: trail.summary)
            }
            row()
        }
    }

    @ViewBuilder
    private func trailLabel(name: String, summary: String?) -> some View {
        switch style {
        case .cards:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.leading, 4)
        case .chips:
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)
                .help(summary ?? name)
        }
    }

    private func bandLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 4)
    }

    private var horizon: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text("CLOSED")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
        .padding(.top, 6)
        .help("Tabs below this line were closed. Click one to bring it back.")
    }

    private static func sections(_ trails: [Trail], map: TabMap, now: Date) -> [MapSection] {
        var sections: [MapSection] = []
        for trail in trails {
            let band = TimeBand.band(for: map.recency(ofTrail: trail.id), now: now)
            if let last = sections.indices.last, sections[last].band == band {
                sections[last].trails.append(trail)
            } else {
                sections.append(MapSection(band: band, trails: [trail]))
            }
        }
        return sections
    }
}

struct TrailRow: View {
    @EnvironmentObject private var store: BrowserStore
    let trail: Trail
    let style: MapStyle
    let archived: Bool
    let selection: TabID?

    /// A live row shows at most this many closed tabs; older ones sit behind the "+N" button.
    static let shownClosedLimit = 8

    /// How a row is drawn: `leading` tabs first (all of them in an archived row), then a gap and the
    /// `closed` tabs of a live row, then `hidden` closed tabs behind a button. `trail.tabs` comes from
    /// `layout()`, which already puts closed tabs last, most recently closed first.
    static func parts(of trail: Trail, archived: Bool) -> (leading: [MapTab], closed: [MapTab], hidden: [MapTab]) {
        guard !archived else { return (trail.tabs, [], []) }
        let open = trail.tabs.filter { !$0.isClosed }
        let closed = trail.tabs.filter(\.isClosed)
        return (open, Array(closed.prefix(shownClosedLimit)), Array(closed.dropFirst(shownClosedLimit)))
    }

    var body: some View {
        let parts = Self.parts(of: trail, archived: archived)
        let spacing: CGFloat = style == .cards ? 10 : 4
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        HStack(spacing: spacing) {
                            ForEach(parts.leading) { tab in placed(tab, acceptsDrops: true) }
                        }
                        if !parts.closed.isEmpty {
                            closedGap
                            HStack(spacing: spacing) {
                                // Closed tabs at the end can be dragged out but are not drop targets.
                                ForEach(parts.closed) { tab in placed(tab, acceptsDrops: false) }
                                if !parts.hidden.isEmpty {
                                    MoreClosedTabsButton(tabs: parts.hidden) { store.choose($0) }
                                }
                            }
                        }
                    }
                    .padding(style == .cards ? 8 : 4)
                }
                HistoryStrip(trail: trail, style: style, selection: selection)
            }
            .background(
                RoundedRectangle(cornerRadius: style == .cards ? 14 : 9)
                    .fill(Color.primary.opacity(isActiveTrail ? 0.08 : 0.035))
            )
            .trailDrop(trail: trail, cornerRadius: style == .cards ? 14 : 9)
            .onChange(of: store.map.activeTabID) { id in
                reveal(id, proxy)
            }
            .onChange(of: selection) { id in
                reveal(id, proxy)
            }
        }
    }

    private func placed(_ tab: MapTab, acceptsDrops: Bool) -> some View {
        cell(tab)
            .overlay(alignment: .topTrailing) { DownloadBadge(tabID: tab.id, style: style) }
            .tabDragDrop(tab: tab, cornerRadius: style == .cards ? 8 : 6, acceptsDrops: acceptsDrops)
            .modifier(SplitMarker(tab: tab, trail: trail, style: style))
            .id(tab.id)
            .contentShape(Rectangle())
            .onTapGesture { store.choose(tab.id) }
            .contextMenu { menu(tab) }
            .help(tooltip(tab))
    }

    /// The space between a live row's open tabs and its closed ones, with a faint line in the middle.
    private var closedGap: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 1, height: style == .cards ? 110 : 16)
            .frame(width: style == .cards ? 18 : 10)
    }

    private var isActiveTrail: Bool {
        guard let active = store.map.activeTabID else { return false }
        return trail.tabs.contains { $0.id == active }
    }

    private func reveal(_ id: TabID?, _ proxy: ScrollViewProxy) {
        guard let id, trail.tabs.contains(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
    }

    @ViewBuilder
    private func cell(_ tab: MapTab) -> some View {
        let isActive = tab.id == store.map.activeTabID
        let isSelected = tab.id == selection
        switch style {
        case .chips:
            TabChip(tab: tab,
                    isActive: isActive,
                    isLoaded: store.isLoaded(tab.id),
                    // In a live row a closed tab shrinks to its icon but keeps its place.
                    collapsed: tab.isClosed && !archived)
        case .cards:
            TabCard(tab: tab,
                    isActive: isActive,
                    isSelected: isSelected,
                    isLoaded: store.isLoaded(tab.id),
                    image: store.snapshot(for: tab.id),
                    version: store.snapshotVersions[tab.id] ?? 0)
        }
    }

    @ViewBuilder
    private func menu(_ tab: MapTab) -> some View {
        if tab.isClosed {
            Button("Reopen") { store.choose(tab.id) }
            Button("Forget This Tab") { store.forgetTab(tab.id) }
        } else {
            Button("Go to Tab") { store.choose(tab.id) }
            SplitMenuItems(tab: tab)
            if trail.tabs.count > 1 {
                Button("Move to New Row") { store.moveTab(tab.id, to: .newTrail) }
            }
            Button(tab.pinned ? "Unpin" : "Pin (Never Auto-Close)") { store.togglePin(tab.id) }
            if !tab.isBlank {
                Button("Keep in Dock") {
                    store.choose(tab.id)
                    AppDock.shared.keepCurrentTabInDock()
                }
            }
            Divider()
            Button("Close Tab") { store.closeTab(tab.id) }
        }
        DownloadMenuItems(tabID: tab.id)
    }

    private func tooltip(_ tab: MapTab) -> String {
        var lines = [tab.displayTitle]
        if let url = tab.url?.absoluteString, url != tab.displayTitle { lines.append(url) }
        if let note = store.sourceNote(for: tab) { lines.append(note) }
        if tab.isClosed { lines.append("Closed. Click to reopen.") }
        return lines.joined(separator: "\n")
    }
}

/// The "+N" capsule at the end of a live row; lists the closed tabs that are not drawn.
struct MoreClosedTabsButton: View {
    let tabs: [MapTab]
    let choose: (TabID) -> Void
    @State private var showing = false

    private let rowHeight: CGFloat = 26

    var body: some View {
        Button { showing = true } label: {
            Text("+\(tabs.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("\(tabs.count) more closed tabs")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tabs) { tab in
                        Button {
                            showing = false
                            choose(tab.id)
                        } label: {
                            HStack(spacing: 8) {
                                FaviconView(url: tab.url, size: 14)
                                Text(tab.displayTitle)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tab.url?.absoluteString ?? tab.displayTitle)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(width: 300, height: min(320, CGFloat(tabs.count) * rowHeight + 12))
        }
    }
}

struct TabChip: View {
    let tab: MapTab
    let isActive: Bool
    let isLoaded: Bool
    let collapsed: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !collapsed, let app = tab.sourceApp { SourceAppIcon(app: app, size: 14) }
            FaviconView(url: tab.url, size: 14)
                .overlay(alignment: .bottomTrailing) {
                    // A shrunk closed tab only has room for a badge.
                    if collapsed, let app = tab.sourceApp { SourceAppIcon(app: app, size: 9).offset(x: 3, y: 3) }
                }
            if !collapsed {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if tab.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8))
                }
            }
        }
        .padding(.horizontal, collapsed ? 5 : 8)
        .padding(.vertical, 5)
        .frame(maxWidth: collapsed ? nil : 150, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor : Color.primary.opacity(0.07))
        )
        .foregroundColor(isActive ? .white : .primary)
        .opacity(tab.isClosed ? 0.45 : (isLoaded || isActive ? 1 : 0.72))
    }
}

struct TabCard: View {
    let tab: MapTab
    let isActive: Bool
    let isSelected: Bool
    let isLoaded: Bool
    let image: NSImage?
    /// Only here so the card redraws when a new thumbnail is saved.
    let version: Int

    private let width: CGFloat = 208
    private let height: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height, alignment: .top)
                        .clipped()
                        .saturation(tab.isClosed ? 0 : 1)
                } else {
                    FaviconView(url: tab.url, size: 36)
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) { SourceAppCorner(app: tab.sourceApp) }
            .reportsCardFrame(for: tab.id)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: isSelected || isActive ? 3 : 1)
            )

            HStack(spacing: 6) {
                FaviconView(url: tab.url, size: 14)
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if tab.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.secondary)
                }
                if !tab.isClosed && !isLoaded && !isActive {
                    Image(systemName: "moon.fill").font(.system(size: 9)).foregroundColor(.secondary)
                        .help("Asleep: the page reloads when you come back")
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .opacity(tab.isClosed ? 0.6 : 1)
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isActive { return Color.accentColor.opacity(0.5) }
        return Color.primary.opacity(0.12)
    }
}

// MARK: Sidebar

/// Pinned, it sits beside the page; `floating`, it slides in over the page from the left edge.
struct MapSidebar: View {
    @EnvironmentObject private var store: BrowserStore
    let floating: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Tab Map")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { store.sidebarShown.toggle() } label: {
                    Image(systemName: store.sidebarShown ? "pin.slash" : "pin")
                }
                .help(store.sidebarShown ? "Unpin the map sidebar (⇧⌘S)" : "Pin the map sidebar open (⇧⌘S)")
                Button { store.newTrail() } label: { Image(systemName: "plus") }
                    .help("New trail (⌘T)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.top, 34) // clear of the window buttons
            .padding(.bottom, 10)
            .background(WindowDragArea()) // the header moves the window; its buttons stay clickable

            AppDockStrip()

            MergeSuggestionBanner(advisor: store.mergeAdvisor, compact: true)
            ScrollView(.vertical) {
                TabMapView(style: .chips)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .bottom) { NewTrailDropStrip(style: .chips) }
        }
        .background {
            if floating {
                Rectangle().fill(.regularMaterial)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }
}

// MARK: Overview

struct MapOverview: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                NativeTextField(text: $store.overviewQuery,
                                placeholder: "Search tabs and groups",
                                fontSize: 16,
                                focusOnAppear: true)
                    .frame(height: 22)
                Text("arrows to move · return to open · ⌘⌫ to close · esc to dismiss")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 38) // clear of the window buttons
            .padding(.bottom, 14)
            .background(WindowDragArea())
            Divider()
            if store.overviewQuery.isEmpty { MergeSuggestionBanner(advisor: store.mergeAdvisor, compact: false) }
            AppDockOverviewRow()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    TabMapView(style: .cards, query: store.overviewQuery, selection: store.overviewSelection)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(alignment: .bottom) { NewTrailDropStrip(style: .cards) }
                .onChange(of: store.overviewSelection) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: store.overviewQuery) { _ in store.overviewQueryChanged() }
    }
}
