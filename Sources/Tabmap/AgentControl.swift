import AppKit
import SwiftUI
import UserNotifications
import WebKit
import TabMapCore

/// "Let Claude control Tabmap": whether it is on, what Claude is doing right now, and the person's
/// controls over it. Claude reaches Tabmap through `AgentServer` (a local MCP server) and acts through
/// `AgentTools`. While Claude acts, the page glows, Claude's cursor shows, and a pill offers Stop.
/// Any click or key press of the person's own in the window also stops Claude straight away.
@MainActor
final class AgentControl: NSObject, ObservableObject {
    static let shared = AgentControl()

    static let enabledKey = "agentControlEnabled"
    static let tokenKey = "agentControlToken"
    static let portKey = "agentControlPort"
    static let defaultPort: UInt16 = 47823

    /// Rows Claude opens are marked as opened from this app: Claude's icon, and "Claude agent" in search.
    static let laneApp = SourceApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude agent")

    enum Phase: Equatable {
        case idle
        /// Claude acted in the last few seconds.
        case driving
        /// The page needs the person (a CAPTCHA, a sign-in, a question from the page). Claude waits.
        case needsYou(String)
        /// The person stopped Claude. Claude's actions are refused for a while, or until Resume.
        case stopped
    }

    @Published private(set) var phase: Phase = .idle
    /// What Claude is doing, in a few words: "Clicking “Sign in”".
    @Published private(set) var status = ""
    /// Claude's pointer, in the window's content, top-left origin. Nil hides it.
    @Published private(set) var cursor: CGPoint?
    /// The page Claude is working on, in the window's content, top-left origin.
    @Published private(set) var pageFrame: CGRect?
    @Published private(set) var serverStatus = "Off"
    /// Claude acted on a page the person can see in the last few seconds: the glow and pointer show.
    @Published private(set) var frontActive = false
    /// Background tabs Claude is working in right now, with what it is doing in each.
    @Published private(set) var backgroundWork: [TabID: String] = [:]

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: AgentControl.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            applyEnabled()
        }
    }

    @Published private(set) var token: String = {
        if let saved = UserDefaults.standard.string(forKey: AgentControl.tokenKey), !saved.isEmpty { return saved }
        let fresh = AgentAccess.makeToken()
        UserDefaults.standard.set(fresh, forKey: AgentControl.tokenKey)
        return fresh
    }()

    var port: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        return saved > 0 && saved < 65536 ? UInt16(saved) : Self.defaultPort
    }

    /// The tab the person was asked to look at, for the notification's click.
    private var handOverTab: TabID?
    private(set) var handOverClearsItself = false
    private var stoppedUntil: Date?
    private var idleTask: Task<Void, Never>?
    private var frontTask: Task<Void, Never>?
    private var backgroundSeen: [TabID: Date] = [:]
    private var monitor: Any?
    /// Where Claude's pointer last was, in window coordinates (bottom-left origin).
    var pointer: NSPoint?
    /// Claude's own recent input events. WebKit hands key equivalents the page didn't use (⌘A on a
    /// link, say) back to the app, so they show up in the monitor below and must not count as the person's.
    private var ownEvents: [NSEvent] = []

    func noteOwnEvent(_ event: NSEvent) {
        ownEvents.append(event)
        if ownEvents.count > 16 { ownEvents.removeFirst(ownEvents.count - 16) }
    }

    private func isOwnEvent(_ event: NSEvent) -> Bool {
        ownEvents.contains { $0 === event || ($0.type == event.type && $0.timestamp == event.timestamp) }
    }

    private override init() {
        super.init()
    }

    // MARK: Turning it on

    func startIfEnabled() {
        if Self.notificationsAvailable { UNUserNotificationCenter.current().delegate = self }
        installMonitor()
        applyEnabled()
    }

    private func applyEnabled() {
        if enabled {
            AgentServer.shared.start(port: port, token: token) { [weak self] state in
                Task { @MainActor in self?.serverStatus = state }
            }
            requestNotificationPermission()
        } else {
            AgentServer.shared.stop()
            serverStatus = "Off"
            finish()
            AgentStage.shared.releaseAll()
        }
    }

    func regenerateToken() {
        token = AgentAccess.makeToken()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        AgentServer.shared.setToken(token)
    }

    /// The command that adds Tabmap to Claude Code.
    var claudeCodeCommand: String {
        "claude mcp add --transport http tabmap http://127.0.0.1:\(port)/mcp --header \"Authorization: Bearer \(token)\""
    }

    // MARK: Claude's actions

    enum Refusal: Error {
        case stopped
        case needsYou(String)
    }

    /// Every action calls this first. Throws when the person has stopped Claude or a page is waiting on them.
    /// `front` false: the tab is out of sight (AgentStage), so no glow or pointer, just a count on the pill.
    func begin(_ what: String, tab: TabID? = nil, front: Bool = true) throws {
        try checkAllowed()
        phase = .driving
        noteStatus(what, tab: tab, front: front)
    }

    /// Between the steps of a longer action (a pointer move, each typed key): lets Stop take effect at once.
    func checkAllowed() throws {
        switch phase {
        case .stopped:
            if let until = stoppedUntil, until > Date() { throw Refusal.stopped }
            phase = .idle
            stoppedUntil = nil
        case .needsYou(let reason):
            throw Refusal.needsYou(reason)
        default:
            break
        }
    }

    var isWaitingForPerson: Bool {
        if case .needsYou = phase { return true }
        return false
    }

    func noteStatus(_ what: String, tab: TabID? = nil, front: Bool = true) {
        if front {
            status = what
            frontActive = true
            frontTask?.cancel()
            frontTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.frontActive = false
                self.cursor = nil
                if let latest = self.backgroundSeen.max(by: { $0.value < $1.value })?.key {
                    self.status = self.backgroundWork[latest] ?? self.status
                }
            }
        } else if let tab {
            backgroundWork[tab] = what
            backgroundSeen[tab] = Date()
            if !frontActive { status = what }
        }
        pruneBackground()
        keepAlive()
    }

    private func pruneBackground() {
        let cutoff = Date().addingTimeInterval(-20)
        for (tab, seen) in backgroundSeen where seen < cutoff {
            backgroundSeen[tab] = nil
            backgroundWork[tab] = nil
        }
    }

    /// The glow stays while Claude keeps acting; it fades out after a quiet spell.
    private func keepAlive() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .driving else { return }
            self.finish()
        }
    }

    private func finish() {
        idleTask?.cancel()
        frontTask?.cancel()
        if phase == .driving { phase = .idle }
        cursor = nil
        status = ""
        frontActive = false
        backgroundWork = [:]
        backgroundSeen = [:]
    }

    /// Claude's pointer moved (window coordinates, bottom-left origin). `page` is the web view it is over.
    func movePointer(to point: NSPoint, in page: NSView) {
        pointer = point
        guard let content = page.window?.contentView else { return }
        let height = content.bounds.height
        cursor = CGPoint(x: point.x, y: height - point.y)
        let frame = page.convert(page.bounds, to: nil)
        pageFrame = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    func notePage(_ page: NSView) {
        guard let content = page.window?.contentView else { return }
        let height = content.bounds.height
        let frame = page.convert(page.bounds, to: nil)
        pageFrame = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: The person's controls

    /// Stop button, or the person clicked or typed in the window while Claude was acting.
    func stop() {
        idleTask?.cancel()
        frontTask?.cancel()
        phase = .stopped
        stoppedUntil = Date().addingTimeInterval(120)
        cursor = nil
        status = ""
        frontActive = false
        backgroundWork = [:]
        backgroundSeen = [:]
        // Back to normal on its own after a while, so the pill doesn't linger.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, self.phase == .stopped else { return }
            self.phase = .idle
            self.stoppedUntil = nil
        }
    }

    func resume() {
        stoppedUntil = nil
        phase = .idle
    }

    /// A page needs the person: a human check, a password, a question the page asks.
    /// Claude stops acting, and the person gets a notification.
    /// `clearsItself`: Claude may carry on without Done once the page no longer shows the check.
    func handOver(_ reason: String, tab: TabID?, site: String?, clearsItself: Bool) {
        if case .needsYou(let current) = phase, current == reason { return }
        idleTask?.cancel()
        phase = .needsYou(reason)
        handOverClearsItself = clearsItself
        status = ""
        cursor = nil
        handOverTab = tab
        notify(title: "Claude needs you" + (site.map { " on \($0)" } ?? ""),
               body: "\(reason). Claude will carry on once you press Done in Tabmap.")
        NSApp.requestUserAttention(.criticalRequest)
    }

    /// A page put up an alert or a question (a modal dialog) while Claude was acting.
    func pageAsks(_ message: String, tab: TabID, site: String?) {
        guard phase == .driving else { return }
        let short = message.count > 80 ? String(message.prefix(79)) + "…" : message
        handOver("The page asks: “\(short)”", tab: tab, site: site, clearsItself: false)
        dialogOpen = true
    }

    /// The person answered the page's dialog.
    func pageAnswered() {
        guard dialogOpen else { return }
        dialogOpen = false
        personDone()
    }

    private var dialogOpen = false

    /// The tab a hand-over is about, when it isn't the one in front.
    var waitingTab: TabID? { isWaitingForPerson ? handOverTab : nil }

    func showWaitingTab() {
        guard let tab = handOverTab else { return }
        let store = BrowserStore.shared
        if AppDock.shared.isFront { AppDock.shared.sendToBack() }
        if store.overviewShown {
            GestureNavigator.shared.closeOverview(showing: tab)
        } else {
            store.choose(tab)
        }
    }

    /// Done on the pill, or the page no longer needs the person.
    func personDone() {
        guard isWaitingForPerson else { return }
        phase = .driving
        handOverTab = nil
        keepAlive()
        if Self.notificationsAvailable {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
    }

    /// The person's own clicks and keys on the page Claude is driving take control back. Claude's input
    /// goes straight to the web view and never passes through here. While Claude only works in
    /// background tabs, the person can use the window freely; Stop on the pill still stops it.
    private func installMonitor() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if let self, self.phase == .driving, self.frontActive, let window = BrowserStore.shared.window,
               event.window === window, !self.isOwnEvent(event), self.isOnClaudesPage(event, in: window) {
                self.stop()
            }
            return event
        }
    }

    private func isOnClaudesPage(_ event: NSEvent, in window: NSWindow) -> Bool {
        if event.type == .keyDown {
            // Typing goes to a page (Claude's, or the other half of a split): either way it is the person's.
            var responder = window.firstResponder as? NSView
            while let view = responder {
                if view is WKWebView { return true }
                responder = view.superview
            }
            return false
        }
        guard let frame = pageFrame, let content = window.contentView else { return true }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        return frame.contains(point)
    }

    // MARK: Notifications

    /// Notifications need an app bundle; `swift run` has none.
    static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    private func requestNotificationPermission() {
        guard Self.notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard Self.notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "agent-needs-you-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

extension AgentControl: UNUserNotificationCenterDelegate {
    /// Show the banner even while Tabmap is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking the notification brings up the page that needs the person.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            let control = AgentControl.shared
            NSApp.activate(ignoringOtherApps: true)
            BrowserStore.shared.window?.makeKeyAndOrderFront(nil)
            if let tab = control.handOverTab, BrowserStore.shared.map.activeTabID != tab {
                BrowserStore.shared.choose(tab)
            }
            completionHandler()
        }
    }
}

