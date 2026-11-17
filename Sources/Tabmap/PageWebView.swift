import AppKit
import WebKit
import TabMapCore

/// The web view every page and app-dock site uses. It exists to make the right-click menu's
/// "Download Image", "Download Linked File" and "Download Video" items work: on their own they do
/// nothing in an app's WKWebView. Each one becomes a real download, credited to the tab it came from.
final class PageWebView: WKWebView {
    private static let marker = "/*tabmap-context-target*/"
    private static let world = WKContentWorld.world(name: "tabmap-downloads")

    /// Remembers what was under the pointer when the context menu opened. Runs in its own world,
    /// so pages can't see or overwrite it, and in the capture phase, so pages can't stop it.
    private static let script = marker + """
    (function () {
      document.addEventListener('contextmenu', function (e) {
        var image = null, link = null, media = null;
        for (var n = e.target; n && n.nodeType === 1; n = n.parentElement) {
          var tag = n.tagName.toUpperCase();
          if (!image && tag === 'IMG') image = n.currentSrc || n.src || null;
          if (!media && (tag === 'VIDEO' || tag === 'AUDIO')) {
            media = n.currentSrc || n.src || null;
            if (!media) { var s = n.querySelector('source[src]'); if (s) media = s.src; }
          }
          if (!link && tag === 'A' && typeof n.href === 'string' && n.href) link = n.href;
        }
        window.__tabmapContext = { image: image, link: link, media: media, page: location.href };
      }, true);
    })();
    """

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        let controller = self.configuration.userContentController
        // Pages opened by a page share its controller; add the script only once.
        if !controller.userScripts.contains(where: { $0.source.hasPrefix(Self.marker) }) {
            controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: Self.world))
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private enum Target: String {
        case image, link, media
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            let id = item.identifier?.rawValue ?? ""
            let title = item.title
            if id == "WKMenuItemIdentifierDownloadImage" || title.hasPrefix("Download Image") {
                retarget(item, .image)
            } else if id == "WKMenuItemIdentifierDownloadLinkedFile" || title.hasPrefix("Download Linked File") {
                retarget(item, .link)
            } else if id == "WKMenuItemIdentifierDownloadMedia" || title.hasPrefix("Download Video")
                        || title.hasPrefix("Download Audio") {
                retarget(item, .media)
            }
        }
    }

    private func retarget(_ item: NSMenuItem, _ target: Target) {
        item.target = self
        item.action = #selector(downloadFromMenu(_:))
        item.representedObject = target.rawValue
        item.isEnabled = true
    }

    @objc private func downloadFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let target = Target(rawValue: raw) else { return }
        evaluateJavaScript("window.__tabmapContext || null", in: nil, in: Self.world) { [weak self] result in
            guard let self else { return }
            let context = (try? result.get()) as? [String: Any]
            var address = context?[target.rawValue] as? String
            // An image inside a link, chosen as "Download Linked File", and the like: fall back sensibly.
            if address == nil, target == .link { address = context?["image"] as? String }
            if address == nil, target == .image { address = context?["media"] as? String }
            guard let address, let url = URL(string: address) else {
                NSSound.beep()
                return
            }
            self.download(url, referrer: (context?["page"] as? String) ?? self.url?.absoluteString)
        }
    }

    private func download(_ url: URL, referrer: String?) {
        var request = URLRequest(url: url)
        // Some image hosts refuse requests that don't say which page they're for.
        if let referrer, url.scheme == "http" || url.scheme == "https" {
            request.setValue(referrer, forHTTPHeaderField: "Referer")
        }
        let tab = (navigationDelegate as? WebTab)?.id
        startDownload(using: request) { download in
            Task { @MainActor in DownloadStore.shared.begin(download, tab: tab) }
        }
    }
}
