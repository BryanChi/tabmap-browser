import SwiftUI
import WebKit
import TabMapCore

/// A slim strip above the page on the search engine's results page: the same query on YouTube,
/// Amazon, Gemini and others, one click away. Click loads it in this tab; ⌘-click opens it beside in the background, ⇧⌘-click goes there.
struct SearchSwitchBar: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var dock = AppDock.shared

    static let height: CGFloat = 30

    var body: some View {
        let query = dock.isFront ? nil
            : SearchSwitch.query(in: store.map.activeTab?.url, searchTemplate: store.map.settings.searchTemplate)
        ZStack {
            if let query {
                SearchSwitchStrip(query: query, leadingRoom: leadingRoom)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: query != nil)
        .modifier(FadesIntoOverview())
    }

    /// With no tab bar or sidebar, the strip is the top edge of the window: leave the window buttons room.
    private var leadingRoom: CGFloat {
        store.tabBarShown || store.sidebarShown ? 8 : TabBarStyle.trafficLightRoom
    }
}

private struct SearchSwitchStrip: View {
    @EnvironmentObject private var store: BrowserStore
    let query: String
    let leadingRoom: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            WindowDragArea().frame(width: leadingRoom)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(SearchSwitch.targets(excludingEngine: store.map.settings.searchTemplate)) { target in
                        SearchSwitchChip(target: target) { newTab in go(target, newTab: newTab) }
                    }
                }
                .padding(.horizontal, 2)
            }
            WindowDragArea().frame(minWidth: 8, maxWidth: .infinity)
        }
        .frame(height: SearchSwitchBar.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func go(_ target: SearchSwitch.Target, newTab: Bool) {
        guard let url = SearchSwitch.url(for: target, query: query) else { return }
        if newTab, let id = store.map.activeTabID {
            store.openChild(of: id, url: url, activate: NSEvent.modifierFlags.contains(.shift))
        } else {
            store.activeWebTab?.load(url)
        }
    }
}

private struct SearchSwitchChip: View {
    @EnvironmentObject private var favicons: FaviconStore
    let target: SearchSwitch.Target
    let action: (_ newTab: Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let iconURL = target.host.flatMap { URL(string: "https://\($0)/") }
        Button {
            action(NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(spacing: 5) {
                Group {
                    if let icon = favicons.icon(for: iconURL) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "magnifyingglass").resizable().scaledToFit().padding(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 13, height: 13)
                Text(target.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Search \(target.name) for this (⌘-click: new tab)")
    }
}

/// Types the query into a chat site that has no search address (Gemini) and sends it.
/// The query arrives in the fragment (`#tabmap-q=`), so it never reaches the site's server in a URL.
@MainActor
enum SearchSwitchComposer {
    private static let world = WKContentWorld.world(name: "tabmap-search-switch")
    private static let marker = "/*tabmap-search-switch*/"

    static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: marker + script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
    }

    private static let script = """
    (() => {
      const key = '#\(SearchSwitch.fragmentKey)=';
      if (!location.hash.startsWith(key)) return;
      if (['gemini.google.com'].indexOf(location.hostname) < 0) return;
      let text;
      try { text = decodeURIComponent(location.hash.slice(key.length)); } catch (_) { return; }
      history.replaceState(history.state, '', location.pathname + location.search);
      if (!text.trim()) return;
      const visible = e => { const r = e.getBoundingClientRect(); return r.width > 80 && r.height > 10; };
      const find = () => [...document.querySelectorAll(
        'rich-textarea [contenteditable="true"], .ql-editor[contenteditable="true"], [contenteditable="true"][role="textbox"], textarea')]
        .filter(visible)[0];
      const send = () => [...document.querySelectorAll('button[aria-label*="Send" i], button.send-button')]
        .find(b => !b.disabled && b.getAttribute('aria-disabled') !== 'true' && visible(b));
      let tries = 0;
      const timer = setInterval(() => {
        if (++tries > 60) return clearInterval(timer);
        const box = find();
        if (!box) return;
        clearInterval(timer);
        box.focus();
        if (box.tagName === 'TEXTAREA') {
          Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(box, text);
          box.dispatchEvent(new Event('input', { bubbles: true }));
        } else {
          document.execCommand('insertText', false, text);
        }
        let waits = 0;
        const go = setInterval(() => {
          const b = send();
          if (b) { clearInterval(go); b.click(); }
          else if (++waits > 20) clearInterval(go);
        }, 150);
      }, 200);
    })();
    """
}