// MARK: - What the person sees

/// Drawn over the whole window: a glow around the page Claude is working on, Claude's pointer,
/// and a pill at the bottom of the page with Stop (or Done, when a page needs the person).
struct AgentOverlay: View {
    @ObservedObject private var control = AgentControl.shared
    @EnvironmentObject private var store: BrowserStore

    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let frame = control.pageFrame, showsGlow, control.frontActive || control.isWaitingForPerson, !store.overviewShown {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Self.claudeOrange.opacity(glowIsCalm ? 0.6 : 0.9), lineWidth: 3)
                    .shadow(color: Self.claudeOrange.opacity(0.8), radius: 10)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let point = control.cursor, control.phase == .driving, control.frontActive, !store.overviewShown {
                AgentCursor()
                    .offset(x: point.x - 3, y: point.y - 2)
                    .allowsHitTesting(false)
                    .animation(.linear(duration: 0.03), value: point)
            }
            if showsPill, !store.overviewShown {
                GeometryReader { geometry in
                    let frame = control.pageFrame ?? CGRect(origin: .zero, size: geometry.size)
                    AgentPill()
                        .position(x: frame.midX, y: frame.maxY - 34)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.25), value: control.phase)
    }

    private var showsGlow: Bool {
        switch control.phase {
        case .driving, .needsYou: return true
        default: return false
        }
    }

    private var glowIsCalm: Bool { control.phase != .driving }

    private var showsPill: Bool { control.phase != .idle }
}

