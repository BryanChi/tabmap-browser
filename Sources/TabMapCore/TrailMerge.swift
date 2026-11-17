import Foundation

// Joining two rows of the map, undoing that, and spotting rows that look like the same thing.
// Everything here is plain Foundation so it can be unit tested; the on-device model's second
// opinion lives in the app (MergeAdvisor.swift).

// MARK: Joining and undoing

/// What is needed to take a join back.
public struct MergeRecord: Equatable {
    /// The row that received the tabs.
    public let targetID: TrailID
    /// The row that was folded in, exactly as it was before the join.
    public let source: Trail
    /// The tabs that moved, in their original order.
    public let movedTabIDs: [TabID]
    /// Where the receiving row's "last active" marker pointed before the join.
    public let targetLastActiveTabID: TabID?
}

extension TabMap {
    /// Moves every tab of `sourceID` to the right-hand end of `targetID` and removes the emptied row.
    /// Tabs keep their ids, so loaded pages, thumbnails and history are untouched.
    @discardableResult
    public mutating func mergeTrail(_ sourceID: TrailID, into targetID: TrailID) -> MergeRecord? {
        guard sourceID != targetID,
              let s = trails.firstIndex(where: { $0.id == sourceID }),
              let t = trails.firstIndex(where: { $0.id == targetID })
        else { return nil }
        let source = trails[s]
        let record = MergeRecord(targetID: targetID,
                                 source: source,
                                 movedTabIDs: source.tabs.map(\.id),
                                 targetLastActiveTabID: trails[t].lastActiveTabID)
        trails[t].tabs.append(contentsOf: source.tabs)
        if let active = activeTabID, source.tabs.contains(where: { $0.id == active }) {
            trails[t].lastActiveTabID = active
        }
        trails.remove(at: s)
        return record
    }

    /// Splits a joined row back in two. Tabs opened from a moved tab since the join go back with it.
    /// Returns false when there is nothing left to split (the row or all the moved tabs are gone).
    @discardableResult
    public mutating func undoMerge(_ record: MergeRecord) -> Bool {
        guard let t = trails.firstIndex(where: { $0.id == record.targetID }),
              !trails.contains(where: { $0.id == record.source.id })
        else { return false }

        var leaving = Set(record.movedTabIDs)
        var back: [MapTab] = []
        var staying: [MapTab] = []
        // A child always sits to the right of its opener, so one pass in row order is enough.
        for tab in trails[t].tabs {
            if leaving.contains(tab.id) {
                back.append(tab)
            } else if let opener = tab.openerID, leaving.contains(opener) {
                leaving.insert(tab.id)
                back.append(tab)
            } else {
                staying.append(tab)
            }
        }
        guard !back.isEmpty else { return false }

        var restored = record.source
        restored.tabs = back
        if let active = activeTabID, leaving.contains(active) {
            restored.lastActiveTabID = active
        } else if let last = restored.lastActiveTabID, back.contains(where: { $0.id == last }) {
            // Still valid.
        } else {
            restored.lastActiveTabID = back.first(where: { !$0.isClosed })?.id ?? back.first?.id
        }

        if staying.isEmpty {
            trails.remove(at: t)
        } else {
            trails[t].tabs = staying
            let current = trails[t].lastActiveTabID
            if current == nil || !staying.contains(where: { $0.id == current }) {
                let before = record.targetLastActiveTabID
                if let before, staying.contains(where: { $0.id == before }) {
                    trails[t].lastActiveTabID = before
                } else {
                    trails[t].lastActiveTabID = staying.first(where: { !$0.isClosed })?.id ?? staying.first?.id
                }
            }
        }
        trails.append(restored)
        return true
    }
}

// MARK: What a row is about

/// The clues a row gives about its subject.
public struct TrailClues: Equatable {
    /// Meaningful words from page titles and search queries, with the number of tabs each appears in.
    public var words: [String: Int] = [:]
    /// Specific corners of a site, such as "github.com/apple/swift".
    public var sections: Set<String> = []
    /// Sites visited, without "www.". Search engines are left out.
    public var hosts: Set<String> = []

    public init() {}
}

