import Foundation

/// Every address you have been to, here or in a browser you imported from, with how often and how lately.
/// It finishes what you type in the address bar: "gi" becomes "github.com", "github.com/ap" becomes the page
/// under it you go to most.
public struct VisitIndex: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var url: URL
        public var title: String
        public var visits: Int
        public var typed: Int
        public var last: Date

        public init(url: URL, title: String, visits: Int, typed: Int, last: Date) {
            self.url = url
            self.title = title
            self.visits = visits
            self.typed = typed
            self.last = last
        }
    }

    /// Keyed by the address without its scheme or "www.", so http and https visits add up.
    public private(set) var entries: [String: Entry] = [:]

    /// Most addresses kept. The least useful go first.
    public static let limit = 25_000

    public init() {}

    public var count: Int { entries.count }

    /// "https://www.GitHub.com/apple/" -> "github.com/apple". Query kept, fragment dropped.
    public static func key(_ url: URL) -> String? {
        guard BrowserImport.isImportable(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased() else { return nil }
        parts.fragment = nil
        var key = strippedWWW(host)
        if let port = parts.port, !(port == 80 || port == 443) { key += ":\(port)" }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        key += path
        if let query = parts.percentEncodedQuery, !query.isEmpty { key += "?" + query }
        return key
    }

    static func strippedWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Adding

    /// A page you went to in Tabmap.
    public mutating func record(_ url: URL, title: String, typed: Bool = false, now: Date) {
        guard let key = Self.key(url) else { return }
        if var e = entries[key] {
            e.visits += 1
            if typed { e.typed += 1 }
            e.last = max(e.last, now)
            if !title.isEmpty { e.title = title }
            entries[key] = e
        } else {
            entries[key] = Entry(url: url, title: title, visits: 1, typed: typed ? 1 : 0, last: now)
        }
        if entries.count > Self.limit + Self.limit / 10 { prune(now: now) }
    }

    /// An address typed into the address bar and opened. The visit itself is recorded when the page loads.
    public mutating func markTyped(_ url: URL, now: Date) {
        guard let key = Self.key(url) else { return }
        if var e = entries[key] {
            e.typed += 1
            e.last = max(e.last, now)
            entries[key] = e
        } else {
            entries[key] = Entry(url: url, title: "", visits: 0, typed: 1, last: now)
        }
    }

    /// History from another browser. Importing the same history twice does not double it: counts take the larger.
    /// Returns how many addresses were new.
    @discardableResult
    public mutating func merge(_ visits: [ImportedVisit], now: Date) -> Int {
        var added = 0
        for v in visits {
            guard let key = Self.key(v.url) else { continue }
            if var e = entries[key] {
                e.visits = max(e.visits, v.visitCount)
                e.typed = max(e.typed, v.typedCount)
                if v.lastVisit > e.last {
                    e.last = v.lastVisit
                    if !v.title.isEmpty { e.title = v.title }
                }
                if e.title.isEmpty { e.title = v.title }
                entries[key] = e
            } else {
                entries[key] = Entry(url: v.url, title: v.title, visits: max(1, v.visitCount),
                                     typed: v.typedCount, last: v.lastVisit)
                added += 1
            }
        }
        if entries.count > Self.limit { prune(now: now) }
        return added
    }

    public mutating func removeAll() { entries = [:] }

    mutating func prune(now: Date) {
        guard entries.count > Self.limit else { return }
        let keep = entries.sorted { Self.score($0.value, now: now) > Self.score($1.value, now: now) }.prefix(Self.limit)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // MARK: Finishing what you type

    /// How much an address counts: typing it counts most, then visits, worth less as they age.
    public static func score(_ e: Entry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(e.last)) / 86_400
        let recency: Double
        switch days {
        case ..<4: recency = 1
        case ..<14: recency = 0.7
        case ..<31: recency = 0.5
        case ..<90: recency = 0.3
        default: recency = 0.1
        }
        return (Double(e.visits) + 3 * Double(e.typed)) * recency
    }

    /// The whole address to show for what was typed, keeping the typed letters as typed,
    /// or nil when nothing fits. Never finishes searches (anything with a space) or a single letter
    /// unless the site is one you use a lot.
    public func completion(for typed: String, now: Date) -> String? {
        guard !typed.isEmpty, !typed.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
        // What comes after any "https://" and "www." typed; the answer adds to the end of what was typed.
        var text = typed.lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        guard !text.isEmpty else { return nil }

        let rest: String?
        if !text.contains("/") {
            // A site: add up everything you did on it.
            var sites: [String: Double] = [:]
            for (key, e) in entries {
                let site = String(key.prefix { $0 != "/" && $0 != "?" })
                guard site.hasPrefix(text) else { continue }
                sites[site, default: 0] += Self.score(e, now: now)
            }
            let minimum = text.count == 1 ? 8.0 : 0
            rest = sites.filter { $0.value >= minimum }
                .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        } else {
            rest = entries.filter { $0.key.hasPrefix(text) }
                .max { a, b in
                    let sa = Self.score(a.value, now: now), sb = Self.score(b.value, now: now)
                    return sa != sb ? sa < sb : a.key.count > b.key.count
                }?.key
        }
        guard let rest, rest.count > text.count else { return nil }
        return typed + rest.dropFirst(text.count)
    }
}
