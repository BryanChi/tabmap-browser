import Foundation

/// The app that handed a link to Tabmap: Claude, Slack, Mail, Messages and so on.
/// Stored on the tab the link opened in, so the map can show the app's icon and search can find it.
public struct SourceApp: Codable, Equatable, Hashable {
    /// Used to find the app's icon again, even after Tabmap restarts.
    public var bundleID: String
    /// The app's name as the person sees it ("Claude"). This is what search matches.
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

extension TabMap {
    /// A link another app asked Tabmap to open. It starts a new row at the top of the map,
    /// becomes the current tab, and remembers which app sent it.
    /// Returns the new tab, and the never-used blank tab that was thrown away by leaving it, if any.
    @discardableResult
    public mutating func openFromApp(url: URL, app: SourceApp?, now: Date) -> (id: TabID, discarded: TabID?) {
        let previous = activeTabID
        let previousWasBlank = activeTab?.isBlank == true
        let id = openRoot(url: url, now: now, activate: true)
        if let loc = locate(id) { trails[loc.trail].tabs[loc.tab].sourceApp = app }
        touch(id, now: now)
        let discarded = (previousWasBlank && previous != nil && tab(previous) == nil) ? previous : nil
        return (id, discarded)
    }

    /// Every tab by id, for following "opened from" links across rows.
    public var tabIndex: [TabID: MapTab] {
        Dictionary(allTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The app behind a tab: the app it was opened from, or else the app that its opener
    /// (or its opener's opener, and so on) was opened from. Tabs you reach by following a link
    /// that Claude gave you count as part of that Claude context.
    public static func originApp(of tab: MapTab, in index: [TabID: MapTab]) -> SourceApp? {
        var current: MapTab? = tab
        var hops = 0
        while let t = current, hops < 64 {
            if let app = t.sourceApp { return app }
            guard let opener = t.openerID else { return nil }
            current = index[opener]
            hops += 1
        }
        return nil
    }

    public func originApp(of id: TabID) -> SourceApp? {
        guard let tab = tab(id) else { return nil }
        return Self.originApp(of: tab, in: tabIndex)
    }

    /// Extra words a tab can be found by in search, beyond its title and address.
    static func searchAliases(of tab: MapTab, in index: [TabID: MapTab]) -> [String] {
        guard let app = originApp(of: tab, in: index) else { return [] }
        return [app.name]
    }
}
