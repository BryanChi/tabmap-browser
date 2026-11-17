import AppKit
import SwiftUI
import WebKit
import TabMapCore

// Goes in Sources/Tabmap.
//
// Each profile is its own Tabmap process (launched with `--profile <uuid>`), so every store in the app
// (map, dock, history, downloads, bookmarks…) stays a simple singleton and simply reads its files from
// `ProfileContext.current.dataDirectory`. Work and Personal can be open side by side, each in its own
// window, and switching brings the other one forward (launching it if needed).

/// Which profile this process is, and where its files live. Settled the first time anything asks,
/// which is before any store reads a file.
final class ProfileContext: @unchecked Sendable {
    static let current = ProfileContext()

    let profile: Profile
    /// ~/Library/Application Support/Tabmap, shared by every profile. profiles.json lives here.
    let appRoot: URL
    /// This profile's folder: `appRoot` itself for the default profile, so nothing moves on upgrade.
    let dataDirectory: URL
    private var lockFD: Int32 = -1

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        appRoot = base.appendingPathComponent("Tabmap", isDirectory: true)
        try? fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
        let book = ProfileFile.load(appRoot: appRoot)
        profile = ProfileLaunch.resolve(arguments: CommandLine.arguments, in: book)
        dataDirectory = ProfileFile.directory(for: profile, appRoot: appRoot)
        try? fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        claimOrHandOff()
    }

    /// One process per profile. If another Tabmap already has this profile open, bring it forward and
    /// quit at once, before this process reads or writes any of the profile's files.
    private func claimOrHandOff() {
        let path = ProfileFile.lockURL(in: dataDirectory).path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd  // held until the process ends; the system releases it even after a crash
            ftruncate(fd, 0)
            let pid = "\(getpid())"
            _ = pid.withCString { pwrite(fd, $0, strlen($0), 0) }
            return
        }
        let owner = ProfileFile.lockOwner(fd: fd)
        close(fd)
        if let owner, let app = NSRunningApplication(processIdentifier: owner) {
            app.activate(options: [.activateAllWindows])
        }
        exit(0)
    }

    /// The title suffix that tells windows apart in Mission Control and the Window menu.
    func titled(_ title: String) -> String {
        profile.isDefault ? title : (title.isEmpty ? profile.name : "\(title) — \(profile.name)")
    }
}

/// File locations and the shared profiles.json.
enum ProfileFile {
    static func url(appRoot: URL) -> URL { appRoot.appendingPathComponent("profiles.json") }

    static func directory(for profile: Profile, appRoot: URL) -> URL {
        profile.relativeDataPath.isEmpty
            ? appRoot
            : appRoot.appendingPathComponent(profile.relativeDataPath, isDirectory: true)
    }

    static func lockURL(in directory: URL) -> URL { directory.appendingPathComponent("running.lock") }

