import Foundation

/// The whole tab map. A value type holding every rule about where tabs go,
/// when they sleep and close, and how you move between them.
public struct TabMap: Codable, Equatable {
    public var trails: [Trail] = []
    public var activeTabID: TabID?
    public var settings = MapSettings()
    /// Split pairs. Read and change through `splits` and the functions in Split.swift.
    public var splitStore: [SplitPair]?

    public init() {}

    // MARK: Lookup

    public func locate(_ id: TabID) -> (trail: Int, tab: Int)? {
        for (ti, trail) in trails.enumerated() {
            if let i = trail.tabs.firstIndex(where: { $0.id == id }) { return (ti, i) }
        }
        return nil
    }

    public func tab(_ id: TabID?) -> MapTab? {
        guard let id, let loc = locate(id) else { return nil }
        return trails[loc.trail].tabs[loc.tab]
    }

    public var activeTab: MapTab? { tab(activeTabID) }

    public var allTabs: [MapTab] { trails.flatMap(\.tabs) }

    // MARK: Opening

    /// Opens a tab in a brand new row. Used for Cmd+T and for links arriving from outside.
    @discardableResult
    public mutating func openRoot(url: URL?, title: String = "", now: Date, activate: Bool = true) -> TabID {
        let tab = MapTab(url: url, title: title, now: now)
        trails.append(Trail(tabs: [tab]))
        if activate { self.activate(tab.id, now: now) }
        return tab.id
    }

    /// Opens a tab from `parentID`, placing it to the parent's right in the same row.
    /// Several children of one parent line up in the order they were opened.
    @discardableResult
    public mutating func openChild(of parentID: TabID, url: URL?, title: String = "", now: Date, activate: Bool) -> TabID? {
        guard let loc = locate(parentID) else { return nil }
        let tab = MapTab(url: url, title: title, openerID: parentID, now: now)
        var insertAt = loc.tab + 1
        let tabs = trails[loc.trail].tabs
        while insertAt < tabs.count, tabs[insertAt].openerID == parentID { insertAt += 1 }
        insertAt = insertIndexKeepingSplit(insertAt, openedFrom: parentID)
        trails[loc.trail].tabs.insert(tab, at: insertAt)
        if activate { self.activate(tab.id, now: now) }
        return tab.id
    }

    // MARK: Activation and access

    public struct Activation: Equatable {
        /// A never-used blank tab that was thrown away when you left it.
        public var discarded: TabID?
        /// True when activating brought a closed tab back.
        public var reopened: Bool
    }

    /// Makes a tab the current one. Reopens it if it was closed.
    /// Does not count as an access by itself, so stepping through tabs does not reshuffle the map;
    /// call `touch` once the tab is really in use.
    @discardableResult
    public mutating func activate(_ id: TabID, now: Date) -> Activation {
        guard let loc = locate(id) else { return Activation(discarded: nil, reopened: false) }
        let previous = activeTabID
        var reopened = false
        if trails[loc.trail].tabs[loc.tab].isClosed {
            trails[loc.trail].tabs[loc.tab].closedAt = nil
            trails[loc.trail].tabs[loc.tab].lastAccessedAt = now
            reopened = true
        }
        trails[loc.trail].lastActiveTabID = id
        activeTabID = id
        var discarded: TabID?
        if let previous, previous != id, let p = tab(previous), p.isBlank {
            remove(previous)
            discarded = previous
        }
        return Activation(discarded: discarded, reopened: reopened)
    }

    /// Records a real use of the tab. This is what lifts its row to the top.
    public mutating func touch(_ id: TabID, now: Date) {
        guard let loc = locate(id) else { return }
        trails[loc.trail].tabs[loc.tab].lastAccessedAt = now
    }

    public mutating func update(_ id: TabID, url: URL?, title: String?) {
        guard let loc = locate(id) else { return }
        if let url { trails[loc.trail].tabs[loc.tab].url = url }
        if let title { trails[loc.trail].tabs[loc.tab].title = title }
    }

    public mutating func setPinned(_ id: TabID, _ pinned: Bool) {
        guard let loc = locate(id) else { return }
        trails[loc.trail].tabs[loc.tab].pinned = pinned
    }

    // MARK: Closing and restoring

    /// Closes a tab by hand. Returns the tab that became active, if the closed one was active.
    @discardableResult
    public mutating func close(_ id: TabID, now: Date) -> TabID? {
        guard let loc = locate(id) else { return activeTabID }
        let wasActive = activeTabID == id
        let trailID = trails[loc.trail].id
        let position = loc.tab

        if trails[loc.trail].tabs[loc.tab].isBlank {
            remove(id)
        } else {
            trails[loc.trail].tabs[loc.tab].closedAt = now
        }
        guard wasActive else { return activeTabID }

        activeTabID = nil
        if let next = successor(afterClosingAt: position, inTrail: trailID) {
            activate(next, now: now)
        }
        return activeTabID
    }

