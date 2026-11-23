import AppKit
import SwiftUI
import WebKit
import TabMapCore

// Trackpad navigation through the tab map.
//
// The map is treated as one big canvas of pages and the window as a viewport on it:
//   two-finger swipe   pushes the viewport to the neighbouring tab; the pages follow the fingers
//   pinch              zooms between a page and the map overview
//
// A swipe belongs to the page first. It moves through the map only when
//   Option is held (always), or
//   the page has no use for it ("edge push"): it cannot scroll any further that way and, for a
//   sideways swipe, has no back/forward history left in that direction.

/// A value that springs towards a target without overshooting.
private struct SpringValue {
    var value: CGFloat
    var velocity: CGFloat
    var target: CGFloat

    /// Advances by `dt` seconds. Returns true once it has come to rest.
    mutating func step(_ dt: CGFloat, stiffness: CGFloat, restDistance: CGFloat, restSpeed: CGFloat) -> Bool {
        let damping = 2 * sqrt(stiffness)
        var remaining = min(dt, 0.05)
        while remaining > 0 {
            let h = min(remaining, 0.004)
            let acceleration = -stiffness * (value - target) - damping * velocity
            velocity += acceleration * h
            value += velocity * h
            remaining -= h
        }
        return abs(value - target) < restDistance && abs(velocity) < restSpeed
    }
}

/// How far the zoom between page and map has gone. Watched by the few views that fade with it.
@MainActor
final class ZoomState: ObservableObject {
    /// 0 is the page, 1 is the map overview.
    @Published var progress: CGFloat = 0
    /// A zoom is under way, so the overview is on screen even though it is not "shown" yet.
    @Published var interactive = false
}

/// The small dot map shown while swiping.
@MainActor
final class MapHUDState: ObservableObject {
    @Published var visible = false
    @Published var rows: [[TabID]] = []
    @Published var current: TabID?
    @Published var target: TabID?
}

/// Receives, from a script in each page, whether the page could scroll when a scroll gesture began.
@MainActor
final class EdgeProbe: NSObject, WKScriptMessageHandler {
    static let shared = EdgeProbe()
    static let handlerName = "tabmapEdge"

    struct Report {
        var up = false, down = false, left = false, right = false
        /// The page handled the wheel event itself (maps, canvases, custom scrollers).
        var prevented = false
        var time: TimeInterval = 0
    }

    private weak var reportedBy: WKWebView?
    private var latest = Report()

    /// The report for `webView`, if it sent one at or after `time`.
    func report(for webView: WKWebView, since time: TimeInterval) -> Report? {
        guard reportedBy === webView, latest.time >= time else { return nil }
        return latest
    }

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(self, contentWorld: .defaultClient, name: Self.handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        func flag(_ key: String) -> Bool { (body[key] as? Bool) ?? ((body[key] as? NSNumber)?.boolValue ?? true) }
        latest = Report(up: flag("up"), down: flag("down"), left: flag("left"), right: flag("right"),
                        prevented: flag("prevented"), time: ProcessInfo.processInfo.systemUptime)
        reportedBy = message.webView
    }

