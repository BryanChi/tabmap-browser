import AppKit
import Combine
import SwiftUI
import TabMapCore

// iCloud sync between your Macs, through iCloud Drive.
//
// Tabmap is not signed with an Apple Developer team, so it cannot use CloudKit or the iCloud key-value store
// (both need an entitlement only Apple can grant). iCloud Drive is just a folder that macOS keeps in sync, and
// any app can use it, so this works today. In iCloud Drive/Tabmap/<profile>/:
//   devices/<device id>/rows.json        the rows open on that Mac
//   devices/<device id>/bookmarks.json   its bookmarks, with when each changed and what it deleted
//   pictures/<bookmark id>.jpg           bookmark pictures, shared by all Macs
//   text/<bookmark id>.txt               the saved text of each bookmarked page, for search
// Each Mac writes only its own device folder, so two Macs never write the same file. The rules for merging
// bookmarks are in TabMapCore/CloudSync.swift.

@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    static let enabledKey = "iCloudSyncEnabled"
    private static let deviceIDKey = "syncDeviceID"
    /// Tabs brought over from another Mac carry that Mac's name, so search finds them by it.
    static let otherMacBundleID = "app.tabmap.other-mac"

    enum Status: Equatable {
        case off
        case noICloudDrive
        case syncing
        case synced(Date)
        case failed(String)
    }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: CloudSync.enabledKey)
    @Published private(set) var status: Status = .off
    /// Rows open on your other Macs, most recently updated Mac first.
    @Published private(set) var otherMacs: [DeviceRows] = []
    @Published var panelShown = false {
        didSet { if panelShown { installEscape(); syncSoon() } }
    }
    @Published var panelQuery = ""

    let deviceID: String
    let deviceName: String

    private var state = BookmarkSyncState()
    private var stateLoaded = false
    private var timer: Timer?
    private var soonTask: Task<Void, Never>?
    private var running = false
    private var again = false
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    /// What was last written, so an unchanged file is not written again (iCloud uploads every write).
    private var lastWritten: [String: Data] = [:]

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Self.deviceIDKey) {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        }
        deviceName = Host.current().localizedName ?? "Mac"
    }

    // MARK: Where things live

    /// iCloud Drive's own folder on this Mac, if iCloud Drive is turned on.
    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    /// The profile's folder in iCloud Drive. Profiles are matched across Macs by name.
    var folder: URL? {
        Self.iCloudDrive?
            .appendingPathComponent("Tabmap", isDirectory: true)
            .appendingPathComponent(Self.profileFolderName, isDirectory: true)
    }

    static var profileFolderName: String { "Personal" }

    /// This Mac's memory of the last sync, next to the rest of Tabmap's data.
    private static var stateURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return base.appendingPathComponent("Tabmap/sync-state.json")
    }

    // MARK: Turning it on and off

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        enabled = on
        if on {
            start()
            syncSoon(delay: 0)
        } else {
            timer?.invalidate()
            timer = nil
            otherMacs = []
            status = .off
        }
    }

    /// Call once the app has finished launching. Does nothing until sync is turned on in Settings.
    func start() {
        guard enabled else { status = .off; return }
        if cancellables.isEmpty {
            BookmarkStore.shared.$library
                .dropFirst()
                .debounce(for: .seconds(3), scheduler: RunLoop.main)
                .sink { _ in MainActor.assumeIsolated { CloudSync.shared.syncSoon(delay: 0) } }
                .store(in: &cancellables)
            BrowserStore.shared.$map
                .dropFirst()
                .debounce(for: .seconds(20), scheduler: RunLoop.main)
                .sink { _ in MainActor.assumeIsolated { CloudSync.shared.syncSoon(delay: 0) } }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { _ in MainActor.assumeIsolated { CloudSync.shared.syncSoon(delay: 1) } }
                .store(in: &cancellables)
        }
        if timer == nil {
            // iCloud Drive brings other Macs' files down by itself; this is how often Tabmap looks at them.
            timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { _ in
                Task { @MainActor in CloudSync.shared.syncSoon(delay: 0) }
            }
        }
        syncSoon(delay: 2)
    }

    func syncSoon(delay: TimeInterval = 0) {
        guard enabled else { return }
        soonTask?.cancel()
        soonTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Writes this Mac's rows and bookmarks if they changed, reads the other Macs', and merges bookmarks.
    func syncNow() async {
        guard enabled else { return }
        if running { again = true; return }
        guard let folder else { status = .noICloudDrive; return }
        running = true
        defer {
            running = false
            if again { again = false; syncSoon(delay: 1) }
        }
        if case .synced = status {} else { status = .syncing }

        if !stateLoaded {
            stateLoaded = true
            if let data = try? Data(contentsOf: Self.stateURL),
               let saved = try? JSONDecoder().decode(BookmarkSyncState.self, from: data) {
                state = saved
            }
        }

        let now = Date()
        let bookmarks = BookmarkStore.shared
        BookmarkSync.noteLocalChanges(in: bookmarks.library, state: &state, now: now)
        let rows = DeviceRows(deviceID: deviceID, deviceName: deviceName, savedAt: now,
                              rows: BrowserStore.shared.map.syncedRows())
        let mine = BookmarkSync.outgoing(bookmarks.library, state: state,
                                         deviceID: deviceID, deviceName: deviceName, now: now)
        let deviceID = self.deviceID
        let previous = lastWritten

        // Encoded here and handed over as plain data, so nothing but bytes crosses to the background.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var rowsKey = rows; rowsKey.savedAt = .distantPast
        var marksKey = mine; marksKey.savedAt = .distantPast
        var outgoing: [Outgoing] = []
        if let data = try? encoder.encode(rows), let key = try? encoder.encode(rowsKey) {
            outgoing.append(Outgoing(name: "rows.json", data: data, key: key))
        }
        if let data = try? encoder.encode(mine), let key = try? encoder.encode(marksKey) {
            outgoing.append(Outgoing(name: "bookmarks.json", data: data, key: key))
        }

        let exchange = await Task.detached(priority: .utility) {
            Self.exchange(folder: folder, deviceID: deviceID, outgoing: outgoing, lastWritten: previous)
        }.value

        guard enabled else { return }
        if let error = exchange.error {
            status = .failed(error)
            return
        }
        lastWritten.merge(exchange.written) { _, new in new }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remoteRows = exchange.rows.compactMap { try? decoder.decode(DeviceRows.self, from: $0) }
        let remoteBookmarks = exchange.bookmarks.compactMap { try? decoder.decode(DeviceBookmarks.self, from: $0) }

        // Merge what the other Macs have. Changes made while files were being read are kept: they are newer
        // than anything read, and are picked up on the next sync.
        var library = bookmarks.library
        BookmarkSync.noteLocalChanges(in: library, state: &state, now: now)
        let result = BookmarkSync.merge(remoteBookmarks, into: &library, state: &state)
        if !result.isEmpty {
            bookmarks.replaceFromSync(library, arrived: result.arrived)
        }
        saveState()

        otherMacs = DeviceRows.others(remoteRows, excluding: deviceID, now: now)
        status = .synced(Date())

        // Pictures and saved text go both ways in the background.
        let localFiles = bookmarks.library.bookmarks.map { b in
            (id: b.id, picture: bookmarks.pictureFile(b.id), text: bookmarks.textFile(b.id))
        }
        let arrived = result.arrived
        let fetched = await Task.detached(priority: .utility) {
            Self.exchangeFiles(folder: folder, local: localFiles, wanted: arrived)
        }.value
        if !fetched.isEmpty { bookmarks.filesArrived(fetched) }
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    // MARK: Files (off the main thread)

    private struct Outgoing: Sendable {
        var name: String
        var data: Data
        /// The same file without the time it was written, to tell whether anything really changed.
        var key: Data
    }

    private struct Exchange: Sendable {
        var rows: [Data] = []
        var bookmarks: [Data] = []
        var written: [String: Data] = [:]
        var error: String?
    }

    nonisolated private static func exchange(folder: URL, deviceID: String, outgoing: [Outgoing],
                                             lastWritten: [String: Data]) -> Exchange {
        var result = Exchange()
        let fm = FileManager.default
        let devices = folder.appendingPathComponent("devices", isDirectory: true)
        let mineDir = devices.appendingPathComponent(deviceID, isDirectory: true)
        do {
            try fm.createDirectory(at: mineDir, withIntermediateDirectories: true)
        } catch {
            result.error = "Tabmap can't write to iCloud Drive. Allow it in System Settings → Privacy & Security → Files and Folders."
            return result
        }

        for file in outgoing where lastWritten[file.name] != file.key {
            if coordinatedWrite(file.data, to: mineDir.appendingPathComponent(file.name)) {
                result.written[file.name] = file.key
            }
        }

        let others = (try? fm.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? []
        for dir in others where dir.lastPathComponent != deviceID && !dir.lastPathComponent.hasPrefix(".") {
            if let data = coordinatedRead(dir.appendingPathComponent("rows.json")) { result.rows.append(data) }
            if let data = coordinatedRead(dir.appendingPathComponent("bookmarks.json")) { result.bookmarks.append(data) }
        }
        return result
    }

    /// Uploads this Mac's bookmark pictures and texts that iCloud Drive does not have yet, and brings down
    /// the ones for bookmarks that just arrived. Returns the bookmarks whose files were brought down.
    nonisolated private static func exchangeFiles(folder: URL, local: [(id: BookmarkID, picture: URL, text: URL)],
                                                  wanted: Set<BookmarkID>) -> Set<BookmarkID> {
        let fm = FileManager.default
        let pictures = folder.appendingPathComponent("pictures", isDirectory: true)
        let texts = folder.appendingPathComponent("text", isDirectory: true)
        try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)
        try? fm.createDirectory(at: texts, withIntermediateDirectories: true)
        var fetched = Set<BookmarkID>()
        for item in local {
            let pairs = [(item.picture, pictures.appendingPathComponent(item.id.uuidString + ".jpg")),
                         (item.text, texts.appendingPathComponent(item.id.uuidString + ".txt"))]
            for (mine, shared) in pairs {
                let haveMine = fm.fileExists(atPath: mine.path)
                let haveShared = fm.fileExists(atPath: shared.path)
                if haveMine && !haveShared, let data = try? Data(contentsOf: mine) {
                    _ = coordinatedWrite(data, to: shared)
                } else if haveShared && (!haveMine || wanted.contains(item.id) && isNewer(shared, than: mine)),
                          let data = coordinatedRead(shared) {
                    try? fm.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? data.write(to: mine, options: .atomic)) != nil { fetched.insert(item.id) }
                }
            }
        }
        return fetched
    }

    nonisolated private static func isNewer(_ a: URL, than b: URL) -> Bool {
        let fm = FileManager.default
        guard let da = (try? fm.attributesOfItem(atPath: a.path))?[.modificationDate] as? Date else { return false }
        guard let db = (try? fm.attributesOfItem(atPath: b.path))?[.modificationDate] as? Date else { return true }
        return da > db
    }

    /// Reads through the file coordinator, which also brings the file down from iCloud if it is not on this Mac.
    nonisolated private static func coordinatedRead(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        return data
    }

    nonisolated private static func coordinatedWrite(_ data: Data, to url: URL) -> Bool {
        var ok = false
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
            ok = (try? data.write(to: writeURL, options: .atomic)) != nil
        }
        return ok && error == nil
    }

    // MARK: Opening rows from other Macs

    /// Brings a row over from another Mac: it opens as a new row at the top of the map,
    /// marked with that Mac's name. With `only`, just that one tab.
    func open(_ row: SyncedRow, from mac: DeviceRows, only: SyncedTab? = nil) {
        let store = BrowserStore.shared
        let tabs = only.map { [$0] } ?? row.tabs
        guard let first = tabs.first else { return }
        let app = SourceApp(bundleID: Self.otherMacBundleID, name: mac.deviceName)
        store.openFromApp(first.url, app: app)
        guard let firstID = store.map.activeTabID else { return }
        var parent = firstID
        for tab in tabs.dropFirst() {
            store.openChild(of: parent, url: tab.url, activate: false)
            // Each tab opens to the right of the one before, so the row keeps its order.
            if let trail = store.map.trails.first(where: { $0.tabs.contains { $0.id == firstID } }),
               let last = trail.tabs.last(where: { !$0.isClosed })?.id {
                parent = last
            }
        }
        panelShown = false
    }

    func togglePanel() {
        if panelShown { panelShown = false } else { panelShown = true }
    }

    private func installEscape() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard CloudSync.shared.panelShown, event.keyCode == 53 else { return event }
                CloudSync.shared.panelShown = false
                return nil
            }
        }
    }

    // MARK: Words for Settings

    var statusText: String {
        switch status {
        case .off:
            return "Your bookmarks, and the rows open on each Mac, are kept in iCloud Drive so your other Macs signed in to the same Apple Account can see them."
        case .noICloudDrive:
            return "Turn on iCloud Drive in System Settings → Apple Account → iCloud to sync."
        case .syncing:
            return "Syncing…"
        case .synced(let date):
            let others = otherMacs.map(\.deviceName)
            let when = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
            let with = others.isEmpty ? "No other Macs yet" : "With " + ListFormatter.localizedString(byJoining: others)
            return "\(with). Last synced \(when)."
        case .failed(let message):
            return message
        }
    }
}

