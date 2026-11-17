import AppKit
import SwiftUI
import WebKit
import TabMapCore

// The page stage is the part of the window that shows web pages. It is plain AppKit so that
// two pages can be on screen at once and follow the fingers during a swipe, and so that the
// current page can be scaled down into its card when zooming out to the map.
//
//   PageStageView
//     backdrop          the gap seen between two pages during a swipe
//     zoomBox           carries the zoom transform; holds the page layers
//       PageLayerView   one per tab on stage: the live web view, a thumbnail, or the start page

/// What a page layer stands for: a tab, or the start page shown when there is no tab at all.
enum PageKey: Hashable {
    case empty
    case tab(TabID)

    init(_ id: TabID?) {
        if let id { self = .tab(id) } else { self = .empty }
    }

    var tabID: TabID? {
        if case .tab(let id) = self { return id }
        return nil
    }
}

/// A view that fills itself with one system colour and follows light and dark mode.
final class FillView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

/// A tab's saved thumbnail stretched to the page width, standing in for a page that is not in memory.
final class SnapshotView: NSView {
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let imageSize: CGSize

    init(image: NSImage?, title: String) {
        imageSize = image?.size ?? .zero
        super.init(frame: .zero)
        if let image, imageSize.width > 1 {
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            addSubview(imageView)
        } else {
            label.stringValue = title
            label.font = .systemFont(ofSize: 20, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        relayout()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        if imageSize.width > 1 {
            // Full width, natural height, pinned to the top like the page it stands for.
            let height = bounds.width * imageSize.height / imageSize.width
            imageView.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        } else {
            label.frame = CGRect(x: 40, y: bounds.midY - 16, width: max(0, bounds.width - 80), height: 32)
        }
    }
}

/// One page on the stage.
final class PageLayerView: NSView {
    let key: PageKey
    private weak var store: BrowserStore?

    private enum Kind { case none, web, start, placeholder, split }
    private var splitContent: SplitContentView?
    private var kind = Kind.none
    private weak var webView: WKWebView?
    private var startHost: NSView?
    /// The thumbnail. Alone it is a placeholder; over a web view it hides the page until it has drawn.
    private var cover: NSView?
    private var coverTask: Task<Void, Never>?

    init(key: PageKey, store: BrowserStore) {
        self.key = key
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for view in subviews { view.frame = bounds }
    }

    /// True when a live page is showing (as opposed to a thumbnail or the start page).
    var showsWeb: Bool { kind == .web || kind == .split }

    /// Brings the layer in line with what the store has for this tab right now.
    func refresh() {
        guard let store else { return }
        if let id = key.tabID, let pair = store.map.split(containing: id) {
            showSplit(pair, store)
            return
        }
        if kind == .split { clear() }
        guard let id = key.tabID, let tab = store.map.tab(id), !tab.isBlank else {
            showStart(store)
            return
        }
        if let page = store.page(for: id) {
            showWeb(page.webView)
        } else {
            showPlaceholder(store, tab)
        }
    }

    private func showStart(_ store: BrowserStore) {
        if kind == .start, startHost?.superview === self { return }
        clear()
        let host = NSHostingView(rootView: StartView()
            .environmentObject(store)
            .environmentObject(store.favicons))
        host.frame = bounds
        addSubview(host)
        startHost = host
        kind = .start
    }

    private func showPlaceholder(_ store: BrowserStore, _ tab: MapTab) {
        if kind == .placeholder, cover?.superview === self { return }
        clear()
        let snapshot = SnapshotView(image: store.snapshot(for: tab.id), title: tab.displayTitle)
        snapshot.frame = bounds
        addSubview(snapshot)
        cover = snapshot
        kind = .placeholder
    }

    private func showWeb(_ webView: WKWebView) {
        if kind == .web, self.webView === webView, webView.superview === self { return }
        // Coming from a thumbnail: keep it on top until the page has something to show.
        let keepCover = kind == .placeholder && cover != nil
        if !keepCover { clear() }
        startHost?.removeFromSuperview()
        startHost = nil
        webView.frame = bounds
        webView.autoresizingMask = []
        if let cover, keepCover {
            addSubview(webView, positioned: .below, relativeTo: cover)
            liftCover(whenReady: webView)
        } else {
            addSubview(webView)
        }
        self.webView = webView
        kind = .web
    }

    private func liftCover(whenReady webView: WKWebView) {
        coverTask?.cancel()
        coverTask = Task { @MainActor [weak self, weak webView] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard self != nil, let webView else { return }
                let elapsed = Date().timeIntervalSince(started)
                let drawn = webView.estimatedProgress >= 0.8 || (!webView.isLoading && elapsed >= 0.6)
                if (elapsed >= 0.3 && drawn) || elapsed >= 4 { break }
            }
            guard !Task.isCancelled, let self, let cover = self.cover, self.kind == .web else { return }
            self.cover = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                cover.animator().alphaValue = 0
            }, completionHandler: {
                cover.removeFromSuperview()
            })
        }
    }

    private func showSplit(_ pair: SplitPair, _ store: BrowserStore) {
        if kind == .split, let splitContent, splitContent.shows(pair) {
            splitContent.refresh()
            return
        }
        clear()
        let content = SplitContentView(pair: pair, store: store)
        content.frame = bounds
        addSubview(content)
        splitContent = content
        kind = .split
        content.refresh()
    }

    private func clear() {
        coverTask?.cancel()
        coverTask = nil
        cover?.removeFromSuperview()
        cover = nil
        startHost?.removeFromSuperview()
        startHost = nil
        if let webView, webView.superview === self { webView.removeFromSuperview() }
        webView = nil
        splitContent?.teardown()
        splitContent?.removeFromSuperview()
        splitContent = nil
        kind = .none
    }

    /// Lets go of the web view (the store owns it) before the layer is thrown away.
    func teardown() {
        clear()
    }
}

