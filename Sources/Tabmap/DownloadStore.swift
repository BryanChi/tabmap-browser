import AppKit
import SwiftUI
import WebKit
import TabMapCore

// Goes in Sources/Tabmap.

/// Runs downloads and remembers them. Files are saved to ~/Downloads; the list is kept in
/// ~/Library/Application Support/Tabmap/downloads.json and outlives the tabs the files came from.
@MainActor
final class DownloadStore: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadStore()

    @Published private(set) var ledger = DownloadLedger()
    /// Fraction done for each running download, or -1 while the size is unknown.
    @Published private(set) var progress: [DownloadID: Double] = [:]
    /// The download that just finished, shown briefly in the pill.
    @Published private(set) var justFinished: DownloadID?
    @Published var panelShown = false
    /// When set, the panel lists only the files from this tab.
    @Published var panelTab: TabID?
    /// When set, the panel lists only the files from this row.
    @Published var panelTrail: TrailID?

    private struct Live {
        let download: WKDownload
        let id: DownloadID
    }

    private var live: [ObjectIdentifier: Live] = [:]
    private var cancelledByUser: Set<DownloadID> = []
    private var progressTimer: Timer?
    private var saveTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private let fileURL: URL
    /// A picture of the page each file came from, taken when the download started.
    private let picturesDir: URL
    private let pictureCache = NSCache<NSString, NSImage>()
    /// Bumped when a page picture is saved, so open previews redraw.
    @Published private(set) var pictureVersions: [DownloadID: Int] = [:]

    private override init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("Tabmap", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("downloads.json")
        picturesDir = root.appendingPathComponent("download-pages", isDirectory: true)
        try? fm.createDirectory(at: picturesDir, withIntermediateDirectories: true)
        super.init()
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(DownloadLedger.self, from: data) {
            ledger = saved
            ledger.markInterrupted(now: Date())
        }
    }

    // MARK: Starting

    /// True when a response should be saved rather than shown.
    static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            return true
        }
        return !response.canShowMIMEType
    }

    /// Takes over a download that WebKit started in `page`, and credits it to the right tab.
    func adopt(_ download: WKDownload, from page: WebTab) {
        let browser = BrowserStore.shared
        var origin = page.id

        // A link that opens a new window only to hand over a file leaves an empty tab behind.
        // Credit the file to the tab the link was on, and take the empty tab away.
        if page.webView.backForwardList.currentItem == nil,
           let opener = browser.map.tab(page.id)?.openerID,
           browser.map.tab(opener) != nil {
            origin = opener
            let empty = page.id
            Task { @MainActor in browser.discardDownloadOnlyTab(empty, backTo: opener) }
        }
        begin(download, tab: origin)
    }

    /// Starts tracking a download, credited to `tab`. Also used by the page's right-click menu.
    /// `page` names the page for a file that comes from outside the map (a dock app).
    func begin(_ download: WKDownload, tab: TabID?, page: (url: URL?, title: String)? = nil) {
        let browser = BrowserStore.shared
        let source = download.originalRequest?.url
        let mapTab = browser.map.tab(tab)
        let trail = tab.flatMap { browser.map.locate($0) }.map { browser.map.trails[$0.trail].id }
        let name = Self.cleanName(source?.lastPathComponent ?? "")
        let id = ledger.start(filename: name,
                              sourceURL: source,
                              pageURL: mapTab?.url ?? page?.url,
                              pageTitle: mapTab?.displayTitle ?? page?.title ?? "",
                              tabID: mapTab == nil ? nil : tab,
                              trailID: trail,
                              now: Date())
        capturePage(for: id, tab: mapTab == nil ? nil : tab)
        download.delegate = self
        live[ObjectIdentifier(download)] = Live(download: download, id: id)
        progress[id] = -1
        startProgressTimer()
        saveSoon()
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        guard let entry = live[ObjectIdentifier(download)] else { return nil }
        let destination = Self.freeDestination(for: Self.cleanName(suggestedFilename))
        ledger.setDestination(entry.id, path: destination.path, filename: destination.lastPathComponent)
        // By now the tab shows its own page again rather than the address of the file.
        if let tab = ledger.record(entry.id)?.tabID, let mapTab = BrowserStore.shared.map.tab(tab),
           mapTab.url != ledger.record(entry.id)?.sourceURL {
            ledger.setPage(entry.id, url: mapTab.url, title: mapTab.displayTitle)
        }
        saveSoon()
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = live.removeValue(forKey: ObjectIdentifier(download)) else { return }
        progress[entry.id] = nil
        var size: Int64?
        if let record = ledger.record(entry.id), let path = record.filePath {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            size = (attributes?[.size] as? NSNumber)?.int64Value
            // Lets Finder's Get Info show where the file came from, and lets a file lead back to its page.
            let from = [record.sourceURL?.absoluteString, record.pageURL?.absoluteString].compactMap { $0 }
            Self.writeWhereFroms(from, to: URL(fileURLWithPath: path))
        }
        ledger.finish(entry.id, byteCount: size, now: Date())
        flash(entry.id)
        stopProgressTimerIfIdle()
        saveSoon()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = live.removeValue(forKey: ObjectIdentifier(download)) else { return }
        settle(entry.id, cancelled: cancelledByUser.remove(entry.id) != nil)
    }

    private func settle(_ id: DownloadID, cancelled: Bool) {
        progress[id] = nil
        ledger.fail(id, cancelled: cancelled, now: Date())
        stopProgressTimerIfIdle()
        saveSoon()
    }

    // MARK: Progress

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in DownloadStore.shared.pollProgress() }
        }
    }

    private func stopProgressTimerIfIdle() {
        guard live.isEmpty else { return }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func pollProgress() {
        var next = progress
        for entry in live.values {
            let p = entry.download.progress
            next[entry.id] = p.totalUnitCount > 0 ? min(1, max(0, p.fractionCompleted)) : -1
        }
        if next != progress { progress = next }
    }

    private func flash(_ id: DownloadID) {
        justFinished = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.justFinished == id else { return }
            self.justFinished = nil
        }
    }

    // MARK: What the views ask

    func count(forTab tab: TabID) -> Int { ledger.count(forTab: tab) }

    func count(forTrail trail: TrailID) -> Int { ledger.count(forTrail: trail, in: BrowserStore.shared.map) }

    /// Tabs to keep in a map search because a file with a matching name came from them.
    func tabs(matching query: String) -> Set<TabID> { ledger.tabIDs(matching: query) }

    var pillVisible: Bool { ledger.activeCount > 0 || justFinished != nil }

    /// Overall progress of everything running, or nil when some size is unknown.
    var overallProgress: Double? {
        let running = ledger.records.filter { $0.state == .inProgress }.compactMap { progress[$0.id] }
        guard !running.isEmpty, !running.contains(where: { $0 < 0 }) else { return nil }
        return running.reduce(0, +) / Double(running.count)
    }

    func fileExists(_ record: DownloadRecord) -> Bool {
        guard let path = record.filePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: Panel

    func showPanel(forTab tab: TabID? = nil, forTrail trail: TrailID? = nil) {
        panelTab = tab
        panelTrail = tab == nil ? trail : nil
        panelShown = true
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panelShown, event.keyCode == 53 else { return event }
                self.panelShown = false
                return nil
            }
        }
    }

    func togglePanel() {
        if panelShown { panelShown = false } else { showPanel() }
    }

    // MARK: Actions on a file

    func open(_ record: DownloadRecord) {
        guard record.state == .finished, let path = record.filePath, fileExists(record) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealInFinder(_ record: DownloadRecord) {
        guard let path = record.filePath, fileExists(record) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Goes back to the tab a file came from. A closed tab is reopened; if the tab has been
    /// forgotten, its page is opened again in a new row and the file now belongs to that tab.
    func goToSource(_ record: DownloadRecord) {
        let browser = BrowserStore.shared
        panelShown = false
        if let tab = record.tabID, browser.map.tab(tab) != nil {
            browser.choose(tab)
            return
        }
        guard let page = record.pageURL else {
            NSSound.beep()
            return
        }
        browser.newTrail()
        browser.open(page)
        if let fresh = browser.map.activeTabID {
            let trail = browser.map.locate(fresh).map { browser.map.trails[$0.trail].id }
            ledger.retarget(from: record.tabID, record: record.id, to: fresh, trail: trail)
            saveSoon()
        }
    }

    func cancel(_ record: DownloadRecord) {
        guard let entry = live.values.first(where: { $0.id == record.id }) else {
            settle(record.id, cancelled: true)
            return
        }
        cancelledByUser.insert(record.id)
        entry.download.cancel { _ in
            Task { @MainActor in
                let store = DownloadStore.shared
                // If WebKit did not report the failure itself, settle it here.
                if store.live.removeValue(forKey: ObjectIdentifier(entry.download)) != nil {
                    store.cancelledByUser.remove(entry.id)
                    store.settle(entry.id, cancelled: true)
                }
            }
        }
    }

    /// Downloads the file again, credited to the same tab as before.
    func retry(_ record: DownloadRecord) {
        guard let source = record.sourceURL, let webView = BrowserStore.shared.activeWebTab?.webView else {
            NSSound.beep()
            return
        }
        let tab = record.tabID
        ledger.remove(record.id)
        webView.startDownload(using: URLRequest(url: source)) { download in
            Task { @MainActor in DownloadStore.shared.begin(download, tab: tab) }
        }
    }

    /// Takes a file off the list. The file itself stays where it is.
    func remove(_ record: DownloadRecord) {
        if record.state == .inProgress { cancel(record) }
        ledger.remove(record.id)
        forgetPicture(record.id)
        saveSoon()
    }

    func clearInactive() {
        for record in ledger.records where record.state != .inProgress { forgetPicture(record.id) }
        ledger.clearInactive()
        saveSoon()
    }

    // MARK: Page pictures

    /// The picture of the page a file came from, taken when it started downloading.
    func pagePicture(_ id: DownloadID) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = pictureCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: pictureURL(id)) else { return nil }
        pictureCache.setObject(image, forKey: key)
        return image
    }

    private func pictureURL(_ id: DownloadID) -> URL {
        picturesDir.appendingPathComponent(id.uuidString + ".jpg")
    }

    /// Keeps a picture of the page, so the list can show it even after the tab is gone.
    /// Uses the live page when it is on screen, otherwise the tab's last snapshot.
    private func capturePage(for id: DownloadID, tab: TabID?) {
        guard let tab else { return }
        let browser = BrowserStore.shared
        if let page = browser.page(for: tab), page.webView.window != nil, page.webView.bounds.width > 10 {
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: 640)
            page.webView.takeSnapshot(with: config) { image, _ in
                Task { @MainActor in
                    let store = DownloadStore.shared
                    if let image = image ?? browser.snapshot(for: tab) { store.savePicture(image, for: id) }
                }
            }
        } else if let image = browser.snapshot(for: tab) {
            savePicture(image, for: id)
        }
    }

    private func savePicture(_ image: NSImage, for id: DownloadID) {
        guard ledger.record(id) != nil else { return }
        pictureCache.setObject(image, forKey: id.uuidString as NSString)
        pictureVersions[id, default: 0] += 1
        let url = pictureURL(id)
        Task.detached(priority: .utility) {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
            else { return }
            try? jpeg.write(to: url, options: .atomic)
        }
    }

    private func forgetPicture(_ id: DownloadID) {
        pictureCache.removeObject(forKey: id.uuidString as NSString)
        pictureVersions[id] = nil
        try? FileManager.default.removeItem(at: pictureURL(id))
    }

    // MARK: From a file back to its page

    /// A file was dropped on Tabmap's Dock icon (or opened with Tabmap): go to the page it came from.
    /// Works for Tabmap's own downloads, and for files from other browsers that recorded their origin.
    @discardableResult
    func goToSource(ofFile file: URL) -> Bool {
        let path = file.standardizedFileURL.path
        if let record = ledger.record(atPath: path) {
            goToSource(record)
            return true
        }
        // Moved or renamed since: fall back to what the file itself remembers.
        let from = Self.readWhereFroms(file).compactMap { URL(string: $0) }
        for url in from {
            if let record = ledger.record(fromSource: url) {
                goToSource(record)
                return true
            }
        }
        if let page = from.last, let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let browser = BrowserStore.shared
            browser.newTrail()
            browser.open(page)
            return true
        }
        NSSound.beep()
        return false
    }

    // MARK: Saving

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    /// Also called when the app quits.
    func saveNow() {
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ledger) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Files

    private static func cleanName(_ suggested: String) -> String {
        var name = (suggested as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty || name == "/" { name = "download" }
        return name
    }

    /// A path in ~/Downloads that is not taken: "name.ext", then "name (1).ext", and so on.
    private static func freeDestination(for name: String) -> URL {
        let fm = FileManager.default
        let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    private static let whereFromsKey = "com.apple.metadata:kMDItemWhereFroms"

    private static func writeWhereFroms(_ urls: [String], to file: URL) {
        guard !urls.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0)
        else { return }
        data.withUnsafeBytes { bytes in
            _ = setxattr(file.path, whereFromsKey, bytes.baseAddress, data.count, 0, 0)
        }
    }

    private static func readWhereFroms(_ file: URL) -> [String] {
        let size = getxattr(file.path, whereFromsKey, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(file.path, whereFromsKey, bytes.baseAddress, size, 0, 0)
        }
        guard read > 0,
              let list = try? PropertyListSerialization.propertyList(from: data.prefix(read), options: [], format: nil)
        else { return [] }
        return (list as? [String]) ?? []
    }
}

