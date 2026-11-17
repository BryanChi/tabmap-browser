import Foundation

// Row-level actions for the controls in each row's header: close or reopen a whole row,
// keep it open, and give it a name of your own.

/// What closing a whole row did, so it can be undone.
public struct ClosedRow: Equatable {
    public var trailID: TrailID
    /// The page tabs that were open and are now closed. Blank tabs are simply dropped.
    public var tabIDs: [TabID]
    /// The tab that was current, if it was in this row.
    public var activeTabID: TabID?
    public var closedAt: Date

    public init(trailID: TrailID, tabIDs: [TabID], activeTabID: TabID?, closedAt: Date) {
        self.trailID = trailID
        self.tabIDs = tabIDs
        self.activeTabID = activeTabID
        self.closedAt = closedAt
    }
}

extension TabMap {
    public func trail(_ id: TrailID) -> Trail? {
        trails.first { $0.id == id }
    }

    /// The order to close a row's open tabs in: everything else first and the current tab last,
    /// so closing does not step through (and load) each neighbour on the way.
    public func closingOrder(ofTrail id: TrailID) -> [TabID] {
        guard let trail = trail(id) else { return [] }
        let open = trail.openTabs.map(\.id)
        guard let active = activeTabID, open.contains(active) else { return open }
        return open.filter { $0 != active } + [active]
    }

    /// Brings closed tabs back where they were, without making any of them current.
    /// Returns true if any tab came back.
    @discardableResult
    public mutating func reopen(_ ids: [TabID]) -> Bool {
        var changed = false
        for id in ids {
            guard let loc = locate(id), trails[loc.trail].tabs[loc.tab].isClosed else { continue }
            trails[loc.trail].tabs[loc.tab].closedAt = nil
            changed = true
        }
        return changed
    }

    /// True when every closed tab in `ids` was closed no earlier than any other closed tab in the map,
    /// i.e. nothing else has been closed since. Used to let ⇧⌘T bring the whole row back.
    public func isLatestClose(_ record: ClosedRow) -> Bool {
        let closedHere = record.tabIDs.compactMap { tab($0) }.filter(\.isClosed)
        guard !closedHere.isEmpty else { return false }
        let ids = Set(record.tabIDs)
        let latestElsewhere = allTabs.filter { $0.isClosed && !ids.contains($0.id) }.compactMap(\.closedAt).max()
        guard let latestElsewhere else { return true }
        return latestElsewhere <= record.closedAt
    }

    /// Keeps every open page in the row from closing on its own, or lets them close again.
    /// Returns the new state: true when the row is now kept.
    @discardableResult
    public mutating func toggleKeep(trail id: TrailID) -> Bool {
        guard let t = trails.firstIndex(where: { $0.id == id }) else { return false }
        let keep = !trails[t].isKept
        for i in trails[t].tabs.indices where !trails[t].tabs[i].isClosed && !trails[t].tabs[i].isBlank {
            trails[t].tabs[i].pinned = keep
        }
        return keep
    }

    /// Names a row by hand. The name sticks: automatic naming leaves the row alone from now on.
    /// An empty name hands the row back to automatic naming.
    @discardableResult
    public mutating func rename(trail id: TrailID, to name: String) -> Bool {
        guard let t = trails.firstIndex(where: { $0.id == id }) else { return false }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            trails[t].namedByHand = nil
            trails[t].name = nil
            trails[t].summary = nil
            trails[t].labelSignature = nil
        } else {
            trails[t].name = String(clean.prefix(60))
            trails[t].namedByHand = true
        }
        return true
    }

    /// Removes a whole closed row from the map for good. Returns the tabs that were removed.
    @discardableResult
    public mutating func forget(trail id: TrailID) -> [TabID] {
        guard let t = trails.firstIndex(where: { $0.id == id }), !trails[t].hasOpenTabs else { return [] }
        let ids = trails[t].tabs.map(\.id)
        trails.remove(at: t)
        return ids
    }
}

extension TabMap {
    // MARK: Marks

    /// The mark a row gets from the star button.
    public static let starMark = "⭐️"

    /// Puts a star or emoji on a row, or clears it with nil (or blank text). Only the first character
    /// is kept, so one emoji with its modifiers survives but a pasted sentence does not.
    /// Returns the row's mark afterwards.
    @discardableResult
    public mutating func setMark(trail id: TrailID, _ mark: String?) -> String? {
        guard let t = trails.firstIndex(where: { $0.id == id }) else { return nil }
        let clean = mark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        trails[t].mark = clean.first.map { String($0) }
        return trails[t].mark
    }

    /// The star button: stars an unmarked row, clears any mark otherwise. Returns the mark afterwards.
    @discardableResult
    public mutating func toggleStar(trail id: TrailID) -> String? {
        guard let trail = trail(id) else { return nil }
        return setMark(trail: id, trail.mark == nil ? Self.starMark : nil)
    }

    // MARK: New tab in a row, sleeping a row

    /// Where the row's "+" button puts a new blank tab: to the right of the row's last-active tab
    /// when it is still open, else after the row's last open tab. Nil for a row with nothing open.
    public func newTabParent(inTrail id: TrailID) -> TabID? {
        guard let trail = trail(id) else { return nil }
        let open = trail.openTabs
        if let last = trail.lastActiveTabID, open.contains(where: { $0.id == last }) { return last }
        return open.last?.id
    }

    /// A blank tab already open in the row, which "+" reuses instead of adding another.
    public func openBlank(inTrail id: TrailID) -> TabID? {
        trail(id)?.openTabs.first(where: \.isBlank)?.id
    }

    /// The row's pages that "Sleep Row" unloads: every loaded open tab except what is on screen.
    public func tabsToSleep(inTrail id: TrailID, loaded: Set<TabID>) -> [TabID] {
        guard let trail = trail(id) else { return [] }
        let shown = Set(onScreen)
        return trail.openTabs.map(\.id).filter { loaded.contains($0) && !shown.contains($0) }
    }
}

extension Trail {
    /// The row has open pages and all of them are pinned (never auto-closed).
    public var isKept: Bool {
        let pages = openTabs.filter { !$0.isBlank }
        return !pages.isEmpty && pages.allSatisfy(\.pinned)
    }
}
