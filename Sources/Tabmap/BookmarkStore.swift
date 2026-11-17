import AppKit
import SwiftUI
import WebKit
import TabMapCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// Bookmarks, the app side: saving what is in front, keeping a picture, the text and a copy of each page,
// filing with the on-device model, the board, the window hot corner, and checking saved pages for changes.
//
// On disk, in ~/Library/Application Support/Tabmap/bookmarks:
//   library.json   every bookmark
//   snapshots/     one JPEG per bookmark
//   text/          the page's own text when it was saved, for search
//   copies/        a web archive of the page, shown if the page changes or goes away

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    static let hotCornerKey = "bookmarkHotCorner"
    static let watchKey = "bookmarkWatchChanges"

    /// Saved text is cut to this length; it is only used for search.
    private static let maxText = 8000
    /// Copies bigger than this are not kept.
    private static let maxCopyBytes = 25_000_000

    enum HotCorner: String, CaseIterable, Identifiable {
        case off, topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .topLeft: return "Top left"
            case .topRight: return "Top right"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            }
        }
    }

    enum ToastKind: Equatable {
        case saved, rowSaved, highlightAdded, alreadySaved, nothingToSave
    }

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let kind: ToastKind
        let bookmarkID: BookmarkID?
    }

    @Published private(set) var library = BookmarkLibrary()
    @Published private(set) var boardShown = false
    @Published var scope: BoardScope = .all
    @Published var query = ""
    /// The bookmark whose editor is open on the board.
    @Published var editing: BookmarkID?
    /// The bookmark whose saved copy is open on the board.
    @Published var viewingCopy: BookmarkID?
    @Published private(set) var toast: Toast?
    /// Bumped when a bookmark's picture changes, so its card redraws.
    @Published private(set) var snapshotVersions: [BookmarkID: Int] = [:]
    /// Bookmarks the model is filing right now.
    @Published private(set) var filing: Set<BookmarkID> = []

    let filer = BookmarkFiler()

    private let root: URL
    private let libraryURL: URL
    private let snapshotsDir: URL
    private let textDir: URL
    private let copiesDir: URL
    private var texts: [BookmarkID: String] = [:]
    private let images = NSCache<NSString, NSImage>()

    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var checkTimer: Timer?
    private var checking = false
    private var monitors: [Any] = []
    private weak var window: NSWindow?
    private var cornerTask: Task<Void, Never>?
    /// The corner fires once per visit: the pointer has to leave it before it can fire again.
    private var cornerArmed = true

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        root = base.appendingPathComponent("Tabmap/bookmarks", isDirectory: true)
        libraryURL = root.appendingPathComponent("library.json")
        snapshotsDir = root.appendingPathComponent("snapshots", isDirectory: true)
        textDir = root.appendingPathComponent("text", isDirectory: true)
        copiesDir = root.appendingPathComponent("copies", isDirectory: true)
        for dir in [root, snapshotsDir, textDir, copiesDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        images.countLimit = 200
        loadLibrary()
    }

    /// Called once the window exists.
    func start(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        guard monitors.isEmpty else { return }
        addMonitor([.mouseMoved, .leftMouseDragged]) { store, event in
            store.handlePointer(event)
            return event
        }
        addMonitor(.keyDown) { store, event in store.handleKey(event) }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in BookmarkStore.shared.checkForChanges() }
        }
        Task { @MainActor [weak self] in
            // Leave the first minute after launch to the pages being restored.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            self?.checkForChanges()
        }
        fileUnfiled()
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (BookmarkStore, NSEvent) -> NSEvent?) {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return handler(self, event)
        }
        if let monitor { monitors.append(monitor) }
    }

    // MARK: Saving

    static func isSaveable(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private struct PageInfo {
        var title = ""
        var description = ""
        var text = ""
        var selection = ""
    }

    private static let readScript = """
        (function(){
          var m = document.querySelector('meta[name="description"],meta[property="og:description"]');
          var s = ''; try { s = String(window.getSelection() || ''); } catch (e) {}
          var b = document.body ? document.body.innerText : '';
          return { title: document.title || '', description: (m && m.content) || '',
                   text: (b || '').slice(0, 20000), selection: s.slice(0, 4000) };
        })()
        """

    private func readPage(_ webView: WKWebView, then: @escaping @MainActor (PageInfo) -> Void) {
        webView.evaluateJavaScript(Self.readScript) { result, _ in
            let dict = result as? [String: Any] ?? [:]
            var info = PageInfo()
            info.title = dict["title"] as? String ?? ""
            info.description = dict["description"] as? String ?? ""
            info.text = dict["text"] as? String ?? ""
            info.selection = dict["selection"] as? String ?? ""
            Task { @MainActor in then(info) }
        }
    }

    /// ⌘D: saves the page in front with a picture of it. Text selected on the page is saved as a highlight,
    /// and on a page that is already saved, ⌘D with a selection adds the highlight to it.
    func bookmarkFrontPage() {
        let browser = BrowserStore.shared
        guard let webView = browser.frontWebView, let url = webView.url ?? browser.frontURL, Self.isSaveable(url) else {
            showToast(.nothingToSave, nil)
            return
        }
        readPage(webView) { [weak self, weak webView] info in
            guard let self, let webView else { return }
            self.savePage(url: url, info: info, webView: webView)
        }
    }

    private func savePage(url: URL, info: PageInfo, webView: WKWebView) {
        let now = Date()
        let selection = info.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = library.bookmark(forPage: url) {
            if !selection.isEmpty, library.addHighlight(selection, to: existing.id, now: now) {
                scheduleSave()
                showToast(.highlightAdded, existing.id)
            } else {
                showToast(.alreadySaved, existing.id)
            }
            return
        }
        let title = info.title.isEmpty ? (webView.title ?? "") : info.title
        var bookmark = Bookmark(url: url, title: title, now: now)
        if !selection.isEmpty { bookmark.highlights = [Highlight(text: selection, createdAt: now)] }
        library.add(bookmark)
        storeText(info.text, for: bookmark.id)
        capture(webView, for: bookmark.id)
        keepCopy(webView, for: bookmark.id)
        scheduleSave()
        showToast(.saved, bookmark.id)
        file(bookmark.id, input: FilingInput(title: title, url: url, description: info.description, text: info.text))
    }

    /// ⇧⌘B: saves the open pages of the current row as one bookmark, with the row's name.
    /// With `trailID` (the row header's bookmark button) it saves that row instead.
    func bookmarkCurrentRow(_ trailID: TrailID? = nil) {
        let browser = BrowserStore.shared
        let map = browser.map
        let picked = trailID.flatMap { id in map.trails.first { $0.id == id } }
        let pickedTab = picked.flatMap { row in
            row.openTabs.first { $0.id == row.lastActiveTabID }?.id ?? row.openTabs.first?.id
        }
        guard let active = trailID == nil ? map.activeTabID : pickedTab, let location = map.locate(active) else {
            showToast(.nothingToSave, nil)
            return
        }
        let trail = map.trails[location.trail]
        let pages = trail.openTabs.compactMap { tab -> SavedPage? in
            guard let url = tab.url, Self.isSaveable(url) else { return nil }
            return SavedPage(url: url, title: tab.displayTitle)
        }
        guard let first = pages.first else {
            showToast(.nothingToSave, nil)
            return
        }
        // A row of one page is just a page.
        if pages.count == 1, trailID == nil {
            bookmarkFrontPage()
            return
        }
        let now = Date()
        let name = trail.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var bookmark = Bookmark(url: first.url, title: name.isEmpty ? first.title : name, pages: pages, now: now)
        bookmark.summary = trail.summary ?? ""
        library.add(bookmark)
        storeText(pages.map(\.title).joined(separator: "\n"), for: bookmark.id)
        if let webView = browser.page(for: active)?.webView, webView.window != nil {
            capture(webView, for: bookmark.id)
        } else if let image = browser.snapshot(for: active) {
            saveImage(image, for: bookmark.id)
        }
        scheduleSave()
        showToast(.rowSaved, bookmark.id)
        file(bookmark.id, input: FilingInput(title: bookmark.title, url: first.url, description: bookmark.summary,
                                             pageTitles: pages.map(\.title)))
    }

    // MARK: Pictures, text and copies

    private func capture(_ webView: WKWebView, for id: BookmarkID) {
        guard webView.window != nil, webView.bounds.width > 10 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 640)
        webView.takeSnapshot(with: config) { image, _ in
            guard let image else { return }
            Task { @MainActor in BookmarkStore.shared.saveImage(image, for: id) }
        }
    }

    func saveImage(_ image: NSImage, for id: BookmarkID) {
        guard library.bookmark(id) != nil else { return }
        images.setObject(image, forKey: id.uuidString as NSString)
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
            try? jpeg.write(to: snapshotURL(id), options: .atomic)
        }
        let colors = Self.colorWords(image)
        library.update(id) { $0.colors = colors }
        snapshotVersions[id, default: 0] += 1
        scheduleSave()
    }

    func image(for id: BookmarkID) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: snapshotURL(id)) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// Colour words for search ("blue", "dark"), read from a small copy of the picture.
    static func colorWords(_ image: NSImage) -> [String] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let width = 32, height = 20
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        var pixels: [(r: Double, g: Double, b: Double)] = []
        pixels.reserveCapacity(width * height)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            pixels.append((r: Double(bytes[i]) / 255, g: Double(bytes[i + 1]) / 255, b: Double(bytes[i + 2]) / 255))
        }
        return ColorWords.words(forPixels: pixels)
    }

    private func storeText(_ text: String, for id: BookmarkID) {
        let clipped = String(text.prefix(Self.maxText))
        guard !clipped.isEmpty else { return }
        texts[id] = clipped
        try? clipped.write(to: textURL(id), atomically: true, encoding: .utf8)
    }

    private func keepCopy(_ webView: WKWebView, for id: BookmarkID) {
        let limit = Self.maxCopyBytes
        webView.createWebArchiveData { result in
            guard case .success(let data) = result, !data.isEmpty, data.count <= limit else { return }
            Task { @MainActor in BookmarkStore.shared.storeCopy(data, for: id) }
        }
    }

    private func storeCopy(_ data: Data, for id: BookmarkID) {
        guard library.bookmark(id) != nil else { return }
        do {
            try data.write(to: copyURL(id), options: .atomic)
            library.update(id) { $0.hasCopy = true }
            scheduleSave()
        } catch {}
    }

    func savedCopy(_ id: BookmarkID) -> Data? {
        try? Data(contentsOf: copyURL(id))
    }

    private func snapshotURL(_ id: BookmarkID) -> URL { snapshotsDir.appendingPathComponent(id.uuidString + ".jpg") }
    private func textURL(_ id: BookmarkID) -> URL { textDir.appendingPathComponent(id.uuidString + ".txt") }
    private func copyURL(_ id: BookmarkID) -> URL { copiesDir.appendingPathComponent(id.uuidString + ".webarchive") }

    // MARK: Filing

    /// Collections offered to the model and in menus: the ones in use, then the standard ones.
    func collectionChoices() -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for name in library.collections().map(\.name) + BookmarkFiling.standardCollections
        where name != BookmarkFiling.unsorted && !seen.contains(name.lowercased()) {
            seen.insert(name.lowercased())
            names.append(name)
        }
        return Array(names.prefix(30))
    }

    private func file(_ id: BookmarkID, input: FilingInput) {
        filing.insert(id)
        let choices = collectionChoices()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.filer.file(input, collections: choices)
            self.filing.remove(id)
            self.library.update(id) { b in
                if !b.filedByHand {
                    b.collection = result.collection
                    b.tags = result.tags
                }
                // A saved row keeps the description its row already had.
                if !(b.isRow && !b.summary.isEmpty) { b.summary = result.summary }
                b.filed = true
            }
            self.scheduleSave()
        }
    }

    private func input(for b: Bookmark) -> FilingInput {
        FilingInput(title: b.title, url: b.url, description: b.isRow ? b.summary : "",
                    text: b.isRow ? "" : (texts[b.id] ?? ""), pageTitles: b.pages.map(\.title))
    }

    /// Files a bookmark again from scratch, replacing a collection or tags chosen by hand.
    func refile(_ id: BookmarkID) {
        guard let b = library.bookmark(id) else { return }
        library.update(id) { $0.filedByHand = false }
        file(id, input: input(for: b))
    }

    /// Bookmarks saved while the app quit before filing finished.
    private func fileUnfiled() {
        for b in library.bookmarks where !b.filed && !filing.contains(b.id) {
            file(b.id, input: input(for: b))
        }
    }

    // MARK: Editing

    func setCollection(_ name: String, for id: BookmarkID) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        library.update(id) { b in
            b.collection = clean
            b.filedByHand = true
            b.filed = true
        }
        scheduleSave()
    }

    func applyEdit(_ id: BookmarkID, title: String, collection: String, tags: String, note: String) {
        guard let old = library.bookmark(id) else { return }
        let cleanCollection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTags = BookmarkFilingText.cleanTags(tags)
        library.update(id) { b in
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty { b.title = trimmedTitle }
            if cleanCollection != old.collection || cleanTags != old.tags {
                b.collection = cleanCollection
                b.tags = cleanTags
                b.filedByHand = true
                b.filed = true
            }
            b.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        scheduleSave()
    }

    func renameCollection(_ old: String, to new: String) {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != old else { return }
        for b in library.bookmarks where b.collection == old {
            library.update(b.id) { $0.collection = clean }
        }
        if scope == .collection(old) { scope = .collection(clean) }
        scheduleSave()
    }

    func removeHighlight(_ highlightID: UUID, from id: BookmarkID) {
        library.update(id) { $0.highlights.removeAll { $0.id == highlightID } }
        scheduleSave()
    }

    func remove(_ id: BookmarkID) {
        guard library.remove(id) != nil else { return }
        texts[id] = nil
        images.removeObject(forKey: id.uuidString as NSString)
        snapshotVersions[id] = nil
        for url in [snapshotURL(id), textURL(id), copyURL(id)] { try? FileManager.default.removeItem(at: url) }
        if editing == id { editing = nil }
        if viewingCopy == id { viewingCopy = nil }
        scheduleSave()
    }

    /// A card dropped on a collection in the board's sidebar.
    func receiveDrop(_ providers: [NSItemProvider], into collection: String) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let id = UUID(uuidString: text as String) else { return }
            Task { @MainActor in BookmarkStore.shared.setCollection(collection, for: id) }
        }
        return true
    }

    // MARK: Opening

    /// A click on a card. A page that is gone from the web opens its saved copy.
    func activate(_ b: Bookmark) {
        if b.isGone, b.hasCopy {
            viewingCopy = b.id
        } else {
            open(b)
        }
    }

    func open(_ b: Bookmark) {
        library.markOpened(b.id, now: Date())
        scheduleSave()
        hideBoard()
        let browser = BrowserStore.shared
        if b.isRow {
            browser.openTrail(b.pages.map(\.url))
            return
        }
        // Go to the page if it is already in the map, open tabs first.
        let key = BookmarkKey.key(b.url)
        let matches = browser.map.allTabs.filter { $0.url.map(BookmarkKey.key) == key }
        if let tab = matches.first(where: { !$0.isClosed }) ?? matches.first {
            browser.choose(tab.id)
        } else {
            browser.openTrail([b.url])
        }
    }

    /// Opens the page scrolled to a saved passage.
    func openHighlight(_ highlight: Highlight, of b: Bookmark) {
        library.markOpened(b.id, now: Date())
        scheduleSave()
        hideBoard()
        BrowserStore.shared.openTrail([TextFragment.url(b.url, highlighting: highlight.text)])
    }

    // MARK: The board

    /// ⌘B, the hot corner.
    func toggleBoard() {
        boardShown ? hideBoard() : showBoard()
    }

    func showBoard() {
        guard !boardShown else { return }
        query = ""
        toast = nil
        boardShown = true
    }

    func hideBoard() {
        guard boardShown else { return }
        boardShown = false
        editing = nil
        viewingCopy = nil
        BrowserStore.shared.focusPage()
    }

    /// The cards to show: the chosen view, or search results from every bookmark.
    func visibleBookmarks() -> [Bookmark] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return library.bookmarks(in: scope, now: Date()) }
        return BookmarkSearch.rank(library.bookmarks(in: .all, now: Date()), query: trimmed, texts: texts)
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard boardShown, event.keyCode == 53 else { return event } // escape
        if viewingCopy != nil {
            viewingCopy = nil
        } else if editing != nil {
            editing = nil
        } else if !query.isEmpty {
            query = ""
        } else {
            hideBoard()
        }
        return nil
    }

    // MARK: Hot corner

    var hotCorner: HotCorner {
        HotCorner(rawValue: UserDefaults.standard.string(forKey: Self.hotCornerKey) ?? "") ?? .off
    }

    private func handlePointer(_ event: NSEvent) {
        let corner = hotCorner
        guard corner != .off, let window, event.window === window else { return }
        guard Self.isInCorner(NSEvent.mouseLocation, frame: window.frame, corner: corner) else {
            cornerArmed = true
            cornerTask?.cancel()
            cornerTask = nil
            return
        }
        guard cornerArmed, cornerTask == nil else { return }
        // A short rest in the corner, so passing through it on the way somewhere does nothing.
        cornerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cornerTask = nil
            guard let window = self.window,
                  Self.isInCorner(NSEvent.mouseLocation, frame: window.frame, corner: self.hotCorner) else { return }
            self.cornerArmed = false
            self.toggleBoard()
        }
    }

    static func isInCorner(_ point: NSPoint, frame: NSRect, corner: HotCorner) -> Bool {
        let reach: CGFloat = 6
        guard frame.insetBy(dx: -2, dy: -2).contains(point) else { return false }
        let left = point.x <= frame.minX + reach, right = point.x >= frame.maxX - reach
        let bottom = point.y <= frame.minY + reach, top = point.y >= frame.maxY - reach
        switch corner {
        case .off: return false
        case .topLeft: return top && left
        case .topRight: return top && right
        case .bottomLeft: return bottom && left
        case .bottomRight: return bottom && right
        }
    }

    // MARK: Changes and dead links

    var watching: Bool {
        UserDefaults.standard.object(forKey: Self.watchKey) as? Bool ?? true
    }

    /// Looks at a few saved pages again, each at most once a day.
    func checkForChanges() {
        guard watching, !checking else { return }
        let due = library.dueForCheck(now: Date(), every: 24 * 3600, limit: 8)
        guard !due.isEmpty else { return }
        checking = true
        Task { @MainActor [weak self] in
            for b in due {
                let result = await PageChecker.check(b.url)
                guard let self else { return }
                self.library.recordCheck(b.id, result: result, now: Date())
            }
            self?.checking = false
            self?.scheduleSave()
        }
    }

    // MARK: Toasts

    private func showToast(_ kind: ToastKind, _ id: BookmarkID?) {
        toast = Toast(kind: kind, bookmarkID: id)
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() { toast = nil }

    /// Undo on the note after saving: the bookmark is removed again.
    func undoToast() {
        if let current = toast, let id = current.bookmarkID, current.kind == .saved || current.kind == .rowSaved {
            remove(id)
        }
        toast = nil
    }

    func editFromToast() {
        guard let id = toast?.bookmarkID else { return }
        toast = nil
        showBoard()
        editing = id
    }

    // MARK: Disk

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        do {
            library = try JSONDecoder().decode(BookmarkLibrary.self, from: data)
        } catch {
            // Keep an unreadable file instead of overwriting it.
            let backup = root.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: libraryURL, to: backup)
            return
        }
        for b in library.bookmarks {
            if let text = try? String(contentsOf: textURL(b.id), encoding: .utf8) { texts[b.id] = text }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(library) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }

    // MARK: Tabs picked in the map

    /// Saves tabs picked together in the map (MapSelection.swift) as one bookmark. Tabs all from one named row
    /// take the row's name; otherwise the first page's title.
    func bookmarkTabs(_ ids: [TabID]) {
        let browser = BrowserStore.shared
        let map = browser.map
        let tabs = ids.compactMap { map.tab($0) }
        let pages = tabs.compactMap { tab -> SavedPage? in
            guard let url = tab.url, Self.isSaveable(url) else { return nil }
            return SavedPage(url: url, title: tab.displayTitle)
        }
        guard let first = pages.first, let firstID = tabs.first(where: { Self.isSaveable($0.url) })?.id else {
            showToast(.nothingToSave, nil)
            return
        }
        let now = Date()
        let rows = Set(ids.compactMap { map.locate($0)?.trail })
        let row = rows.count == 1 ? rows.first.map { map.trails[$0] } : nil
        let name = row?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title: String
        if pages.count == 1 {
            title = first.title
        } else if !name.isEmpty {
            title = name
        } else {
            title = "\(first.title) and \(pages.count - 1) more"
        }
        var bookmark = pages.count == 1 ? Bookmark(url: first.url, title: title, now: now)
                                        : Bookmark(url: first.url, title: title, pages: pages, now: now)
        bookmark.summary = row?.summary ?? ""
        library.add(bookmark)
        storeText(pages.map(\.title).joined(separator: "\n"), for: bookmark.id)
        if let webView = browser.page(for: firstID)?.webView, webView.window != nil {
            capture(webView, for: bookmark.id)
        } else if let image = browser.snapshot(for: firstID) {
            saveImage(image, for: bookmark.id)
        }
        scheduleSave()
        showToast(pages.count == 1 ? .saved : .rowSaved, bookmark.id)
        file(bookmark.id, input: FilingInput(title: bookmark.title, url: first.url, description: bookmark.summary,
                                             pageTitles: pages.map(\.title)))
    }
}

