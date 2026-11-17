import AppKit
import WebKit
import TabMapCore

// The side-by-side view of a split pair. It lives inside one page layer of the page stage, so a
// pair behaves like a single page everywhere else: it slides as one during a swipe and shrinks as
// one into the map.
//
//   PageLayerView (for the pair's left tab)
//     SplitContentView
//       SplitPaneView     left page
//       SplitPaneView     right page
//       SplitDividerView  the line between them; drag to resize, drag to an edge to end the split

/// One half of a split: a tab's live page, or its thumbnail while the page is not in memory.
final class SplitPaneView: NSView {
    let tabID: TabID
    private weak var store: BrowserStore?
    private weak var webView: WKWebView?
    private var placeholder: NSView?
    /// A thin accent line along the top of the half the address bar is talking to.
    private let focusBar = SplitTintView(color: .controlAccentColor)

    init(tabID: TabID, store: BrowserStore) {
        self.tabID = tabID
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        focusBar.alphaValue = 0
        addSubview(focusBar)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        if let webView, webView.superview === self { webView.frame = bounds }
        placeholder?.frame = bounds
        focusBar.frame = CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
    }

    /// Brings the half in line with what the store has for its tab right now.
    func refresh(showFocus: Bool) {
        guard let store else { return }
        if let page = store.page(for: tabID) {
            let view = page.webView
            if view.superview !== self {
                view.autoresizingMask = []
                view.frame = bounds
                addSubview(view, positioned: .below, relativeTo: focusBar)
            }
            webView = view
            placeholder?.removeFromSuperview()
            placeholder = nil
        } else if placeholder == nil {
            if let webView, webView.superview === self { webView.removeFromSuperview() }
            webView = nil
            let title = store.map.tab(tabID)?.displayTitle ?? ""
            let snapshot = SnapshotView(image: store.snapshot(for: tabID), title: title)
            snapshot.frame = bounds
            addSubview(snapshot, positioned: .below, relativeTo: focusBar)
            placeholder = snapshot
        }
        let alpha: CGFloat = showFocus ? 1 : 0
        if focusBar.alphaValue != alpha {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                focusBar.animator().alphaValue = alpha
            }
        }
    }

    /// Lets go of the web view (the store owns it) before the half is thrown away.
    func teardown() {
        if let webView, webView.superview === self { webView.removeFromSuperview() }
        webView = nil
        placeholder?.removeFromSuperview()
        placeholder = nil
    }
}

/// A view filled with one colour that may be see-through.
final class SplitTintView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill(using: .sourceOver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The line between the two halves. Wider than it looks, so it is easy to grab.
final class SplitDividerView: NSView {
    static let grabWidth: CGFloat = 9

    /// Called with the pointer's x in the split's coordinates while dragging.
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var dragging = false

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        CGRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill(using: .sourceOver)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let parent = superview else { return }
        onDrag?(parent.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDragEnded?()
    }
}

/// Two pages side by side.
final class SplitContentView: NSView {
    private(set) var pair: SplitPair
    private weak var store: BrowserStore?
    private let leftPane: SplitPaneView
    private let rightPane: SplitPaneView
    private let divider = SplitDividerView()

    /// Where the divider is while it is being dragged, as a share of the width.
    private var dragFraction: CGFloat?
    private var lastActive: TabID?
    private var flashUntil = Date.distantPast
    private var flashTask: Task<Void, Never>?

    /// Dragging the divider this close to an edge ends the split in favour of the larger page.
    private static let collapseBelow: CGFloat = 0.14

    init(pair: SplitPair, store: BrowserStore) {
        self.pair = pair
        self.store = store
        leftPane = SplitPaneView(tabID: pair.left, store: store)
        rightPane = SplitPaneView(tabID: pair.right, store: store)
        super.init(frame: .zero)
        addSubview(leftPane)
        addSubview(rightPane)
        addSubview(divider)
        lastActive = store.map.activeTabID

        divider.onDrag = { [weak self] x in self?.dragged(to: x) }
        divider.onDragEnded = { [weak self] in self?.dragEnded() }
        divider.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.store?.setSplitFraction(0.5, for: self.pair.left)
        }
        SplitFocusMonitor.shared.install()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPanes()
    }

    func shows(_ other: SplitPair) -> Bool {
        other.left == pair.left && other.right == pair.right
    }

    private func layoutPanes() {
        let width = bounds.width, height = bounds.height
        let fraction = dragFraction ?? CGFloat(pair.fraction)
        let x = (width * fraction).rounded()
        leftPane.frame = CGRect(x: 0, y: 0, width: max(0, x), height: height)
        rightPane.frame = CGRect(x: x + 1, y: 0, width: max(0, width - x - 1), height: height)
        let grab = SplitDividerView.grabWidth
        divider.frame = CGRect(x: x - floor(grab / 2), y: 0, width: grab, height: height)
        window?.invalidateCursorRects(for: divider)
    }

    /// Follows the store: the divider position, which half is current, and each half's page.
    func refresh() {
        guard let store else { return }
        if let live = store.map.split(containing: pair.left), shows(live), live.fraction != pair.fraction {
            pair = live
            if dragFraction == nil { layoutPanes() }
        }
        let active = store.map.activeTabID
        if active != lastActive {
            lastActive = active
            flashFocus()
        }
        let show = store.chromeExpanded || Date() < flashUntil
        leftPane.refresh(showFocus: show && active == pair.left)
        rightPane.refresh(showFocus: show && active == pair.right)
    }

    /// Shows for a moment which half has just become the current one.
    private func flashFocus() {
        flashUntil = Date().addingTimeInterval(1.2)
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func teardown() {
        flashTask?.cancel()
        leftPane.teardown()
        rightPane.teardown()
    }

    // MARK: Divider

    private func dragged(to x: CGFloat) {
        guard bounds.width > 1 else { return }
        let fraction = min(0.96, max(0.04, x / bounds.width))
        dragFraction = fraction
        // The half that is about to go fades, so letting go here is no surprise.
        leftPane.alphaValue = fraction < Self.collapseBelow ? 0.35 : 1
        rightPane.alphaValue = fraction > 1 - Self.collapseBelow ? 0.35 : 1
        layoutPanes()
    }

    private func dragEnded() {
        guard let fraction = dragFraction else { return }
        dragFraction = nil
        leftPane.alphaValue = 1
        rightPane.alphaValue = 1
        if fraction < Self.collapseBelow {
            store?.unsplit(pair.left, keep: pair.right)
        } else if fraction > 1 - Self.collapseBelow {
            store?.unsplit(pair.left, keep: pair.left)
        } else {
            let range = SplitPair.fractionRange
            pair.fraction = min(range.upperBound, max(range.lowerBound, Double(fraction)))
            store?.setSplitFraction(pair.fraction, for: pair.left)
            layoutPanes()
        }
    }
}

/// Clicking in a half of a split makes that tab the current one, so the address bar, back and
/// forward, and reload all follow the page you are working in.
@MainActor
final class SplitFocusMonitor {
    static let shared = SplitFocusMonitor()
    private var token: Any?

    private init() {}

    func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { SplitFocusMonitor.shared.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard let content = event.window?.contentView else { return }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let current = view {
            if let pane = current as? SplitPaneView {
                // The click itself gives the page the keyboard.
                BrowserStore.shared.focusPane(pane.tabID, takeKeyboard: false)
                return
            }
            view = current.superview
        }
    }
}