// MARK: Hooks into the browser

extension BrowserStore {
    /// The map as the search should show it: tabs matching by title or address,
    /// plus tabs a file with a matching name was downloaded from.
    func mapLayout(matching query: String) -> MapLayout {
        map.layout(matching: query, alsoShowing: DownloadStore.shared.tabs(matching: query))
    }

    /// Removes a tab that only ever existed to hand over a download, and returns to the tab it came from.
    func discardDownloadOnlyTab(_ id: TabID, backTo opener: TabID) {
        guard map.tab(id) != nil else { return }
        let wasActive = map.activeTabID == id
        forgetTab(id)
        if wasActive, map.tab(opener) != nil { activate(opener, commit: true) }
    }
}

extension WebTab {
    /// Anything the page cannot show, or that the server marks as an attachment, becomes a download.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        DownloadStore.shouldDownload(navigationResponse) ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadStore.shared.adopt(download, from: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadStore.shared.adopt(download, from: self)
    }
}

/// Dock apps (Gmail and the like) and their peeks save files the same way map tabs do.
extension DockPage {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        DownloadStore.shouldDownload(navigationResponse) ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adoptDownload(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adoptDownload(download)
    }

    private func adoptDownload(_ download: WKDownload) {
        let dock = AppDock.shared
        let app = dock.page(appID)
        // The file is credited to the app's page, not to an empty peek opened just to fetch it.
        let source = (role == .app || webView.backForwardList.currentItem != nil) ? self : (app ?? self)
        DownloadStore.shared.begin(download, tab: nil, page: (source.url, source.displayTitle))
        // A peek that only existed to hand over the file goes away again.
        if role != .app, webView.backForwardList.currentItem == nil {
            let empty = id
            Task { @MainActor in AppDock.shared.closePeek(empty) }
        }
    }
}
