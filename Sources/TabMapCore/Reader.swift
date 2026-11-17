import Foundation

/// An article pulled out of a page for reader mode. `contentHTML` is the cleaned body that the
/// extractor script returns; it is shown in a web view with scripts turned off.
public struct ReaderArticle: Equatable, Sendable {
    public var title: String
    public var byline: String?
    public var siteName: String?
    public var contentHTML: String
    public var url: URL?
    /// Words in the article text, used for the reading time.
    public var wordCount: Int

    public init(title: String, byline: String? = nil, siteName: String? = nil,
                contentHTML: String, url: URL? = nil, wordCount: Int) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.contentHTML = contentHTML
        self.url = url
        self.wordCount = wordCount
    }

    /// Builds an article from the extractor's reply. Nil when the page has no article in it.
    public init?(reply: [String: Any], url: URL?) {
        guard let content = reply["content"] as? String,
              let words = (reply["words"] as? NSNumber)?.intValue,
              words >= ReaderArticle.minimumWords else { return nil }
        func text(_ key: String) -> String? {
            let value = (reply[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        self.init(title: text("title") ?? url?.host ?? "Article",
                  byline: text("byline"), siteName: text("siteName"),
                  contentHTML: content, url: url, wordCount: words)
    }

    /// Fewer words than this is not worth a reader view (a search page, a login form).
    public static let minimumWords = 150

    /// Whole minutes at 230 words a minute, at least one.
    public var readingMinutes: Int { max(1, Int((Double(wordCount) / 230).rounded())) }
}

/// How the reader view looks. Kept in UserDefaults as one string per setting.
public struct ReaderStyle: Equatable, Sendable {
    public enum Theme: String, CaseIterable, Sendable {
        /// Follows the system appearance.
        case auto, light, sepia, dark
    }

    public enum Font: String, CaseIterable, Sendable {
        case serif, sans
    }

    public var theme: Theme
    public var font: Font
    /// Index into `ReaderStyle.sizes`.
    public var sizeStep: Int

    /// Body text sizes in points; the default is the middle one.
    public static let sizes: [Int] = [14, 16, 18, 20, 22, 25, 28, 32]
    public static let defaultSizeStep = 2

    public init(theme: Theme = .auto, font: Font = .serif, sizeStep: Int = ReaderStyle.defaultSizeStep) {
        self.theme = theme
        self.font = font
        self.sizeStep = ReaderStyle.clampStep(sizeStep)
    }

    public var fontSize: Int { ReaderStyle.sizes[ReaderStyle.clampStep(sizeStep)] }
    public var canGrow: Bool { sizeStep < ReaderStyle.sizes.count - 1 }
    public var canShrink: Bool { sizeStep > 0 }

    public mutating func grow() { sizeStep = ReaderStyle.clampStep(sizeStep + 1) }
    public mutating func shrink() { sizeStep = ReaderStyle.clampStep(sizeStep - 1) }

    static func clampStep(_ step: Int) -> Int { min(max(step, 0), sizes.count - 1) }
}

/// Builds the HTML page for the reader view.
public enum ReaderDocument {
    /// The page's own scripts never run in the reader (the web view has JavaScript off), and this
    /// policy also stops it fetching anything but images and media.
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'; font-src data:"

    public static func html(for article: ReaderArticle, style: ReaderStyle) -> String {
        var meta: [String] = []
        if let site = article.siteName ?? article.url?.host.map(trimWWW) { meta.append(escape(site)) }
        if let byline = article.byline { meta.append(escape(byline)) }
        meta.append("\(article.readingMinutes) min read")

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width">
        <title>\(escape(article.title))</title>
        <style>\(styleSheet(style))</style>
        </head><body class="theme-\(style.theme.rawValue)">
        <article>
        <header>
        <p class="meta">\(meta.joined(separator: " · "))</p>
        <h1>\(escape(article.title))</h1>
        </header>
        \(article.contentHTML)
        </article>
        </body></html>
        """
    }

    public static func styleSheet(_ style: ReaderStyle) -> String {
        let family = style.font == .serif
            ? "\"New York\", \"Iowan Old Style\", Charter, Georgia, serif"
            : "-apple-system, \"SF Pro Text\", \"Helvetica Neue\", sans-serif"
        let light = "--bg:#ffffff;--fg:#1d1d1f;--muted:#6e6e73;--link:#0066cc;--rule:#e5e5ea;--code:#f2f2f7;"
        let sepia = "--bg:#f8f1e3;--fg:#4f321c;--muted:#8a6d55;--link:#9c4f1c;--rule:#e6d9c0;--code:#efe5d0;"
        let dark = "--bg:#1c1c1e;--fg:#e5e5e7;--muted:#98989d;--link:#4da3ff;--rule:#3a3a3c;--code:#2c2c2e;"
        return """
        body.theme-auto,body.theme-light{\(light)}
        body.theme-sepia{\(sepia)}
        body.theme-dark{\(dark)}
        @media (prefers-color-scheme: dark){body.theme-auto{\(dark)}}
        html{-webkit-text-size-adjust:none}
        body{margin:0;background:var(--bg);color:var(--fg);font-family:\(family);
          font-size:\(style.fontSize)px;line-height:1.6;-webkit-font-smoothing:antialiased;
          text-rendering:optimizeLegibility}
        article{max-width:38em;margin:0 auto;padding:72px 32px 120px}
        header{margin-bottom:2em}
        .meta{font-family:-apple-system,sans-serif;font-size:13px;letter-spacing:.02em;color:var(--muted);margin:0 0 .6em}
        h1{font-size:1.9em;line-height:1.18;margin:0;font-weight:700}
        h2,h3,h4,h5,h6{line-height:1.3;margin:1.6em 0 .5em}
        h2{font-size:1.4em}h3{font-size:1.2em}h4,h5,h6{font-size:1em}
        p,ul,ol,blockquote,pre,figure,table{margin:0 0 1.1em}
        a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}
        img,video,picture,svg{max-width:100%;height:auto;border-radius:6px}
        figure{margin-left:0;margin-right:0}
        figcaption{font-family:-apple-system,sans-serif;font-size:.75em;color:var(--muted);margin-top:.5em}
        blockquote{border-left:3px solid var(--rule);margin-left:0;padding-left:1em;color:var(--muted)}
        pre,code{font-family:ui-monospace,Menlo,monospace;font-size:.85em;background:var(--code);border-radius:4px}
        code{padding:.1em .3em}pre{padding:.8em 1em;overflow-x:auto}pre code{padding:0;background:none}
        hr{border:0;border-top:1px solid var(--rule);margin:2em 0}
        table{border-collapse:collapse;font-size:.9em;display:block;overflow-x:auto}
        td,th{border:1px solid var(--rule);padding:.35em .6em}
        ::selection{background:rgba(0,122,255,.25)}
        """
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func trimWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
