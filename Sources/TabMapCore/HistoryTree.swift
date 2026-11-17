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
