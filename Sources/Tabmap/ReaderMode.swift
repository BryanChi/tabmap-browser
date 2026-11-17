import AppKit
import SwiftUI
import WebKit
import TabMapCore

/// Reader mode (⇧⌘R): the article on the current page, on its own, in clean type.
///
/// The article is pulled out by a script that only reads the page, then shown in a separate web
/// view laid over the tab, with JavaScript off. The tab's page stays loaded underneath, so closing
/// the reader (⇧⌘R, Esc or the × in its pill) puts you back exactly where you were.
/// Hooks elsewhere: `ReaderLayer()` in ContentView, a menu item, and a button in the island.
@MainActor
final class ReaderController: ObservableObject {
    static let shared = ReaderController()

    /// Tabs whose page has an article worth reading (checked when a page finishes loading).
    @Published private(set) var available: Set<TabID> = []
    /// Tabs showing the reader, with their article.
    @Published private(set) var articles: [TabID: ReaderArticle] = [:]
    @Published var style: ReaderStyle {
        didSet { if style != oldValue { saveStyle() } }
    }
    /// Briefly true after the reader opens or the style changes, so the controls pill shows fully.
    @Published private(set) var pillWake = 0

    private var monitor: Any?
    private let world = WKContentWorld.world(name: "TabmapReader")
    private static let themeKey = "readerTheme", fontKey = "readerFont", sizeKey = "readerSizeStep"

    private init() {
        let defaults = UserDefaults.standard
        style = ReaderStyle(
            theme: ReaderStyle.Theme(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .auto,
            font: ReaderStyle.Font(rawValue: defaults.string(forKey: Self.fontKey) ?? "") ?? .serif,
            sizeStep: defaults.object(forKey: Self.sizeKey) as? Int ?? ReaderStyle.defaultSizeStep)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func saveStyle() {
        let defaults = UserDefaults.standard
        defaults.set(style.theme.rawValue, forKey: Self.themeKey)
        defaults.set(style.font.rawValue, forKey: Self.fontKey)
        defaults.set(style.sizeStep, forKey: Self.sizeKey)
        pillWake += 1
    }

    // MARK: State for the current tab

    private var activeID: TabID? {
        AppDock.shared.isFront ? nil : BrowserStore.shared.map.activeTabID
    }

    var activeArticle: ReaderArticle? { activeID.flatMap { articles[$0] } }
    var isShown: Bool { activeArticle != nil }
    var canShow: Bool { activeID.map { available.contains($0) || articles[$0] != nil } ?? false }

    // MARK: Actions

    func toggle() {
        guard let id = activeID else { return }
        if articles[id] != nil {
            close(id)
        } else {
            open(id)
        }
    }

    func open(_ id: TabID) {
        guard let page = BrowserStore.shared.page(for: id) else { return }
        let url = page.webView.url
        run(mode: "extract", in: page.webView) { [weak self] reply in
            guard let self, let reply, let article = ReaderArticle(reply: reply, url: url) else {
                NSSound.beep()
                return
            }
            self.available.insert(id)
            self.articles[id] = article
            self.pillWake += 1
            FindController.shared.close()
        }
    }

    func close(_ id: TabID) {
        guard articles.removeValue(forKey: id) != nil else { return }
        if id == activeID, let webView = BrowserStore.shared.page(for: id)?.webView {
            webView.window?.makeFirstResponder(webView)
        }
    }

    /// A tab's page finished loading: see whether it has an article.
    func check(_ id: TabID) {
        guard let page = BrowserStore.shared.page(for: id) else { return }
        run(mode: "check", in: page.webView) { [weak self] reply in
            guard let self else { return }
            let words = (reply?["words"] as? NSNumber)?.intValue ?? 0
            if words >= ReaderArticle.minimumWords {
                self.available.insert(id)
            } else {
                self.available.remove(id)
            }
        }
    }

    /// A tab started loading a new page: its reader view and article no longer apply.
    func pageStarted(_ id: TabID, url: URL?) {
        if let article = articles[id], Self.samePage(article.url, url) { return }
        available.remove(id)
        articles.removeValue(forKey: id)
    }

    /// A link clicked in the reader: leave the reader and follow it in the tab (⌘-click opens it to the right).
    func follow(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        guard let id = activeID else { return }
        let store = BrowserStore.shared
        if modifiers.contains(.command) {
            store.openChild(of: id, url: url, activate: modifiers.contains(.shift))
            return
        }
        close(id)
        store.page(for: id)?.load(url)
    }

    private static func samePage(_ a: URL?, _ b: URL?) -> Bool {
        func strip(_ url: URL?) -> String? {
            guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            return parts.string
        }
        return strip(a) != nil && strip(a) == strip(b)
    }

    private func run(mode: String, in webView: WKWebView, done: @escaping ([String: Any]?) -> Void) {
        webView.callAsyncJavaScript(Self.script, arguments: ["mode": mode], in: nil, in: world) { result in
            let reply: [String: Any]?
            if case .success(let value) = result { reply = value as? [String: Any] } else { reply = nil }
            Task { @MainActor in done(reply) }
        }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let store = BrowserStore.shared
        guard isShown, !store.overviewShown, event.window === store.activeWebTab?.webView.window else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers
        if flags.isEmpty, event.keyCode == 53, !store.addressEditing, !FindController.shared.shown { // escape
            toggle()
            return true
        }
        if flags == [.command] || flags == [.command, .shift] {
            switch key {
            case "=", "+": style.grow(); return true
            case "-": style.shrink(); return true
            case "0": style.sizeStep = ReaderStyle.defaultSizeStep; return true
            default: break
            }
        }
        return false
    }

    // The extractor. Body of an async function; argument: mode ("check" | "extract").
    // Runs in Tabmap's own script world and only reads the page.
    static let script = #"""
    // Body of an async function. Argument: mode ("check" | "extract").
    // Finds the main article on the page without changing the page. Returns
    // { words, title, byline, siteName, content } (content only for "extract").
    const doc = document;
    if (!doc.body) return { words: 0 };

    const UNLIKELY = /(^|[\s_-])(ad|ads|advert|advertisement|banner|breadcrumbs?|combx|comments?|community|cookie|disqus|extra|footer|gdpr|header|legends|menu|modal|nav|newsletter|outbrain|pager|pagination|popup|promo|promoted|related|remark|replies|rss|share|sharing|shoutbox|sidebar|skyscraper|social|sponsor|sponsored|subscribe|subscription|taboola|tags|toolbar|tools|tweet|twitter|widget)([\s_-]|$)/i;
    const LIKELY = /(^|[\s_-])(article|body|content|entry|hentry|h-entry|main|page|post|story|text|blog)([\s_-]|$)/i;
    const NEGATIVE = /(^|[\s_-])(hidden|hide|comment|com-|contact|foot|footer|footnote|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|tool|widget)([\s_-]|$)/i;
    const SKIP_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "NAV", "ASIDE", "FOOTER", "FORM", "BUTTON", "SELECT", "TEXTAREA", "INPUT", "DIALOG", "MENU", "SVG", "IFRAME", "OBJECT", "EMBED", "CANVAS"]);
    const SKIP_ROLES = new Set(["navigation", "banner", "complementary", "contentinfo", "dialog", "alertdialog", "menu", "menubar", "search", "toolbar"]);