    private func successor(afterClosingAt position: Int, inTrail trailID: TrailID) -> TabID? {
        if let trail = trails.first(where: { $0.id == trailID }) {
            let tabs = trail.tabs
            // Nearest open neighbour, preferring the right-hand side, then the left.
            if let right = tabs.dropFirst(min(position, tabs.count)).first(where: { !$0.isClosed }) {
                return right.id
            }
            if let left = tabs.prefix(min(position, tabs.count)).last(where: { !$0.isClosed }) {
                return left.id
            }
        }
        guard let top = layout().open.first else { return nil }
        if let last = top.lastActiveTabID, let t = top.tabs.first(where: { $0.id == last }), !t.isClosed {
            return last
        }
        return top.openTabs.first?.id
    }

    /// Brings back the most recently closed tab and makes it active.
    @discardableResult
    public mutating func reopenLastClosed(now: Date) -> TabID? {
        let closed = allTabs.filter(\.isClosed)
        guard let latest = closed.max(by: { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }) else {
            return nil
        }
        activate(latest.id, now: now)
        return latest.id
    }

    /// Forgets a tab completely.
    public mutating func remove(_ id: TabID) {
        guard let loc = locate(id) else { return }
        trails[loc.trail].tabs.remove(at: loc.tab)
        if trails[loc.trail].tabs.isEmpty {
            trails.remove(at: loc.trail)
        } else if trails[loc.trail].lastActiveTabID == id {
            trails[loc.trail].lastActiveTabID = trails[loc.trail].openTabs.first?.id ?? trails[loc.trail].tabs.first?.id
        }
        if activeTabID == id { activeTabID = nil }
    }

    // MARK: Ageing

    public struct SweepResult: Equatable {
        public var closed: [TabID] = []
        public var purged: [TabID] = []
        public var isEmpty: Bool { closed.isEmpty && purged.isEmpty }
    }

    /// Closes tabs that have gone unused for `closeAfter` and forgets closed tabs older than `purgeAfter`.
    /// The active tab and pinned tabs are never closed.
    public mutating func sweep(now: Date) -> SweepResult {
        let shown = onScreen
        var result = SweepResult()
        for ti in trails.indices {
            for i in trails[ti].tabs.indices {
                let t = trails[ti].tabs[i]
                if shown.contains(t.id) { continue }
                if t.isClosed {
                    if let closedAt = t.closedAt, now.timeIntervalSince(closedAt) >= settings.purgeAfter {
                        result.purged.append(t.id)
                    }
                } else if t.isBlank {
                    result.purged.append(t.id)
                } else if !t.pinned, now.timeIntervalSince(t.lastAccessedAt) >= settings.closeAfter {
                    trails[ti].tabs[i].closedAt = now
                    result.closed.append(t.id)
                }
            }
        }
        for id in result.purged { remove(id) }
        return result
    }

    /// Which loaded pages should be unloaded now: those idle past `sleepAfter`,
    /// plus the least recently used ones beyond `maxLoadedTabs`. Never the active tab.
    public func tabsToSleep(loaded: [TabID], now: Date) -> [TabID] {
        var asleep: [TabID] = []
        var awake: [MapTab] = []
        let shown = onScreen
        for id in loaded where !shown.contains(id) {
            guard let t = tab(id) else { asleep.append(id); continue }
            if t.isClosed || now.timeIntervalSince(t.lastAccessedAt) >= settings.sleepAfter {
                asleep.append(id)
            } else {
                awake.append(t)
            }
        }
        let activeLoaded = loaded.contains { $0 == activeTabID } ? 1 : 0
        let allowed = max(0, settings.maxLoadedTabs - activeLoaded)
        if awake.count > allowed {
            let byRecency = awake.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
            asleep.append(contentsOf: byRecency.dropFirst(allowed).map(\.id))
        }
        return asleep
    }

    // MARK: Layout

