import AppKit
import SwiftUI
import WebKit
import TabMapCore

/// Picture in picture for videos (⌥⌘P, or the button in the island when a page has a video).
///
/// Uses WebKit's own floating video window, so it behaves like Safari's: it stays on top of other
/// apps, can be moved to any corner, and has its own play and close controls.
/// With "pop out playing videos" on (the default), leaving a tab while its video plays sends the
/// video into picture in picture, and coming back to the tab brings it back into the page.
/// Hooks elsewhere: `prepare(_:)` in WebTab's configuration, `leaving`/`arrived` in BrowserStore,
/// a menu item, a Settings toggle and a button in the island.
@MainActor
final class PictureInPicture: ObservableObject {
    static let shared = PictureInPicture()
    static let autoKey = "autoPictureInPicture"

    /// Whether the page in front has a video to pop out. Refreshed when the island opens.
    @Published private(set) var frontHasVideo = false

    /// Tabs whose video went into picture in picture on its own when you left them.
    private var autoTabs: Set<TabID> = []
    private let world = WKContentWorld.world(name: "TabmapPiP")

    private var autoEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
    }

    /// Picture in picture is on by default in WebKit on the Mac; this makes sure of it where the
    /// switch exists, without touching anything that is not there.
    static func prepare(_ config: WKWebViewConfiguration) {
        // Key-value coding finds the private `_set...:` setter and passes a real BOOL.
        if config.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) {
            config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
    }

    // MARK: Actions

    /// Pops the main video on the front page out, or brings it back if it is already out.
    func toggleFront() {
        guard let webView = BrowserStore.shared.frontWebView else { return }
        run("toggle", in: webView) { reply in
            if (reply?["ok"] as? Bool) != true { NSSound.beep() }
        }
        if let id = BrowserStore.shared.map.activeTabID, !AppDock.shared.isFront { autoTabs.remove(id) }
    }

    func refreshFront() {
        guard let webView = BrowserStore.shared.frontWebView else {
            frontHasVideo = false
            return
        }
        run("probe", in: webView) { [weak self] reply in
            self?.frontHasVideo = (reply?["video"] as? Bool) ?? false
        }
    }

    /// The map is about to move away from `id`. Called before its page leaves the screen, while the
    /// video can still be handed over smoothly.
    func leaving(_ id: TabID) {
        guard autoEnabled, let webView = BrowserStore.shared.page(for: id)?.webView else { return }
        run("auto-out", in: webView) { [weak self] reply in
            if (reply?["ok"] as? Bool) == true { self?.autoTabs.insert(id) }
        }
    }

    /// The map came back to `id`: a video that left on its own returns to the page.
    func arrived(_ id: TabID) {
        guard autoTabs.remove(id) != nil, let webView = BrowserStore.shared.page(for: id)?.webView else { return }
        run("auto-in", in: webView) { _ in }
    }

    private func run(_ action: String, in webView: WKWebView, done: @escaping ([String: Any]?) -> Void) {
        webView.callAsyncJavaScript(Self.script, arguments: ["action": action], in: nil, in: world) { result in
            let reply: [String: Any]?
            if case .success(let value) = result { reply = value as? [String: Any] } else { reply = nil }
            Task { @MainActor in done(reply) }
        }
    }

    // Body of an async function. Argument: action ("probe" | "toggle" | "auto-out" | "auto-in").
    private static let script = #"""
    const videos = Array.from(document.querySelectorAll("video"));
    const inPiP = (v) => document.pictureInPictureElement === v
        || (v.webkitPresentationMode && v.webkitPresentationMode === "picture-in-picture");
    const area = (v) => { const r = v.getBoundingClientRect(); return r.width * r.height; };
    const playing = (v) => !v.paused && !v.ended && v.readyState > 2;
    const current = videos.find(inPiP);

    const enter = async (v) => {
        v.removeAttribute("disablepictureinpicture");
        try { v.disablePictureInPicture = false; } catch (e) {}
        if (v.requestPictureInPicture && document.pictureInPictureEnabled !== false) {
            try { await v.requestPictureInPicture(); return true; } catch (e) {}
        }
        if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode("picture-in-picture")) {
            v.webkitSetPresentationMode("picture-in-picture");
            return true;
        }
        return false;
    };
    const leave = async (v) => {
        if (document.pictureInPictureElement === v && document.exitPictureInPicture) {
            try { await document.exitPictureInPicture(); return true; } catch (e) {}
        }
        if (v.webkitSetPresentationMode) { v.webkitSetPresentationMode("inline"); return true; }
        return false;
    };
    // The video you are most likely watching: one that is playing, else the biggest one with something loaded.
    const pick = () => {
        const ready = videos.filter((v) => v.readyState > 0 && area(v) > 0);
        const live = ready.filter(playing);
        const pool = live.length ? live : ready;
        return pool.sort((a, b) => area(b) - area(a))[0] || null;
    };

    if (action === "probe") return { video: videos.some((v) => v.readyState > 0 || v.src || v.querySelector("source")) };
    if (action === "auto-in") return { ok: current ? await leave(current) : false };
    if (action === "auto-out") {
        // Only a video that is playing with sound and big enough to be the point of the page.
        if (current) return { ok: false };
        const v = videos.filter((v) => playing(v) && !v.muted && v.volume > 0 && area(v) > 200 * 120)
            .sort((a, b) => area(b) - area(a))[0];
        return { ok: v ? await enter(v) : false };
    }
    if (current) return { ok: await leave(current) };
    const v = pick();
    return { ok: v ? await enter(v) : false };
    """#
}
