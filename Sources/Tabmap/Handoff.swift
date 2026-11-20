import AppKit
import Combine
import TabMapCore

// Handoff: the page in front is offered to your iPhone, iPad and other Macs (it shows in their app switcher
// or Dock), and a page handed off from Safari on your iPhone opens here in a new row when Tabmap is the
// default browser. Uses the standard web-browsing activity, so the other side opens it in its own browser.

@MainActor
final class Handoff: NSObject {
    static let shared = Handoff()

    static let enabledKey = "handoffEnabled"
    /// Marks tabs that arrived by Handoff, for the icon on the tab and for search ("handoff").
    static let sourceApp = SourceApp(bundleID: "app.tabmap.handoff", name: "Handoff")

    private var activity: NSUserActivity?
    private var cancellables: Set<AnyCancellable> = []

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Call once the app has finished launching.
    func start() {
        guard cancellables.isEmpty else { return }
        BrowserStore.shared.objectWillChange
            .merge(with: AppDock.shared.objectWillChange)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { Handoff.shared.update() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in MainActor.assumeIsolated { Handoff.shared.update(force: true) } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { Handoff.shared.update() } }
            .store(in: &cancellables)
        update(force: true)
    }

    /// Offers the page in front, or stops offering when there is no web page in front.
    func update(force: Bool = false) {
        let store = BrowserStore.shared
        guard enabled, let url = store.frontURL, Self.canHandOff(url) else {
            stop()
            return
        }
        if !force, activity?.webpageURL == url { return }
        // A fresh activity per page: other devices pick up the change more reliably than when one is edited.
        activity?.invalidate()
        let next = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        next.webpageURL = url
        if AppDock.shared.frontPage == nil {
            next.title = store.windowTitle
        }
        next.isEligibleForHandoff = true
        next.isEligibleForSearch = false
        next.becomeCurrent()
        activity = next
    }

    func stop() {
        activity?.invalidate()
        activity = nil
    }

    static func canHandOff(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: Receiving

    /// A page handed off from another device (Safari on your iPhone, another Mac).
    /// It opens in a new row at the top of the map, marked as arriving by Handoff.
    @discardableResult
    func receive(_ incoming: NSUserActivity) -> Bool {
        guard incoming.activityType == NSUserActivityTypeBrowsingWeb,
              let url = incoming.webpageURL, Self.canHandOff(url)
        else { return false }
        let store = BrowserStore.shared
        store.openFromApp(url, app: Self.sourceApp)
        NSApp.activate(ignoringOtherApps: true)
        if let window = store.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
