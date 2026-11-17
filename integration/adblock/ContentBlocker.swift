import AppKit
import ObjectiveC
import SwiftUI
import WebKit
import TabMapCore

/// Built-in ad and tracker blocking.
///
/// EasyList (ads) and EasyPrivacy (trackers) are downloaded, converted on this Mac into WebKit
/// content rules (FilterListConverter) and compiled by WebKit, which then blocks requests and hides
/// ad boxes inside the page process, so nothing is slowed down by the app. A small built-in list
/// covers the time before the first download. Lists refresh weekly.
///
/// Per site: the shield in the address island turns blocking off for the site in front. That works
/// by taking the rule lists off the tab's content controller before each main-frame load.
@MainActor
final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    static let enabledKey = "contentBlockingEnabled"
    static let allowedKey = "contentBlockingAllowedSites"
    private static let listIDsKey = "contentBlockingListIDs"
    private static let versionKey = "contentBlockingConverterVersion"
    private static let updatedKey = "contentBlockingUpdated"
    private static let ruleCountKey = "contentBlockingRuleCount"

    static let sources: [(name: String, url: URL)] = [
        ("EasyList", URL(string: "https://easylist.to/easylist/easylist.txt")!),
        ("EasyPrivacy", URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]
    static let refreshInterval: TimeInterval = 7 * 86400

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            reapplyEverywhere()
        }
    }
    @Published private(set) var allowlist: BlockingAllowlist
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var ruleCount = 0
    @Published private(set) var updating = false
    @Published private(set) var problem: String?
    /// True while only the small built-in list is in use.
    @Published private(set) var usingBuiltIn = true

    private var lists: [WKContentRuleList] = []
    private let webViews = NSHashTable<WKWebView>.weakObjects()
    private var started = false
    private var refreshTimer: Timer?

    private var store: WKContentRuleListStore { WKContentRuleListStore.default() }

    private init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        allowlist = BlockingAllowlist(UserDefaults.standard.stringArray(forKey: Self.allowedKey) ?? [])
        lastUpdated = UserDefaults.standard.object(forKey: Self.updatedKey) as? Date
        ruleCount = UserDefaults.standard.integer(forKey: Self.ruleCountKey)
    }

    // MARK: Hooks called by WebTab

    /// Called for every new web view configuration. Lists are attached per load in `prepare`.
    func install(in config: WKWebViewConfiguration) {
        start()
        if enabled { lists.forEach { config.userContentController.add($0) } }
        config.userContentController.tabmapBlockingOn = enabled && !lists.isEmpty
        config.userContentController.tabmapGeneration = listGeneration
    }

    /// Called before each main-frame navigation: blocking on or off for the site being opened.
    func prepare(_ webView: WKWebView, for url: URL) {
        webViews.add(webView)
        apply(to: webView, host: url.host)
    }

    // MARK: State

    func isBlocking(on url: URL?) -> Bool {
        guard enabled, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return !allowlist.allows(host: url.host)
    }

    /// The island's shield: turns blocking off (or back on) for the site in front and reloads it.
    func toggleSite(of url: URL?) {
        guard let host = url?.host else { return }
        let allow = !allowlist.allows(host: host)
        allowlist.set(host: host, allowed: allow)
        saveAllowlist()
        reapplyEverywhere()
    }

    func removeAllowed(_ site: String) {
        allowlist.set(host: site, allowed: false)
        saveAllowlist()
        reapplyEverywhere()
    }

    private func saveAllowlist() {
        UserDefaults.standard.set(allowlist.sites.sorted(), forKey: Self.allowedKey)
    }

    private func apply(to webView: WKWebView, host: String?) {
        let controller = webView.configuration.userContentController
        let want = enabled && !lists.isEmpty && !allowlist.allows(host: host)
        let generation = listGeneration
        if controller.tabmapBlockingOn == want, !want || controller.tabmapGeneration == generation { return }
        controller.removeAllContentRuleLists()
        if want { lists.forEach { controller.add($0) } }
        controller.tabmapBlockingOn = want
        controller.tabmapGeneration = generation
    }

    /// Re-applies after a setting changes and reloads the open pages it affects
    /// (rule lists only take effect from a page's next load).
    private func reapplyEverywhere() {
        for webView in webViews.allObjects {
            let before = webView.configuration.userContentController.tabmapBlockingOn
            apply(to: webView, host: webView.url?.host)
            if webView.url != nil, before != webView.configuration.userContentController.tabmapBlockingOn {
                webView.reload()
            }
        }
    }

    private var listGeneration = 0

    private func use(_ newLists: [WKContentRuleList], rules: Int, builtIn: Bool) {
        lists = newLists
        listGeneration += 1
        usingBuiltIn = builtIn
        ruleCount = rules
        for webView in webViews.allObjects { apply(to: webView, host: webView.url?.host) }
    }

    // MARK: Lists

    func start() {
        guard !started else { return }
        started = true
        Task { await loadStoredLists() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in ContentBlocker.shared.refreshIfStale() }
        }
    }

    private func loadStoredLists() async {
        let defaults = UserDefaults.standard
        let ids = defaults.stringArray(forKey: Self.listIDsKey) ?? []
        if defaults.integer(forKey: Self.versionKey) == FilterListConverter.version, !ids.isEmpty {
            var found: [WKContentRuleList] = []
            for id in ids {
                if let list = await lookUp(id) { found.append(list) }
            }
            if found.count == ids.count {
                use(found, rules: defaults.integer(forKey: Self.ruleCountKey), builtIn: false)
                refreshIfStale()
                return
            }
        }
        // Nothing stored yet: the built-in list now, the full lists as soon as they download.
        let builtIn = FilterListConverter.convert(Self.builtInList)
        if let list = await compile("tabmap-builtin-\(FilterListConverter.version)",
                                    ConvertedFilters.encode(builtIn.chunks().first ?? [])) {
            if lists.isEmpty { use([list], rules: builtIn.ruleCount, builtIn: true) }
        }
        await update()
    }

    func refreshIfStale() {
        guard !updating else { return }
        if usingBuiltIn || lastUpdated.map({ Date().timeIntervalSince($0) > Self.refreshInterval }) ?? true {
            Task { await update() }
        }
    }

    /// Downloads both lists, converts and compiles them, then swaps them in.
    func update() async {
        guard !updating else { return }
        updating = true
        problem = nil
        defer { updating = false }

        var texts: [String] = []
        for source in Self.sources {
            do {
                var request = URLRequest(url: source.url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 60
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                texts.append(String(decoding: data, as: UTF8.self))
            } catch {
                problem = "Could not download \(source.name). Will try again later."
                return
            }
        }

        let input = texts
        let converted = await Task.detached(priority: .utility) { FilterListConverter.convert(input) }.value
        let generation = Int(Date().timeIntervalSince1970)
        var compiled: [WKContentRuleList] = []
        var ids: [String] = []
        var rules = 0
        for (i, chunk) in converted.chunks().enumerated() {
            let id = "tabmap-\(generation)-\(i)"
            let got = await compileSplitting(id, chunk)
            compiled += got.lists
            ids += got.ids
            rules += got.rules
        }
        guard !compiled.isEmpty else {
            problem = "WebKit could not use the downloaded lists."
            return
        }

        let old = UserDefaults.standard.stringArray(forKey: Self.listIDsKey) ?? []
        let defaults = UserDefaults.standard
        defaults.set(ids, forKey: Self.listIDsKey)
        defaults.set(FilterListConverter.version, forKey: Self.versionKey)
        defaults.set(rules, forKey: Self.ruleCountKey)
        defaults.set(Date(), forKey: Self.updatedKey)
        lastUpdated = Date()
        use(compiled, rules: rules, builtIn: false)
        for id in old where !ids.contains(id) { store.removeContentRuleList(forIdentifier: id) { _ in } }
    }

    /// Compiles a chunk; if WebKit rejects it (one bad rule fails the whole list), halves it and
    /// tries again, so a single bad rule only costs a small slice of the list.
    private func compileSplitting(_ id: String, _ rules: [ContentRule]) async -> (lists: [WKContentRuleList], ids: [String], rules: Int) {
        if let list = await compile(id, ConvertedFilters.encode(rules)) {
            return ([list], [id], rules.count)
        }
        // Exceptions sit at the end of a chunk and must stay with the blocks they cancel; the
        // halves each keep them by splitting only the leading block/hide part.
        let tail = rules.drop(while: { $0.action.type != "ignore-previous-rules" })
        let head = rules.prefix(rules.count - tail.count)
        guard head.count >= 500 else { return ([], [], 0) }
        let cut = head.count / 2
        let a = await compileSplitting(id + "a", Array(head.prefix(cut)) + tail)
        let b = await compileSplitting(id + "b", Array(head.dropFirst(cut)) + tail)
        return (a.lists + b.lists, a.ids + b.ids, a.rules + b.rules)
    }

    private func compile(_ id: String, _ json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let error { NSLog("Tabmap content blocking: \(id) failed: \(error.localizedDescription)") }
                continuation.resume(returning: list)
            }
        }
    }

    private func lookUp(_ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in continuation.resume(returning: list) }
        }
    }

    /// Used until the full lists have downloaded: the most common ad and tracking hosts.
    static let builtInList = """
    ||doubleclick.net^
    ||googlesyndication.com^
    ||googleadservices.com^$third-party
    ||google-analytics.com^
    ||adservice.google.com^
    ||amazon-adsystem.com^
    ||adnxs.com^
    ||adsrvr.org^
    ||criteo.com^
    ||criteo.net^
    ||taboola.com^
    ||outbrain.com^
    ||scorecardresearch.com^
    ||quantserve.com^
    ||pubmatic.com^
    ||rubiconproject.com^
    ||openx.net^
    ||casalemedia.com^
    ||moatads.com^
    ||adsafeprotected.com^
    ||doubleverify.com^
    ||3lift.com^
    ||sharethrough.com^
    ||smartadserver.com^
    ||bidswitch.net^
    ||demdex.net^
    ||krxd.net^
    ||bluekai.com^
    ||hotjar.com^$third-party
    ||ads-twitter.com^
    ||bat.bing.com^
    ||connect.facebook.net^$third-party
    ||media.net^$third-party
    ||yieldmo.com^
    ||teads.tv^
    ||adform.net^
    ||serving-sys.com^
    ||everesttech.net^
    """
}

