import Foundation

// Bookmarks: the rules, with no AppKit. Saving, filing, searching, smart collections,
// and telling whether a saved page has changed. The app side is in BookmarkStore.swift.

public typealias BookmarkID = UUID

/// A passage saved from a page.
public struct Highlight: Codable, Identifiable, Equatable {
    public let id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// One page of a saved row.
public struct SavedPage: Codable, Equatable {
    public var url: URL
    public var title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

/// A saved page, or a whole saved row (then `pages` lists the row left to right).
public struct Bookmark: Codable, Identifiable, Equatable {
    public let id: BookmarkID
    /// The page's address. For a row, the address of its first page.
    public var url: URL
    /// The page's title. For a row, the row's name.
    public var title: String
    public var createdAt: Date
    /// Empty for a single page; the row's pages otherwise.
    public var pages: [SavedPage] = []

    /// The collection it is filed in. Empty until it has been filed.
    public var collection: String = ""
    public var tags: [String] = []
    /// One sentence about the page.
    public var summary: String = ""
    public var note: String = ""
    public var highlights: [Highlight] = []
    /// Colour words read from the snapshot ("blue", "dark"), so a search can use what the page looked like.
    public var colors: [String] = []

    /// Filing (collection, tags, summary) has been done.
    public var filed: Bool = false
    /// The person chose the collection or tags; automatic filing leaves those alone.
    public var filedByHand: Bool = false

    public var lastOpenedAt: Date?
    /// A copy of the page is kept on this Mac.
    public var hasCopy: Bool = false

    // Watching for changes.
    /// A fingerprint of the page's text from the last check.
    public var sketch: [UInt64]?
    public var checkedAt: Date?
    /// Set when the page was found to differ from the last time it was looked at.
    public var changedAt: Date?
    /// Checks in a row that found the page missing.
    public var missingChecks: Int = 0
    /// Set once the page is considered gone from the web.
    public var goneAt: Date?

    public init(id: BookmarkID = BookmarkID(), url: URL, title: String, pages: [SavedPage] = [], now: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.pages = pages
        self.createdAt = now
    }

    public var isRow: Bool { !pages.isEmpty }
    public var isGone: Bool { goneAt != nil }
    public var hasChanged: Bool { changedAt != nil }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return BookmarkKey.displayHost(url) ?? url.absoluteString
    }
}

/// Decides when two addresses are the same saved page.
public enum BookmarkKey {
    /// Host without "www." in lower case, path without a trailing slash, and the query. No scheme, no "#anchor".
    public static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host else {
            return url.absoluteString
        }
        parts.fragment = nil
        var path = parts.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        var key = stripWWW(host.lowercased()) + path
        if let query = parts.percentEncodedQuery, !query.isEmpty { key += "?" + query }
        return key
    }

    public static func displayHost(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return stripWWW(host)
    }

    static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: The library

/// What the board is showing.
public enum BoardScope: Hashable {
    case all, thisWeek, readLater, highlights, rows, changed, offline
    case collection(String)

    /// The built-in views, in the order they are listed.
    public static let smart: [BoardScope] = [.all, .thisWeek, .readLater, .highlights, .rows, .changed, .offline]

    public var title: String {
        switch self {
        case .all: return "All Bookmarks"
        case .thisWeek: return "Saved This Week"
        case .readLater: return "Read Later"
        case .highlights: return "Highlights"
        case .rows: return "Saved Rows"
        case .changed: return "Changed Since Saved"
        case .offline: return "Gone From the Web"
        case .collection(let name): return name
        }
    }
}

public struct CollectionCount: Identifiable, Equatable {
    public let name: String
    public let count: Int
    public var id: String { name }
}

public struct BookmarkLibrary: Codable, Equatable {
    public var bookmarks: [Bookmark] = []

    public init() {}

    public func bookmark(_ id: BookmarkID?) -> Bookmark? {
        guard let id else { return nil }
        return bookmarks.first { $0.id == id }
    }

    /// The saved single page with this address, if there is one. Saved rows do not count.
    public func bookmark(forPage url: URL) -> Bookmark? {
        let key = BookmarkKey.key(url)
        return bookmarks.first { !$0.isRow && BookmarkKey.key($0.url) == key }
    }

    public mutating func add(_ bookmark: Bookmark) {
        bookmarks.append(bookmark)
    }