    const classAndId = (el) => ((typeof el.className === "string" ? el.className : "") + " " + (el.id || ""));
    const textOf = (el) => (el.textContent || "").replace(/\s+/g, " ").trim();
    const isHidden = (el) => {
      if (el.hidden || el.getAttribute("aria-hidden") === "true") return true;
      if (el.checkVisibility) return !el.checkVisibility({ visibilityProperty: true });
      const style = el.style || {};
      return style.display === "none" || style.visibility === "hidden";
    };
    const isJunk = (el) => {
      if (SKIP_TAGS.has(el.tagName)) return true;
      if (SKIP_ROLES.has((el.getAttribute("role") || "").toLowerCase())) return true;
      if (el.tagName === "HEADER" && !el.closest("article")) return true;
      const names = classAndId(el);
      return UNLIKELY.test(names) && !LIKELY.test(names) && el.tagName !== "BODY" && el.tagName !== "ARTICLE" && el.tagName !== "MAIN";
    };
    const junkCache = new Map();
    const inJunk = (el) => {
      const chain = [];
      let result = false;
      for (let node = el; node && node !== doc.body; node = node.parentElement) {
        if (junkCache.has(node)) { result = junkCache.get(node); break; }
        chain.push(node);
        if (isJunk(node) || isHidden(node)) { result = true; break; }
      }
      for (const node of chain) junkCache.set(node, result);
      return result;
    };
    const linkDensity = (el) => {
      const total = textOf(el).length;
      if (!total) return 0;
      let links = 0;
      for (const a of el.querySelectorAll("a")) links += textOf(a).length;
      return links / total;
    };
    const classWeight = (el) => {
      const names = classAndId(el);
      let weight = 0;
      if (NEGATIVE.test(names)) weight -= 25;
      if (LIKELY.test(names)) weight += 25;
      return weight;
    };