public enum TrailSimilarity {
    /// Words that say nothing about a subject.
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "your", "you", "are", "was", "not", "but",
        "all", "any", "can", "has", "have", "how", "what", "when", "where", "why", "who", "which", "into",
        "about", "more", "most", "than", "then", "its", "our", "out", "via", "per", "use", "using",
        "new", "top", "best", "guide", "tips", "review", "reviews", "home", "page", "official", "online",
        "free", "search", "results", "welcome", "login", "log", "sign", "account", "index", "untitled",
        "com", "org", "net", "www", "http", "https", "html", "tab", "site", "web", "website",
        "les", "des", "une", "est", "pour", "avec", "der", "die", "das", "und", "los", "las", "del", "con", "para",
    ]

    /// Sites that host every subject at once, so sharing them means nothing.
    static let generalHosts: Set<String> = [
        "google.com", "bing.com", "duckduckgo.com", "kagi.com", "search.yahoo.com", "yahoo.com",
        "baidu.com", "yandex.com", "ecosia.org", "search.brave.com", "startpage.com",
    ]

    /// Query parameters that carry what the person typed into a search box.
    static let queryNames: Set<String> = ["q", "query", "search_query", "p", "text", "k", "search", "keywords"]

    /// Splits text into lowercase words worth comparing.
    public static func words(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { word in
            guard !word.isEmpty, !stopWords.contains(word) else { return false }
            let isASCII = word.unicodeScalars.allSatisfy { $0.isASCII }
            if word.count < (isASCII ? 3 : 2) { return false }
            if word.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return false }
            return true
        }
    }

    static func bareHost(_ url: URL?) -> String? {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    public static func clues(of trail: Trail) -> TrailClues {
        var clues = TrailClues()
        for tab in trail.tabs where !tab.isBlank {
            var tabWords = Set(words(in: tab.title))
            let host = bareHost(tab.url)

            if let url = tab.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                for item in items where queryNames.contains(item.name.lowercased()) {
                    tabWords.formUnion(words(in: item.value ?? ""))
                }
            }
            if let host {
                // "GitHub" in a GitHub page's title is the site talking, not the subject.
                for label in host.split(separator: ".") { tabWords.remove(String(label)) }
                if !generalHosts.contains(host) {
                    clues.hosts.insert(host)
                    let parts = (tab.url?.pathComponents ?? []).filter { $0 != "/" }
                    if parts.count >= 2 {
                        clues.sections.insert(([host] + parts.prefix(2)).joined(separator: "/").lowercased())
                    }
                }
            }
            for word in tabWords { clues.words[word, default: 0] += 1 }
        }
        return clues
    }

    /// How alike two rows are, from 0 to 1. `rarity` says how telling each word is
    /// (a word found in every row tells little); words missing from it count as 1.
    public static func score(_ a: TrailClues, _ b: TrailClues, rarity: [String: Double] = [:]) -> Double {
        func weights(_ clues: TrailClues) -> [String: Double] {
            var out: [String: Double] = [:]
            for (word, count) in clues.words {
                out[word] = Double(count).squareRoot() * (rarity[word] ?? 1)
            }
            return out
        }
        let wa = weights(a)
        let wb = weights(b)
        var dot = 0.0
        for (word, x) in wa { if let y = wb[word] { dot += x * y } }
        let na = wa.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let nb = wb.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        var score = (na > 0 && nb > 0) ? dot / (na * nb) : 0
        if !a.sections.isDisjoint(with: b.sections) { score += 0.35 }
        if !a.hosts.isDisjoint(with: b.hosts) { score += 0.08 }
        return min(1, score)
    }

    /// The words two rows share, most telling first.
    public static func sharedWords(_ a: TrailClues, _ b: TrailClues, rarity: [String: Double] = [:]) -> [String] {
        let shared = a.words.keys.filter { b.words[$0] != nil }
        func weight(_ word: String) -> Double {
            Double((a.words[word] ?? 0) + (b.words[word] ?? 0)) * (rarity[word] ?? 1)
        }
        return shared.sorted { x, y in
            let wx = weight(x), wy = weight(y)
            if wx != wy { return wx > wy }
            return x < y
        }
    }
}

// MARK: Finding rows to join

/// Two rows that look like they are about the same thing.
public struct MergeCandidate: Equatable, Identifiable {
    /// The more recently used row. It keeps its place and receives the other row's tabs.
    public let targetID: TrailID
    /// The row that would be folded in.
    public let sourceID: TrailID
    public let score: Double
    public let sharedWords: [String]
    public let sharesSiteSection: Bool

    public var pairKey: String { MergeCandidate.pairKey(targetID, sourceID) }
    public var id: String { pairKey }

    /// The same for (a, b) and (b, a).
    public static func pairKey(_ a: TrailID, _ b: TrailID) -> String {
        [a.uuidString, b.uuidString].sorted().joined(separator: "+")
    }
}

extension TabMap {
    /// Pairs of rows with open tabs that look alike, strongest first. Each row appears at most once.
    /// - Parameters:
    ///   - minimumScore: pairs scoring below this are left out.
    ///   - excluding: pair keys the person has already said no to.
    ///   - consider: only this many of the most recently used rows are compared.
    public func mergeCandidates(minimumScore: Double,
                                excluding: Set<String> = [],
                                limit: Int = 5,
                                consider: Int = 40) -> [MergeCandidate] {
        let rows = Array(layout().open.prefix(consider))
        guard rows.count >= 2 else { return [] }
        // Clues come from the stored row, not a filtered copy.
        let clues = rows.map { TrailSimilarity.clues(of: $0) }

        var found: [String: Int] = [:]
        for c in clues { for word in c.words.keys { found[word, default: 0] += 1 } }
        let total = Double(rows.count)
        let rarity = found.mapValues { 1 + log(total / Double($0)) }

        var all: [MergeCandidate] = []
        for i in rows.indices {
            for j in rows.indices where j > i {
                let key = MergeCandidate.pairKey(rows[i].id, rows[j].id)
                if excluding.contains(key) { continue }
                let shared = TrailSimilarity.sharedWords(clues[i], clues[j], rarity: rarity)
                let sharesSection = !clues[i].sections.isDisjoint(with: clues[j].sections)
                // One shared word is a coincidence. Two, or the same corner of a site, is a clue.
                guard shared.count >= 2 || sharesSection else { continue }
                let score = TrailSimilarity.score(clues[i], clues[j], rarity: rarity)
                guard score >= minimumScore else { continue }
                // rows is ordered most recently used first, so i is the row that stays.
                all.append(MergeCandidate(targetID: rows[i].id,
                                          sourceID: rows[j].id,
                                          score: score,
                                          sharedWords: shared,
                                          sharesSiteSection: sharesSection))
            }
        }
        all.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.pairKey < b.pairKey
        }
        var used = Set<TrailID>()
        var picked: [MergeCandidate] = []
        for candidate in all {
            if used.contains(candidate.targetID) || used.contains(candidate.sourceID) { continue }
            used.insert(candidate.targetID)
            used.insert(candidate.sourceID)
            picked.append(candidate)
            if picked.count == limit { break }
        }
        return picked
    }
}
