import Foundation

// Goes in Sources/TabMapCore. The rules for dock apps: sites kept outside the map, always loaded.
// Named "dock apps" to stay clear of MapTab.pinned, which only means "never auto-close".

/// A site kept in the dock.
public struct DockApp: Codable, Identifiable, Equatable {
    public let id: TabID
    /// Where the app starts, and where "Go Home" returns to.
    public var home: URL
    /// Where the app was last, restored on launch.
    public var url: URL
    public var title: String
    public var addedAt: Date

    public init(id: TabID = TabID(), home: URL, title: String = "", now: Date) {
        self.id = id
        self.home = home
        self.url = home
        self.title = title
        self.addedAt = now
    }

    public var displayTitle: String {
        let stripped = UnreadBadge.stripping(title).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty { return stripped }
        return home.host ?? home.absoluteString
    }
}

/// The dock's contents, left to right. Position decides the ⌘1 to ⌘9 shortcut.
public struct AppShelf: Codable, Equatable {
    public var apps: [DockApp] = []

    public init() {}

    public func app(_ id: TabID?) -> DockApp? {
        guard let id else { return nil }
        return apps.first { $0.id == id }
    }

    /// The app behind ⌘`number`, counting from 1.
    public func app(atShortcut number: Int) -> DockApp? {
        guard number >= 1, number <= apps.count else { return nil }
        return apps[number - 1]
    }

    /// An app already in the dock for the same site as `url`, if any.
    public func app(forSiteOf url: URL) -> DockApp? {
        apps.first { $0.home.host == url.host }
    }

    @discardableResult
    public mutating func add(home: URL, title: String = "", id: TabID = TabID(), now: Date) -> DockApp {
        let app = DockApp(id: id, home: home, title: title, now: now)
        apps.append(app)
        return app
    }

    @discardableResult
    public mutating func remove(_ id: TabID) -> DockApp? {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return nil }
        return apps.remove(at: i)
    }

    /// Moves an app by `offset` places, stopping at either end.
    public mutating func move(_ id: TabID, by offset: Int) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), apps.count - 1)
        guard j != i else { return }
        let app = apps.remove(at: i)
        apps.insert(app, at: j)
    }

    /// Records where an app is now. Returns true when something changed.
    @discardableResult
    public mutating func update(_ id: TabID, url: URL?, title: String?) -> Bool {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return false }
        var changed = false
        if let url, url.scheme == "http" || url.scheme == "https", apps[i].url != url {
            apps[i].url = url
            changed = true
        }
        if let title, !title.isEmpty, apps[i].title != title {
            apps[i].title = title
            changed = true
        }
        return changed
    }
}

/// Reads an unread marker out of a page title, the way sites announce one:
/// "Inbox (3) - me@example.com - Gmail", "(12) Feed", "[4] Chat", "* Slack", "• Discord".
public enum UnreadBadge {
    private static let counter = try! NSRegularExpression(pattern: "[\\(\\[]\\s*(\\d{1,3}(?:[,.]\\d{3})+|\\d+)(\\+?)\\s*[\\)\\]]")
    private static let dots: Set<Character> = ["*", "•", "●", "·", "◉"]

    /// "3", "99+" for anything larger, "•" for a marker without a number, nil for nothing unread.
    public static func parse(_ title: String) -> String? {
        let range = NSRange(title.startIndex..., in: title)
        if let match = counter.firstMatch(in: title, range: range),
           let digits = Range(match.range(at: 1), in: title) {
            let plus = match.range(at: 2).length > 0
            let cleaned = title[digits].filter(\.isNumber)
            guard let n = Int(cleaned), n > 0 else { return nil }
            if n > 99 { return "99+" }
            return plus ? "\(n)+" : "\(n)"
        }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, dots.contains(first), trimmed.dropFirst().first == " " {
            return "•"
        }
        return nil
    }

    /// The title without its unread marker, for labels and tooltips.
    public static func stripping(_ title: String) -> String {
        var result = title
        let range = NSRange(result.startIndex..., in: result)
        if let match = counter.firstMatch(in: result, range: range), let r = Range(match.range, in: result) {
            result.removeSubrange(r)
        }
        result = result.trimmingCharacters(in: .whitespaces)
        if let first = result.first, dots.contains(first), result.dropFirst().first == " " {
            result.removeFirst(2)
        }
        return result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Decides whether a link leaves the app it was clicked in.
public enum SiteMatch {
    /// The last two labels of a host: "mail.google.com" and "accounts.google.com" are both "google.com".
    /// Good enough to tell an app's own pages from the outside world without a public suffix list.
    public static func site(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        // Addresses like 192.168.0.1 are one site as a whole.
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    public static func sameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let sa = site(a?.host), let sb = site(b?.host) else { return false }
        return sa == sb
    }

    /// True when a link clicked inside an app at `home` should open on top of the app as a peek.
    public static func leavesApp(home: URL, link: URL) -> Bool {
        guard let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !sameSite(home, link)
    }
}