// MARK: Filing with the on-device model

/// Files a bookmark: a collection, a few tags and one sentence. Uses Apple's on-device model
/// (macOS 26 with Apple Intelligence) when it is there, and the site and words otherwise. Nothing leaves the Mac.
@MainActor
final class BookmarkFiler {
    var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    func file(_ input: FilingInput, collections: [String]) async -> Filing {
        let fallback = BookmarkFiling.file(input)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           let reply = await askModel(instructions: BookmarkFilingText.instructions(collections: collections),
                                      prompt: BookmarkFilingText.prompt(for: input)),
           let parsed = BookmarkFilingText.parse(reply, known: collections) {
            return Filing(collection: parsed.collection ?? fallback.collection,
                          tags: parsed.tags.isEmpty ? fallback.tags : parsed.tags,
                          summary: parsed.summary ?? fallback.summary)
        }
        #endif
        return fallback
    }

    #if canImport(FoundationModels)
    /// One fresh session per bookmark. Nil on any failure or refusal.
    @available(macOS 26.0, *)
    private func askModel(instructions: String, prompt: String) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 120)
        do {
            let response = try await session.respond(to: prompt, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
    #endif
}

// MARK: Looking at a saved page again

/// Fetches a saved page without cookies and reports whether it is still there and what its text looks like.
@MainActor
enum PageChecker {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                + "Version/\(WebTab.safariVersion) Safari/605.1.15",
        ]
        return URLSession(configuration: config)
    }()

    static func check(_ url: URL) async -> PageCheck {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .unreachable }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            if http.statusCode == 404 || http.statusCode == 410 { return .missing }
            guard (200..<300).contains(http.statusCode) else { return .unreachable }
            let html = String(decoding: data.prefix(1_500_000), as: UTF8.self)
            let sketch = await Task.detached(priority: .utility) { PageSketch.sketch(ofHTML: html) }.value
            return .found(sketch)
        } catch let error as URLError {
            return error.code == .cannotFindHost ? .missing : .unreachable
        } catch {
            return .unreachable
        }
    }
}
