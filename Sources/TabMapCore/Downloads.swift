import Foundation

// Downloads, tied to the map. Every file remembers the tab and the row it came from,
// so a tab can show how many files were taken from it, a file name can find its tab,
// and a file can lead back to its page even after the tab has closed.
//
// Goes in Sources/TabMapCore. Pure Foundation, covered by DownloadsTests.

public typealias DownloadID = UUID

/// One downloaded file and where it came from.
public struct DownloadRecord: Codable, Identifiable, Equatable {
    public enum State: String, Codable {
        case inProgress, finished, failed, cancelled
    }

    public let id: DownloadID
    public var filename: String
    /// Where the file was saved. Nil until a destination has been chosen.
    public var filePath: String?
    /// The address of the file itself.
    public var sourceURL: URL?
    /// The page the download was started from.
    public var pageURL: URL?
    public var pageTitle: String
    /// The tab the download was started from. The tab may since have closed or been forgotten.
    public var tabID: TabID?
    /// The row that tab was in when the download started. Used once the tab itself is gone.
    public var trailID: TrailID?
    public var startedAt: Date
    public var finishedAt: Date?
    public var state: State
    public var byteCount: Int64?

    public init(id: DownloadID = DownloadID(), filename: String, sourceURL: URL?, pageURL: URL?,
                pageTitle: String = "", tabID: TabID?, trailID: TrailID?, now: Date) {
        self.id = id
        self.filename = filename
        self.filePath = nil
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.tabID = tabID
        self.trailID = trailID
        self.startedAt = now
        self.finishedAt = nil
        self.state = .inProgress
        self.byteCount = nil
    }

    /// Failed and cancelled downloads do not count as files taken from a tab.
    public var countsTowardTab: Bool { state == .inProgress || state == .finished }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return false }
        return filename.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Downloads that belong together in the list: everything taken from one row of the map.
public struct DownloadGroup: Identifiable, Equatable {
    public let id: String
    /// Nil for files whose row is no longer in the map.
    public var trailID: TrailID?
    public var title: String
    /// Newest first.
    public var records: [DownloadRecord]

    public var latest: Date { records.first?.startedAt ?? .distantPast }
}

/// Every download Tabmap knows about. A value type, saved beside the map.
public struct DownloadLedger: Codable, Equatable {
    public var records: [DownloadRecord] = []

    public init() {}

    // MARK: Recording

    @discardableResult
    public mutating func start(filename: String, sourceURL: URL?, pageURL: URL?, pageTitle: String = "",
                               tabID: TabID?, trailID: TrailID?, now: Date) -> DownloadID {
        let record = DownloadRecord(filename: filename, sourceURL: sourceURL, pageURL: pageURL,
                                    pageTitle: pageTitle, tabID: tabID, trailID: trailID, now: now)
        records.append(record)
        return record.id
    }

    private func index(_ id: DownloadID) -> Int? {
        records.firstIndex { $0.id == id }
    }

    public func record(_ id: DownloadID) -> DownloadRecord? {
        index(id).map { records[$0] }
    }

    public mutating func setDestination(_ id: DownloadID, path: String, filename: String) {
        guard let i = index(id) else { return }
        records[i].filePath = path
        records[i].filename = filename
    }

    public mutating func setPage(_ id: DownloadID, url: URL?, title: String) {
        guard let i = index(id) else { return }
        if let url { records[i].pageURL = url }
        if !title.isEmpty { records[i].pageTitle = title }
    }

    public mutating func finish(_ id: DownloadID, byteCount: Int64?, now: Date) {
        guard let i = index(id), records[i].state == .inProgress else { return }
        records[i].state = .finished
        records[i].finishedAt = now
        records[i].byteCount = byteCount
    }

    /// Marks a download as failed, or as cancelled when the person stopped it. A finished download stays finished.
    public mutating func fail(_ id: DownloadID, cancelled: Bool, now: Date) {
        guard let i = index(id), records[i].state == .inProgress else { return }
        records[i].state = cancelled ? .cancelled : .failed
        records[i].finishedAt = now
    }

    /// Called at launch: anything still marked as running was cut off when the app quit.
    public mutating func markInterrupted(now: Date) {
        for i in records.indices where records[i].state == .inProgress {
            records[i].state = .failed
            records[i].finishedAt = now
        }
    }

