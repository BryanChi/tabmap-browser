import Foundation

// Reading what other browsers keep: bookmarks, history and exported passwords.
// Pure parsing, no file system access, so it is unit tested. The app finds the files.

/// A bookmark from another browser. `folders` runs from the outermost folder in, without the browser's own roots
/// (Bookmarks Bar, Favorites, Other Bookmarks and the like).
public struct ImportedBookmark: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var folders: [String]
    public var addedAt: Date?

    public init(url: URL, title: String, folders: [String] = [], addedAt: Date? = nil) {
        self.url = url
        self.title = title
        self.folders = folders
        self.addedAt = addedAt
    }

    /// The bookmark board collection it goes in: its outermost folder, or empty to let the board file it.
    public var collection: String {
        folders.first.map { BrowserImport.cleanName($0) } ?? ""
    }

    /// Deeper folders become tags, so "Recipes / Soups / Winter" lands in Recipes tagged soups and winter.
    public var tags: [String] {
        folders.dropFirst().map { BrowserImport.cleanName($0).lowercased() }.filter { !$0.isEmpty }
    }
}

/// One address from another browser's history.
public struct ImportedVisit: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var visitCount: Int
    /// How often it was typed into the address bar (Chrome keeps this; Safari does not).
    public var typedCount: Int
    public var lastVisit: Date

    public init(url: URL, title: String, visitCount: Int, typedCount: Int = 0, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisit = lastVisit
    }
}

/// One saved login from a password export.
public struct ImportedLogin: Equatable, Sendable {
    public var url: URL
    public var username: String
    public var password: String
    public var note: String
    public var title: String

    public init(url: URL, username: String, password: String, note: String = "", title: String = "") {
        self.url = url
        self.username = username
        self.password = password
        self.note = note
        self.title = title
    }

    /// The site the login is for, lowercased.
    public var host: String { (url.host ?? "").lowercased() }
}

public enum BrowserImportError: Error, Equatable {
    case unreadable
}

public enum BrowserImport {
    /// Only pages worth keeping: web addresses. No javascript: bookmarklets, chrome:// pages, file:// paths.
    public static func isImportable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    static func cleanName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Folder names browsers use for their own roots. They are not collections anyone made.
    static let rootFolders: Set<String> = [
        "bookmarks bar", "bookmarks toolbar", "bookmarks menu", "other bookmarks", "mobile bookmarks",
        "favorites", "favourites", "favorites bar", "bookmarksbar", "bookmarksmenu", "bookmarks", "other favorites",
        "synced bookmarks", "unsorted bookmarks", "menu", "toolbar",
    ]

    static func isRoot(_ name: String) -> Bool { rootFolders.contains(cleanName(name).lowercased()) }

    static func url(_ string: String?) -> URL? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let url = URL(string: s) else { return nil }
        return url
    }

    /// Keeps the first of each address, so importing a bookmark twice from two folders keeps one.
    public static func uniqueBookmarks(_ list: [ImportedBookmark]) -> [ImportedBookmark] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.url.absoluteString).inserted }
    }
}

// MARK: Chromium (Chrome, Brave, Edge, Arc, Vivaldi)

/// Chromium counts time in microseconds since 1 January 1601.
public enum ChromiumTime {
    static let offset: Double = 11_644_473_600 // seconds from 1601 to 1970

    public static func date(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - offset)
    }

    public static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + offset) * 1_000_000)
    }
}

