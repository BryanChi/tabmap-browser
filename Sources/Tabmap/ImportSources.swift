import AppKit
import SQLite3
import TabMapCore

/// A browser profile on this Mac that Tabmap can bring things in from.
struct ImportSource: Identifiable, Hashable, Sendable {
    enum Browser: String, CaseIterable {
        case chrome = "Google Chrome", arc = "Arc", brave = "Brave", edge = "Microsoft Edge"
        case vivaldi = "Vivaldi", chromium = "Chromium", safari = "Safari"

        /// Folder under ~/Library/Application Support holding the profiles.
        var supportPath: String? {
            switch self {
            case .chrome: return "Google/Chrome"
            case .arc: return "Arc/User Data"
            case .brave: return "BraveSoftware/Brave-Browser"
            case .edge: return "Microsoft Edge"
            case .vivaldi: return "Vivaldi"
            case .chromium: return "Chromium"
            case .safari: return nil
            }
        }

        var bundleID: String {
            switch self {
            case .chrome: return "com.google.Chrome"
            case .arc: return "company.thebrowser.Browser"
            case .brave: return "com.brave.Browser"
            case .edge: return "com.microsoft.edgemac"
            case .vivaldi: return "com.vivaldi.Vivaldi"
            case .chromium: return "org.chromium.Chromium"
            case .safari: return "com.apple.Safari"
            }
        }

        /// The browser's own page for exporting passwords, where it has one that can be opened from outside.
        var passwordExportHelp: String {
            switch self {
            case .safari:
                return "In the Passwords app choose File > Export All Passwords, or in Safari choose File > Export Browsing Data and include passwords."
            case .arc, .chrome, .brave, .edge, .vivaldi, .chromium:
                return "In \(rawValue), open Settings > Passwords (or Password Manager > Settings) and choose Export passwords."
            }
        }

        var icon: NSImage? {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    let browser: Browser
    /// The profile's display name ("Person 1", "Work"); empty for Safari.
    let profile: String
    /// The profile folder.
    let folder: URL
    /// Safari only: false until Tabmap has Full Disk Access.
    let readable: Bool

    var id: String { browser.rawValue + "|" + folder.path }

    var title: String {
        profile.isEmpty ? browser.rawValue : "\(browser.rawValue) · \(profile)"
    }

    var hasBookmarks: Bool {
        let name = browser == .safari ? "Bookmarks.plist" : "Bookmarks"
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    var hasHistory: Bool {
        let name = browser == .safari ? "History.db" : "History"
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }
}

/// Finds browsers and reads their files. Everything here is safe to run off the main thread.
enum ImportReader {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func detectSources() -> [ImportSource] {
        var found: [ImportSource] = []
        let support = home.appendingPathComponent("Library/Application Support")
        for browser in ImportSource.Browser.allCases {
            guard let path = browser.supportPath else { continue }
            found += chromiumProfiles(browser, root: support.appendingPathComponent(path))
        }
        let safari = home.appendingPathComponent("Library/Safari")
        if FileManager.default.fileExists(atPath: safari.path) || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") != nil {
            found.append(ImportSource(browser: .safari, profile: "", folder: safari, readable: safariReadable()))
        }
        return found
    }

    /// Safari's files are behind Full Disk Access; reading one is the only honest check.
    static func safariReadable() -> Bool {
        let file = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
        return (try? Data(contentsOf: file, options: .mappedIfSafe)) != nil
    }

    static func chromiumProfiles(_ browser: ImportSource.Browser, root: URL) -> [ImportSource] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, info) in cache {
                names[dir] = (info as? [String: Any])?["name"] as? String ?? dir
            }
        }
        let dirs = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return dirs.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { $0 == "Default" ? true : $1 == "Default" ? false : $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { dir in
                let folder = root.appendingPathComponent(dir)
                let source = ImportSource(browser: browser, profile: names[dir] ?? (dir == "Default" ? "" : dir),
                                          folder: folder, readable: true)
                return source.hasBookmarks || source.hasHistory ? source : nil
            }
    }

    // MARK: Reading a browser's own files

    static func bookmarks(from source: ImportSource) throws -> [ImportedBookmark] {
        if source.browser == .safari {
            return try SafariBookmarks.parse(Data(contentsOf: source.folder.appendingPathComponent("Bookmarks.plist")))
        }
        return try ChromiumBookmarks.parse(Data(contentsOf: source.folder.appendingPathComponent("Bookmarks")))
    }

    static let historyLimit = 20_000

