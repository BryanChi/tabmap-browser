import Foundation

/// Where a tab dragged by hand should land.
public enum TabPlacement: Equatable {
    /// In the row of the given tab, immediately to its left.
    case before(TabID)
    /// In the row of the given tab, immediately to its right.
    case after(TabID)
    /// At the right-hand end of a row.
    case endOfTrail(TrailID)
    /// Alone in a brand new row.
    case newTrail
}

extension TabMap {
    /// Moves a tab to another row, or to another place in its own row, because the person said so.
    ///
    /// Only that one tab moves; tabs opened from it stay where they are. The tab keeps its identity,
    /// its open/closed state and its recency, so row order follows from the usual rule. A row left
    /// empty disappears. The tab is stamped `movedByHandAt` so automatic grouping can leave it alone.
    ///
    /// Returns false, changing nothing, when the move is impossible or would leave the tab where it is.
    @discardableResult
    public mutating func moveTab(_ id: TabID, to placement: TabPlacement, now: Date) -> Bool {
        guard let from = locate(id) else { return false }
        let sourceTabs = trails[from.trail].tabs

        // Refuse moves that go nowhere.
        switch placement {
        case .before(let target):
            guard target != id, let t = locate(target) else { return false }
            if t.trail == from.trail, t.tab == from.tab + 1 { return false }
        case .after(let target):
            guard target != id, let t = locate(target) else { return false }
            if t.trail == from.trail, t.tab == from.tab - 1 { return false }
        case .endOfTrail(let trailID):
            guard let ti = trails.firstIndex(where: { $0.id == trailID }) else { return false }
            if ti == from.trail, from.tab == sourceTabs.count - 1 { return false }
        case .newTrail:
            if sourceTabs.count == 1 { return false }
        }

        let original = self
        var tab = sourceTabs[from.tab]

        // Lift the tab out of its row.
        trails[from.trail].tabs.remove(at: from.tab)
        if trails[from.trail].tabs.isEmpty {
            trails.remove(at: from.trail)
        } else if trails[from.trail].lastActiveTabID == id {
            let rest = trails[from.trail].tabs
            let right = rest.dropFirst(from.tab).first { !$0.isClosed }
            let left = rest.prefix(from.tab).last { !$0.isClosed }
            trails[from.trail].lastActiveTabID = (right ?? left ?? rest.first)?.id
        }

        tab.movedByHandAt = now

        // Set it down.
        let destination: Int
        let insertAt: Int
        switch placement {
        case .before(let target):
            guard let t = locate(target) else { self = original; return false }
            destination = t.trail
            insertAt = t.tab
        case .after(let target):
            guard let t = locate(target) else { self = original; return false }
            destination = t.trail
            insertAt = t.tab + 1
        case .endOfTrail(let trailID):
            guard let ti = trails.firstIndex(where: { $0.id == trailID }) else { self = original; return false }
            destination = ti
            insertAt = trails[ti].tabs.count
        case .newTrail:
            tab.openerID = nil
            trails.append(Trail(tabs: [tab]))
            return true
        }

        // "Opened from" only means something inside one row.
        if let opener = tab.openerID, !trails[destination].tabs.contains(where: { $0.id == opener }) {
            tab.openerID = nil
        }
        trails[destination].tabs.insert(tab, at: insertAt)
        if activeTabID == id || trails[destination].lastActiveTabID == nil {
            trails[destination].lastActiveTabID = id
        }
        return true
    }
}
