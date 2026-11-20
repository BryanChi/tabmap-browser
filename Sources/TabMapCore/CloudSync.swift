import Foundation

// Syncing with your other Macs: the rules, with no AppKit or iCloud code. The app side is in CloudSync.swift.
//
// Each Mac writes only its own files into a shared folder (iCloud Drive), so two Macs never edit the same file:
//   devices/<device id>/rows.json        the rows open on that Mac, to open here
//   devices/<device id>/bookmarks.json   that Mac's bookmarks, with when each one last changed and what it deleted
// Every Mac reads the others' files and merges bookmarks into its own library. Rows are not merged: they show
// as "On <Mac name>" and you bring a row over when you want it.

// MARK: Bookmarks

/// One Mac's bookmarks as written to the shared folder.
public struct DeviceBookmarks: Codable, Equatable {
    public var deviceID: String
    public var deviceName: String
    public var savedAt: Date
    public var bookmarks: [Bookmark]
    /// When each bookmark last changed, by bookmark id (uuidString). Newest change wins.
    public var changed: [String: Date]
    /// Bookmarks this Mac deleted, and when.
    public var deleted: [String: Date]

    public init(deviceID: String, deviceName: String, savedAt: Date, bookmarks: [Bookmark],
                changed: [String: Date], deleted: [String: Date]) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.savedAt = savedAt
        self.bookmarks = bookmarks
        self.changed = changed
        self.deleted = deleted
    }
}

/// What this Mac remembers between syncs, to tell its own changes from ones it took from other Macs.
public struct BookmarkSyncState: Codable, Equatable {
    /// The library as it was right after the last sync.
    public var baseline: [Bookmark] = []
    public var changed: [String: Date] = [:]
    public var deleted: [String: Date] = [:]

    public init() {}
}

/// What a merge did to the local library.
public struct BookmarkMergeResult: Equatable {
    public var added: Set<BookmarkID> = []
    public var updated: Set<BookmarkID> = []
    public var removed: Set<BookmarkID> = []

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
    /// Bookmarks whose picture or saved text may have to come from another Mac.
    public var arrived: Set<BookmarkID> { added.union(updated) }
}

public enum BookmarkSync {
    /// Deletions are remembered this long, then forgotten, so the files do not grow for ever.
    public static let forgetDeletionsAfter: TimeInterval = 90 * 86400

    /// A bookmark as it is compared and shared. Whether a copy of the page is kept is up to each Mac.
    static func comparable(_ b: Bookmark) -> Bookmark {
        var b = b
        b.hasCopy = false
        return b
    }

    /// Stamps what changed in `library` since the last sync: edited or new bookmarks get `now`,
    /// bookmarks that disappeared are remembered as deleted.
    public static func noteLocalChanges(in library: BookmarkLibrary, state: inout BookmarkSyncState, now: Date) {
        let before = Dictionary(state.baseline.map { ($0.id, comparable($0)) }, uniquingKeysWith: { a, _ in a })
        var present = Set<BookmarkID>()
        for b in library.bookmarks {
            present.insert(b.id)
            let key = b.id.uuidString
            if before[b.id] != comparable(b) || state.changed[key] == nil {
                state.changed[key] = now
            }
            state.deleted[key] = nil
        }
        for id in before.keys where !present.contains(id) {
            state.changed[id.uuidString] = nil
            state.deleted[id.uuidString] = now
        }
        state.deleted = state.deleted.filter { now.timeIntervalSince($0.value) < forgetDeletionsAfter }
        state.baseline = library.bookmarks
    }

    /// This Mac's bookmarks, ready to write to the shared folder. Call after `noteLocalChanges`.
    public static func outgoing(_ library: BookmarkLibrary, state: BookmarkSyncState,
                                deviceID: String, deviceName: String, now: Date) -> DeviceBookmarks {
        DeviceBookmarks(deviceID: deviceID, deviceName: deviceName, savedAt: now,
                        bookmarks: library.bookmarks, changed: state.changed, deleted: state.deleted)
    }

