import AppKit
import SwiftUI
import TabMapCore

// Links other apps hand to Tabmap (a link Claude gives you, a link in Slack or Mail).
// Each one opens in a new row at the top of the map, and the tab remembers which app sent it:
// the app's icon shows on the tab, and searching the map for the app's name finds it,
// along with every tab you went on to open from it.

/// Receives "open this URL" requests from other apps and works out who sent them.
@MainActor
final class ExternalLinks: NSObject {
    static let shared = ExternalLinks()

    /// Call from `applicationWillFinishLaunching`, so a link that launched Tabmap is not missed.
    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // Remember the app in front before Tabmap, since macOS often brings Tabmap forward
        // before it delivers the link.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                if pid == ProcessInfo.processInfo.processIdentifier {
                    Self.shared.tabmapActivatedAt = Date()
                } else {
                    Self.shared.previousAppPID = pid
                }
            }
        }
    }

    private var previousAppPID: pid_t?
    private var tabmapActivatedAt: Date?

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = Self.url(from: text)
        else { return }
        open([url], from: Self.sender(of: event))
    }

    /// Files (an .html file double-clicked in Finder) arrive through the app delegate instead.
    func openFiles(_ urls: [URL]) {
        let app = NSAppleEventManager.shared().currentAppleEvent.flatMap(Self.sender(of:)) ?? Self.frontmostOtherApp()
        open(urls, from: app)
    }

    private func open(_ urls: [URL], from app: SourceApp?) {
        let store = BrowserStore.shared
        for url in urls { store.openFromApp(url, app: app) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = store.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) { return url }
        // Some apps send addresses with spaces or other characters that need escaping.
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed))
        return escaped.flatMap(URL.init(string:))
    }

    // MARK: Who sent it

    /// The app behind an Apple Event: its sending process, or the app that process belongs to
    /// (Electron apps such as Claude and Slack can send from a helper). If the sender is not an
    /// app at all (the `open` command, a system service), the app in front is the best guess,
    /// since that is where the link was clicked.
    static func sender(of event: NSAppleEventDescriptor) -> SourceApp? {
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        if pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
           let running = NSRunningApplication(processIdentifier: pid),
           let app = describe(running) {
            return app
        }
        return frontmostOtherApp()
    }

    static func frontmostOtherApp() -> SourceApp? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        if front.processIdentifier != ProcessInfo.processInfo.processIdentifier { return describe(front) }
        // Tabmap was brought forward to receive the link: use the app that was in front just before.
        guard let at = shared.tabmapActivatedAt, Date().timeIntervalSince(at) < 2,
              let pid = shared.previousAppPID,
              let previous = NSRunningApplication(processIdentifier: pid)
        else { return nil }
        return describe(previous)
    }

    /// Names a running process as the app a person would recognise, or nil if it is not one.
    private static func describe(_ running: NSRunningApplication) -> SourceApp? {
        // A helper inside another app (Slack.app/Contents/Frameworks/Slack Helper.app) stands for the outer app.
        if let bundleURL = running.bundleURL, let outer = outermostApp(containing: bundleURL),
           outer != bundleURL.standardizedFileURL,
           let bundle = Bundle(url: outer), let id = bundle.bundleIdentifier {
            return make(bundleID: id, name: displayName(of: outer, bundle: bundle))
        }
        guard running.activationPolicy != .prohibited, let id = running.bundleIdentifier else { return nil }
        let name = running.localizedName ?? running.bundleURL.map { displayName(of: $0, bundle: nil) } ?? id
        return make(bundleID: id, name: name)
    }

    private static func make(bundleID: String, name: String) -> SourceApp? {
        if bundleID == Bundle.main.bundleIdentifier { return nil }
        return SourceApp(bundleID: bundleID, name: name)
    }

    /// The first `.app` in the path, e.g. /Applications/Slack.app for a helper deep inside it.
    private static func outermostApp(containing url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard let i = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...i])))
            .standardizedFileURL
    }

    private static func displayName(of appURL: URL, bundle: Bundle?) -> String {
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty { return name }
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty { return name }
        return FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: Default browser

/// Tabmap only receives links from other apps once it is the default web browser.
@MainActor
enum DefaultBrowser {
    static var isDefault: Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let handlerID = Bundle(url: handler)?.bundleIdentifier
        else { return false }
        return handlerID == Bundle.main.bundleIdentifier
    }

    /// The name of the current default browser, for the settings text.
    static var currentName: String? {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return nil }
        return FileManager.default.displayName(atPath: handler.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Asks macOS to make Tabmap the default. macOS shows its own confirmation first.
    static func makeDefault(completion: @escaping @MainActor (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { completion(false); return }
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
                // http and https go together in the system dialog, but set https as well to be sure.
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
                completion(true)
            } catch {
                completion(false)
            }
        }
    }
}