    /// Rows top to bottom. `query` filters tabs by title and address (every word must match),
    /// or keeps a whole row when its name and summary match; rows left empty are dropped.
    /// In rows that still have open tabs, the open tabs come first in their stored order and the
    /// closed ones follow, most recently closed first. Archived rows keep their stored order.
    public func layout(matching query: String = "") -> MapLayout {
        var open: [Trail] = []
        var archived: [Trail] = []
        let index = TextMatch.words(query).isEmpty ? [:] : tabIndex
        for trail in trails {
            // Row order is decided on the unfiltered row so a search does not reorder the map.
            let isOpen = trail.hasOpenTabs
            var shown = trail
            // A row whose name or summary matches is shown whole; otherwise only its matching tabs.
            if !trail.labelMatches(query) {
                shown.tabs = trail.tabs.filter { $0.matches(query, aliases: Self.searchAliases(of: $0, in: index)) }
            }
            if shown.tabs.isEmpty { continue }
            if isOpen {
                // Closed tabs gather at the right end of a live row, most recently closed first.
                // Only the drawn order changes: `trails` keeps each tab's place, so a reopened
                // tab goes back to where it was.
                let closed = shown.tabs.filter(\.isClosed)
                    .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
                shown.tabs = shown.tabs.filter { !$0.isClosed } + closed
                open.append(shown)
            } else {
                archived.append(shown)
            }
        }
        let recency = Dictionary(uniqueKeysWithValues: trails.map { ($0.id, $0.recency) })
        let order: (Trail, Trail) -> Bool = { a, b in
            let ra = recency[a.id] ?? .distantPast
            let rb = recency[b.id] ?? .distantPast
            if ra != rb { return ra > rb }
            return a.id.uuidString < b.id.uuidString
        }
        return MapLayout(open: open.sorted(by: order), archived: archived.sorted(by: order))
    }

    // MARK: Row names

    /// Rows that should get a (new) name, most recently used first.
    public func trailsNeedingLabels() -> [Trail] {
        trails.filter(\.needsLabel).sorted { $0.recency > $1.recency }
    }

    /// Stores a row's name and summary, but only if the row still holds the pages they were made for.
    /// Returns false when the row is gone or has changed since.
    @discardableResult
    public mutating func setLabel(trail id: TrailID, name: String, summary: String, signature: String) -> Bool {
        guard let i = trails.firstIndex(where: { $0.id == id }),
              trails[i].pageTabs.count >= 2,
              trails[i].contentSignature == signature
        else { return false }
        trails[i].name = name
        trails[i].summary = summary
        trails[i].labelSignature = signature
        return true
    }

    /// Removes the name from rows that have dropped below two pages. Returns true if anything changed.
    @discardableResult
    public mutating func clearStaleLabels() -> Bool {
        var changed = false
        for i in trails.indices where trails[i].pageTabs.count < 2 {
            if trails[i].name != nil || trails[i].summary != nil || trails[i].labelSignature != nil {
                trails[i].name = nil
                trails[i].summary = nil
                trails[i].labelSignature = nil
                changed = true
            }
        }
        return changed
    }

    /// Recency of a row as stored (unaffected by any filter applied to a layout).
    public func recency(ofTrail id: TrailID) -> Date {
        trails.first { $0.id == id }?.recency ?? .distantPast
    }

    // MARK: Moving around

    /// The tab reached from the active one by moving through open tabs only.
    /// Left and right stay inside the row. Up and down change rows and land on the tab
    /// that was last active there.
    public func neighbor(of id: TabID?, _ direction: MapDirection) -> TabID? {
        let rows = layout().open
        guard let id, let r = rows.firstIndex(where: { row in row.tabs.contains { $0.id == id } }) else {
            return rows.first.flatMap { landing(in: $0, column: 0) }
        }
        let openTabs = rows[r].openTabs
        guard let c = openTabs.firstIndex(where: { $0.id == id }) else { return openTabs.first?.id }
        switch direction {
        case .left: return c > 0 ? openTabs[c - 1].id : nil
        case .right: return c + 1 < openTabs.count ? openTabs[c + 1].id : nil
        case .up: return r > 0 ? landing(in: rows[r - 1], column: c) : nil
        case .down: return r + 1 < rows.count ? landing(in: rows[r + 1], column: c) : nil
        }
    }

    private func landing(in trail: Trail, column: Int) -> TabID? {
        let open = trail.openTabs
        if let last = trail.lastActiveTabID, open.contains(where: { $0.id == last }) { return last }
        guard !open.isEmpty else { return nil }
        return open[min(column, open.count - 1)].id
    }
}

/// Plain grid movement over whatever rows are on screen, used by the full map view
/// where closed tabs can be selected too.
public enum GridNav {
    public static func move(from id: TabID?, _ direction: MapDirection, in rows: [[TabID]]) -> TabID? {
        let rows = rows.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }
        guard let id,
              let r = rows.firstIndex(where: { $0.contains(id) }),
              let c = rows[r].firstIndex(of: id)
        else { return rows[0][0] }
        switch direction {
        case .left: return rows[r][max(c - 1, 0)]
        case .right: return rows[r][min(c + 1, rows[r].count - 1)]
        case .up:
            guard r > 0 else { return id }
            return rows[r - 1][min(c, rows[r - 1].count - 1)]
        case .down:
            guard r + 1 < rows.count else { return id }
            return rows[r + 1][min(c, rows[r + 1].count - 1)]
        }
    }
}
