import Foundation

/// Search helpers: a query is split into words and every word has to be found.
public enum TextMatch {
    public static func words(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Case- and diacritic-insensitive substring test.
    public static func contains(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Names a row from its page titles and sites alone, with no language model.
/// Used when the on-device model is unavailable or gives nothing usable.
public enum TrailLabelHeuristic {
    public static func label(for trail: Trail) -> (name: String, summary: String) {
        let pages = trail.pageTabs
        let hosts = pages.compactMap { displayHost($0.url) }
        return (name(pages: pages, hosts: hosts), summary(pageCount: pages.count, hosts: hosts))
    }

    // MARK: Name

    static func name(pages: [MapTab], hosts: [String]) -> String {
        let siteWords = Set(hosts.flatMap { siteLabels($0) })
        // Count each word once per page, so one long title cannot dominate.
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        for page in pages {
            var seen = Set<String>()
            for word in titleWords(page.title) where !seen.contains(word) {
                seen.insert(word)
                if isNoise(word, siteWords: siteWords) { continue }
                counts[word, default: 0] += 1
                if firstSeen[word] == nil { firstSeen[word] = order; order += 1 }
            }
        }
        let ranked = counts
            .filter { $0.value >= 2 } // shared by at least two pages
            .sorted { a, b in
                a.value != b.value ? a.value > b.value : firstSeen[a.key]! < firstSeen[b.key]!
            }
            .prefix(2)
            .map(\.key)
        if !ranked.isEmpty {
            return ranked.map(capitalized).joined(separator: " ")
        }
        if let site = dominant(hosts) {
            return readableSiteName(site)
        }
        return "Untitled Group"
    }

    static func titleWords(_ title: String) -> [String] {
        title.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }

    static func isNoise(_ word: String, siteWords: Set<String>) -> Bool {
        if word.count < 3 { return true }
        if !word.contains(where: \.isLetter) { return true }
        if stopWords.contains(word) { return true }
        if siteWords.contains(word) { return true }
        // "stack" and "overflow" on stackoverflow.com are the site's name, not the topic.
        if word.count >= 4, siteWords.contains(where: { $0.contains(word) }) { return true }
        return false
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "these", "those", "your", "you", "are", "was",
        "were", "been", "how", "what", "why", "when", "where", "which", "who", "can", "not", "all", "new",
        "our", "out", "about", "into", "onto", "more", "most", "home", "page", "pages", "login", "log",
        "sign", "welcome", "official", "site", "website", "search", "results", "untitled", "tab", "tabs",
        "html", "www", "http", "https", "com", "org", "net", "using", "use", "best", "top", "free",
        "online", "get", "has", "have", "had", "its", "one", "two", "will", "just", "also", "but", "they",
        "them", "their", "there", "any", "some", "via", "per", "than", "then", "over", "under", "after",
        "before", "here", "only", "own", "same", "each", "other", "such", "very", "may", "might", "should",
        "would", "could", "does", "did", "doing", "his", "her", "him", "she",
        "yours", "dashboard", "inbox", "loading", "view", "edit",
    ]

    // MARK: Summary

    static func summary(pageCount: Int, hosts: [String]) -> String {
        let pagesText = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        let sites = rankedUnique(hosts)
        switch sites.count {
        case 0: return pagesText
        case 1: return "\(pagesText) on \(sites[0])"
        case 2: return "\(pagesText) across \(sites[0]) and \(sites[1])"
        default:
            let others = sites.count - 2
            return "\(pagesText) across \(sites[0]), \(sites[1]) and \(others) other site\(others == 1 ? "" : "s")"
        }
    }

    // MARK: Sites

    /// "www.github.com" → "github.com".
    static func displayHost(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Host labels that name the site: "docs.github.com" → ["docs", "github"].
    static func siteLabels(_ host: String) -> [String] {
        var parts = host.split(separator: ".").map(String.init)
        if parts.count > 1 { parts.removeLast() } // TLD
        if parts.count > 1, let last = parts.last, secondLevel.contains(last) { parts.removeLast() } // co.uk
        return parts.filter { $0 != "www" }
    }

    /// "docs.github.com" → "Github", "bbc.co.uk" → "Bbc".
    static func readableSiteName(_ host: String) -> String {
        capitalized(siteLabels(host).last ?? host)
    }

    static let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]

    /// Hosts by how often they occur, ties in order of first appearance.
    static func rankedUnique(_ hosts: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for h in hosts {
            if counts[h] == nil { order.append(h) }
            counts[h, default: 0] += 1
        }
        return order.enumerated()
            .sorted { a, b in
                let ca = counts[a.element]!, cb = counts[b.element]!
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map(\.element)
    }

    static func dominant(_ hosts: [String]) -> String? { rankedUnique(hosts).first }

    static func capitalized(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }
}

/// The text side of asking a language model to name a row: the prompt and cleaning up the reply.
public enum TrailLabelText {
    public static let instructions = """
        You name groups of browser tabs. Given the page titles and sites in one group, reply with a name \
        of 2 to 4 words that says what the group is about, and one plain sentence of at most 15 words \
        describing it. No quotes, no trailing punctuation in the name, do not mention tabs or browsing. \
        Reply in exactly two lines:
        Name: <the name>
        Description: <the sentence>
        """

    public static let maxNameLength = 40
    public static let maxSummaryLength = 120

    /// Up to 12 pages as "title — host", titles cut to about 80 characters.
    public static func prompt(for trail: Trail) -> String {
        let lines = trail.pageTabs.prefix(12).map { tab -> String in
            var title = tab.displayTitle
            if title.count > 80 { title = String(title.prefix(79)) + "…" }
            let host = TrailLabelHeuristic.displayHost(tab.url) ?? ""
            return host.isEmpty ? "- \(title)" : "- \(title) — \(host)"
        }
        return "Pages in this group:\n" + lines.joined(separator: "\n")
    }

    /// Reads "Name: …" and "Description: …" lines (or, failing that, the first two lines).
    /// Returns nil when no usable name is found.
    public static func parse(_ reply: String) -> (name: String, summary: String?)? {
        let lines = reply.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var name: String?
        var summary: String?
        for line in lines {
            if let rest = value(of: line, after: ["name"]) { name = name ?? rest }
            else if let rest = value(of: line, after: ["description", "summary"]) { summary = summary ?? rest }
        }
        if name == nil, summary == nil {
            name = lines.first
            summary = lines.dropFirst().first
        }
        guard let clean = cleanName(name ?? "") else { return nil }
        return (clean, summary.flatMap(cleanSummary))
    }

    private static func value(of line: String, after keys: [String]) -> String? {
        var text = line
        while let first = text.first, "*#-_ ".contains(first) { text.removeFirst() }
        for key in keys {
            guard text.lowercased().hasPrefix(key) else { continue }
            var rest = text.dropFirst(key.count)
            while let first = rest.first, "*_ ".contains(first) { rest.removeFirst() }
            guard rest.first == ":" else { continue }
            return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static let quotes = CharacterSet(charactersIn: "\"'`“”‘’«»*_")

    public static func cleanName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(quotes))
        while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(quotes))
        s = truncate(s, to: maxNameLength)
        return s.isEmpty ? nil : s
    }

    public static func cleanSummary(_ raw: String) -> String? {
        let s = truncate(raw.trimmingCharacters(in: .whitespacesAndNewlines.union(quotes)), to: maxSummaryLength)
        return s.isEmpty ? nil : s
    }

    /// Cuts at a word boundary where possible.
    static func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        let cut = s.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]).trimmingCharacters(in: .whitespaces)
        }
        return String(cut)
    }
}
