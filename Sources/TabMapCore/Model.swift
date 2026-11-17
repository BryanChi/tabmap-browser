import Foundation

public typealias TabID = UUID
public typealias TrailID = UUID

/// One page in the map.
public struct MapTab: Codable, Identifiable, Equatable {
    public let id: TabID
    public var url: URL?
    public var title: String
    /// The tab this one was opened from (cmd-click, target=_blank, window.open).
    public var openerID: TabID?
    public var createdAt: Date
    /// Drives the Y axis. Updated when the tab is actually used, not merely passed over.
    public var lastAccessedAt: Date
    /// Non-nil once the tab has been closed, by hand or by the sweeper. Closed tabs stay restorable.
    public var closedAt: Date?
    /// Pinned tabs are never closed automatically.
    public var pinned: Bool
    /// Set when the person dragged this tab to where it is now. Automatic grouping should respect it.
    public var movedByHandAt: Date?

    public init(id: TabID = TabID(), url: URL?, title: String = "", openerID: TabID? = nil, now: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.openerID = openerID
        self.createdAt = now
        self.lastAccessedAt = now
        self.closedAt = nil
        self.pinned = false
    }

    public var isClosed: Bool { closedAt != nil }
    public var isBlank: Bool { url == nil }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = url?.host, !host.isEmpty { return host }
        if let url, url.scheme != "about" { return url.absoluteString }
        return "New Tab"
    }

    /// True when every word of `query` is found in the title or the address.
    public func matches(_ query: String) -> Bool {
        let words = TextMatch.words(query)
        if words.isEmpty { return true }
        let address = url?.absoluteString ?? ""
        return words.allSatisfy { TextMatch.contains(title, $0) || TextMatch.contains(address, $0) }
    }
}

/// One row of the map: a context. Tabs run left to right in the order they branched off.
public struct Trail: Codable, Identifiable, Equatable {
    public let id: TrailID
    public var tabs: [MapTab]
    /// The tab that was last active in this row, so moving up or down lands where you left off.
    public var lastActiveTabID: TabID?
    /// A short name for the row, generated once it has two or more pages.
    public var name: String?
    /// One sentence about what the row is about.
    public var summary: String?
    /// The `contentSignature` the name and summary were generated for.
    public var labelSignature: String?

    public init(id: TrailID = TrailID(), tabs: [MapTab]) {
        self.id = id
        self.tabs = tabs
        self.lastActiveTabID = tabs.first?.id
    }

    public var openTabs: [MapTab] { tabs.filter { !$0.isClosed } }
    public var hasOpenTabs: Bool { tabs.contains { !$0.isClosed } }

    /// Tabs that hold a page (not blank), open or closed.
    public var pageTabs: [MapTab] { tabs.filter { !$0.isBlank } }

    /// Identifies what is in the row: each page's host, path and title, in order.
    /// Changes when a page is added, removed, navigates or retitles. The label fields are not part of it.
    public var contentSignature: String {
        pageTabs.map { tab -> String in
            let place: String
            if let url = tab.url, let host = url.host, !host.isEmpty {
                place = host.lowercased() + url.path
            } else {
                place = tab.url?.absoluteString ?? ""
            }
            return place + "\t" + tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")
    }

    /// The row is big enough to name and its name was made for different pages (or never made).
    public var needsLabel: Bool {
        pageTabs.count >= 2 && labelSignature != contentSignature
    }

    /// True when every word of `query` appears somewhere in the row's name and summary.
    public func labelMatches(_ query: String) -> Bool {
        let words = TextMatch.words(query)
        let text = [name, summary].compactMap { $0 }.joined(separator: " ")
        guard !words.isEmpty, !text.isEmpty else { return false }
        return words.allSatisfy { TextMatch.contains(text, $0) }
    }

    /// Recency of the row: the most recent access among its open tabs
    /// (or among all tabs once the whole row is closed).
    public var recency: Date {
        let pool = hasOpenTabs ? openTabs : tabs
        return pool.map(\.lastAccessedAt).max() ?? .distantPast
    }
}

public struct MapSettings: Codable, Equatable {
    /// A tab left untouched this long has its page unloaded. It keeps its place in the map.
    public var sleepAfter: TimeInterval = 30 * 60
    /// A tab left untouched this long is closed and sinks below the horizon.
    public var closeAfter: TimeInterval = 24 * 60 * 60
    /// A closed tab is forgotten for good after this long.
    public var purgeAfter: TimeInterval = 30 * 24 * 60 * 60
    /// Upper bound on pages kept in memory at once, whatever their age.
    public var maxLoadedTabs: Int = 12
    /// Search URL with %s standing in for the query.
    public var searchTemplate: String = "https://www.google.com/search?q=%s"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MapSettings()
        sleepAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .sleepAfter) ?? d.sleepAfter
        closeAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .closeAfter) ?? d.closeAfter
        purgeAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .purgeAfter) ?? d.purgeAfter
        maxLoadedTabs = try c.decodeIfPresent(Int.self, forKey: .maxLoadedTabs) ?? d.maxLoadedTabs
        searchTemplate = try c.decodeIfPresent(String.self, forKey: .searchTemplate) ?? d.searchTemplate
    }
}

/// The rows as they should be drawn, top to bottom.
public struct MapLayout: Equatable {
    /// Rows with at least one open tab, most recently used first.
    public var open: [Trail]
    /// Rows whose tabs are all closed, below the horizon, most recently used first.
    public var archived: [Trail]

    public var isEmpty: Bool { open.isEmpty && archived.isEmpty }
}

public enum MapDirection {
    case left, right, up, down
}

/// Coarse labels for the Y axis.
public enum TimeBand: Int, CaseIterable, Comparable {
    case lastHour, today, yesterday, thisWeek, older

    public static func < (a: TimeBand, b: TimeBand) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .lastHour: return "Last hour"
        case .today: return "Earlier today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .older: return "Older"
        }
    }

    public static func band(for date: Date, now: Date, calendar: Calendar = .current) -> TimeBand {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 3600 { return .lastHour }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return .yesterday
        }
        if elapsed < 7 * 86400 { return .thisWeek }
        return .older
    }
}