struct DefaultBrowserSection: View {
    @State private var isDefault = DefaultBrowser.isDefault
    @State private var current = DefaultBrowser.currentName
    @State private var asking = false

    var body: some View {
        Section {
            HStack {
                Text(isDefault ? "Tabmap is your default browser" : "Tabmap is not your default browser")
                Spacer()
                if !isDefault {
                    Button(asking ? "Asking…" : "Make Default") {
                        asking = true
                        DefaultBrowser.makeDefault { _ in
                            asking = false
                            refresh()
                        }
                    }
                    .disabled(asking || Bundle.main.bundleURL.pathExtension != "app")
                }
            }
            Text(isDefault
                 ? "Links you open in other apps, like Claude, Slack or Mail, open here in a new row, with that app's icon on the tab. Search the map for the app's name to find them again."
                 : "Links from other apps go to \(current ?? "another browser") for now. Make Tabmap the default and they open here in a new row, marked with the icon of the app they came from.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        isDefault = DefaultBrowser.isDefault
        current = DefaultBrowser.currentName
    }
}

/// "Make Tabmap Your Default Browser…" in the Tabmap menu. macOS asks before it changes anything.
struct MakeDefaultBrowserMenuItem: View {
    var body: some View {
        Button("Make Tabmap Your Default Browser…") {
            DefaultBrowser.makeDefault { _ in }
        }
        .disabled(Bundle.main.bundleURL.pathExtension != "app" || DefaultBrowser.isDefault)
    }
}

// MARK: Icons

/// Looks up app icons by bundle id and keeps them.
@MainActor
final class AppIconStore {
    static let shared = AppIconStore()
    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func icon(for bundleID: String) -> NSImage? {
        if let icon = cache[bundleID] { return icon }
        if missing.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// The icon of the app a tab came from. A generic symbol if that app is no longer installed.
struct SourceAppIcon: View {
    let app: SourceApp
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let symbol = Self.symbols[app.bundleID] {
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.secondary)
            } else if let icon = AppIconStore.shared.icon(for: app.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "arrow.up.forward.app")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Opened from \(app.name)")
    }

    /// Tabs that came from another device rather than an app.
    private static let symbols: [String: String] = [
        Handoff.sourceApp.bundleID: "laptopcomputer.and.iphone",
        CloudSync.otherMacBundleID: "laptopcomputer",
    ]
}

/// The app icon in the top-left corner of a thumbnail card.
struct SourceAppCorner: View {
    let app: SourceApp?

    var body: some View {
        if let app {
            SourceAppIcon(app: app, size: 22)
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .padding(6)
        }
    }
}

extension BrowserStore {
    /// A line for a tab's tooltip about where it came from, if it came from another app.
    func sourceNote(for tab: MapTab) -> String? {
        if let app = tab.sourceApp { return "Opened from \(app.name)" }
        if let app = map.originApp(of: tab.id) { return "Followed from a link opened in \(app.name)" }
        return nil
    }
}