// MARK: - Per-controller bookkeeping

private var blockingOnKey: UInt8 = 0
private var generationKey: UInt8 = 0

extension WKUserContentController {
    /// Whether the rule lists are attached to this controller now.
    var tabmapBlockingOn: Bool {
        get { (objc_getAssociatedObject(self, &blockingOnKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &blockingOnKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    /// Which set of lists is attached, so new lists replace old ones.
    var tabmapGeneration: Int {
        get { (objc_getAssociatedObject(self, &generationKey) as? Int) ?? 0 }
        set { objc_setAssociatedObject(self, &generationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - Page shown when the address itself is on a list

extension WebTab {
    /// WebKit error 104: the page's own address is on a block list (usually an ad or tracking link).
    func showBlockedByContentBlocker(_ error: NSError) {
        let failing = (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
        let host = URL(string: failing)?.host ?? failing
        let safe = host.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <html><head><meta name="viewport" content="width=device-width">
        <style>
        body { font-family: -apple-system, sans-serif; color: #666; display: flex; align-items: center;
               justify-content: center; height: 90vh; margin: 0; }
        div { max-width: 480px; text-align: center; }
        h1 { font-size: 20px; color: #333; }
        p { font-size: 13px; }
        @media (prefers-color-scheme: dark) { body { background: #1e1e1e; color: #999; } h1 { color: #ddd; } }
        </style></head><body><div>
        <h1>\(safe) is on the ad and tracker list</h1>
        <p>Tabmap stopped this page from opening. To open it anyway, show the address bar and click the shield to turn blocking off for this site.</p>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: failing))
    }
}

// MARK: - UI

/// The shield in the address island. Filled while blocking is on for the site in front.
struct BlockingShield: View {
    @ObservedObject private var blocker = ContentBlocker.shared
    let url: URL?

    var body: some View {
        if blocker.enabled, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let on = blocker.isBlocking(on: url)
            Button { blocker.toggleSite(of: url) } label: {
                Image(systemName: on ? "shield.lefthalf.filled" : "shield.slash")
                    .opacity(on ? 1 : 0.55)
            }
            .help(on ? "Blocking ads and trackers on \(url.host ?? "this site"). Click to allow them here."
                     : "Ads and trackers are allowed on \(url.host ?? "this site"). Click to block them.")
        }
    }
}

/// Settings section.
struct ContentBlockingSettings: View {
    @ObservedObject private var blocker = ContentBlocker.shared

    var body: some View {
        Section {
            Toggle("Block ads and trackers", isOn: $blocker.enabled)
            Text(statusText)
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if blocker.enabled {
                HStack {
                    Button(blocker.updating ? "Updating…" : "Update Lists Now") { Task { await blocker.update() } }
                        .disabled(blocker.updating)
                    Spacer()
                }
                if !blocker.allowlist.sites.isEmpty {
                    Text("Allowed on these sites (click the shield in the address bar to change):")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    ForEach(blocker.allowlist.sites.sorted(), id: \.self) { site in
                        HStack {
                            Text(site)
                            Spacer()
                            Button { blocker.removeAllowed(site) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Block ads and trackers on \(site) again")
                        }
                    }
                }
            }
        }
    }

    private var statusText: String {
        if let problem = blocker.problem { return problem }
        if blocker.updating { return "Downloading EasyList and EasyPrivacy…" }
        if blocker.usingBuiltIn { return "Using a small built-in list until EasyList and EasyPrivacy download." }
        let when = blocker.lastUpdated.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "recently"
        return "EasyList and EasyPrivacy, \(blocker.ruleCount.formatted()) rules, updated \(when). Blocking happens inside WebKit on this Mac."
    }
}