    static func history(from source: ImportSource) throws -> [ImportedVisit] {
        if source.browser == .safari {
            let sql = """
                SELECT i.url, v.title, i.visit_count, 0, MAX(v.visit_time)
                FROM history_items i JOIN history_visits v ON v.history_item = i.id
                GROUP BY i.id ORDER BY MAX(v.visit_time) DESC LIMIT \(historyLimit)
                """
            return try query(source.folder.appendingPathComponent("History.db"), sql) { SafariTime.date($0) }
        }
        let sql = """
            SELECT url, title, visit_count, typed_count, last_visit_time FROM urls
            WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT \(historyLimit)
            """
        return try query(source.folder.appendingPathComponent("History"), sql) { ChromiumTime.date(Int64($0)) }
    }

    /// Reads a copy of the database: the browser keeps the real one locked while it runs.
    private static func query(_ file: URL, _ sql: String, time: (Double) -> Date?) throws -> [ImportedVisit] {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("tabmap-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let copy = temp.appendingPathComponent(file.lastPathComponent)
        try fm.copyItem(at: file, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: file.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw BrowserImportError.unreadable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw BrowserImportError.unreadable }
        defer { sqlite3_finalize(statement) }

        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(statement, i) else { return "" }
            return String(cString: c)
        }
        var out: [ImportedVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = URL(string: text(0)), BrowserImport.isImportable(url),
                  let when = time(sqlite3_column_double(statement, 4)) else { continue }
            out.append(ImportedVisit(url: url, title: text(1), visitCount: Int(sqlite3_column_int64(statement, 2)),
                                     typedCount: Int(sqlite3_column_int64(statement, 3)), lastVisit: when))
        }
        return out
    }

    // MARK: Reading exported files

    struct Exported: Sendable {
        var bookmarks: [ImportedBookmark] = []
        var visits: [ImportedVisit] = []
        var logins: [ImportedLogin] = []
        var skippedLogins = 0
        /// Password files read, so they can be moved to the Trash afterwards.
        var passwordFiles: [URL] = []
        var unreadable: [String] = []
    }

    /// A file or folder the person picked: Safari's export (a .zip or its unzipped folder), a bookmarks .html,
    /// a passwords .csv, a History.json or a Chromium Bookmarks file.
    static func readExported(_ urls: [URL]) -> Exported {
        var result = Exported()
        let fm = FileManager.default
        var temps: [URL] = []
        defer { temps.forEach { try? fm.removeItem(at: $0) } }

        var files: [URL] = []
        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                let temp = fm.temporaryDirectory.appendingPathComponent("tabmap-import-\(UUID().uuidString)", isDirectory: true)
                temps.append(temp)
                guard unzip(url, to: temp) else {
                    result.unreadable.append(url.lastPathComponent)
                    continue
                }
                files += allFiles(in: temp)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += allFiles(in: url)
            } else {
                files.append(url)
            }
        }

        for file in files {
            let name = file.lastPathComponent.lowercased()
            let ext = file.pathExtension.lowercased()
            if name.hasPrefix(".") || name.hasPrefix("__macosx") { continue }
            if ext == "csv" {
                guard let text = readText(file) else { result.unreadable.append(file.lastPathComponent); continue }
                let parsed = PasswordCSV.parse(text)
                if parsed.logins.isEmpty && parsed.skipped == 0 { continue }
                result.logins += parsed.logins
                result.skippedLogins += parsed.skipped
                // Only a file read from the person's own folders is worth trashing; zip contents are temporary.
                if !temps.contains(where: { file.path.hasPrefix($0.path) }) { result.passwordFiles.append(file) }
            } else if ext == "html" || ext == "htm" {
                guard let text = readText(file) else { result.unreadable.append(file.lastPathComponent); continue }
                result.bookmarks += NetscapeBookmarks.parse(text)
            } else if ext == "json", name.contains("history") {
                if let data = try? Data(contentsOf: file), let visits = try? SafariHistoryExport.parse(data) {
                    result.visits += visits
                } else {
                    result.unreadable.append(file.lastPathComponent)
                }
            } else if name == "bookmarks.plist" {
                if let data = try? Data(contentsOf: file), let list = try? SafariBookmarks.parse(data) { result.bookmarks += list }
            } else if name == "bookmarks", ext.isEmpty {
                if let data = try? Data(contentsOf: file), let list = try? ChromiumBookmarks.parse(data) { result.bookmarks += list }
            }
        }
        return result
    }

    private static func allFiles(in folder: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var out: [URL] = []
        while let url = e?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(url) }
        }
        return out
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func unzip(_ zip: URL, to folder: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
