import AppKit
import SwiftUI
import TabMapCore
import WebKit

/// Address and card autofill.
///
/// A script in its own world (pages cannot see or fake it) describes the form around whichever
/// field gets focus. The rules in TabMapCore work out what each field asks for; if it is an
/// address or card form, a pill under the island offers the saved addresses or cards. Choosing
/// one fills that form in that frame only. Cards ask for Touch ID or the Mac's password every
/// time, and the security code is never filled or kept: the cursor lands in its field instead.
/// After a form is sent with a new card or address, the pill offers to save it.
///
/// Hooks elsewhere: `FormAutofill.shared.install(in:)` in `WebTab.makeConfiguration`,
/// `AutofillIsland()` in ContentView, `AutofillSettingsSection()` in SettingsView.
@MainActor
final class FormAutofill: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = FormAutofill()
    static let handlerName = "tabmapAutofill"

    enum Offer: Equatable {
        case none
        case address(host: String, choices: [AutofillAddress])
        case card(host: String, choices: [CardSummary])
        case saveAddress(host: String, address: AutofillAddress)
        case saveCard(host: String, card: CardDetails)
        case notice(String)
    }

    @Published private(set) var offer: Offer = .none
    @Published var hovering = false

    let world = WKContentWorld.world(name: "TabmapAutofill")

    /// The form around the focused field, so a fill goes back to exactly that frame and form.
    private weak var focusedView: WKWebView?
    private var focusedFrame: WKFrameInfo?
    private var scanID = 0
    private var fields: [FormField] = []
    private var kinds: [Int: AutofillFieldKind] = [:]
    private var hideTask: Task<Void, Never>?
    private var lastSubmit: (key: Int, at: Date)?

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.formScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        controller.add(self, contentWorld: world, name: Self.handlerName)
    }

    // MARK: Messages from pages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView else { return }
        let origin = message.frameInfo.securityOrigin
        guard let host = LoginDomain.normalizedHost(origin.host) else { return }
        // Personal details only go to pages that arrived encrypted (and to this Mac's own servers).
        let secure = origin.protocol == "https" || host == "localhost" || host == "127.0.0.1"
        let store = AutofillStore.shared

        switch type {
        case "focus":
            guard secure, let scan = body["scan"] as? Int, let focused = body["focused"] as? Int,
                  let fields = Self.decodeFields(body["fields"]) else { return }
            let kinds = FieldClassifier.classify(fields)
            switch AutofillOffer.forFocus(focused, kinds: kinds) {
            case .address:
                guard store.addressesEnabled, !store.addresses.isEmpty else { return }
                remember(webView, message.frameInfo, scan, fields, kinds)
                show(.address(host: host, choices: store.addresses))
            case .card:
                guard store.cardsEnabled, !store.cards.isEmpty else { return }
                remember(webView, message.frameInfo, scan, fields, kinds)
                show(.card(host: host, choices: store.cards))
            case .none:
                break
            }
        case "blur":
            switch offer {
            case .address, .card: scheduleHide(after: 2.5)
            default: break
            }
        case "submit":
            guard secure, store.offerSaveEnabled, let fields = Self.decodeFields(body["fields"]) else { return }
            submitted(host: host, fields: fields)
        default:
            break
        }
    }

    private func remember(_ view: WKWebView, _ frame: WKFrameInfo, _ scan: Int, _ fields: [FormField],
                          _ kinds: [Int: AutofillFieldKind]) {
        focusedView = view
        focusedFrame = frame
        scanID = scan
        self.fields = fields
        self.kinds = kinds
    }

    private func submitted(host: String, fields: [FormField]) {
        // Clicking Pay and the form's own submit both report the same send.
        var hasher = Hasher()
        hasher.combine(host)
        for f in fields { hasher.combine(f.value) }
        let key = hasher.finalize()
        if let last = lastSubmit, last.key == key, Date().timeIntervalSince(last.at) < 5 { return }
        lastSubmit = (key, Date())

        let store = AutofillStore.shared
        let kinds = FieldClassifier.classify(fields)
        var next: Offer?
        if store.cardsEnabled, let card = AutofillPlanner.card(from: fields, kinds: kinds), store.matchingCard(card) == nil {
            next = .saveCard(host: host, card: card)
        } else if store.addressesEnabled, let address = AutofillPlanner.address(from: fields, kinds: kinds), !store.knows(address) {
            next = .saveAddress(host: host, address: address)
        }
        guard let next else { return }
        // Let the next page start first, so the pill does not flash over a form that was refused.
        hideTask?.cancel()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.show(next, hideAfter: 30)
        }
    }

    static func decodeFields(_ raw: Any?) -> [FormField]? {
        guard let raw, JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode([FormField].self, from: data)
    }

    // MARK: Actions from the pill

    func fill(_ address: AutofillAddress) {
        guard case .address = offer, let webView = focusedView, let frame = focusedFrame else { return }
        let values = AutofillPlanner.values(for: address, fields: fields, kinds: kinds)
        hide()
        Task { @MainActor in
            _ = try? await self.send(values, to: webView, frame: frame, card: false)
        }
    }

    func fill(_ card: CardSummary) {
        guard case .card(let host, _) = offer, let webView = focusedView, let frame = focusedFrame else { return }
        let fields = self.fields, kinds = self.kinds
        Task { @MainActor in
            do {
                let details = try await AutofillStore.shared.details(for: card, reason: "fill your \(card.masked) on \(host)")
                hide()
                let result = try await self.send(AutofillPlanner.values(for: details, fields: fields, kinds: kinds),
                                                 to: webView, frame: frame, card: true)
                if result?["csc"] as? Bool == true {
                    show(.notice("Type the security code from the back of your card"), hideAfter: 4)
                }
            } catch AutofillStore.StoreError.cancelled {
                // Declined Touch ID: leave the pill as it was.
            } catch {
                show(.notice("Could not fill: \(error.localizedDescription)"), hideAfter: 4)
            }
        }
    }

    private func send(_ values: [Int: String], to webView: WKWebView, frame: WKFrameInfo, card: Bool) async throws -> [String: Any]? {
        let byIndex = Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })
        let result = try await webView.callAsyncJavaScript(Self.fillCall,
                                                           arguments: ["scan": scanID, "values": byIndex, "card": card],
                                                           in: frame, contentWorld: world)
        return result as? [String: Any]
    }

    func confirmSave() {
        let store = AutofillStore.shared
        switch offer {
        case .saveCard(_, let card):
            do {
                let saved = try store.saveCard(card)
                show(.notice("Saved \(saved.masked) to your keychain"), hideAfter: 2.5)
            } catch {
                show(.notice("Could not save: \(error.localizedDescription)"), hideAfter: 4)
            }
        case .saveAddress(_, var address):
            if address.label.isEmpty { address.label = address.streetLines.first ?? "Address" }
            store.saveAddress(address)
            show(.notice("Saved the address"), hideAfter: 2)
        default:
            break
        }
    }

    func hide() {
        hideTask?.cancel()
        offer = .none
    }

    // MARK: Showing and hiding

    private func show(_ next: Offer, hideAfter seconds: Double? = nil) {
        hideTask?.cancel()
        offer = next
        if let seconds { scheduleHide(after: seconds) }
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.hovering { self.scheduleHide(after: 1.5) } else { self.offer = .none }
        }
    }

    // MARK: Page script

    /// Runs in the "TabmapAutofill" world in every frame. Never reads or sends the security code.
    private static let formScript = #"""
    (function () {
      if (window.__tabmapAutofill) { return; }
      window.__tabmapAutofill = true;
      const post = (m) => { try { webkit.messageHandlers.tabmapAutofill.postMessage(m); } catch (e) {} };
      const SKIP = /^(password|hidden|submit|button|checkbox|radio|file|image|reset|search|range|color)$/i;
      const CSC = /cvc|cvv|csc|cvn|security.?code|card.?verif/i;
      let scan = { id: 0, els: [], focused: null };
      let filling = false;

      function visible(el) {
        if (!el || el.disabled || el.readOnly) { return false; }
        const r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) { return false; }
        const s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
      }
      function clean(s) { return (s || '').replace(/\s+/g, ' ').trim().slice(0, 80); }
      function labelOf(el) {
        let t = '';
        if (el.labels && el.labels.length) { t = el.labels[0].innerText; }
        if (!t) { t = el.getAttribute('aria-label') || ''; }
        if (!t) {
          const ids = (el.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean);
          t = ids.map((i) => { const n = document.getElementById(i); return n ? n.innerText : ''; }).join(' ');
        }
        if (!t) { const p = el.closest('label'); if (p) { t = p.innerText; } }
        if (!t) {
          const prev = el.previousElementSibling;
          if (prev && /^(LABEL|SPAN|DIV|P)$/.test(prev.tagName) && prev.innerText.length < 60) { t = prev.innerText; }
        }
        return clean(t);
      }
      function isField(el) {
        if (el instanceof HTMLInputElement) { return !SKIP.test(el.type); }
        return el instanceof HTMLSelectElement || el instanceof HTMLTextAreaElement;
      }
      function isCSC(el) {
        return /cc-csc/.test(el.getAttribute('autocomplete') || '') || CSC.test((el.name || '') + ' ' + (el.id || '') + ' ' + labelOf(el));
      }
      function scopeOf(el) { return el.form || el.closest('form, [role=dialog], fieldset, main') || document.body || document.documentElement; }
      function signIn(scope) { return !!(scope.querySelector && scope.querySelector('input[type=password]')); }
      function describe(scope, withValues) {
        const els = Array.from(scope.querySelectorAll('input, select, textarea')).filter((el) => isField(el) && visible(el)).slice(0, 80);
        const fields = els.map((el, i) => {
          const f = {
            index: i, tag: el.tagName.toLowerCase(), type: (el.type || '').toLowerCase(),
            autocomplete: (el.getAttribute('autocomplete') || '').toLowerCase(),
            name: el.name || '', id: el.id || '', label: labelOf(el), placeholder: el.placeholder || '',
            maxLength: el.maxLength > 0 ? el.maxLength : -1,
          };
          if (el instanceof HTMLSelectElement) {
            f.options = Array.from(el.options).slice(0, 400).map((o) => ({ value: o.value, text: clean(o.text) }));
          }
          if (withValues && !isCSC(el)) {
            f.value = el.value || '';
            if (el instanceof HTMLSelectElement && el.selectedIndex >= 0) { f.selectedText = clean(el.options[el.selectedIndex].text); }
          }
          return f;
        });
        return { els, fields };
      }

      document.addEventListener('focusin', (e) => {
        const el = e.target;
        if (filling || !(el instanceof Element) || !isField(el)) { return; }
        const scope = scopeOf(el);
        if (signIn(scope)) { return; }
        const d = describe(scope, false);
        const focused = d.els.indexOf(el);
        if (focused < 0) { return; }
        scan = { id: scan.id + 1, els: d.els, focused: el };
        post({ type: 'focus', scan: scan.id, focused, fields: d.fields });
      }, true);
      document.addEventListener('focusout', (e) => {
        if (!filling && e.target instanceof Element && isField(e.target)) { post({ type: 'blur' }); }
      }, true);

      let lastSent = 0;
      function capture(from) {
        const now = Date.now();
        if (now - lastSent < 500) { return; }
        const scope = from ? scopeOf(from) : document.body;
        if (!scope || signIn(scope)) { return; }
        const d = describe(scope, true);
        if (!d.fields.some((f) => f.value)) { return; }
        lastSent = now;
        post({ type: 'submit', fields: d.fields });
      }
      document.addEventListener('submit', (e) => capture(e.target), true);
      document.addEventListener('click', (e) => {
        const b = e.target instanceof Element ? e.target.closest('button, input[type=submit], input[type=button], [role=button]') : null;
        if (!b) { return; }
        const text = (b.innerText || b.value || b.getAttribute('aria-label') || '').trim();
        if (b.type === 'submit' || /pay|place.?order|order|checkout|check out|purchase|buy|continue|next|save|submit|confirm|complete|add card|use this address|ship/i.test(text)) {
          capture(b);
        }
      }, true);

      window.__tabmapAutofillFill = function (id, values, card) {
        if (id !== scan.id) { return { filled: 0, csc: false }; }
        const setters = {
          INPUT: Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set,
          TEXTAREA: Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set,
          SELECT: Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set,
        };
        let filled = 0;
        filling = true;
        try {
          for (const key of Object.keys(values)) {
            const el = scan.els[Number(key)];
            if (!el || !el.isConnected || isCSC(el)) { continue; }
            // Text someone already typed stays, except in the field the fill was started from.
            if (el !== scan.focused && !(el instanceof HTMLSelectElement) && el.value) { continue; }
            setters[el.tagName].call(el, values[key]);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            filled += 1;
          }
        } finally {
          filling = false;
        }
        if (card) {
          const csc = scan.els.find((el) => el.isConnected && isCSC(el) && !el.value);
          if (csc) { csc.focus(); return { filled, csc: true }; }
        }
        return { filled, csc: false };
      };
    })();
    """#

    /// Body for `callAsyncJavaScript`; arguments arrive as variables, never pasted into source.
    private static let fillCall = "return window.__tabmapAutofillFill(scan, values, card);"
}

// MARK: - The pill

/// Sits under the island, below the password pill when both show.
struct AutofillIsland: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var autofill = FormAutofill.shared
    @ObservedObject private var passwords = PasswordAutofill.shared
    @ObservedObject private var find = FindController.shared
    @ObservedObject private var downloads = DownloadStore.shared

    private var topInset: CGFloat {
        var top: CGFloat = store.chromeExpanded ? 54 : 7
        if downloads.pillVisible { top += 38 }
        if find.shown { top += 40 }
        if passwords.offer != .none { top += 40 }
        return top
    }

    private var visible: Bool { autofill.offer != .none && !store.overviewShown }

    var body: some View {
        content
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minWidth: 240)
            .frame(height: 32)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .onHover { autofill.hovering = $0 }
            .scaleEffect(visible ? 1 : 0.5, anchor: .top)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: visible)
            .environment(\.colorScheme, .dark)
            .padding(.top, topInset)
    }

    @ViewBuilder private var content: some View {
        switch autofill.offer {
        case .none:
            Color.clear.frame(width: 240, height: 1)

        case .address(_, let choices):
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle").foregroundColor(.white.opacity(0.6))
                if choices.count == 1, let only = choices.first {
                    Button { autofill.fill(only) } label: { Text("Fill \(only.summary)").lineLimit(1) }
                } else {
                    Menu {
                        ForEach(choices) { address in
                            Button(address.summary) { autofill.fill(address) }
                        }
                    } label: { Text("Fill an address") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button { autofill.hide() } label: { Image(systemName: "xmark") }
            }

        case .card(_, let choices):
            HStack(spacing: 10) {
                Image(systemName: "creditcard.fill").foregroundColor(.white.opacity(0.6))
                if choices.count == 1, let only = choices.first {
                    Button { autofill.fill(only) } label: { Text("Fill \(only.summary)").lineLimit(1) }
                        .help("Asks for Touch ID, then fills the card. The security code is never saved.")
                } else {
                    Menu {
                        ForEach(choices) { card in
                            Button(card.summary + (card.isExpired() ? " (expired)" : "")) { autofill.fill(card) }
                        }
                    } label: { Text("Fill a card") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button { autofill.hide() } label: { Image(systemName: "xmark") }
            }

        case .saveCard(_, let card):
            HStack(spacing: 10) {
                Image(systemName: "creditcard.fill").foregroundColor(.white.opacity(0.6))
                Text("Save \(CardNumber.masked(brand: CardNumber.brand(card.number), last4: CardNumber.last4(card.number))) for next time?")
                    .lineLimit(1)
                Button("Save") { autofill.confirmSave() }
                Button("Not Now") { autofill.hide() }
            }

        case .saveAddress(_, let address):
            HStack(spacing: 10) {
                Image(systemName: "house.fill").foregroundColor(.white.opacity(0.6))
                Text("Save \(address.streetLines.first ?? "this address") for next time?").lineLimit(1)
                Button("Save") { autofill.confirmSave() }
                Button("Not Now") { autofill.hide() }
            }

        case .notice(let text):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundColor(.white.opacity(0.6))
                Text(text).lineLimit(1)
            }
        }
    }
}