/// Claude's own pointer: an arrow in Claude's colour, so it never looks like the person's.
private struct AgentCursor: View {
    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(AgentOverlay.claudeOrange)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .overlay(alignment: .bottomTrailing) {
                Text("Claude")
                    .font(.system(size: 10, weight: .semibold))
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(AgentOverlay.claudeOrange))
                    .foregroundColor(.white)
                    .offset(x: 34, y: 10)
            }
    }
}

private struct AgentPill: View {
    @ObservedObject private var control = AgentControl.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .foregroundColor(AgentOverlay.claudeOrange)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            button
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
    }

    private var message: String {
        switch control.phase {
        case .driving:
            let others = control.backgroundWork.count
            if !control.frontActive && others > 0 {
                return "Claude, in \(others) background tab\(others == 1 ? "" : "s"): \(control.status)"
            }
            let base = control.status.isEmpty ? "Claude is driving" : "Claude: \(control.status)"
            return others > 0 ? base + " · +\(others) in background" : base
        case .needsYou(let reason): return "Your turn: \(reason)"
        case .stopped: return "Claude stopped"
        case .idle: return ""
        }
    }

    @ViewBuilder private var button: some View {
        switch control.phase {
        case .driving:
            pillButton("Stop", systemImage: "stop.fill") { control.stop() }
                .help("Take back control. Clicking or typing in the page also stops Claude.")
        case .needsYou:
            if let tab = control.waitingTab, BrowserStore.shared.map.activeTabID != tab {
                pillButton("Show", systemImage: "eye") { control.showWaitingTab() }
                    .help("Open the tab that needs you")
            }
            pillButton("Done", systemImage: "checkmark") { control.personDone() }
                .help("Let Claude carry on")
        case .stopped:
            pillButton("Let Claude continue", systemImage: "play.fill") { control.resume() }
        case .idle:
            EmptyView()
        }
    }

    private func pillButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct AgentSettingsSection: View {
    @ObservedObject private var control = AgentControl.shared
    @State private var copied = false

    var body: some View {
        Section("Claude") {
            Toggle("Let Claude control Tabmap", isOn: $control.enabled)
            Text("Claude can read pages, click, type and scroll in your signed-in Tabmap, with real mouse and keyboard input. It works in its own row, often in background tabs while you use other ones, shows its pointer and a Stop button, and stops when you click or type in the page it is driving. When a site asks whether you're human, Claude stops and sends you a notification. Only programs on this Mac with the key below can connect.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if control.enabled {
                Text("Server: \(control.serverStatus)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if AgentAccessibility.shared.isAvailable {
                    Text("Claude reads pages through macOS accessibility, the way VoiceOver does.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Claude reads pages from their HTML. Allowing Tabmap under Privacy & Security > Accessibility lets it read them the way VoiceOver does, including frames from other sites.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Allow…") { AgentAccessibility.shared.requestPermission() }
                    }
                }
                Text("Add it to Claude Code by running this in Terminal:")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text(control.claudeCodeCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(copied ? "Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(control.claudeCodeCommand, forType: .string)
                        copied = true
                    }
                    Button("New Key") {
                        control.regenerateToken()
                        copied = false
                    }
                    .help("Programs using the old key lose access. Run the command again after this.")
                }
            }
        }
    }
}
