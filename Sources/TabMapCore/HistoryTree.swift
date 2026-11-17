import Foundation

/// One page a tab has shown.
public struct HistoryNode: Codable, Identifiable, Equatable {
    public let id: Int
    public var url: URL
    public var title: String
    public var parent: Int?
    /// In the order they were first visited.
    public var children: [Int]
    public var visitedAt: Date

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = url.host, !host.isEmpty { return host }
        return url.absoluteString
    }
}

/// Where one page of the tree is drawn. Columns run left to right with depth, lanes top to bottom.
public struct PlacedHistoryNode: Identifiable, Equatable {
    public let id: Int
    public var column: Int
    public var lane: Int
    public var parent: Int?
    /// The current page or one of the pages that led to it.
    public var onCurrentPath: Bool
    public var isCurrent: Bool
}

public struct HistoryLayout: Equatable {
    public var nodes: [PlacedHistoryNode] = []
    public var columns = 0
    public var lanes = 0

    public func node(_ id: Int) -> PlacedHistoryNode? { nodes.first { $0.id == id } }
}

/// The back/forward history of one tab, kept as a tree instead of a list.
///
/// A browser's own history forgets: go back two pages, click a different link, and the two pages
/// you left are gone. Here that click starts a new branch beside the old one, so every detour
/// stays reachable.
public struct HistoryTree: Codable, Equatable {
    public private(set) var nodes: [Int: HistoryNode] = [:]
    public private(set) var rootID: Int?
    public private(set) var currentID: Int?
    private var nextID = 0

    /// Beyond this, the oldest abandoned pages are forgotten first.
    public static let maxNodes = 80

    public init() {}

    // MARK: Lookup

    public var count: Int { nodes.count }
    public var isEmpty: Bool { nodes.isEmpty }
    public func node(_ id: Int?) -> HistoryNode? { id.flatMap { nodes[$0] } }
    public var current: HistoryNode? { node(currentID) }

    /// True once a detour exists: some page led to more than one other page.
    public var hasBranches: Bool { nodes.values.contains { $0.children.count > 1 } }

    /// The pages that led to `id`, nearest first, not including `id` itself.
    public func ancestors(of id: Int?) -> [Int] {
        var result: [Int] = []
        var cursor = node(id)?.parent
        while let c = cursor, result.count <= nodes.count {
            result.append(c)
            cursor = nodes[c]?.parent
        }
        return result
    }

    /// Root to current, inclusive.
    public var pathToCurrent: [Int] {
        guard let currentID else { return [] }
        return Array(ancestors(of: currentID).reversed()) + [currentID]
    }

    /// The page "forward" leads to from `id`: the child visited most recently.
    public func preferredChild(of id: Int?) -> Int? {
        guard let n = node(id) else { return nil }
        var best: HistoryNode?
        for c in n.children {
            guard let child = nodes[c] else { continue }
            if best == nil || child.visitedAt > best!.visitedAt { best = child }
        }
        return best?.id
    }

    /// The pages reached by going forward repeatedly from `id`, nearest first.
    public func forwardChain(from id: Int?) -> [Int] {
        var result: [Int] = []
        var cursor = preferredChild(of: id)
        while let c = cursor, result.count <= nodes.count {
            result.append(c)
            cursor = preferredChild(of: c)
        }
        return result
    }

    // MARK: Recording

    /// Records a navigation from the current page to `url` and returns the page it landed on.
    /// Revisiting a page already reached from here follows the existing branch rather than adding a twin.
    @discardableResult
    public mutating func visit(url: URL, title: String = "", now: Date) -> Int {
        guard let currentID, let here = nodes[currentID] else {
            let id = makeNode(url: url, title: title, parent: nil, now: now)
            rootID = id
            self.currentID = id
            return id
        }
        if here.url == url {
            nodes[currentID]?.visitedAt = now
            if !title.isEmpty { nodes[currentID]?.title = title }
            return currentID
        }
        if let existing = here.children.first(where: { nodes[$0]?.url == url }) {
            nodes[existing]?.visitedAt = now
            if !title.isEmpty { nodes[existing]?.title = title }
            self.currentID = existing
            return existing
        }
        let id = makeNode(url: url, title: title, parent: currentID, now: now)
        nodes[currentID]?.children.append(id)
        self.currentID = id
        prune()
        return id
    }

