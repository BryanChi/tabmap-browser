import AppKit
import TabMapCore
import UniformTypeIdentifiers

/// Brings bookmarks, history and passwords in from Chrome, Safari and other browsers.
///
/// Chromium browsers (Chrome, Arc, Brave, Edge, Vivaldi) are read straight from their profile folders.
/// Safari's folder needs Full Disk Access; without it, Safari's own File > Export Browsing Data file works.
/// Passwords only come from export files (CSV): Tabmap never reads another browser's encrypted password store.
@MainActor
final class BrowserImporter: ObservableObject {
    static let shared = BrowserImporter()

    /// Set once the first-launch offer has been shown.
    static let offeredKey = "importOffered"

    enum Phase: Equatable {
        case choosing
        case importing
        case done
    }

    struct Summary {
        var bookmarksAdded = 0
        var bookmarksSkipped = 0
        var historyAdded = 0
        var historyRead = 0
        var passwords = PasswordImport.Result()
        var passwordsSkipped = 0
        var problems: [String] = []
        /// CSV files with passwords in plain text, offered for the Trash.
        var passwordFiles: [URL] = []
        var trashed = false
    }

    @Published private(set) var shown = false
    @Published private(set) var phase = Phase.choosing
    @Published private(set) var sources: [ImportSource] = []
    @Published var selected: Set<String> = []
    @Published var takeBookmarks = true
    @Published var takeHistory = true
    @Published private(set) var summary = Summary()

    private init() {}

    // MARK: Showing

    /// On first launch, once: offered only when another browser is on this Mac.
    func offerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.offeredKey) else { return }
        defaults.set(true, forKey: Self.offeredKey)
        refreshSources()
        guard !sources.isEmpty else { return }
        // Let the window settle first.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.show()
        }
    }

    func show() {
        refreshSources()
        summary = Summary()
        phase = .choosing
        shown = true
    }

    func hide() {
        guard phase != .importing else { return }
        shown = false
    }

    func refreshSources() {
        let found = ImportReader.detectSources()
        let firstShow = sources.isEmpty
        sources = found
        if firstShow || selected.isEmpty {
            // Preselect the default profile of each browser that can be read.
            var picked = Set<String>()
            var browsers = Set<ImportSource.Browser>()
            for s in found where s.readable && !browsers.contains(s.browser) {
                browsers.insert(s.browser)
                picked.insert(s.id)
            }
            selected = picked
        } else {
            selected = selected.intersection(found.filter(\.readable).map(\.id))
        }
    }

    func toggle(_ source: ImportSource) {
        guard source.readable else { return }
        if selected.contains(source.id) { selected.remove(source.id) } else { selected.insert(source.id) }
    }

    var canImport: Bool { !selected.isEmpty && (takeBookmarks || takeHistory) }

    // MARK: Importing from browsers on this Mac

    func importSelected() {
        let chosen = sources.filter { selected.contains($0.id) && $0.readable }
        let bookmarks = takeBookmarks, history = takeHistory
        run {
            var out = ImportReader.Exported()
            for source in chosen {
                if bookmarks, source.hasBookmarks {
                    do { out.bookmarks += try ImportReader.bookmarks(from: source) }
                    catch { out.unreadable.append("\(source.title) bookmarks") }
                }
                if history, source.hasHistory {
                    do { out.visits += try ImportReader.history(from: source) }
                    catch { out.unreadable.append("\(source.title) history") }
                }
            }
            return out
        }
    }

    // MARK: Importing exported files

    /// Safari's export (.zip or folder), bookmark .html files, password .csv files, History.json.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Exported Browser Data"
        panel.message = "Choose Safari's exported .zip or folder, a bookmarks .html file, or a passwords .csv file."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.zip, .html, .commaSeparatedText, .json, .folder]
        if let plist = UTType(filenameExtension: "plist") { types.append(plist) }
        panel.allowedContentTypes = types
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        if !shown { shown = true }
        run { ImportReader.readExported(urls) }
    }

    /// Reading happens off the main thread; adding to Tabmap's stores happens on it.
    private func run(_ read: @escaping @Sendable () -> ImportReader.Exported) {
        phase = .importing
        Task.detached(priority: .userInitiated) {
            let data = read()
            await MainActor.run { BrowserImporter.shared.apply(data) }
        }
    }

    private func apply(_ data: ImportReader.Exported) {
        var s = Summary()
        s.problems = data.unreadable
        if !data.bookmarks.isEmpty {
            let result = BookmarkStore.shared.importBookmarks(BrowserImport.uniqueBookmarks(data.bookmarks))
            s.bookmarksAdded = result.added
            s.bookmarksSkipped = result.skipped
        }
        if !data.visits.isEmpty {
            s.historyRead = data.visits.count
            s.historyAdded = VisitStore.shared.merge(data.visits)
        }
        if !data.logins.isEmpty {
            s.passwords = PasswordImport.save(data.logins)
        }
        s.passwordsSkipped = data.skippedLogins
        s.passwordFiles = data.passwordFiles
        summary = s
        phase = .done
    }

    /// Exported password files hold every password in plain text; they should not stay in Downloads.
    func trashPasswordFiles() {
        var all = true
        for file in summary.passwordFiles {
            do { try FileManager.default.trashItem(at: file, resultingItemURL: nil) } catch { all = false }
        }
        summary.trashed = all
        if !all { summary.problems.append("Could not move the password file to the Trash") }
    }

    // MARK: Help

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the browser so the person can export from it.
    func openBrowser(_ browser: ImportSource.Browser) {
        if browser == .safari,
           let passwords = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.openApplication(at: passwords, configuration: .init())
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }
}