    /// On the first wheel event of a gesture, looks from the element under the pointer outwards for
    /// anything that can still scroll in each direction, and reports it. Runs in its own script world.
    private static let source = """
    (function () {
      if (window.__tabmapEdgeProbe) { return; }
      window.__tabmapEdgeProbe = true;
      var last = 0;
      function scrolls(value) { return value === 'auto' || value === 'scroll' || value === 'overlay'; }
      function probe(event) {
        var r = { up: false, down: false, left: false, right: false, prevented: false };
        var path = event.composedPath ? event.composedPath() : [];
        for (var i = 0; i < path.length; i++) {
          var el = path[i];
          if (!(el instanceof Element)) { continue; }
          if (el === document.documentElement || el === document.body || el === document.scrollingElement) { continue; }
          var style = getComputedStyle(el);
          if (el.scrollHeight > el.clientHeight + 1 && scrolls(style.overflowY)) {
            if (el.scrollTop > 0) { r.up = true; }
            if (el.scrollTop + el.clientHeight < el.scrollHeight - 1) { r.down = true; }
          }
          if (el.scrollWidth > el.clientWidth + 1 && scrolls(style.overflowX)) {
            if (el.scrollLeft > 0) { r.left = true; }
            if (el.scrollLeft + el.clientWidth < el.scrollWidth - 1) { r.right = true; }
          }
        }
        var d = document.scrollingElement || document.documentElement;
        if (d) {
          if (window.scrollY > 0) { r.up = true; }
          if (window.scrollY + window.innerHeight < d.scrollHeight - 1) { r.down = true; }
          if (window.scrollX > 0) { r.left = true; }
          if (window.scrollX + window.innerWidth < d.scrollWidth - 1) { r.right = true; }
        }
        return r;
      }
      window.addEventListener('wheel', function (event) {
        var now = performance.now();
        var fresh = now - last > 120;
        last = now;
        if (!fresh || event.ctrlKey) { return; }
        var r = probe(event);
        setTimeout(function () {
          r.prevented = event.defaultPrevented;
          try { window.webkit.messageHandlers.tabmapEdge.postMessage(r); } catch (e) {}
        }, 0);
      }, { capture: true, passive: true });
    })();
    """
}

@MainActor
final class GestureNavigator {
    static let shared = GestureNavigator()

    weak var stage: PageStageView?
    let zoom = ZoomState()
    let hud = MapHUDState()
    /// Where each card's thumbnail is in the overview, in SwiftUI's window coordinates (origin top left).
    var cardFrames: [TabID: CGRect] = [:]

    private var store: BrowserStore { BrowserStore.shared }

    private init() {}