/// The `Bookmarks` JSON file in a Chromium profile folder.
public enum ChromiumBookmarks {
    public static func parse(_ data: Data) throws -> [ImportedBookmark] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw BrowserImportError.unreadable }
        var out: [ImportedBookmark] = []
        // Bar first, then Other, then Mobile, then anything newer Chromium adds.
        let order = ["bookmark_bar", "other", "synced"]
        let keys = order.filter { roots[$0] != nil } + roots.keys.filter { !order.contains($0) }.sorted()
        for key in keys {
            guard let node = roots[key] as? [String: Any] else { continue }
            walk(node, folders: [], isRoot: true, into: &out)
        }
        return out
    }

    private static func walk(_ node: [String: Any], folders: [String], isRoot: Bool, into out: inout [ImportedBookmark]) {
        let type = node["type"] as? String
        let name = node["name"] as? String ?? ""
        if type == "url" {
            guard let url = BrowserImport.url(node["url"] as? String), BrowserImport.isImportable(url) else { return }
            let added = (node["date_added"] as? String).flatMap { Int64($0) }.flatMap(ChromiumTime.date)
            out.append(ImportedBookmark(url: url, title: name, folders: folders, addedAt: added))
            return
        }
        guard let children = node["children"] as? [[String: Any]] else { return }
        let path = isRoot || BrowserImport.isRoot(name) || name.isEmpty ? folders : folders + [name]
        for child in children { walk(child, folders: path, isRoot: false, into: &out) }
    }
}

// MARK: Safari

/// `~/Library/Safari/Bookmarks.plist` (readable only with Full Disk Access).
public enum SafariBookmarks {
    public static func parse(_ data: Data) throws -> [ImportedBookmark] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BrowserImportError.unreadable
        }
        var out: [ImportedBookmark] = []
        walk(plist, folders: [], depth: 0, into: &out)
        return out
    }

    private static func walk(_ node: [String: Any], folders: [String], depth: Int, into out: inout [ImportedBookmark]) {
        switch node["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            let dict = node["URIDictionary"] as? [String: Any]
            guard let url = BrowserImport.url(node["URLString"] as? String), BrowserImport.isImportable(url) else { return }
            let title = dict?["title"] as? String ?? ""
            let added = (node["ReadingList"] as? [String: Any])?["DateAdded"] as? Date
            out.append(ImportedBookmark(url: url, title: title, folders: folders, addedAt: added))
        case "WebBookmarkTypeList":
            var title = node["Title"] as? String ?? ""
            if title == "com.apple.ReadingList" { title = "Reading List" }
            if title == "History" { return } // an old placeholder, never bookmarks
            let path = depth == 0 || title.isEmpty || BrowserImport.isRoot(title) ? folders : folders + [title]
            for child in node["Children"] as? [[String: Any]] ?? [] {
                walk(child, folders: path, depth: depth + 1, into: &out)
            }
        default:
            return // proxies (the History and Reading List shortcuts) and anything unknown
        }
    }
}

/// `History.json` from Safari's File > Export Browsing Data.
public enum SafariHistoryExport {
    public static func parse(_ data: Data) throws -> [ImportedVisit] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["history"] as? [[String: Any]] else { throw BrowserImportError.unreadable }
        var byURL: [String: ImportedVisit] = [:]
        var order: [String] = []
        for item in items {
            guard let url = BrowserImport.url(item["url"] as? String), BrowserImport.isImportable(url) else { continue }
            let micro = (item["time_usec"] as? NSNumber)?.int64Value ?? 0
            let when = Date(timeIntervalSince1970: Double(micro) / 1_000_000)
            let count = max(1, (item["visit_count"] as? NSNumber)?.intValue ?? 1)
            let title = item["title"] as? String ?? ""
            let key = url.absoluteString
            if var old = byURL[key] {
                // The file may list each visit: add them up and keep the latest title.
                old.visitCount += (item["visit_count"] == nil ? 1 : 0)
                if when > old.lastVisit {
                    old.lastVisit = when
                    if !title.isEmpty { old.title = title }
                }
                byURL[key] = old
            } else {
                byURL[key] = ImportedVisit(url: url, title: title, visitCount: count, lastVisit: when)
                order.append(key)
            }
        }
        return order.compactMap { byURL[$0] }
    }
}

/// Safari's own history database counts seconds since 1 January 2001.
public enum SafariTime {
    public static func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
}

// MARK: Bookmark HTML (Safari, Chrome, Firefox and Edge all export this)