    @discardableResult
    public mutating func remove(_ id: BookmarkID) -> Bookmark? {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return nil }
        return bookmarks.remove(at: i)
    }

    /// Changes one bookmark in place. Returns false when it is not there.
    @discardableResult
    public mutating func update(_ id: BookmarkID, _ change: (inout Bookmark) -> Void) -> Bool {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        change(&bookmarks[i])
        return true
    }

    /// Adds a passage to a bookmark unless the same passage is already there.
    @discardableResult
    public mutating func addHighlight(_ text: String, to id: BookmarkID, now: Date) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        if bookmarks[i].highlights.contains(where: { $0.text == clean }) { return false }
        bookmarks[i].highlights.append(Highlight(text: clean, createdAt: now))
        return true
    }

    /// Collections in use, biggest first, ties by name.
    public func collections() -> [CollectionCount] {
        var counts: [String: Int] = [:]
        for b in bookmarks where !b.collection.isEmpty { counts[b.collection, default: 0] += 1 }
        return counts.map { CollectionCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    public func contains(_ bookmark: Bookmark, in scope: BoardScope, now: Date) -> Bool {
        switch scope {
        case .all: return true
        case .thisWeek: return now.timeIntervalSince(bookmark.createdAt) < 7 * 86400
        // Saved and not looked at since.
        case .readLater: return bookmark.lastOpenedAt == nil && !bookmark.isRow
        case .highlights: return !bookmark.highlights.isEmpty
        case .rows: return bookmark.isRow
        case .changed: return bookmark.hasChanged
        case .offline: return bookmark.isGone
        case .collection(let name): return bookmark.collection == name
        }
    }

    /// The bookmarks of a view, newest first.
    public func bookmarks(in scope: BoardScope, now: Date) -> [Bookmark] {
        bookmarks.filter { contains($0, in: scope, now: now) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    public func count(in scope: BoardScope, now: Date) -> Int {
        bookmarks.reduce(0) { $0 + (contains($1, in: scope, now: now) ? 1 : 0) }
    }

    /// Pages due a check for changes: never checked first, then the longest unchecked. Rows are not watched.
    public func dueForCheck(now: Date, every interval: TimeInterval, limit: Int) -> [Bookmark] {
        bookmarks
            .filter { !$0.isRow && ($0.checkedAt.map { now.timeIntervalSince($0) >= interval } ?? true) }
            .sorted { ($0.checkedAt ?? .distantPast) < ($1.checkedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Records the result of looking at a page again.
    public mutating func recordCheck(_ id: BookmarkID, result: PageCheck, now: Date) {
        update(id) { b in
            b.checkedAt = now
            switch result {
            case .unreachable:
                break // no network, a timeout, a server having a bad day: says nothing about the page
            case .missing:
                b.missingChecks += 1
                if b.missingChecks >= PageCheck.missingChecksBeforeGone, b.goneAt == nil { b.goneAt = now }
            case .found(let sketch):
                b.missingChecks = 0
                b.goneAt = nil
                guard !sketch.isEmpty else { return }
                if let old = b.sketch, !old.isEmpty,
                   PageSketch.similarity(old, sketch) < PageSketch.changedBelow {
                    b.changedAt = now
                }
                b.sketch = sketch
            }
        }
    }

    /// The person has opened the bookmark: it is read, and any "changed" mark is cleared.
    public mutating func markOpened(_ id: BookmarkID, now: Date) {
        update(id) { b in
            b.lastOpenedAt = now
            b.changedAt = nil
        }
    }
}

public enum PageCheck: Equatable {
    /// The page answered; this is the fingerprint of its text (empty when there was too little text to tell).
    case found([UInt64])
    /// The server says the page does not exist, or the site itself cannot be found.
    case missing
    /// Could not tell.
    case unreachable

    public static let missingChecksBeforeGone = 2
}

// MARK: Search

/// Finds bookmarks by anything known about them: title, tags, collection, summary, notes, highlights,
/// address, colours, and the page's own text as it was when saved.
public enum BookmarkSearch {
    /// Words that say nothing about which page is meant ("that ramen place with the blue logo").
    static let fillerWords: Set<String> = [
        "the", "a", "an", "that", "this", "with", "and", "or", "of", "in", "on", "at", "for", "to", "from",
        "it", "is", "was", "are", "my", "i", "me", "one", "some", "about", "page", "site", "website", "thing",
        "saved", "bookmark", "bookmarked", "had", "has", "have", "where", "which", "what", "there", "its",
    ]

    /// The words of a query worth matching. Falls back to every word when all of them are filler.
    public static func terms(_ query: String) -> [String] {
        let words = TextMatch.words(query).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        let kept = words.filter { !fillerWords.contains($0.lowercased()) }
        return kept.isEmpty ? words : kept
    }

    /// How much one word counts for a bookmark: the weight of the best place it is found, 0 when nowhere.
    static func weight(of word: String, in b: Bookmark, text: String?) -> Int {
        if TextMatch.contains(b.title, word) { return 6 }
        if b.tags.contains(where: { TextMatch.contains($0, word) }) { return 5 }
        if TextMatch.contains(b.collection, word) { return 4 }
        if TextMatch.contains(b.note, word) || b.highlights.contains(where: { TextMatch.contains($0.text, word) }) { return 4 }
        if TextMatch.contains(b.summary, word) { return 3 }
        if b.pages.contains(where: { TextMatch.contains($0.title, word) }) { return 3 }
        if b.colors.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { return 2 }
        if TextMatch.contains(b.url.absoluteString, word)
            || b.pages.contains(where: { TextMatch.contains($0.url.absoluteString, word) }) { return 2 }
        if let text, TextMatch.contains(text, word) { return 1 }
        return 0
    }

    /// Best matches first. Bookmarks matching every word come back alone; when there are none,
    /// those matching at least half the words are offered instead.
    public static func rank(_ bookmarks: [Bookmark], query: String, texts: [BookmarkID: String] = [:]) -> [Bookmark] {
        let terms = terms(query)
        guard !terms.isEmpty else { return bookmarks }
        struct Hit {
            let bookmark: Bookmark
            let matched: Int
            let score: Int
        }
        var hits: [Hit] = []
        for b in bookmarks {
            var matched = 0, score = 0
            for term in terms {
                let w = weight(of: term, in: b, text: texts[b.id])
                if w > 0 { matched += 1; score += w }
            }
            if matched > 0 { hits.append(Hit(bookmark: b, matched: matched, score: score)) }
        }
        let full = hits.filter { $0.matched == terms.count }
        let pool = full.isEmpty ? hits.filter { $0.matched * 2 >= terms.count } : full
        return pool.sorted { a, b in
            if a.matched != b.matched { return a.matched > b.matched }
            if a.score != b.score { return a.score > b.score }
            return a.bookmark.createdAt > b.bookmark.createdAt
        }.map(\.bookmark)
    }
}

// MARK: Filing

/// What is known about a page when it is filed.
public struct FilingInput {
    public var title: String
    public var url: URL
    /// The page's own description of itself (meta description), if it has one.
    public var description: String
    /// The start of the page's text.
    public var text: String
    /// For a saved row: the titles of its pages.
    public var pageTitles: [String]

    public init(title: String, url: URL, description: String = "", text: String = "", pageTitles: [String] = []) {
        self.title = title
        self.url = url
        self.description = description
        self.text = text
        self.pageTitles = pageTitles
    }
}

public struct Filing: Equatable {
    public var collection: String
    public var tags: [String]
    public var summary: String

    public init(collection: String, tags: [String], summary: String) {
        self.collection = collection
        self.tags = tags
        self.summary = summary
    }
}

/// Files a bookmark from its site and words alone, with no language model.
public enum BookmarkFiling {
    public static let unsorted = "Unsorted"

    /// Collections offered before the person has made any of their own.
    public static let standardCollections = [
        "Recipes", "Places", "Videos", "Music", "Shopping", "Code", "Reference",
        "News", "Travel", "Social", "Tools", "Reading",
    ]

    private static let siteRules: [(collection: String, sites: [String])] = [
        ("Videos", ["youtube.com", "youtu.be", "vimeo.com", "twitch.tv", "netflix.com", "bilibili.com"]),
        ("Code", ["github.com", "gitlab.com", "stackoverflow.com", "stackexchange.com", "npmjs.com",
                  "developer.apple.com", "crates.io", "pypi.org", "swift.org"]),
        ("Reference", ["wikipedia.org", "developer.mozilla.org", "wiktionary.org", "britannica.com"]),
        ("Shopping", ["amazon.", "ebay.", "etsy.com", "aliexpress.com", "ikea.com", "shopee.", "momoshop.com.tw"]),
        ("News", ["nytimes.com", "bbc.com", "bbc.co.uk", "theguardian.com", "reuters.com", "cnn.com",
                  "apnews.com", "bloomberg.com", "wsj.com", "theverge.com", "arstechnica.com"]),
        ("Social", ["twitter.com", "x.com", "reddit.com", "instagram.com", "facebook.com", "threads.net",
                    "bsky.app", "mastodon.social", "linkedin.com", "news.ycombinator.com"]),
        ("Music", ["spotify.com", "soundcloud.com", "bandcamp.com", "music.apple.com", "genius.com"]),
        ("Travel", ["booking.com", "airbnb.", "tripadvisor.", "expedia.", "skyscanner.", "agoda.com"]),
        ("Places", ["yelp.com", "tabelog.com", "opentable.com", "maps.google.", "maps.apple.com"]),
    ]

    private static let wordRules: [(collection: String, words: [String])] = [
        ("Recipes", ["recipe", "recipes", "ingredients", "tablespoon", "preheat"]),
        ("Places", ["restaurant", "ramen", "cafe", "café", "bistro", "izakaya", "reservations", "opening hours"]),
        ("Shopping", ["add to cart", "add to bag", "free shipping", "in stock", "checkout"]),
        ("Travel", ["itinerary", "flights", "hotel", "hostel"]),
        ("Code", ["api reference", "documentation", "changelog", "pull request", "npm install"]),
    ]

    public static func file(_ input: FilingInput) -> Filing {
        Filing(collection: collection(for: input), tags: tags(for: input), summary: summary(for: input))
    }

    static func collection(for input: FilingInput) -> String {
        let host = BookmarkKey.displayHost(input.url) ?? ""
        let pathHost = host + input.url.path.lowercased()
        // The site first: a recipe on YouTube is a video; a recipe on a blog is found by its words below.
        for rule in siteRules where rule.sites.contains(where: { site in
            site.hasSuffix(".") ? (host.hasPrefix(site) || host.contains("." + site)) || pathHost.hasPrefix(site)
                                : (host == site || host.hasSuffix("." + site))
        }) {
            return rule.collection
        }
        let words = (input.title + " " + input.pageTitles.joined(separator: " ") + " "
                     + input.description + " " + String(input.text.prefix(1500))).lowercased()
        for rule in wordRules where rule.words.contains(where: { words.contains($0) }) {
            return rule.collection
        }
        // A long page with nothing else to go on is something to read.
        return input.text.count > 3000 ? "Reading" : unsorted
    }

    /// Up to four tags: the words that best name the page, then the site.
    static func tags(for input: FilingInput) -> [String] {
        let host = BookmarkKey.displayHost(input.url) ?? ""
        let siteWords = Set(TrailLabelHeuristic.siteLabels(host))
        var tags: [String] = []
        let titles = [input.title] + input.pageTitles
        var counts: [String: Int] = [:]
        var order: [String] = []
        for title in titles {
            for word in TrailLabelHeuristic.titleWords(title) where !TrailLabelHeuristic.isNoise(word, siteWords: siteWords) {
                if counts[word] == nil { order.append(word) }
                counts[word, default: 0] += 1
            }
        }
        // Words used more often first, then in the order they appear; longer words say more than short ones.
        let ranked = order.enumerated().sorted { a, b in
            let ca = counts[a.element]!, cb = counts[b.element]!
            if ca != cb { return ca > cb }
            return a.offset < b.offset
        }.map(\.element)
        tags.append(contentsOf: ranked.prefix(3))
        if let site = TrailLabelHeuristic.siteLabels(host).last, !site.isEmpty, !tags.contains(site) { tags.append(site) }
        return tags
    }

    static func summary(for input: FilingInput) -> String {
        let description = oneLine(input.description)
        if description.count >= 20 { return TrailLabelText.truncate(description, to: 160) }
        if !input.pageTitles.isEmpty {
            let n = input.pageTitles.count
            return "\(n) page\(n == 1 ? "" : "s"): " + TrailLabelText.truncate(input.pageTitles.joined(separator: ", "), to: 130)
        }
        // The first sentence of the page that is long enough to say something.
        let text = String(input.text.prefix(1500))
        for line in text.components(separatedBy: .newlines) {
            let clean = oneLine(line)
            guard clean.count >= 60 else { continue }
            if let stop = clean.range(of: ". "), clean.distance(from: clean.startIndex, to: stop.lowerBound) >= 40 {
                return TrailLabelText.truncate(String(clean[..<stop.upperBound]).trimmingCharacters(in: .whitespaces), to: 160)
            }
            return TrailLabelText.truncate(clean, to: 160)
        }
        return description
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// The text side of asking a language model to file a bookmark: the prompt and cleaning up the reply.
public enum BookmarkFilingText {
    public static func instructions(collections: [String]) -> String {
        """
        You file saved web pages. Given a page's title, site and some of its text, reply with the collection \
        it belongs in, 2 to 4 short lowercase tags, and one plain sentence of at most 20 words saying what the \
        page is. Prefer one of these collections: \(collections.joined(separator: ", ")). Only invent a new \
        collection (1 or 2 words) when none fits. Do not mention bookmarks or browsing. \
        Reply in exactly three lines:
        Collection: <collection>
        Tags: <tag>, <tag>, <tag>
        Summary: <the sentence>
        """
    }

    public static func prompt(for input: FilingInput) -> String {
        var lines = ["Title: " + TrailLabelText.truncate(BookmarkFiling.oneLine(input.title), to: 120)]
        if let host = BookmarkKey.displayHost(input.url) { lines.append("Site: " + host) }
        if !input.pageTitles.isEmpty {
            lines.append("Pages saved together:")
            lines.append(contentsOf: input.pageTitles.prefix(10).map { "- " + TrailLabelText.truncate($0, to: 80) })
        }
        let description = BookmarkFiling.oneLine(input.description)
        if !description.isEmpty { lines.append("Description: " + TrailLabelText.truncate(description, to: 300)) }
        let text = BookmarkFiling.oneLine(String(input.text.prefix(1400)))
        if !text.isEmpty { lines.append("Text: " + text) }
        return lines.joined(separator: "\n")
    }

    /// Reads the three labelled lines. Nil unless there is at least a usable collection or summary.
    /// `known` are collections already in use: a reply naming one of them in other letter case is matched to it.
    public static func parse(_ reply: String, known: [String]) -> (collection: String?, tags: [String], summary: String?)? {
        var collection: String?
        var tags: [String] = []
        var summary: String?
        for raw in reply.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "*#-_ ".contains(first) { line.removeFirst() }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "*_ ")).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "collection", "category": collection = collection ?? cleanCollection(value, known: known)
            case "tags", "tag": if tags.isEmpty { tags = cleanTags(value) }
            case "summary", "description": summary = summary ?? TrailLabelText.cleanSummary(value).map { TrailLabelText.truncate($0, to: 160) }
            default: break
            }
        }
        if collection == nil, summary == nil { return nil }
        return (collection, tags, summary)
    }

    public static func cleanCollection(_ raw: String, known: [String]) -> String? {
        guard let name = TrailLabelText.cleanName(raw) else { return nil }
        if let match = known.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        let words = name.split(separator: " ")
        guard name.count <= 24, words.count <= 3 else { return nil }
        return words.map { TrailLabelHeuristic.capitalized(String($0)) }.joined(separator: " ")
    }

    /// Lower case, no "#", no repeats, at most five, each at most 24 characters.
    public static func cleanTags(_ raw: String) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for part in raw.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            let tag = part.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#\"'`.*[]")))
                .lowercased()
            guard !tag.isEmpty, tag.count <= 24, !seen.contains(tag) else { continue }
            seen.insert(tag)
            tags.append(tag)
            if tags.count == 5 { break }
        }
        return tags
    }
}

// MARK: Has the page changed?

/// A small fingerprint of a page's text. Two fetches of the same article give nearly the same
/// fingerprint even when the clock, the counters and the adverts around it differ.
public enum PageSketch {
    public static let size = 64
    /// Fingerprints less alike than this mean the page has changed.
    public static let changedBelow = 0.7
    static let shingle = 4
    static let minimumWords = 40

    /// The words of an HTML page that a reader would see, without scripts, styles, tags or numbers.
    public static func words(fromHTML html: String) -> [String] {
        var text = html
        for pattern in ["<script\\b[^>]*>.*?</script>", "<style\\b[^>]*>.*?</style>", "<noscript\\b[^>]*>.*?</noscript>",
                        "<!--.*?-->", "<[^>]+>", "&[a-zA-Z#0-9]+;"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        return words(fromText: text)
    }

    public static func words(fromText text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            // Numbers are dates, prices and counters: the parts that change without the page changing.
            .filter { !$0.isEmpty && $0.count <= 30 && !$0.contains(where: \.isNumber) }
    }

    /// The `size` smallest hashes of every run of four words. Empty when there is too little text to judge.
    public static func sketch(ofWords words: [String]) -> [UInt64] {
        guard words.count >= minimumWords else { return [] }
        var hashes = Set<UInt64>()
        for i in 0...(words.count - shingle) {
            hashes.insert(fnv1a(words[i..<(i + shingle)].joined(separator: " ")))
        }
        return Array(hashes.sorted().prefix(size))
    }

    public static func sketch(ofHTML html: String) -> [UInt64] { sketch(ofWords: words(fromHTML: html)) }

    /// From 0 (nothing in common) to 1 (the same text). Two empty fingerprints count as the same.
    public static func similarity(_ a: [UInt64], _ b: [UInt64]) -> Double {
        if a.isEmpty || b.isEmpty { return a.isEmpty && b.isEmpty ? 1 : 0 }
        let setA = Set(a), setB = Set(b)
        let smallest = setA.union(setB).sorted().prefix(size)
        let shared = smallest.reduce(0) { $0 + (setA.contains($1) && setB.contains($1) ? 1 : 0) }
        return Double(shared) / Double(smallest.count)
    }

    /// A hash that gives the same answer on every launch (Swift's own hashing does not).
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

// MARK: What the page looked like

/// Turns a snapshot's pixels into colour words, so "the one with the blue logo" has something to match.
public enum ColorWords {
    /// `pixels` are red, green, blue from 0 to 1. Returns up to two colour names, most common first,
    /// then "dark" or "light" when the page is clearly one or the other.
    public static func words(forPixels pixels: [(r: Double, g: Double, b: Double)]) -> [String] {
        guard !pixels.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        var brightness = 0.0
        for p in pixels {
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            brightness += 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
            let saturation = hi <= 0 ? 0 : (hi - lo) / hi
            guard saturation > 0.35, hi > 0.25 else { continue }
            counts[name(hue: hue(p.r, p.g, p.b, hi: hi, lo: lo), value: hi), default: 0] += 1
        }
        let total = Double(pixels.count)
        var words = counts
            // A logo or a header band is a small part of a page, so a modest share is enough.
            .filter { Double($0.value) / total >= 0.04 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(2)
            .map(\.key)
        let mean = brightness / total
        if mean < 0.3 { words.append("dark") } else if mean > 0.8 { words.append("light") }
        return words
    }

    static func hue(_ r: Double, _ g: Double, _ b: Double, hi: Double, lo: Double) -> Double {
        let span = hi - lo
        guard span > 0 else { return 0 }
        var h: Double
        if hi == r { h = (g - b) / span } else if hi == g { h = 2 + (b - r) / span } else { h = 4 + (r - g) / span }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    static func name(hue: Double, value: Double) -> String {
        switch hue {
        case ..<15, 345...: return "red"
        case ..<45: return value < 0.6 ? "brown" : "orange"
        case ..<70: return "yellow"
        case ..<165: return "green"
        case ..<255: return "blue"
        case ..<290: return "purple"
        default: return "pink"
        }
    }
}

// MARK: Going back to a highlight

/// Builds an address that opens a page scrolled to a passage (a "text fragment", which WebKit understands).
public enum TextFragment {
    public static func url(_ url: URL, highlighting passage: String) -> URL {
        // Matching does not cross paragraphs, so use the first paragraph that has a few words in it.
        let paragraphs = passage.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        guard let words = paragraphs.first(where: { $0.count >= 3 }) ?? paragraphs.first(where: { !$0.isEmpty }) else { return url }
        let directive: String
        if words.count <= 10 {
            directive = encode(words.joined(separator: " "))
        } else {
            directive = encode(words.prefix(5).joined(separator: " ")) + "," + encode(words.suffix(5).joined(separator: " "))
        }
        var base = url.absoluteString
        if let hash = base.firstIndex(of: "#") { base = String(base[..<hash]) }
        return URL(string: base + "#:~:text=" + directive) ?? url
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "._~!*'()")
        // "-", "," and "&" have meanings of their own inside a text fragment, so they are always escaped.
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
