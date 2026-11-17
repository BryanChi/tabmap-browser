import Foundation

/// What makes two addresses "the same page" for the purpose of not opening it twice.
///
/// Two addresses share a key when they differ only in ways that do not change what you see:
/// http vs https, a leading "www.", upper or lower case in the host, a default port, a trailing
/// slash, a "#section" anchor, the order of query items, and tracking tags such as utm_source.
/// Everything else (the path, the remaining query items, "#/route" style fragments) must match.
public struct PageKey: Hashable {
    public let value: String

    /// Query items that only record where a visit came from.
    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "mc_cid", "mc_eid", "igshid", "_hsenc", "_hsmi", "li_fat_id", "ref_src",
    ]

    static func isTracking(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || trackingNames.contains(n)
    }

    /// Nil for anything that is not an ordinary web page (blank tabs, about:, file:, data: and so on).
    public init?(_ url: URL?) {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = (c.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        guard var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
        guard !host.isEmpty else { return nil }

        var key = host
        if let port = c.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) {
            key += ":\(port)"
        }

        var path = c.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        key += path

        let items = (c.percentEncodedQueryItems ?? [])
            .filter { !Self.isTracking($0.name) }
            .map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }
            .sorted()
        if !items.isEmpty { key += "?" + items.joined(separator: "&") }

        // "#section" is a place on the same page. "#/inbox" and "#!/inbox" are how some apps name pages.
        if let fragment = c.percentEncodedFragment, fragment.hasPrefix("/") || fragment.hasPrefix("!") {
            key += "#" + fragment
        }
        value = key
    }
}

public extension TabMap {
    /// Where to look for a tab that already shows a page.
    enum DuplicateScope {
        /// Any tab in the map, closed ones included. Used when you are about to be taken to the page.
        case wholeMap
        /// Open tabs in the same row as the tab you are opening from. Used for links opened in the background.
        case openTabsInTrail
    }

    /// The tab that already shows `url`, if opening it from `origin` would make a copy.
    ///
    /// Returns nil when `origin` itself already shows the page, so typing the current address again reloads it.
    /// With several matches, an open tab wins over a closed one, then the most recently used.
    func duplicate(of url: URL, from origin: TabID?, scope: DuplicateScope = .wholeMap) -> TabID? {
        guard let key = PageKey(url) else { return nil }
        if let origin, let current = tab(origin), PageKey(current.url) == key { return nil }

        let pool: [MapTab]
        switch scope {
        case .wholeMap:
            pool = allTabs
        case .openTabsInTrail:
            guard let origin, let loc = locate(origin) else { return nil }
            pool = trails[loc.trail].openTabs
        }
        let matches = pool.filter { $0.id != origin && PageKey($0.url) == key }
        return matches.max { a, b in
            if a.isClosed != b.isClosed { return a.isClosed }
            return a.lastAccessedAt < b.lastAccessedAt
        }?.id
    }
}
