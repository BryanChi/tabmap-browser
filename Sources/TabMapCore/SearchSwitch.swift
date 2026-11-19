import Foundation

/// The bar of other sites shown on the search engine's results page: the same query, one click away.
public enum SearchSwitch {
    /// A site the query can be sent to.
    public struct Target: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// Search URL with %s standing in for the query.
        public let template: String
        /// Sites with no search address get the query typed in by a script after the page loads.
        /// The query rides in the fragment (`#tabmap-q=`), which never leaves the Mac.
        public let fillsComposer: Bool

        public init(id: String, name: String, template: String, fillsComposer: Bool = false) {
            self.id = id
            self.name = name
            self.template = template
            self.fillsComposer = fillsComposer
        }

        public var host: String? { URL(string: template.replacingOccurrences(of: "%s", with: "x"))?.host }
    }

    /// Fragment key a composer-filling site reads its query from.
    public static let fragmentKey = "tabmap-q"

    public static let targets: [Target] = [
        Target(id: "youtube", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
        Target(id: "amazon", name: "Amazon", template: "https://www.amazon.com/s?k=%s"),
        Target(id: "gemini", name: "Gemini", template: "https://gemini.google.com/app", fillsComposer: true),
        Target(id: "chatgpt", name: "ChatGPT", template: "https://chatgpt.com/?q=%s"),
        Target(id: "claude", name: "Claude", template: "https://claude.ai/new?q=%s"),
        Target(id: "perplexity", name: "Perplexity", template: "https://www.perplexity.ai/search?q=%s"),
        Target(id: "maps", name: "Maps", template: "https://www.google.com/maps/search/%s"),
        Target(id: "images", name: "Images", template: "https://www.google.com/search?udm=2&q=%s"),
        Target(id: "reddit", name: "Reddit", template: "https://www.reddit.com/search/?q=%s"),
        Target(id: "wikipedia", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search=%s"),
    ]

    /// The query on `url` if it is a results page of the engine `searchTemplate` describes, else nil.
    /// Matches host (ignoring "www."), path, and every fixed parameter of the template; the query
    /// parameter must be present and not blank.
    public static func query(in url: URL?, searchTemplate: String) -> String? {
        guard let url, let page = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let engine = URLComponents(string: searchTemplate.replacingOccurrences(of: "%s", with: "__TABMAP_Q__")),
              let pageHost = page.host, let engineHost = engine.host,
              bare(pageHost) == bare(engineHost) else { return nil }
        let pagePath = page.path.isEmpty ? "/" : page.path
        let enginePath = engine.path.isEmpty ? "/" : engine.path
        guard pagePath == enginePath else { return nil }
        // Form encoding: "+" is a space, "%2B" a plus.
        let pageItems = (page.percentEncodedQueryItems ?? []).map {
            URLQueryItem(name: $0.name.removingPercentEncoding ?? $0.name,
                         value: $0.value.map { $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? $0 })
        }
        var queryName: String?
        for item in engine.queryItems ?? [] {
            if item.value?.contains("__TABMAP_Q__") == true {
                queryName = item.name
            } else if !pageItems.contains(where: { $0.name == item.name && $0.value == item.value }) {
                return nil
            }
        }
        guard let queryName,
              let value = pageItems.first(where: { $0.name == queryName })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        // Google Images and similar tabs of the engine itself are still the engine's results page,
        // but switching from them to a plain search would be odd; only the main results count.
        if pageItems.contains(where: { $0.name == "tbm" || $0.name == "udm" }) && !(engine.queryItems ?? []).contains(where: { $0.name == "tbm" || $0.name == "udm" }) {
            return nil
        }
        return value
    }

    /// Where `target` shows `query`.
    public static func url(for target: Target, query: String) -> URL? {
        if target.fillsComposer {
            var allowed = CharacterSet.urlFragmentAllowed
            allowed.remove(charactersIn: "&=+#")
            let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
            return URL(string: target.template + "#\(fragmentKey)=" + encoded)
        }
        var allowed = target.template.contains("/%s") ? CharacterSet.urlPathAllowed : CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: target.template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// The targets to offer on the engine's results page: everything but the engine itself.
    public static func targets(excludingEngine searchTemplate: String) -> [Target] {
        targets.filter { $0.template != searchTemplate }
    }

    private static func bare(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
