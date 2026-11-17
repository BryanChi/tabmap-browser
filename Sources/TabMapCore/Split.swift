import Foundation

// Split view: two neighbouring tabs of one row shown side by side.
//
// A pair is made from two open tabs that sit next to each other in a row. It is remembered in the
// map, so leaving the pair and coming back to either tab shows both again. Pairs are checked every
// time they are read: once one of the two tabs is closed, forgotten or moved to another row, the
// pair simply stops counting. Nothing else in the map has to know about pairs to keep them honest.

/// Two tabs of one row viewed side by side.
public struct SplitPair: Codable, Equatable {
    /// The tab on the left, which is also the one further left in the row.
    public var left: TabID
    public var right: TabID
    /// Share of the width given to the left page.
    public var fraction: Double

    public static let fractionRange: ClosedRange<Double> = 0.25...0.75

    public init(left: TabID, right: TabID, fraction: Double = 0.5) {
        self.left = left
        self.right = right
        self.fraction = fraction
    }

    public func contains(_ id: TabID?) -> Bool {
        guard let id else { return false }
        return id == left || id == right
    }

    public func partner(of id: TabID) -> TabID? {
        if id == left { return right }
        if id == right { return left }
        return nil
    }
}

extension TabMap {
    /// Every remembered pair, live or not.
    public var splits: [SplitPair] {
        get { splitStore ?? [] }
        set { splitStore = newValue.isEmpty ? nil : newValue }
    }

    /// A pair counts while both tabs are open, have a page, and share a row.
    private func isLive(_ pair: SplitPair) -> Bool {
        guard pair.left != pair.right,
              let l = locate(pair.left), let r = locate(pair.right),
              l.trail == r.trail, l.tab < r.tab else { return false }
        let a = trails[l.trail].tabs[l.tab]
        let b = trails[r.trail].tabs[r.tab]
        return !a.isClosed && !b.isClosed && !a.isBlank && !b.isBlank
    }

    /// The pair `id` is part of, if it is in one that still counts.
    public func split(containing id: TabID?) -> SplitPair? {
        guard let id, let stored = splitStore else { return nil }
        return stored.first { $0.contains(id) && isLive($0) }
    }

    public func splitPartner(of id: TabID?) -> TabID? {
        guard let id else { return nil }
        return split(containing: id)?.partner(of: id)
    }

    /// The tabs that are on screen together when `id` is the current tab: the tab alone, or its pair
    /// from left to right.
    public func screen(of id: TabID?) -> [TabID] {
        guard let id else { return [] }
        if let pair = split(containing: id) { return [pair.left, pair.right] }
        return [id]
    }

    /// One name for a screen whichever of its tabs is current: the left tab of a pair, or the tab itself.
    public func screenID(of id: TabID?) -> TabID? {
        guard let id else { return nil }
        return split(containing: id)?.left ?? id
    }

    /// True when the two tabs are shown together (or are the same tab).
    public func sameScreen(_ a: TabID?, _ b: TabID?) -> Bool {
        guard let a, let b else { return false }
        return a == b || splitPartner(of: a) == b
    }

    /// The tabs on screen right now.
    public var onScreen: [TabID] { screen(of: activeTabID) }

    /// Two open tabs side by side in the same row, with only closed tabs (if anything) between them.
    public func areNeighbours(_ a: TabID, _ b: TabID) -> Bool {
        guard a != b, let la = locate(a), let lb = locate(b), la.trail == lb.trail else { return false }
        let open = trails[la.trail].openTabs.map(\.id)
        guard let ia = open.firstIndex(of: a), let ib = open.firstIndex(of: b) else { return false }
        return abs(ia - ib) == 1
    }

    /// Whether dragging `a` onto `b` should make a pair.
    public func canSplit(_ a: TabID, _ b: TabID) -> Bool {
        guard areNeighbours(a, b), let ta = tab(a), let tb = tab(b) else { return false }
        return !ta.isBlank && !tb.isBlank
    }

    /// Pairs two neighbouring tabs. Either tab leaves any pair it was in before.
    @discardableResult
    public mutating func split(_ a: TabID, with b: TabID) -> SplitPair? {
        guard canSplit(a, b), let la = locate(a), let lb = locate(b) else { return nil }
        let pair = la.tab < lb.tab ? SplitPair(left: a, right: b) : SplitPair(left: b, right: a)
        var kept = splits.filter { !$0.contains(a) && !$0.contains(b) && isLive($0) }
        kept.append(pair)
        splits = kept
        return pair
    }

    /// Ends the pair `id` is in. Both tabs stay open where they are.
    public mutating func unsplit(_ id: TabID) {
        splits = splits.filter { !$0.contains(id) }
    }

    public mutating func setSplitFraction(_ fraction: Double, for id: TabID) {
        guard var stored = splitStore, let i = stored.firstIndex(where: { $0.contains(id) && isLive($0) }) else { return }
        let range = SplitPair.fractionRange
        stored[i].fraction = min(range.upperBound, max(range.lowerBound, fraction))
        splitStore = stored
    }

    /// Forgets pairs that no longer count.
    public mutating func pruneSplits() {
        guard let stored = splitStore else { return }
        let live = stored.filter { isLive($0) }
        if live.count != stored.count { splits = live }
    }

    /// Like `neighbor`, but a pair counts as one stop: moving sideways from either half of a pair
    /// lands on the first tab beyond it. Used for swipes, where the whole screen moves.
    public func screenNeighbor(of id: TabID?, _ direction: MapDirection) -> TabID? {
        guard let id else { return neighbor(of: nil, direction) }
        var current = id
        // A pair has two tabs, so one extra step is the most this ever takes.
        for _ in 0..<3 {
            guard let next = neighbor(of: current, direction) else { return nil }
            if !sameScreen(next, id) { return next }
            current = next
        }
        return nil
    }

    /// Where a tab opened from `parentID` should go so that it does not land between the two halves
    /// of a pair: a link opened from the left half goes to the right of the pair.
    public func insertIndexKeepingSplit(_ index: Int, openedFrom parentID: TabID) -> Int {
        guard let pair = split(containing: parentID), pair.left == parentID,
              let l = locate(pair.left), let r = locate(pair.right) else { return index }
        let tabs = trails[l.trail].tabs
        // Only when the right half is what the new tab would have been put in front of.
        guard index == r.tab else { return index }
        var at = r.tab + 1
        while at < tabs.count, tabs[at].openerID == parentID || tabs[at].openerID == pair.right { at += 1 }
        return at
    }
}