// MARK: Settings

struct SyncSettingsSection: View {
    @ObservedObject private var sync = CloudSync.shared
    @AppStorage(Handoff.enabledKey) private var handoff = true

    var body: some View {
        Section {
            Toggle("Hand off the page in front to your iPhone, iPad and other Macs", isOn: $handoff)
            Text("It shows up in their app switcher or Dock. Pages handed off from Safari on your iPhone open here when Tabmap is your default browser. Handoff also has to be on in System Settings → General → AirDrop & Handoff.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Sync bookmarks and open rows with your other Macs", isOn: Binding(
                get: { sync.enabled },
                set: { sync.setEnabled($0) }
            ))
            HStack(alignment: .firstTextBaseline) {
                Text(sync.statusText)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if sync.enabled {
                    Button("Sync Now") { sync.syncSoon(delay: 0) }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: The panel

/// Rows open on your other Macs. Click a row to bring all of it over, or a tab to bring just that page.
struct OtherMacsLayer: View {
    @ObservedObject private var sync = CloudSync.shared

    var body: some View {
        ZStack {
            if sync.panelShown {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { sync.panelShown = false }
                OtherMacsPanel()
                    .frame(width: 460)
                    .frame(maxHeight: 560)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.16), value: sync.panelShown)
    }
}

struct OtherMacsPanel: View {
    @ObservedObject private var sync = CloudSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "laptopcomputer")
                Text("On Your Other Macs").font(.system(size: 13, weight: .semibold))
                Spacer()
                TextField("Search", text: $sync.panelQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
            .padding(12)
            Divider()
            content
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }

    @ViewBuilder private var content: some View {
        if !sync.enabled {
            message("Turn on “Sync bookmarks and open rows with your other Macs” in Tabmap Settings on each Mac.")
        } else if sync.otherMacs.isEmpty {
            message(sync.status == .noICloudDrive
                    ? "Turn on iCloud Drive in System Settings to see rows from your other Macs."
                    : "No other Macs yet. Turn on sync in Tabmap Settings on your other Mac, signed in to the same Apple Account.")
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sync.otherMacs) { mac in
                        let rows = mac.rows.filter { $0.matches(sync.panelQuery) }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(mac.deviceName.uppercased()) · \(Self.ago(mac.savedAt))")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                ForEach(rows) { row in
                                    OtherMacRow(row: row, mac: mac)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(maxWidth: .infinity)
    }

    static func ago(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

private struct OtherMacRow: View {
    let row: SyncedRow
    let mac: DeviceRows
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(row.tabs.count == 1 ? "1 tab" : "\(row.tabs.count) tabs")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Button("Open Row") { CloudSync.shared.open(row, from: mac) }
                    .controlSize(.small)
                    .opacity(hovering ? 1 : 0)
            }
            ForEach(Array(row.tabs.prefix(6).enumerated()), id: \.offset) { _, tab in
                Button {
                    CloudSync.shared.open(row, from: mac, only: tab)
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.displayTitle).lineLimit(1)
                        Text(tab.url.host ?? "").foregroundColor(.secondary).lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.url.absoluteString)
            }
            if row.tabs.count > 6 {
                Text("and \(row.tabs.count - 6) more").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0.035)))
        .onHover { hovering = $0 }
    }
}