    /// Makes an existing page the current one (back, forward, or a jump across branches).
    public mutating func move(to id: Int, now: Date) {
        guard nodes[id] != nil else { return }
        currentID = id
        nodes[id]?.visitedAt = now
    }

    /// Corrects what is known about a page, for a redirect or a title that arrived late.
    public mutating func update(_ id: Int, url: URL? = nil, title: String? = nil) {
        guard nodes[id] != nil else { return }
        if let url { nodes[id]?.url = url }
        if let title, !title.isEmpty { nodes[id]?.title = title }
    }

    private mutating func makeNode(url: URL, title: String, parent: Int?, now: Date) -> Int {
        let id = nextID
        nextID += 1
        nodes[id] = HistoryNode(id: id, url: url, title: title, parent: parent, children: [], visitedAt: now)
        return id
    }

    /// Keeps the tree within `maxNodes`. Abandoned branch tips go first, oldest first;
    /// when everything left leads to the current page, the far end of the path goes.
    private mutating func prune() {
        while nodes.count > Self.maxNodes {
            let keep = Set(pathToCurrent)
            let tips = nodes.values.filter { $0.children.isEmpty && !keep.contains($0.id) }
            if let oldest = tips.min(by: { ($0.visitedAt, $0.id) < ($1.visitedAt, $1.id) }) {
                if let p = oldest.parent { nodes[p]?.children.removeAll { $0 == oldest.id } }
                nodes[oldest.id] = nil
                continue
            }
            guard let root = rootID, root != currentID,
                  let only = nodes[root]?.children.first, nodes[root]?.children.count == 1
            else { return }
            nodes[root] = nil
            nodes[only]?.parent = nil
            rootID = only
        }
    }

    // MARK: Drawing

    /// Places every page on a grid. The path to the current page, and the way forward from it,
    /// run straight along the top lane; each detour hangs on a lane of its own underneath.
    public func layout() -> HistoryLayout {
        var result = HistoryLayout()
        guard let rootID, nodes[rootID] != nil else { return result }
        let path = Set(pathToCurrent)
        var nextLane = 0
        // Explicit stack, so a long history cannot overflow the call stack.
        var stack: [(id: Int, column: Int, lane: Int?)] = [(rootID, 0, 0)]
        while let entry = stack.popLast() {
            let (id, column, fixedLane) = entry
            guard let n = nodes[id] else { continue }
            let lane: Int
            if let fixedLane {
                lane = fixedLane
            } else {
                nextLane += 1
                lane = nextLane
            }
            result.nodes.append(PlacedHistoryNode(id: id, column: column, lane: lane, parent: n.parent,
                                                  onCurrentPath: path.contains(id), isCurrent: id == currentID))
            result.columns = max(result.columns, column + 1)
            result.lanes = max(result.lanes, lane + 1)

            // The child that carries on in the same lane: the one leading to the current page,
            // otherwise the one "forward" would take.
            let straight = n.children.first(where: { path.contains($0) }) ?? preferredChild(of: id)
            let detours = n.children.filter { $0 != straight }
                .sorted { (nodes[$0]?.visitedAt ?? .distantPast, $0) > (nodes[$1]?.visitedAt ?? .distantPast, $1) }
            // Pushed in reverse: the straight child and everything under it is placed first,
            // then the detours, newest nearest the main line.
            for d in detours.reversed() { stack.append((d, column + 1, nil)) }
            if let straight { stack.append((straight, column + 1, lane)) }
        }
        return result
    }
}

// MARK: - Rows for the back-button menu