    /// Swiping past the edge of a page moves through the map. Off leaves only Option + swipe.
    static let edgeSwipeKey = "edgeSwipe"
    private var edgeSwipeEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.edgeSwipeKey) as? Bool) ?? true
    }

    // MARK: Ticker

    private var ticker: Timer?
    private var lastTick: CFTimeInterval = 0
    private var onTick: ((CGFloat) -> Void)?

    private func startTicker(_ body: @escaping (CGFloat) -> Void) {
        ticker?.invalidate()
        onTick = body
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated { GestureNavigator.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        onTick = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(now - lastTick)
        lastTick = now
        onTick?(dt)
    }

    // MARK: Swipe state

    private enum ScrollState { case idle, observing, engaged, rejected }
    private var scrollState = ScrollState.idle
    private var scrollTotal = CGSize.zero
    private var gestureStart: TimeInterval = 0
    private var optionAtStart = false
    private var swallowMomentum = false
    private var lastWheelStep = Date.distantPast

    private var horizontal = true
    /// Raw finger travel along the axis since the swipe took hold. Positive: content moves right or down.
    private var travel: CGFloat = 0
    /// Neighbour revealed by negative travel (right or below) and by positive travel (left or above).
    private var neighborNegative: TabID?
    private var neighborPositive: TabID?
    /// Which side currently has its page prepared: -1 negative travel, +1 positive, 0 none.
    private var preparedSign = 0
    private var samples: [(time: TimeInterval, delta: CGFloat)] = []

    private struct Settle {
        var spring: SpringValue
        var commit: TabID?
        var side: CGFloat
    }
    private var settle: Settle?

    private func neighbor(forSign sign: Int) -> TabID? {
        sign < 0 ? neighborNegative : (sign > 0 ? neighborPositive : nil)
    }

    private func axisLength(_ stage: PageStageView) -> CGFloat {
        horizontal ? stage.bounds.width : stage.bounds.height
    }

    /// The pointer is over the page, not over the sidebar that floats above it.
    private func onStage(_ event: NSEvent) -> Bool {
        guard let stage, stage.window != nil, !stage.isHidden else { return false }
        if store.sidebarPeek, !store.sidebarShown, event.locationInWindow.x < 270 { return false }
        return stage.bounds.contains(stage.convert(event.locationInWindow, from: nil))
    }

    // MARK: Scroll events

    func handleScroll(_ event: NSEvent) -> NSEvent? {
        if BookmarkStore.shared.boardShown { return event }
        // The app dock claims swipes that start at the bottom edge; map swipes are off while an app is in front.
        if AppDock.shared.handleScroll(event) { return nil }
        if AppDock.shared.isFront { return event }
        guard let stage, let window = store.window, event.window === window,
              !store.overviewShown, !zoom.interactive, pinch == nil else { return event }

        // The coast after the fingers lift. Never let it scroll the page we just arrived on.
        if !event.momentumPhase.isEmpty {
            return swallowMomentum ? nil : event
        }

        // A plain mouse wheel has no phases: with Option, one tab per notch.
        if event.phase.isEmpty {
            guard event.modifierFlags.contains(.option), onStage(event) else { return event }
            let now = Date()
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if now.timeIntervalSince(lastWheelStep) > 0.3, max(abs(dx), abs(dy)) > 0 {
                lastWheelStep = now
                if abs(dx) >= abs(dy) {
                    animateMove(dx < 0 ? .right : .left)
                } else {
                    animateMove(dy < 0 ? .down : .up)
                }
            }
            return nil
        }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            finishSwipeNow()
            swallowMomentum = false
            scrollTotal = .zero
            gestureStart = event.timestamp
            guard onStage(event) else {
                scrollState = .rejected
                return event
            }
            optionAtStart = event.modifierFlags.contains(.option)
            if optionAtStart {
                // Ours from the first event: the page never hears of it.
                scrollState = .observing
                return nil
            }
            scrollState = edgeSwipeEnabled ? .observing : .rejected
            return event
        }

        let finished = event.phase.contains(.ended) || event.phase.contains(.cancelled)

        switch scrollState {
        case .idle, .rejected:
            return event

        case .engaged:
            if !finished {
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                travel += delta
                samples.append((event.timestamp, delta))
                if samples.count > 12 { samples.removeFirst(samples.count - 12) }
                updateSwipe(stage)
            } else {
                endSwipe(stage, at: event.timestamp)
            }
            return nil

        case .observing:
            if finished {
                scrollState = .idle
                return optionAtStart ? nil : event
            }
            scrollTotal.width += event.scrollingDeltaX
            scrollTotal.height += event.scrollingDeltaY
            let ax = abs(scrollTotal.width), ay = abs(scrollTotal.height)

            if optionAtStart {
                if max(ax, ay) > 4 {
                    engage(stage, horizontal: ax >= ay)
                    travel = horizontal ? scrollTotal.width : scrollTotal.height
                    updateSwipe(stage)
                }
                return nil
            }

            // Edge push: let the page have the first stretch, then see whether it could use it.
            guard max(ax, ay) > 26 else { return event }
            let clearlyHorizontal = ax > ay * 1.3
            let clearlyVertical = ay > ax * 1.3
            guard clearlyHorizontal || clearlyVertical else {
                if max(ax, ay) > 70 { scrollState = .rejected }
                return event
            }
            let positive = (clearlyHorizontal ? scrollTotal.width : scrollTotal.height) > 0
            switch edgeDecision(horizontal: clearlyHorizontal, positive: positive) {
            case .take:
                if let webView = store.activeWebTab?.webView { sendScrollEnded(like: event, to: webView) }
                engage(stage, horizontal: clearlyHorizontal)
                updateSwipe(stage)
                return nil
            case .leave:
                scrollState = .rejected
                return event
            case .wait:
                if max(ax, ay) > 70 { scrollState = .rejected }
                return event
            }
        }
    }

    private enum EdgeDecision { case take, leave, wait }

    /// Whether a swipe without Option should move through the map. `positive`: content moving right or down.
    private func edgeDecision(horizontal: Bool, positive: Bool) -> EdgeDecision {
        let direction: MapDirection = horizontal ? (positive ? .left : .right) : (positive ? .up : .down)
        guard let active = store.map.activeTabID,
              store.map.screenNeighbor(of: active, direction) != nil else { return .leave }
        // A blank tab or a thumbnail has nothing to scroll.
        guard let webView = store.activeWebTab?.webView, stage?.currentShowsWeb == true else { return .take }
        if webView.magnification > 1.01 { return .leave }
        if horizontal {
            // Back and forward come first; the swipe carries on into the trail once history runs out.
            if positive && webView.canGoBack { return .leave }
            if !positive && webView.canGoForward { return .leave }
        }
        guard let report = EdgeProbe.shared.report(for: webView, since: gestureStart - 0.05) else { return .wait }
        if report.prevented { return .leave }
        let canScroll: Bool
        switch direction {
        case .up: canScroll = report.up
        case .down: canScroll = report.down
        case .left: canScroll = report.left
        case .right: canScroll = report.right
        }
        return canScroll ? .leave : .take
    }

    /// Tells the page its scroll gesture is over, since it will not see the rest of it.
    private func sendScrollEnded(like event: NSEvent, to webView: WKWebView) {
        guard let copy = event.cgEvent?.copy() else { return }
        copy.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4) // kCGScrollPhaseEnded
        let deltas: [CGEventField] = [
            .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
            .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
            .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
        ]
        for field in deltas { copy.setIntegerValueField(field, value: 0) }
        if let ended = NSEvent(cgEvent: copy) { webView.scrollWheel(with: ended) }
    }

    // MARK: Swipe mechanics

    private func engage(_ stage: PageStageView, horizontal: Bool) {
        scrollState = .engaged
        swallowMomentum = true
        beginSwipe(stage, horizontal: horizontal)
    }

    private func beginSwipe(_ stage: PageStageView, horizontal: Bool) {
        self.horizontal = horizontal
        travel = 0
        samples = []
        preparedSign = 0
        let active = store.map.activeTabID
        if let active {
            neighborNegative = store.map.screenNeighbor(of: active, horizontal ? .right : .down)
            neighborPositive = store.map.screenNeighbor(of: active, horizontal ? .left : .up)
        } else {
            neighborNegative = nil
            neighborPositive = nil
        }
        stage.busy = true
        showHUD(current: active)
    }

    /// Makes sure the page on the side being revealed is ready beside the current one.
    private func prepare(_ stage: PageStageView, sign: Int) {
        guard sign != 0, sign != preparedSign else { return }
        preparedSign = sign
        let target = neighbor(forSign: sign)
        stage.setIncoming(target.map { PageKey.tab($0) })
        if hud.target != target { hud.target = target }
    }

    /// Where the current page sits for a given finger travel: one to one towards a neighbour,
    /// with growing resistance where there is none.
    private func displayed(_ travel: CGFloat, _ stage: PageStageView) -> CGFloat {
        let sign = travel < 0 ? -1 : (travel > 0 ? 1 : 0)
        let length = axisLength(stage)
        if neighbor(forSign: sign) != nil {
            let limit = length + PageStageView.gap
            return max(-limit, min(limit, travel))
        }
        let limit = length * 0.2
        let x = abs(travel)
        return CGFloat(sign) * (1 - 1 / (x * 0.5 / limit + 1)) * limit
    }

    private func updateSwipe(_ stage: PageStageView) {
        let sign = travel < 0 ? -1 : (travel > 0 ? 1 : 0)
        prepare(stage, sign: sign)
        stage.applySwipe(horizontal: horizontal, offset: displayed(travel, stage), side: sign < 0 ? 1 : -1)
    }

    private func velocity(at time: TimeInterval) -> CGFloat {
        let recent = samples.filter { time - $0.time < 0.1 }
        guard let first = recent.first else { return 0 }
        let span = max(time - first.time, 1.0 / 60.0)
        return recent.reduce(0) { $0 + $1.delta } / CGFloat(span)
    }

    private func endSwipe(_ stage: PageStageView, at time: TimeInterval) {
        scrollState = .idle
        let sign = travel < 0 ? -1 : (travel > 0 ? 1 : 0)
        let length = axisLength(stage)
        let speed = velocity(at: time)
        let sameWay = (speed < 0) == (travel < 0)
        var target: TabID?
        if let candidate = neighbor(forSign: sign) {
            let distance = abs(travel)
            let far: Bool
            if optionAtStart {
                far = distance > length * 0.25 || (abs(speed) > 500 && sameWay && distance > 20)
            } else {
                // Without Option the bar is higher, so a stray flick at the top of a page stays put.
                far = distance > length * 0.33 || (abs(speed) > 1100 && sameWay && distance > length * 0.12)
            }
            if far { target = candidate }
        }
        let from = displayed(travel, stage)
        let end: CGFloat = target == nil ? 0 : CGFloat(sign) * (length + PageStageView.gap)
        let initial = (target != nil && sameWay) ? speed : 0
        startSettle(stage, from: from, velocity: initial, to: end, commit: target, side: sign < 0 ? 1 : -1)
    }

    private func startSettle(_ stage: PageStageView, from: CGFloat, velocity: CGFloat, to: CGFloat,
                             commit: TabID?, side: CGFloat) {
        settle = Settle(spring: SpringValue(value: from, velocity: velocity, target: to), commit: commit, side: side)
        startTicker { [weak self] dt in
            guard let self, var settle = self.settle, let stage = self.stage else {
                self?.finishSwipeNow()
                return
            }
            let done = settle.spring.step(dt, stiffness: 340, restDistance: 0.6, restSpeed: 25)
            self.settle = settle
            if done {
                self.finishSwipeNow()
            } else {
                stage.applySwipe(horizontal: self.horizontal, offset: settle.spring.value, side: settle.side)
            }
        }
    }

    /// Ends whatever swipe animation is running by jumping to its end.
    private func finishSwipeNow() {
        guard let settle else {
            if scrollState == .engaged, let stage {
                // A gesture that never ended properly: put the page back.
                scrollState = .idle
                stage.finishSwipe(commit: false)
                stage.busy = false
                stage.sync()
                hideHUD(after: 0)
            }
            return
        }
        self.settle = nil
        stopTicker()
        guard let stage else { return }
        stage.finishSwipe(commit: settle.commit != nil)
        if let target = settle.commit {
            hud.current = target
            hud.target = nil
            store.activate(target, commit: false)
            if !store.addressEditing { store.focusPage() }
        }
        stage.busy = false
        stage.sync()
        hideHUD(after: 0.7)
    }

    /// Slides to the neighbouring tab without a gesture (keyboard, mouse wheel, three-finger swipe).
    func animateMove(_ direction: MapDirection) {
        finishSwipeNow()
        // Inside a split, the arrow keys first move between its two halves.
        if let active = store.map.activeTabID, let partner = store.map.neighbor(of: active, direction),
           store.map.sameScreen(active, partner) {
            store.focusPane(partner)
            return
        }
        let target = store.map.activeTabID.flatMap { store.map.neighbor(of: $0, direction) }
        guard let stage, stage.window != nil, !stage.isHidden, !store.overviewShown,
              !zoom.interactive, scrollState != .engaged, pinch == nil else {
            if let target { store.activate(target, commit: false) }
            return
        }
        let horizontal = direction == .left || direction == .right
        // Going right or down, the content moves left or up: negative travel.
        let sign = (direction == .right || direction == .down) ? -1 : 1
        beginSwipe(stage, horizontal: horizontal)
        prepare(stage, sign: sign)
        let side: CGFloat = sign < 0 ? 1 : -1
        if target != nil {
            let end = CGFloat(sign) * (axisLength(stage) + PageStageView.gap)
            startSettle(stage, from: 0, velocity: CGFloat(sign) * 1400, to: end, commit: target, side: side)
        } else {
            // Nothing there: a short nudge and back.
            startSettle(stage, from: 0, velocity: CGFloat(sign) * 900, to: 0, commit: nil, side: side)
        }
    }

    /// Three-finger swipe, when the system is set to send it. It arrives already finished.
    func handleSwipe(_ event: NSEvent) -> NSEvent? {
        if BookmarkStore.shared.boardShown { return event }
        if AppDock.shared.isFront { return event }
        guard let window = store.window, event.window === window, !store.overviewShown else { return event }
        if event.deltaX > 0 { animateMove(.right) }
        else if event.deltaX < 0 { animateMove(.left) }
        else if event.deltaY > 0 { animateMove(.down) }
        else if event.deltaY < 0 { animateMove(.up) }
        else { return event }
        return nil
    }

    // MARK: Dot map

    private var hudHide: Task<Void, Never>?

    private func showHUD(current: TabID?) {
        hudHide?.cancel()
        let rows = store.map.layout().open.map { $0.openTabs.map(\.id) }
        if hud.rows != rows { hud.rows = rows }
        hud.current = current
        hud.target = nil
        if !hud.visible { hud.visible = true }
    }

    private func hideHUD(after delay: TimeInterval) {
        hudHide?.cancel()
        hudHide = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.hud.visible = false
        }
    }

    // MARK: Pinch

    private enum Pinch {
        /// Started on a page that is not zoomed in.
        case page(WKWebView?)
        /// Started in the overview: spreading opens this tab.
        case overview(TabID?)
    }
    private var pinch: Pinch?
    private var pinchTotal: CGFloat = 0
    private var pinchSamples: [(time: TimeInterval, progress: CGFloat)] = []
    /// The tab whose card the page shrinks into or grows out of.
    private var zoomTab: TabID?
    private var zoomSpring: SpringValue?
    private var zoomCompletion: (() -> Void)?
    /// True while this class is the one flipping `overviewShown`.
    private var settingOverviewFlag = false

    func handleMagnify(_ event: NSEvent) -> NSEvent? {
        if BookmarkStore.shared.boardShown { return event }
        // A pinch on a link peek belongs to the app dock; the map zoom is off while an app is in front.
        if AppDock.shared.handleMagnify(event) { return nil }
        if AppDock.shared.isFront { return event }
        guard let stage, let window = store.window, event.window === window else { return event }

        if event.phase.contains(.began) {
            pinch = nil
            pinchTotal = 0
            pinchSamples = []
            guard scrollState != .engaged else { return event }
            finishSwipeNow()
            finishZoomNow()
            if store.overviewShown {
                let target = store.overviewSelection ?? store.map.activeTabID
                pinch = .overview(target)
                zoomTab = target
                // Put the tab that would open on the (still hidden) stage.
                stage.busy = false
                stage.display(PageKey(target))
                stage.busy = true
                zoom.interactive = true
                setZoom(1)
                return nil
            }
            guard onStage(event) else { return event }
            let webView = stage.currentShowsWeb ? store.activeWebTab?.webView : nil
            // A page that is zoomed in keeps its pinch.
            if let webView, webView.magnification > 1.001 { return event }
            pinch = .page(webView)
            zoomTab = store.map.activeTabID
            return nil
        }

        guard let pinch else { return event }
        pinchTotal += event.magnification

        switch pinch {
        case .page(let webView):
            if pinchTotal > 0 {
                // Spreading: zoom the page itself, as the web view would have.
                if zoom.interactive { setZoom(0) }
                if let webView {
                    let point = webView.convert(event.locationInWindow, from: nil)
                    webView.setMagnification(min(1 + pinchTotal, 3), centeredAt: point)
                }
            } else {
                if let webView, webView.magnification != 1 {
                    webView.setMagnification(1, centeredAt: .zero)
                }
                if !zoom.interactive {
                    store.prepareOverview()
                    stage.busy = true
                    zoom.interactive = true
                }
                setZoom(min(1, -pinchTotal / 0.55))
            }
        case .overview:
            setZoom(max(0, min(1, 1 - pinchTotal / 0.7)))
        }
        pinchSamples.append((event.timestamp, zoom.progress))
        if pinchSamples.count > 12 { pinchSamples.removeFirst(pinchSamples.count - 12) }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endPinch(pinch, at: event.timestamp)
        }
        return nil
    }

    private func pinchSpeed(at time: TimeInterval) -> CGFloat {
        let recent = pinchSamples.filter { time - $0.time < 0.1 }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return 0 }
        return (last.progress - first.progress) / CGFloat(last.time - first.time)
    }

    private func endPinch(_ pinch: Pinch, at time: TimeInterval) {
        self.pinch = nil
        let speed = pinchSpeed(at: time)
        let p = zoom.progress
        switch pinch {
        case .page:
            guard zoom.interactive else { return } // it was a zoom into the page
            let open = (p > 0.3 && speed > -1.0) || (speed > 1.2 && p > 0.06)
            settleZoom(to: open ? 1 : 0, velocity: speed)
        case .overview(let target):
            let close = (p < 0.7 && speed < 1.0) || (speed < -1.2 && p < 0.94)
            if close, let target {
                setOverviewFlag(false)
                store.activate(target, commit: true)
                zoomTab = target
                stage?.refreshCurrent()
                store.focusPage()
                settleZoom(to: 0, velocity: speed)
            } else if close {
                setOverviewFlag(false)
                settleZoom(to: 0, velocity: speed)
            } else {
                settleZoom(to: 1, velocity: speed)
            }
        }
    }

    // MARK: Zoom mechanics

    /// The card's thumbnail in the stage's coordinates, if the card is on screen.
    private func cardRect(for id: TabID?) -> CGRect? {
        guard let id, let frame = cardFrames[id], let stage, let content = stage.window?.contentView else { return nil }
        let inWindow = CGRect(x: frame.minX, y: content.bounds.height - frame.maxY,
                              width: frame.width, height: frame.height)
        guard inWindow.width > 1, content.bounds.intersects(inWindow) else { return nil }
        return stage.convert(inWindow, from: nil)
    }

    private func setZoom(_ progress: CGFloat) {
        guard let stage else { return }
        if stage.isHidden { stage.isHidden = false }
        if zoom.progress != progress { zoom.progress = progress }
        stage.applyZoom(progress, card: cardRect(for: zoomTab))
    }

    private func setOverviewFlag(_ shown: Bool) {
        settingOverviewFlag = true
        store.overviewShown = shown
        settingOverviewFlag = false
    }

    /// `then` runs once the zoom has come to rest (and not if another zoom replaces this one).
    private func settleZoom(to target: CGFloat, velocity: CGFloat, stiffness: CGFloat = 300,
                            then: (() -> Void)? = nil) {
        zoomSpring = SpringValue(value: zoom.progress, velocity: velocity, target: target)
        zoomCompletion = { [weak self] in
            guard let self else { return }
            self.restZoom(overview: target >= 0.5)
            then?()
        }
        startTicker { [weak self] dt in
            guard let self, var spring = self.zoomSpring else { return }
            let done = spring.step(dt, stiffness: stiffness, restDistance: 0.003, restSpeed: 0.05)
            self.zoomSpring = spring
            if done {
                self.finishZoomNow()
            } else {
                self.setZoom(max(0, min(1, spring.value)))
            }
        }
    }

    /// Ends a running zoom animation by jumping to its end.
    private func finishZoomNow() {
        guard zoomSpring != nil else { return }
        zoomSpring = nil
        stopTicker()
        let completion = zoomCompletion
        zoomCompletion = nil
        completion?()
    }

    /// The resting state at either end of the zoom.
    private func restZoom(overview: Bool) {
        if store.overviewShown != overview { setOverviewFlag(overview) }
        zoom.progress = overview ? 1 : 0
        zoom.interactive = false
        guard let stage else { return }
        stage.resetZoom()
        stage.isHidden = overview
        stage.busy = false
        stage.sync()
    }

    /// ⌘E, the map button, Esc.
    func toggleOverview() {
        if store.overviewShown || (zoom.interactive && (zoomSpring?.target ?? 0) >= 0.5) {
            closeOverview(showing: store.map.activeTabID)
        } else {
            openOverview()
        }
    }

    func openOverview() {
        finishSwipeNow()
        finishZoomNow()
        guard pinch == nil else { return }
        store.prepareOverview()
        guard let stage, stage.window != nil else {
            setOverviewFlag(true)
            return
        }
        zoomTab = store.map.activeTabID
        stage.busy = true
        zoom.interactive = true
        setZoom(0)
        settleZoom(to: 1, velocity: 2.5)
    }

    /// Zooms from the map into `id`'s page. The caller has already made it the current tab.
    func closeOverview(showing id: TabID?, stiffness: CGFloat = 300, velocity: CGFloat = -2.5,
                       then: (() -> Void)? = nil) {
        finishSwipeNow()
        finishZoomNow()
        guard pinch == nil else { return }
        guard let stage, stage.window != nil else {
            setOverviewFlag(false)
            return
        }
        zoomTab = id
        stage.busy = false
        stage.sync()
        stage.busy = true
        zoom.interactive = true
        setZoom(1)
        setOverviewFlag(false)
        settleZoom(to: 0, velocity: velocity, stiffness: stiffness, then: then)
    }

    /// Called by the store whenever `overviewShown` changes. When something other than this class
    /// changed it, snap to the matching state.
    func overviewFlagChanged(_ shown: Bool) {
        guard !settingOverviewFlag else { return }
        zoomSpring = nil
        zoomCompletion = nil
        if settle == nil { stopTicker() }
        pinch = nil
        restZoom(overview: shown)
    }

    // MARK: New tab from a link (NewTabHop.swift)

    /// A link that opens a new tab zooms out to the map, shows the new card landing in its row,
    /// then zooms into it. Off: the new page just slides in.
    static let newTabHopKey = "newTabHop"
    private var newTabHopEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.newTabHopKey) as? Bool) ?? true
    }
    /// Each half of the hop is snappier than a pinch settling; the whole hop is about 0.6 s.
    private static let hopStiffness: CGFloat = 1100
    /// How long the map stays up so the new card can be seen popping into its row.
    private static let hopPause: TimeInterval = 0.18
    private var hopStep: DispatchWorkItem?

    /// A link on `parent`, the page on stage, opened `child` (already in the map, not yet current).
    /// Zooms out to the map, pops the new card in, then zooms into it and makes it current.
    /// False when the hop can't run right now; the caller then switches to the tab itself.
    func hopToNewTab(_ child: TabID, from parent: TabID) -> Bool {
        guard newTabHopEnabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let stage, stage.window != nil, !stage.isHidden, !store.overviewShown,
              !zoom.interactive, scrollState != .engaged, pinch == nil, settle == nil, zoomSpring == nil,
              !AppDock.shared.isFront,
              store.map.activeTabID == parent,
              stage.current == PageKey(store.map.screenID(of: parent))
        else { return false }
        hopStep?.cancel()
        store.prepareOverview()
        NewTabArrival.shared.arriving = child
        zoomTab = parent
        stage.busy = true
        zoom.interactive = true
        setZoom(0)
        settleZoom(to: 1, velocity: 7, stiffness: Self.hopStiffness) { [weak self] in
            self?.hopShowCard(child)
        }
        return true
    }

    /// The map is up: bring the new card into view, let it pop in, then zoom into it.
    private func hopShowCard(_ child: TabID) {
        guard store.overviewShown, store.map.tab(child)?.isClosed == false else { hopEnd(); return }
        // Selecting it outlines it and scrolls it into view if the row runs off screen.
        store.overviewSelection = child
        let step = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hopStep = nil
            // Anything the user did meanwhile (Esc, picking another card, a pinch) wins.
            guard self.store.overviewShown, !self.zoom.interactive, self.pinch == nil,
                  self.store.map.tab(child)?.isClosed == false else { self.hopEnd(); return }
            self.store.activate(child, commit: true)
            self.closeOverview(showing: child, stiffness: Self.hopStiffness, velocity: -7) { [weak self] in
                self?.hopEnd()
            }
            self.store.focusPage()
        }
        hopStep = step
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hopPause, execute: step)
    }

    private func hopEnd() {
        hopStep = nil
        NewTabArrival.shared.arriving = nil
    }
}
