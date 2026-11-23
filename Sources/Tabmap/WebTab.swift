import AppKit
import WebKit
import TabMapCore

/// A loaded page: owns the WKWebView for one tab and reports what happens in it to the store.
@MainActor
final class WebTab: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let id: TabID
    let webView: WKWebView
    private weak var store: BrowserStore?

    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false

    private var observations: [NSKeyValueObservation] = []

    /// The version of the Safari installed on this Mac, so sites see a current browser
    /// (Gmail warns about old versions). Falls back to a recent one if Safari cannot be read.
    static let safariVersion: String = {
        let paths = ["/Applications/Safari.app", "/System/Cryptexes/App/System/Applications/Safari.app"]
        for path in paths {
            if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String,
               let major = Int(version.split(separator: ".").first ?? ""), major >= 18 {
                return version
            }
        }
        return "26.0"
    }()

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Present as Safari so sites serve their normal pages.
        config.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        // window.open without a click is how pop-up ads arrive; keep those out of the map.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        EdgeProbe.shared.install(in: config)
        ContentBlocker.shared.install(in: config)
        PasswordAutofill.shared.install(in: config)
        SearchSwitchComposer.install(in: config)
        return config
    }

    /// `configuration` is supplied by WebKit when a page opens a new window; it must be used as given.
    /// `adopting` takes over a web view that already exists (a page coming out of the app dock).
    init(id: TabID, store: BrowserStore, configuration: WKWebViewConfiguration?, adopting: WKWebView? = nil) {
        self.id = id
        self.store = store
        self.webView = adopting ?? PageWebView(frame: .zero, configuration: configuration ?? WebTab.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        observations = [
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor [weak self] in self?.syncMeta() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor [weak self] in self?.syncMeta() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor [weak self] in self?.syncNavState() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor [weak self] in self?.syncNavState() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor [weak self] in self?.syncNavState() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor [weak self] in self?.syncNavState() } },
        ]
    }

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Lets go of the web view so the app dock can take it over. The tab object is dead afterwards.
    func release() -> WKWebView {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        return webView
    }

    private func syncMeta() {
        store?.tabMetaChanged(id, url: webView.url, title: webView.title)
        HistoryStore.shared.sync(tab: id, webView: webView)
    }

    private func syncNavState() {
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if progress != webView.estimatedProgress { progress = webView.estimatedProgress }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }

        // Cmd-click: open to the right of this tab, in the background. Add Shift to switch to it.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            store?.openChild(of: id, url: url, activate: navigationAction.modifierFlags.contains(.shift), hop: true)
            return .cancel
        }

        // mailto:, facetime:, app links and the like go to the system.
        let scheme = (url.scheme ?? "").lowercased()
        let inApp: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
        if !scheme.isEmpty, !inApp.contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        // Ad and tracker blocking on or off for the site this tab is about to show.
        if navigationAction.targetFrame?.isMainFrame == true { ContentBlocker.shared.prepare(webView, for: url) }
        if navigationAction.shouldPerformDownload { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        store?.tabDidNavigate(id)
        HistoryStore.shared.sync(tab: id, webView: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncMeta()
        store?.tabDidFinishLoading(id)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func showError(_ error: Error) {
        let ns = error as NSError
        // Cancelled loads and loads handed off elsewhere are not failures.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 104 { showBlockedByContentBlocker(ns); return }
        let failing = (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
        let html = """
        <html><head><meta name="viewport" content="width=device-width">
        <style>
        body { font: -apple-system-body; font-family: -apple-system, sans-serif; color: #666;
               display: flex; align-items: center; justify-content: center; height: 90vh; margin: 0; }
        div { max-width: 480px; text-align: center; }
        h1 { font-size: 20px; color: #333; }
        p { font-size: 13px; word-break: break-all; }
        @media (prefers-color-scheme: dark) { body { background: #1e1e1e; color: #999; } h1 { color: #ddd; } }
        </style></head><body><div>
        <h1>This page could not be opened</h1>
        <p>\(Self.escape(ns.localizedDescription))</p>
        <p>\(Self.escape(failing))</p>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: failing))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: WKUIDelegate

    /// target=_blank and window.open: the new page becomes a tab to the right of this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        store?.adoptPopup(from: id, configuration: configuration, url: navigationAction.request.url)
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.closeTab(id)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