    // --- Metadata
    const meta = (...names) => {
      for (const name of names) {
        const el = doc.querySelector(`meta[property="${name}"],meta[name="${name}"]`);
        const value = el && el.getAttribute("content");
        if (value && value.trim()) return value.trim();
      }
      return null;
    };
    const siteName = meta("og:site_name", "application-name");
    let title = meta("og:title", "twitter:title") || "";
    if (!title) {
      const h1 = doc.querySelector("article h1, main h1, h1");
      title = h1 ? textOf(h1) : "";
    }
    if (!title) {
      title = (doc.title || "").trim();
      const parts = title.split(/\s+[|\-–—·»:]\s+/);
      if (parts.length > 1 && parts[0].split(/\s+/).length >= 3) title = parts[0];
    }
    let byline = meta("author", "article:author", "parsely-author", "sailthru.author");
    if (byline && /^https?:/.test(byline)) byline = null;
    if (!byline) {
      const el = doc.querySelector('[rel="author"], [itemprop="author"] [itemprop="name"], [itemprop="author"], .byline, .author-name');
      const text = el ? textOf(el) : "";
      if (text && text.length < 100) byline = text.replace(/^by\s+/i, "");
    }

    // --- Find the article
    const scores = new Map();
    const addScore = (el, amount) => {
      if (!el || el === doc.documentElement) return;
      if (!scores.has(el)) scores.set(el, classWeight(el) + ({ ARTICLE: 10, MAIN: 5, SECTION: 3, DIV: 5, PRE: 3, TD: 3, BLOCKQUOTE: 3, FORM: -3, UL: -3, OL: -3, LI: -3, TH: -5, ADDRESS: -3 }[el.tagName] || 0));
      scores.set(el, scores.get(el) + amount);
    };
    for (const p of doc.body.querySelectorAll("p, pre, td, blockquote, div > br + br")) {
      const node = p.tagName === "BR" ? p.parentElement : p;
      if (inJunk(node)) continue;
      const text = textOf(node);
      if (text.length < 25) continue;
      const score = 1 + text.split(/[,，、]/).length + Math.min(3, Math.floor(text.length / 100));
      let parent = node.parentElement;
      for (let level = 0; parent && level < 3; level += 1, parent = parent.parentElement) {
        addScore(parent, score / (level === 0 ? 1 : level === 1 ? 2 : level * 3));
      }
    }
    let top = null;
    let topScore = 0;
    for (const [el, score] of scores) {
      const adjusted = score * (1 - linkDensity(el));
      if (adjusted > topScore) { top = el; topScore = adjusted; }
    }
    // Pages that mark up their article are trusted when it carries most of the text.
    const marked = doc.querySelector('[itemprop="articleBody"]') || (doc.querySelectorAll("article").length === 1 ? doc.querySelector("article") : null);
    if (marked && !inJunk(marked) && (!top || marked.contains(top) || textOf(marked).length > textOf(top).length * 0.8)) top = marked;
    if (!top) return { words: 0, title, byline, siteName };
    // A candidate that is one child of its parent with most of its text: climb to take in headings and figures.
    while (top.parentElement && top.parentElement !== doc.body && textOf(top).length > textOf(top.parentElement).length * 0.85 && !inJunk(top.parentElement)) {
      top = top.parentElement;
    }

    // Siblings that look like part of the same article (split articles, continued text).
    const parts = [];
    if (top.parentElement && top !== marked) {
      const threshold = Math.max(10, topScore * 0.2);
      for (const sibling of top.parentElement.children) {
        if (sibling === top) { parts.push(sibling); continue; }
        if (inJunk(sibling)) continue;
        const score = (scores.get(sibling) || 0) * (1 - linkDensity(sibling));
        const text = textOf(sibling);
        const paragraph = sibling.tagName === "P" && ((text.length > 80 && linkDensity(sibling) < 0.25) || (text.length > 0 && linkDensity(sibling) === 0 && /\.( |$)/.test(text)));
        if (score >= threshold || paragraph) parts.push(sibling);
      }
    } else {
      parts.push(top);
    }