/// The old Netscape bookmark file: `<DT><H3>Folder</H3><DL>…<DT><A HREF="…">Title</A>…</DL>`.
public enum NetscapeBookmarks {
    public static func parse(_ html: String) -> [ImportedBookmark] {
        var out: [ImportedBookmark] = []
        var stack: [String?] = [] // nil for a list that is not a named folder
        var pendingFolder: String?
        var i = html.startIndex
        while let open = html[i...].firstIndex(of: "<") {
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let tag = html[html.index(after: open)..<close]
            let name = tag.prefix { !$0.isWhitespace && $0 != ">" }.lowercased()
            i = html.index(after: close)
            switch name {
            case "h3", "h1":
                let end = html[i...].range(of: "</" + name, options: .caseInsensitive)?.lowerBound ?? html.endIndex
                let text = decode(String(html[i..<end]))
                // The file's own <H1>Bookmarks</H1> heading is not a folder.
                pendingFolder = name == "h3" ? text : nil
                i = end
            case "dl":
                stack.append(pendingFolder.flatMap { BrowserImport.isRoot($0) ? nil : BrowserImport.cleanName($0) })
                pendingFolder = nil
            case "/dl":
                if !stack.isEmpty { stack.removeLast() }
            case "a":
                let end = html[i...].range(of: "</a", options: .caseInsensitive)?.lowerBound ?? html.endIndex
                let title = decode(String(html[i..<end]))
                i = end
                guard let href = attribute("href", in: String(tag)), let url = BrowserImport.url(decode(href)),
                      BrowserImport.isImportable(url) else { continue }
                let added = attribute("add_date", in: String(tag)).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
                out.append(ImportedBookmark(url: url, title: title, folders: stack.compactMap { $0 }, addedAt: added))
            default:
                break
            }
        }
        return out
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var rest = tag[range.upperBound...]
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            return String(rest.prefix { $0 != quote })
        }
        return String(rest.prefix { !$0.isWhitespace })
    }

    static func decode(_ s: String) -> String {
        var text = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in entities { text = text.replacingOccurrences(of: k, with: v) }
        // Numeric entities, then &amp; last so "&amp;lt;" stays "&lt;".
        while let r = text.range(of: "&#[0-9]{1,6};", options: .regularExpression) {
            let digits = text[r].dropFirst(2).dropLast()
            let scalar = UInt32(digits).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ""
            text.replaceSubrange(r, with: scalar)
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Password exports

/// Password CSV files from Chrome (name,url,username,password,note), Safari and the Passwords app
/// (Title,URL,Username,Password,Notes,OTPAuth), Firefox (url,username,password,…) and most password managers.
public enum PasswordCSV {
    public struct Result: Equatable {
        public var logins: [ImportedLogin]
        /// Rows with no web address or no password, such as Wi-Fi or app passwords.
        public var skipped: Int
    }

    public static func parse(_ text: String) -> Result {
        let rows = CSV.rows(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else {
            return Result(logins: [], skipped: 0)
        }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlCol = column(["url", "website", "login_uri", "web site", "address"]),
              let passCol = column(["password", "login_password"]) else { return Result(logins: [], skipped: rows.count - 1) }
        let userCol = column(["username", "user name", "login", "login_username", "email"])
        let noteCol = column(["note", "notes", "comment", "comments", "extra"])
        let titleCol = column(["name", "title"])

        var logins: [ImportedLogin] = []
        var skipped = 0
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            func value(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            var address = value(urlCol).trimmingCharacters(in: .whitespaces)
            if !address.isEmpty, !address.contains("://") { address = "https://" + address }
            let password = value(passCol)
            guard let url = URL(string: address), BrowserImport.isImportable(url), !password.isEmpty else {
                skipped += 1
                continue
            }
            logins.append(ImportedLogin(url: url, username: value(userCol), password: password,
                                        note: value(noteCol), title: value(titleCol)))
        }
        return Result(logins: logins, skipped: skipped)
    }
}

/// RFC 4180 CSV: quoted fields with "" for a quote, and line breaks inside quotes.
public enum CSV {
    public static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var scalars = Substring(text).unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() } // byte order mark
        var chars = scalars.makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    let after = next()
                    if after == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = after }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty: quoted = true
            case ",": row.append(field); field = ""
            case "\r":
                let after = next()
                if after != "\n" { pending = after }
                row.append(field); rows.append(row); row = []; field = ""
            case "\n": row.append(field); rows.append(row); row = []; field = ""
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