    public mutating func remove(_ id: DownloadID) {
        records.removeAll { $0.id == id }
    }

    /// Clears the list of everything that is not still downloading. Files on disk are left alone.
    public mutating func clearInactive() {
        records.removeAll { $0.state != .inProgress }
    }

    /// Points downloads at a new tab, used when the page they came from is opened again in a fresh tab.
    public mutating func retarget(from old: TabID?, record id: DownloadID, to tab: TabID, trail: TrailID?) {
        for i in records.indices where records[i].id == id || (old != nil && records[i].tabID == old) {
            records[i].tabID = tab
            records[i].trailID = trail
        }
    }

    // MARK: Per tab

    public func records(forTab tab: TabID) -> [DownloadRecord] {
        records.filter { $0.tabID == tab }.sorted { $0.startedAt > $1.startedAt }
    }

    /// How many files were downloaded from this tab. This is the number on the tab's badge.
    public func count(forTab tab: TabID) -> Int {
        records.reduce(0) { $0 + (($1.tabID == tab && $1.countsTowardTab) ? 1 : 0) }
    }

    public func isDownloading(tab: TabID) -> Bool {
        records.contains { $0.tabID == tab && $0.state == .inProgress }
    }

    public var activeCount: Int {
        records.reduce(0) { $0 + ($1.state == .inProgress ? 1 : 0) }
    }

    // MARK: Search

    /// Tabs that a file matching `query` was downloaded from, so the map's search can find a tab by file name.
    public func tabIDs(matching query: String) -> Set<TabID> {
        var ids: Set<TabID> = []
        for r in records where r.countsTowardTab && r.matches(query) {
            if let tab = r.tabID { ids.insert(tab) }
        }
        return ids
    }

    /// The first file from `tab` whose name matches `query`.
    public func firstMatch(forTab tab: TabID, query: String) -> DownloadRecord? {
        records(forTab: tab).first { $0.countsTowardTab && $0.matches(query) }
    }

    /// The download saved at `path`, newest first if a path was reused.
    public func record(atPath path: String) -> DownloadRecord? {
        records.last { $0.filePath == path }
    }

    /// The newest download of the file at this address.
    public func record(fromSource url: URL) -> DownloadRecord? {
        records.last { $0.sourceURL == url }
    }

    // MARK: Grouping

    /// The list, grouped by the row of the map each file came from. A file follows its tab if the tab
    /// has moved to another row. Groups are ordered by their newest download. `onlyTab` narrows to one tab.
    public func groups(in map: TabMap, onlyTab: TabID? = nil) -> [DownloadGroup] {
        var order: [String] = []
        var byKey: [String: DownloadGroup] = [:]
        let lost = "lost"

        for record in records.sorted(by: { $0.startedAt > $1.startedAt }) {
            if let onlyTab, record.tabID != onlyTab { continue }
            var trail: Trail?
            if let tab = record.tabID, let loc = map.locate(tab) {
                trail = map.trails[loc.trail]
            } else if let id = record.trailID {
                trail = map.trails.first { $0.id == id }
            }
            let key = trail?.id.uuidString ?? lost
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = DownloadGroup(id: key,
                                           trailID: trail?.id,
                                           title: trail?.tabs.first?.displayTitle ?? "Pages no longer in the map",
                                           records: [])
            }
            byKey[key]?.records.append(record)
        }
        return order.compactMap { byKey[$0] }
    }
}

public extension TabMap {
    /// Like `layout(matching:)`, but a tab in `extra` is kept even when its title and address do not match.
    /// The search uses this to show tabs found by the name of a file downloaded from them.
    func layout(matching query: String, alsoShowing extra: Set<TabID>) -> MapLayout {
        if extra.isEmpty { return layout(matching: query) }
        let full = layout()
        func keep(_ rows: [Trail]) -> [Trail] {
            rows.compactMap { row in
                var shown = row
                shown.tabs = row.tabs.filter { $0.matches(query) || extra.contains($0.id) }
                return shown.tabs.isEmpty ? nil : shown
            }
        }
        return MapLayout(open: keep(full.open), archived: keep(full.archived))
    }
}