/// One line of the history menu.
public struct HistoryMenuRow: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// A page.
        case page(Int)
        /// A side trip folded into one line: the pages reached from `start` onwards.
        case branch(start: Int, pages: Int, expanded: Bool)
    }

    public var kind: Kind
    /// Horizontal position of the row's dot in the graph: 0 is the main line, each
    /// side trip opened inside another sits one lane further right.
    public var lane: Int
    /// The row the graph line runs down to from this one (the page it came from).
    public var link: String?
    /// On the way from the first page to the current one.
    public var onCurrentPath: Bool
    public var isCurrent: Bool
    /// After the current page on the main line: where Forward goes.
    public var isAhead: Bool
    /// Inside a side trip (its own pages, not the folded line).
    public var inBranch: Bool

    public var id: String {
        switch kind {
        case .page(let n): return "p\(n)"
        case .branch(let start, _, _): return "b\(start)"
        }
    }

    public var node: Int {
        switch kind {
        case .page(let n): return n
        case .branch(let start, _, _): return start
        }
    }
}

extension HistoryTree {
    /// How many pages hang from `id`, itself included.
    public func subtreeSize(_ id: Int) -> Int {
        var count = 0
        var stack = [id]
        while let n = stack.popLast(), count <= nodes.count {
            guard let node = nodes[n] else { continue }
            count += 1
            stack.append(contentsOf: node.children)
        }
        return count
    }

    /// The menu, top to bottom, newest first like a browser's back list.
    ///
    /// The main line is one straight run: where Forward leads at the top, then the current page,
    /// then every page that led to it. Branches are never mixed into it. Each side trip is folded
    /// into a single row sitting just above the page it left from; expanding it (its start id in
    /// `expanded`) shows its pages in their own lane above that row, built the same way, so a
    /// side trip inside a side trip folds again.
    public func menuRows(expanded: Set<Int> = []) -> [HistoryMenuRow] {
        guard let rootID, nodes[rootID] != nil else { return [] }
        let path = Set(pathToCurrent)
        var bottomUp: [HistoryMenuRow] = []
        var stack: Set<Int> = []
        appendLine(from: rootID, lane: 0, firstLink: nil, inBranch: false,
                   path: path, expanded: expanded, into: &bottomUp, visiting: &stack)
        return bottomUp.reversed()
    }

    /// A line: `start`, then on through the child on the way to the current page, or failing that
    /// the child Forward would take.
    private func line(from start: Int, path: Set<Int>) -> [Int] {
        var result = [start]
        var cursor = start
        while result.count <= nodes.count, let n = nodes[cursor] {
            guard let next = n.children.first(where: { path.contains($0) }) ?? preferredChild(of: cursor) else { break }
            result.append(next)
            cursor = next
        }
        return result
    }

    private func appendLine(from start: Int, lane: Int, firstLink: String?, inBranch: Bool,
                            path: Set<Int>, expanded: Set<Int>,
                            into rows: inout [HistoryMenuRow], visiting: inout Set<Int>) {
        guard !visiting.contains(start) else { return }
        visiting.insert(start)
        let nodesInLine = line(from: start, path: path)
        var aheadOfCurrent = false
        var previousPage = firstLink
        for (i, id) in nodesInLine.enumerated() {
            guard let node = nodes[id] else { continue }
            let pageRow = HistoryMenuRow(kind: .page(id), lane: lane, link: previousPage,
                                         onCurrentPath: path.contains(id), isCurrent: id == currentID,
                                         isAhead: aheadOfCurrent && !inBranch, inBranch: inBranch)
            rows.append(pageRow)
            if id == currentID { aheadOfCurrent = true }
            previousPage = pageRow.id

            let next = i + 1 < nodesInLine.count ? nodesInLine[i + 1] : nil
            let detours = node.children.filter { $0 != next && nodes[$0] != nil }
                .sorted { (nodes[$0]!.visitedAt, $0) < (nodes[$1]!.visitedAt, $1) }
            // Oldest first going up, so the most recent side trip sits nearest the main line's next page.
            for d in detours {
                let open = expanded.contains(d)
                let fold = HistoryMenuRow(kind: .branch(start: d, pages: subtreeSize(d), expanded: open),
                                          lane: lane + 1, link: pageRow.id,
                                          onCurrentPath: false, isCurrent: false, isAhead: false, inBranch: true)
                rows.append(fold)
                if open {
                    appendLine(from: d, lane: lane + 1, firstLink: fold.id, inBranch: true,
                               path: path, expanded: expanded, into: &rows, visiting: &visiting)
                }
            }
        }
    }
}