    /// Takes in what other Macs changed. For each bookmark the newest change wins, and a deletion wins over
    /// an older edit. When two Macs saved the same page separately, the one saved first is kept on both.
    @discardableResult
    public static func merge(_ remotes: [DeviceBookmarks], into library: inout BookmarkLibrary,
                             state: inout BookmarkSyncState) -> BookmarkMergeResult {
        var result = BookmarkMergeResult()

        // Newest version of every bookmark any other Mac has, and the newest deletion of each.
        var incoming: [BookmarkID: (bookmark: Bookmark, at: Date)] = [:]
        var deletions: [BookmarkID: Date] = [:]
        for remote in remotes {
            for b in remote.bookmarks {
                let at = remote.changed[b.id.uuidString] ?? .distantPast
                if let seen = incoming[b.id], seen.at >= at { continue }
                incoming[b.id] = (b, at)
            }
            for (key, at) in remote.deleted {
                guard let id = UUID(uuidString: key) else { continue }
                if let seen = deletions[id], seen >= at { continue }
                deletions[id] = at
            }
        }

        // Deletions from elsewhere.
        for (id, at) in deletions {
            let key = id.uuidString
            if let edited = state.changed[key], edited >= at { continue }
            if let mine = state.deleted[key], mine >= at { continue }
            if let incomingEdit = incoming[id], incomingEdit.at > at { continue }
            if library.remove(id) != nil { result.removed.insert(id) }
            state.changed[key] = nil
            state.deleted[key] = at
            incoming[id] = nil
        }

        // New and edited bookmarks from elsewhere, oldest first so that ties settle the same way on every Mac.
        let ordered = incoming.values.sorted { order($0.bookmark, $1.bookmark) }
        for (remote, at) in ordered {
            let key = remote.id.uuidString
            if let deletedAt = state.deleted[key], deletedAt >= at { continue }
            if let local = library.bookmark(remote.id) {
                if let mine = state.changed[key], mine >= at { continue }
                guard comparable(local) != comparable(remote) else { state.changed[key] = at; continue }
                var adopted = remote
                adopted.hasCopy = local.hasCopy
                library.update(remote.id) { $0 = adopted }
                state.changed[key] = at
                state.deleted[key] = nil
                result.updated.insert(remote.id)
                continue
            }
            // The same page saved separately on two Macs: keep the one saved first, everywhere.
            if !remote.isRow, let twin = library.bookmark(forPage: remote.url), twin.id != remote.id {
                if order(twin, remote) { continue }
                library.remove(twin.id)
                state.changed[twin.id.uuidString] = nil
                result.removed.insert(twin.id)
                result.added.remove(twin.id)
                result.updated.remove(twin.id)
            }
            var adopted = remote
            adopted.hasCopy = false
            library.add(adopted)
            state.changed[key] = at
            state.deleted[key] = nil
            result.added.insert(remote.id)
        }

        state.baseline = library.bookmarks
        return result
    }

    /// Which of two bookmarks counts as first: saved earlier, then the smaller id.
    static func order(_ a: Bookmark, _ b: Bookmark) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}

// MARK: Rows on other Macs

public struct SyncedTab: Codable, Equatable, Hashable {
    public var url: URL
    public var title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? url.absoluteString
    }
}

/// A row open on another Mac, left to right.
public struct SyncedRow: Codable, Equatable, Identifiable {
    public var id: TrailID
    public var name: String?
    public var mark: String?
    public var tabs: [SyncedTab]
    public var lastUsed: Date

    public init(id: TrailID, name: String?, mark: String?, tabs: [SyncedTab], lastUsed: Date) {
        self.id = id
        self.name = name
        self.mark = mark
        self.tabs = tabs
        self.lastUsed = lastUsed
    }

    public var displayName: String {
        let named = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = named.isEmpty ? (tabs.first?.displayTitle ?? "Untitled row") : named
        if let mark, !mark.isEmpty { return mark + " " + base }
        return base
    }

    public func matches(_ query: String) -> Bool {
        let words = TextMatch.words(query)
        if words.isEmpty { return true }
        let text = ([name, mark].compactMap { $0 } + tabs.flatMap { [$0.title, $0.url.absoluteString] })
            .joined(separator: " ")
        return words.allSatisfy { TextMatch.contains(text, $0) }
    }
}

/// One Mac's open rows as written to the shared folder.
public struct DeviceRows: Codable, Equatable, Identifiable {
    public var deviceID: String
    public var deviceName: String
    public var savedAt: Date
    public var rows: [SyncedRow]

    public var id: String { deviceID }

    public init(deviceID: String, deviceName: String, savedAt: Date, rows: [SyncedRow]) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.savedAt = savedAt
        self.rows = rows
    }

    /// Other Macs worth showing: not this one, heard from in the last month, with something open.
    /// Most recently updated first.
    public static func others(_ all: [DeviceRows], excluding deviceID: String, now: Date,
                              maxAge: TimeInterval = 30 * 86400) -> [DeviceRows] {
        all.filter { $0.deviceID != deviceID && !$0.rows.isEmpty && now.timeIntervalSince($0.savedAt) < maxAge }
            .sorted { $0.savedAt > $1.savedAt }
    }
}

extension TabMap {
    /// The open rows to show on other Macs, most recently used first: only web pages, closed tabs left out.
    public func syncedRows(maxRows: Int = 60, maxTabsPerRow: Int = 60) -> [SyncedRow] {
        layout().open.compactMap { trail -> SyncedRow? in
            let tabs = trail.openTabs.compactMap { tab -> SyncedTab? in
                guard let url = tab.url, let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { return nil }
                return SyncedTab(url: url, title: tab.title)
            }
            guard !tabs.isEmpty else { return nil }
            return SyncedRow(id: trail.id, name: trail.name, mark: trail.mark,
                             tabs: Array(tabs.prefix(maxTabsPerRow)), lastUsed: trail.recency)
        }
        .prefix(maxRows)
        .map { $0 }
    }
}