/// Shows the current page, and a second one while a swipe is under way.
final class PageStageView: NSView {
    private weak var store: BrowserStore?
    private let backdrop = FillView(color: .underPageBackgroundColor)
    private let zoomBox = NSView()
    private let zoomMask = CALayer()
    private var layers: [PageKey: PageLayerView] = [:]

    private(set) var current: PageKey?
    private(set) var incoming: PageKey?

    /// Set by the gesture navigator while it is moving things; the stage then leaves the layout alone.
    var busy = false

    /// Gap between two pages during a swipe.
    static let gap: CGFloat = 28

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        backdrop.isHidden = true
        addSubview(backdrop)
        zoomBox.wantsLayer = true
        addSubview(zoomBox)
        zoomMask.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !busy else { return }
        settle()
    }

    /// Puts everything in its resting place: the current page fills the stage, the rest is parked out of sight.
    private func settle() {
        backdrop.frame = bounds
        backdrop.isHidden = true
        resetZoom()
        zoomBox.frame = bounds
        for (key, view) in layers {
            if key == current {
                view.frame = bounds
            } else {
                park(view)
            }
        }
    }

    /// Out of sight but still in the window, so a thumbnail can still be taken of it.
    private func park(_ view: NSView) {
        view.frame = CGRect(x: -bounds.width - 4000, y: 0, width: bounds.width, height: bounds.height)
    }

    private func layerView(for key: PageKey) -> PageLayerView? {
        if let view = layers[key] { return view }
        guard let store else { return nil }
        let view = PageLayerView(key: key, store: store)
        layers[key] = view
        park(view)
        zoomBox.addSubview(view)
        return view
    }

    // MARK: Following the store

    /// Shows whatever tab the store says is current. Does nothing in the middle of a gesture.
    func sync() {
        guard !busy, let store else { return }
        let want = screenKey(PageKey(store.map.activeTabID))
        if current != want {
            display(want)
        } else {
            layers[want]?.refresh()
        }
    }

    /// Makes `key` the page on stage, without any animation.
    /// A split pair is one page on the stage, named after its left tab.
    private func screenKey(_ key: PageKey) -> PageKey {
        guard let store, let id = key.tabID else { return key }
        return PageKey(store.map.screenID(of: id))
    }

    func display(_ key: PageKey) {
        let key = screenKey(key)
        incoming = nil
        current = key
        layerView(for: key)?.refresh()
        settle()
        schedulePrune()
    }

    func refreshCurrent() {
        if let current { layers[current]?.refresh() }
    }

    /// True when the page on stage is a live web page.
    var currentShowsWeb: Bool {
        guard let current else { return false }
        return layers[current]?.showsWeb ?? false
    }

    private func schedulePrune() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.prune()
        }
    }

    /// Drops layers that are no longer on stage.
    private func prune() {
        guard !busy else { return }
        for (key, view) in layers where key != current && key != incoming {
            view.teardown()
            view.removeFromSuperview()
            layers[key] = nil
        }
    }

    // MARK: Swiping

    /// Gets a neighbouring page ready beside the current one. `nil` clears it.
    func setIncoming(_ key: PageKey?) {
        let key = key.map(screenKey)
        if let old = incoming, old != key, old != current, let view = layers[old] { park(view) }
        incoming = key
        if let key { layerView(for: key)?.refresh() }
    }

    /// Positions the pages for a swipe. `offset` is how far the current page has moved on screen:
    /// positive is right (horizontal) or down (vertical). `side` says where the incoming page sits
    /// relative to the current one: +1 to its right or below it, -1 to its left or above it.
    func applySwipe(horizontal: Bool, offset: CGFloat, side: CGFloat) {
        let size = bounds.size
        backdrop.frame = bounds
        backdrop.isHidden = false
        if let current, let view = layers[current] {
            view.frame = CGRect(origin: Self.origin(horizontal, offset), size: size)
        }
        if let incoming, let view = layers[incoming] {
            let distance = (horizontal ? size.width : size.height) + Self.gap
            view.frame = CGRect(origin: Self.origin(horizontal, offset + side * distance), size: size)
        }
    }

    /// Screen offsets to AppKit's coordinates, where y grows upwards.
    private static func origin(_ horizontal: Bool, _ offset: CGFloat) -> CGPoint {
        horizontal ? CGPoint(x: offset, y: 0) : CGPoint(x: 0, y: -offset)
    }

    /// Ends a swipe. With `commit`, the incoming page becomes the current one.
    func finishSwipe(commit: Bool) {
        if commit, let incoming {
            current = incoming
        }
        incoming = nil
        settle()
        schedulePrune()
    }

    // MARK: Zooming

    /// Scales the current page between filling the stage (`progress` 0) and sitting on its card in
    /// the map (`progress` 1). `card` is the card's thumbnail in stage coordinates, when it is known.
    func applyZoom(_ progress: CGFloat, card: CGRect?) {
        let width = bounds.width, height = bounds.height
        guard width > 1, height > 1, let layer = zoomBox.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard progress > 0.0005 else {
            layer.setAffineTransform(.identity)
            layer.mask = nil
            zoomBox.alphaValue = 1
            return
        }
        let target = card ?? CGRect(x: width * 0.36, y: height * 0.36, width: width * 0.28, height: height * 0.28)
        let p = min(1, progress)
        let rect = CGRect(x: target.minX * p,
                          y: target.minY * p,
                          width: width + (target.width - width) * p,
                          height: height + (target.height - height) * p)
        let scale = max(rect.width / width, 0.01)
        // The card shows the top of the page, so the page keeps its top edge and loses its bottom.
        let visibleHeight = min(height, rect.height / scale)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY - height * scale)
        let anchor = CGPoint(x: layer.anchorPoint.x * width, y: layer.anchorPoint.y * height)
        let tx = bottomLeft.x - layer.position.x + scale * anchor.x
        let ty = bottomLeft.y - layer.position.y + scale * anchor.y
        layer.setAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty))

        zoomMask.frame = CGRect(x: 0, y: height - visibleHeight, width: width, height: visibleHeight)
        zoomMask.cornerRadius = 8 * p / scale
        if layer.mask !== zoomMask { layer.mask = zoomMask }
        // Over the last stretch the page melts into its card.
        zoomBox.alphaValue = p < 0.88 ? 1 : max(0, (1 - p) / 0.12)
    }

    func resetZoom() {
        guard let layer = zoomBox.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(.identity)
        layer.mask = nil
        CATransaction.commit()
        zoomBox.alphaValue = 1
    }
}

/// The SwiftUI face of the stage.
struct PageStage: NSViewRepresentable {
    @EnvironmentObject private var store: BrowserStore

    func makeNSView(context: Context) -> PageStageView {
        let stage = PageStageView(store: store)
        GestureNavigator.shared.stage = stage
        stage.sync()
        return stage
    }

    func updateNSView(_ stage: PageStageView, context: Context) {
        stage.sync()
    }
}