    const words = parts.reduce((sum, el) => {
      let text = "";
      const walker = doc.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
        acceptNode: (n) => (n.parentElement && inJunk(n.parentElement) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
      });
      for (let n = walker.nextNode(); n; n = walker.nextNode()) text += " " + n.data;
      return sum + (text.match(/[\p{L}\p{N}]+/gu) || []).length;
    }, 0);
    if (mode !== "extract") return { words, title };

    // --- Copy and clean
    const KEEP_ATTRS = { A: ["href", "title"], IMG: ["src", "srcset", "alt", "title", "width", "height"], SOURCE: ["srcset", "type", "media"], TD: ["colspan", "rowspan"], TH: ["colspan", "rowspan"], VIDEO: ["src", "poster", "controls"], AUDIO: ["src", "controls"], OL: ["start"] };
    const DROP_EMPTY = new Set(["P", "DIV", "SECTION", "HEADER", "ARTICLE", "MAIN", "SPAN", "A", "LI", "UL", "OL", "H1", "H2", "H3", "H4", "H5", "H6", "BLOCKQUOTE", "FIGURE"]);
    const RENAME = { SECTION: "div", ARTICLE: "div", MAIN: "div", HEADER: "div", FONT: "span", CENTER: "div" };
    const absolute = (value) => { try { return new URL(value, doc.baseURI).href; } catch (e) { return null; } };
    const absoluteSrcset = (value) => value.split(",").map((part) => {
      const [url, ...rest] = part.trim().split(/\s+/);
      const abs = url && absolute(url);
      return abs ? [abs, ...rest].join(" ") : "";
    }).filter(Boolean).join(", ");
    const out = doc.implementation.createHTMLDocument("");

    const copy = (node) => {
      if (node.nodeType === 3) return out.createTextNode(node.data);
      if (node.nodeType !== 1) return null;
      const el = node;
      if (el.tagName === "BR") return out.createElement("br");
      if (el.tagName === "HR") return out.createElement("hr");
      if (isJunk(el) || isHidden(el)) return null;
      if (el.tagName === "H1" && textOf(el) === title) return null;
      if (byline && /^(P|DIV|SPAN|ADDRESS)$/.test(el.tagName) && textOf(el).replace(/^by\s+/i, "") === byline) return null;
      const tag = RENAME[el.tagName] || el.tagName.toLowerCase();
      // Lists and boxes that are mostly links (related stories, tag clouds) are left out.
      if (/^(div|ul|ol|table)$/.test(tag) && !el.querySelector("img, picture, video, pre")) {
        const text = textOf(el);
        if (text.length < 400 && linkDensity(el) > 0.5) return null;
      }
      let result;
      try { result = out.createElement(tag); } catch (e) { result = out.createElement("span"); }
      for (const name of KEEP_ATTRS[el.tagName] || []) {
        let value = el.getAttribute(name);
        if (el.tagName === "IMG" && name === "src") value = el.getAttribute("data-src") || el.getAttribute("data-lazy-src") || el.currentSrc || value;
        if (el.tagName === "IMG" && name === "srcset") value = el.getAttribute("data-srcset") || value;
        if (value == null || value === "") continue;
        if (name === "href" || name === "src" || name === "poster") {
          if (/^\s*javascript:/i.test(value)) continue;
          value = value.startsWith("#") ? value : absolute(value);
          if (!value) continue;
        }
        if (name === "srcset") value = absoluteSrcset(value);
        result.setAttribute(name, value);
      }
      if (el.tagName === "VIDEO") result.setAttribute("controls", "");
      for (const child of el.childNodes) {
        const copied = copy(child);
        if (copied) result.appendChild(copied);
      }
      if (DROP_EMPTY.has(el.tagName) && !textOf(result) && !result.querySelector("img, picture, video, audio, br, hr, table, pre")) return null;
      if (el.tagName === "IMG" && !result.getAttribute("src")) return null;
      return result;
    };

    const body = out.createElement("div");
    for (const part of parts) {
      const copied = copy(part);
      if (copied) body.appendChild(copied);
    }
    return { words, title, byline, siteName, content: body.innerHTML };
    """#
}

// MARK: Views

/// The reader laid over the page stage, with its controls pill.
struct ReaderLayer: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var reader = ReaderController.shared
    @ObservedObject private var dock = AppDock.shared

    var body: some View {
        let article = store.overviewShown ? nil : reader.activeArticle
        ZStack(alignment: .top) {
            if let article {
                ReaderWebView(article: article, style: reader.style)
                    .transition(.opacity)
                ReaderPill()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: article?.url)
        .background {
            if let page = store.activeWebTab { ReaderPageWatcher(page: page) }
        }
    }
}

/// Checks each page for an article as it finishes loading, and drops a stale reader when the tab
/// moves to another page.
private struct ReaderPageWatcher: View {
    @ObservedObject var page: WebTab

    var body: some View {
        Color.clear
            .onChange(of: page.isLoading) { loading in
                let reader = ReaderController.shared
                if loading {
                    reader.pageStarted(page.id, url: page.webView.url)
                } else {
                    reader.check(page.id)
                }
            }
            .onAppear {
                if !page.isLoading { ReaderController.shared.check(page.id) }
            }
    }
}

/// A web view with scripts off showing the article page.
private struct ReaderWebView: NSViewRepresentable {
    let article: ReaderArticle
    let style: ReaderStyle

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: ReaderArticle?
        var shownStyle: ReaderStyle?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            // Jumps within the article (footnotes) stay in the reader.
            if url.fragment != nil, let base = shown?.url,
               url.absoluteString.hasPrefix(base.absoluteString.components(separatedBy: "#")[0] + "#") {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            let modifiers = action.modifierFlags
            Task { @MainActor in ReaderController.shared.follow(url, modifiers: modifiers) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.shown != article {
            coordinator.shown = article
            coordinator.shownStyle = style
            view.loadHTMLString(ReaderDocument.html(for: article, style: style), baseURL: article.url)
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if coordinator.shownStyle != style {
            // Restyle in place so the reading position is kept.
            coordinator.shownStyle = style
            let css = ReaderDocument.styleSheet(style)
            let theme = "theme-\(style.theme.rawValue)"
            view.callAsyncJavaScript(
                "document.querySelector('style').textContent = css; document.body.className = theme;",
                arguments: ["css": css, "theme": theme], in: nil, in: .defaultClient, completionHandler: nil)
        }
    }
}

/// The reader's controls: text size, font, theme and close. Sits at the top right in the island
/// style, and fades back once you start reading; it comes back when the pointer is over it.
private struct ReaderPill: View {
    @ObservedObject private var reader = ReaderController.shared
    @ObservedObject private var find = FindController.shared
    @EnvironmentObject private var store: BrowserStore
    @State private var hovering = false
    @State private var awake = true

    var body: some View {
        HStack(spacing: 10) {
            Button { reader.style.shrink() } label: { Text("A").font(.system(size: 11, weight: .semibold)) }
                .disabled(!reader.style.canShrink)
                .help("Smaller text (⌘−)")
            Button { reader.style.grow() } label: { Text("A").font(.system(size: 16, weight: .semibold)) }
                .disabled(!reader.style.canGrow)
                .help("Larger text (⌘+)")
            Divider().frame(height: 14).overlay(Color.white.opacity(0.2))
            Button {
                reader.style.font = reader.style.font == .serif ? .sans : .serif
            } label: {
                Text("Aa").font(reader.style.font == .serif
                                ? Font.system(size: 13, weight: .medium, design: .serif)
                                : Font.system(size: 13, weight: .medium))
            }
            .help(reader.style.font == .serif ? "Use sans-serif" : "Use serif")
            Divider().frame(height: 14).overlay(Color.white.opacity(0.2))
            ForEach(ReaderStyle.Theme.allCases, id: \.self) { theme in
                Button { reader.style.theme = theme } label: { ThemeDot(theme: theme, selected: reader.style.theme == theme) }
                    .help(theme == .auto ? "Match the system" : theme.rawValue.capitalized)
            }
            Divider().frame(height: 14).overlay(Color.white.opacity(0.2))
            Button { reader.toggle() } label: { Image(systemName: "xmark") }
                .help("Close Reader (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .opacity(hovering || awake ? 1 : 0.3)
        .animation(.easeOut(duration: 0.25), value: hovering || awake)
        .onHover { hovering = $0 }
        .padding(.top, (store.chromeExpanded ? 54 : 7) + (find.shown ? 40 : 0))
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.18), value: store.chromeExpanded)
        .task(id: reader.pillWake) {
            awake = true
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { awake = false }
        }
    }
}

private struct ThemeDot: View {
    let theme: ReaderStyle.Theme
    let selected: Bool

    var body: some View {
        ZStack {
            switch theme {
            case .auto:
                Circle().fill(LinearGradient(colors: [.white, Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing))
            case .light: Circle().fill(Color.white)
            case .sepia: Circle().fill(Color(red: 0.97, green: 0.95, blue: 0.89))
            case .dark: Circle().fill(Color(white: 0.11))
            }
            Circle().strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.35), lineWidth: selected ? 2 : 1)
        }
        .frame(width: 15, height: 15)
        .contentShape(Circle())
    }
}
