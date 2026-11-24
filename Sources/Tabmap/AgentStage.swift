import AppKit
import WebKit
import TabMapCore

/// Where Claude's background tabs live while it works in them: each page in an off-screen window of
/// its own, so the person keeps the window and the page in front to themselves.
///
/// Off screen, WebKit would treat the page as hidden (timers slowed, no animation frames, many sites
/// stop updating). Turning off the web view's occlusion detection keeps it running as if it were in
/// front. Mouse and key events go straight to the web view, as for the page in front, so the page sees
/// them as the person's own (`isTrusted`). When the person opens the tab, Tabmap's page stage takes the
/// web view back as usual; pages Claude has left alone for a while go back to being ordinary
/// background tabs (and may sleep again).
@MainActor
final class AgentStage {
    static let shared = AgentStage()

    private var windows: [TabID: NSWindow] = [:]
    private var lastUse: [TabID: Date] = [:]
    private var views: [TabID: WeakView] = [:]
    private var sweepTask: Task<Void, Never>?
    /// How long a page stays held after Claude last touched it.
    static let holdTime: TimeInterval = 300

    /// Puts the page in its off-screen window (if it isn't on screen in Tabmap's own window) and keeps it running.
    func host(_ page: WebTab, size: NSSize) {
        let view = page.webView
        lastUse[page.id] = Date()
        startSweeping()
        if let window = windows[page.id], view.window === window { return }
        let window = windows[page.id] ?? makeWindow(size: size)
        windows[page.id] = window
        views[page.id] = WeakView(view: view)
        if window.frame.size != size { window.setContentSize(size) }
        view.removeFromSuperview()
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        Self.setOcclusionDetection(view, enabled: false)
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
    }

    func isHosting(_ view: WKWebView) -> Bool {
        guard let window = view.window else { return false }
        return windows.values.contains { $0 === window }
    }

    /// The page went back on screen in Tabmap's own window (the person opened it): let WebKit judge its
    /// visibility again.
    func noteOnScreen(_ page: WebTab) {
        if windows[page.id] != nil { Self.setOcclusionDetection(page.webView, enabled: true) }
    }

    func touch(_ id: TabID) { lastUse[id] = Date() }

    /// Tabs Claude has worked in lately: they don't sleep, so Claude doesn't lose its place.
    func holds(_ id: TabID) -> Bool {
        guard let used = lastUse[id] else { return false }
        return Date().timeIntervalSince(used) < Self.holdTime
    }

    /// Hands every page back (Claude control turned off, or the person stopped Claude).
    func releaseAll() {
        for id in Array(windows.keys) { release(id) }
    }

    private func release(_ id: TabID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        lastUse[id] = nil
        if let web = views.removeValue(forKey: id)?.view {
            Self.setOcclusionDetection(web, enabled: true)
            if web.window === window { web.removeFromSuperview() }
        }
        window.orderOut(nil)
        window.close()
    }

    private func startSweeping() {
        guard sweepTask == nil else { return }
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.sweep()
                if self.windows.isEmpty { self.sweepTask = nil; return }
            }
        }
    }

    private func sweep() {
        let store = BrowserStore.shared
        for (id, window) in windows {
            let empty = !(window.contentView?.subviews.contains { $0 is WKWebView } ?? false)
            if empty || store.map.tab(id)?.isClosed != false || !holds(id) { release(id) }
        }
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        // Far off every screen, so it never shows; never key, never in the Window menu or Mission Control.
        let window = AgentStageWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenNone]
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        window.title = "Claude background tab"
        return window
    }

    /// WebKit's own switch (`_setWindowOcclusionDetectionEnabled:`), as Safari uses for pages it keeps live.
    static func setOcclusionDetection(_ view: WKWebView, enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let method = class_getInstanceMethod(type(of: view), selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(view, selector, enabled)
    }
}

private struct WeakView {
    weak var view: WKWebView?
}

/// Never takes focus from the person's windows.
private final class AgentStageWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