    /// Reads the list; a missing or unreadable file is replaced by the starting list, written out at
    /// once so every process agrees on the profiles' ids.
    static func load(appRoot: URL) -> ProfileBook {
        let file = url(appRoot: appRoot)
        if let data = try? Data(contentsOf: file), let book = try? JSONDecoder().decode(ProfileBook.self, from: data) {
            return book
        }
        if FileManager.default.fileExists(atPath: file.path) {
            let backup = appRoot.appendingPathComponent("profiles-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: backup)
        }
        let book = ProfileBook()
        save(book, appRoot: appRoot)
        return book
    }

    static func save(_ book: ProfileBook, appRoot: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(book) else { return }
        try? data.write(to: url(appRoot: appRoot), options: .atomic)
    }

    static func lockOwner(fd: Int32) -> pid_t? {
        var buffer = [CChar](repeating: 0, count: 32)
        let count = pread(fd, &buffer, 31, 0)
        guard count > 0 else { return nil }
        return pid_t(String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The process that has a profile open right now, if any. Probes the profile's lock without taking it.
    static func runningProcess(for directory: URL) -> pid_t? {
        let fd = open(lockURL(in: directory).path, O_RDWR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        return lockOwner(fd: fd) ?? -1
    }
}

/// The profile list as the UI sees it, and switching between profiles.
@MainActor
final class ProfileSwitcher: ObservableObject {
    static let shared = ProfileSwitcher()

    @Published private(set) var book: ProfileBook
    let current: Profile
    private let appRoot: URL
    private var websiteData: WKWebsiteDataStore?
    private var activeObserver: Any?

    private init() {
        let context = ProfileContext.current
        current = context.profile
        appRoot = context.appRoot
        book = ProfileFile.load(appRoot: appRoot)
        // Another profile's window may have renamed or added profiles meanwhile.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ProfileSwitcher.shared.reload() }
        }
    }

    /// This profile as currently named and coloured (another window may have renamed it).
    var currentProfile: Profile { book.profile(current.id) ?? current }

    // MARK: Website data

    /// Cookies, sign-ins, local storage and cache for this profile. The default profile keeps WebKit's
    /// shared store, so sign-ins from before profiles stay. Other profiles get their own store
    /// (macOS 14 and later); on macOS 13 they get a private store that is forgotten when Tabmap quits.
    var websiteDataStore: WKWebsiteDataStore {
        if let websiteData { return websiteData }
        let store: WKWebsiteDataStore
        if current.isDefault {
            store = .default()
        } else if #available(macOS 14.0, *) {
            store = WKWebsiteDataStore(forIdentifier: current.id)
        } else {
            store = .nonPersistent()
        }
        websiteData = store
        return store
    }

    static var keepsSignInsSeparately: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    // MARK: Launch

    /// Called when the app has finished launching: marks the Dock icon of every profile but the default.
    func didLaunch() {
        NSApp.dockTile.badgeLabel = current.isDefault ? nil : currentProfile.initials
    }

    func reload() {
        let fresh = ProfileFile.load(appRoot: appRoot)
        if fresh != book { book = fresh }
        didLaunch()
    }

    // MARK: Switching

    func isCurrent(_ profile: Profile) -> Bool { profile.id == current.id }

    func isRunning(_ profile: Profile) -> Bool {
        isCurrent(profile) || ProfileFile.runningProcess(for: directory(of: profile)) != nil
    }

    /// Brings a profile's window forward, opening that profile if it isn't running.
    func open(_ profile: Profile) {
        if isCurrent(profile) {
            NSApp.activate(ignoringOtherApps: true)
            BrowserStore.shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        if let pid = ProfileFile.runningProcess(for: directory(of: profile)), pid > 0,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        launch(profile)
    }

    func open(atShortcut number: Int) {
        if let profile = book.profile(atShortcut: number) { open(profile) }
    }

    private func launch(_ profile: Profile) {
        let arguments = ProfileLaunch.arguments(for: profile)
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
                if let error { NSLog("Tabmap: could not open profile \(profile.name): \(error)") }
            }
        } else if let executable = Bundle.main.executableURL {
            // Running from `swift run`, without an app bundle.
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            try? process.run()
        }
    }

    // MARK: Editing

    /// Adds a profile and opens it straight away.
    func newProfile() {
        var fresh = ProfileFile.load(appRoot: appRoot)
        let profile = fresh.add()
        commit(fresh)
        open(profile)
    }

    func rename(_ profile: Profile, to name: String) {
        edit { $0.rename(profile.id, to: name) }
    }

    func setColor(_ profile: Profile, to color: Int) {
        edit { $0.setColor(profile.id, to: color) }
    }

    func move(_ profile: Profile, by offset: Int) {
        edit { $0.move(profile.id, by: offset) }
    }

    /// Why a profile can't be deleted right now, or nil if it can.
    func deleteBlocker(_ profile: Profile) -> String? {
        if profile.isDefault { return "The first profile can't be deleted." }
        if isCurrent(profile) { return "Switch to another profile to delete this one." }
        if isRunning(profile) { return "Close this profile's window first." }
        if !book.canRemove(profile.id) { return "The last profile can't be deleted." }
        return nil
    }

    /// Deletes a profile with its tabs, dock apps, bookmarks, history and website data. Asks first.
    func delete(_ profile: Profile) {
        guard deleteBlocker(profile) == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the profile “\(profile.name)”?"
        alert.informativeText = "Its tabs, dock apps, bookmarks, history, downloads list and website sign-ins are removed from this Mac. Downloaded files stay where they are."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        edit { $0.remove(profile.id) }
        try? FileManager.default.removeItem(at: directory(of: profile))
        if #available(macOS 14.0, *) {
            let id = profile.id
            Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        }
    }

    // MARK: Helpers

    private func directory(of profile: Profile) -> URL {
        ProfileFile.directory(for: profile, appRoot: appRoot)
    }

    /// Applies a change to the freshest copy on disk, so two windows editing don't undo each other.
    private func edit(_ change: (inout ProfileBook) -> Void) {
        var fresh = ProfileFile.load(appRoot: appRoot)
        change(&fresh)
        commit(fresh)
    }

    private func commit(_ fresh: ProfileBook) {
        ProfileFile.save(fresh, appRoot: appRoot)
        book = fresh
        didLaunch()
    }
}

extension Profile {
    var swatch: Color {
        switch Profile.colorNames[color] {
        case "blue": return .blue
        case "orange": return .orange
        case "green": return .green
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return Color(nsColor: .systemTeal)
        case "yellow": return .yellow
        default: return .gray
        }
    }
}
