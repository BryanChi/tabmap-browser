import AppKit
import Security
import SwiftUI
import TabMapCore
import WebKit

/// Password autofill, saving, suggested passwords, and the passkey fallback.
///
/// A script in its own world (pages cannot see or fake it) watches for sign-in fields and form
/// submissions in every frame. When a sign-in field gets focus, a pill under the island offers the
/// saved logins for that frame's site; after a form is sent it offers to save or update the login;
/// in a new-password field it suggests a strong password. Filling only ever targets the frame
/// that asked, and only with logins for that frame's own site.
///
/// Hooks elsewhere: `PasswordAutofill.shared.install(in:)` in `WebTab.makeConfiguration`,
/// `PasswordIsland()` in ContentView, `PasswordSettingsSection()` in SettingsView.
@MainActor
final class PasswordAutofill: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = PasswordAutofill()
    static let handlerName = "tabmapPasswords"
    static let passkeyHandlerName = "tabmapPasskeys"

    /// What the pill is showing.
    enum Offer: Equatable {
        case none
        /// Saved logins for the focused sign-in field.
        case fill(host: String, logins: [SavedLogin])
        /// A strong password for a new-password field.
        case suggest(host: String, password: String)
        /// After a form was sent.
        case save(host: String, username: String, password: String, update: Bool, secure: Bool)
        /// Brief confirmation, e.g. after a suggested password was saved.
        case notice(String)
        /// A site asked for a passkey and this build cannot use them.
        case passkey(host: String, url: URL)
    }

    @Published private(set) var offer: Offer = .none
    @Published var hovering = false

    /// Where the focused sign-in field is, so a fill goes back to exactly that frame.
    private weak var focusedView: WKWebView?
    private var focusedFrame: WKFrameInfo?
    private var hideTask: Task<Void, Never>?
    /// The username a site asked for on a page before the password page ("identifier first"
    /// sign-ins such as Google and Apple), per site, so the password can be saved with it.
    private var recentUsernames: [String: (name: String, at: Date)] = [:]
    /// The last password suggested, so sending it saves without asking.
    private var suggested: (host: String, password: String)?
    private var lastSubmit: (key: String, at: Date)?

    let world = WKContentWorld.world(name: "TabmapPasswords")

    /// True when this build is signed with Apple's web-browser passkey entitlement; WebKit then
    /// handles passkeys itself and the fallback is not installed.
    static let hasPasskeyEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
        return (value as? Bool) == true
    }()

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.formScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        controller.add(self, contentWorld: world, name: Self.handlerName)
        if !Self.hasPasskeyEntitlement {
            controller.addUserScript(WKUserScript(source: Self.passkeyScript, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .page))
            controller.add(self, contentWorld: .page, name: Self.passkeyHandlerName)
        }
    }

    // MARK: Messages from pages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView else { return }
        let origin = message.frameInfo.securityOrigin
        guard let host = LoginDomain.normalizedHost(origin.host) else { return }
        let secure = origin.protocol == "https" || host == "localhost" || host == "127.0.0.1"

        if message.name == Self.passkeyHandlerName {
            if type == "passkey", let url = message.frameInfo.request.url ?? webView.url {
                show(.passkey(host: host, url: url), hideAfter: 12)
            }
            return
        }

        switch type {
        case "focus":
            guard secure else { return }
            focusedView = webView
            focusedFrame = message.frameInfo
            let kind = body["kind"] as? String ?? "login"
            if kind == "new" {
                guard PasswordStore.shared.autofillEnabled else { return }
                let password = (suggested?.host == host ? suggested?.password : nil) ?? PasswordGenerator.generate()
                show(.suggest(host: host, password: password))
            } else {
                guard PasswordStore.shared.autofillEnabled else { return }
                let logins = PasswordStore.shared.candidates(forHost: host)
                guard !logins.isEmpty else { return }
                show(.fill(host: host, logins: logins))
            }
        case "blur":
            switch offer {
            case .fill, .suggest: scheduleHide(after: 2.5)
            default: break
            }
        case "identifier":
            if let name = body["username"] as? String, !name.isEmpty, let site = LoginDomain.registrable(host) {
                recentUsernames[site] = (name, Date())
            }
        case "submit":
            submitted(host: host, secure: secure, body: body)
        default:
            break
        }
    }

    private func submitted(host: String, secure: Bool, body: [String: Any]) {
        let store = PasswordStore.shared
        guard store.offerSaveEnabled, let password = body["password"] as? String, !password.isEmpty else { return }
        var username = (body["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let site = LoginDomain.registrable(host) ?? host
        if username.isEmpty, let recent = recentUsernames[site], Date().timeIntervalSince(recent.at) < 600 {
            username = recent.name
        }
        // Clicking a button and pressing Return both report the same send.
        let key = "\(host)\u{1F}\(username)\u{1F}\(password.hashValue)"
        if let last = lastSubmit, last.key == key, Date().timeIntervalSince(last.at) < 3 { return }
        lastSubmit = (key, Date())

        // A password Tabmap suggested is saved without asking, as Safari does.
        if let s = suggested, s.host == host, s.password == password {
            suggested = nil
            if (try? store.save(host: host, username: username, password: password, secure: secure)) != nil {
                show(.notice("Saved the new password for \(host)"), hideAfter: 3)
            }
            return
        }
        let decision = SaveDecision.offer(username: username, password: password,
                                          existing: store.compare(host: host, password: password),
                                          neverSave: store.neverSave(host))
        switch decision {
        case .none: return
        case .save, .update:
            // Let the next page start loading first, so the pill does not flash on a failed sign-in
            // that clears the form and stays put; it still shows if the page does not move.
            hideTask?.cancel()
            let offer = Offer.save(host: host, username: username, password: password,
                                   update: decision == .update, secure: secure)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self.show(offer, hideAfter: 30)
            }
        }
    }

    // MARK: Actions from the pill

    func fill(_ login: SavedLogin) {
        guard case .fill(let host, _) = offer, let webView = focusedView, let frame = focusedFrame else { return }
        Task { @MainActor in
            do {
                let password = try await PasswordStore.shared.password(for: login, reason: "fill your password for \(host)")
                hide()
                _ = try await webView.callAsyncJavaScript(Self.fillCall,
                                                      arguments: ["username": login.username, "password": password, "mode": "login"],
                                                      in: frame, contentWorld: world)
            } catch PasswordStore.StoreError.cancelled {
                // Declined Touch ID: leave the pill as it was.
            } catch {
                show(.notice("Could not fill: \(error.localizedDescription)"), hideAfter: 4)
            }
        }
    }

    func useSuggested() {
        guard case .suggest(let host, let password) = offer, let webView = focusedView, let frame = focusedFrame else { return }
        suggested = (host, password)
        hide()
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(Self.fillCall,
                                                       arguments: ["username": "", "password": password, "mode": "new"],
                                                       in: frame, contentWorld: world)
        }
    }

    func confirmSave() {
        guard case .save(let host, let username, let password, _, let secure) = offer else { return }
        do {
            try PasswordStore.shared.save(host: host, username: username, password: password, secure: secure)
            show(.notice("Saved to your keychain"), hideAfter: 2)
        } catch {
            show(.notice("Could not save: \(error.localizedDescription)"), hideAfter: 4)
        }
    }

    func neverForSite() {
        guard case .save(let host, _, _, _, _) = offer else { return }
        PasswordStore.shared.addNeverSave(host)
        hide()
    }

    func openInSafari() {
        guard case .passkey(_, let url) = offer else { return }
        hide()
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
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

    // MARK: Page scripts

    /// Runs in the "TabmapPasswords" world in every frame.
    private static let formScript = #"""
    (function () {
      if (window.__tabmapPasswords) { return; }
      window.__tabmapPasswords = true;
      const post = (m) => { try { webkit.messageHandlers.tabmapPasswords.postMessage(m); } catch (e) {} };
      const USERISH = /user|login|email|e-mail|mail|account|identifier|phone|mobile|handle|signin/i;
      const TEXTY = /^(text|email|tel|)$/i;

      function visible(el) {
        if (!el || el.disabled || el.type === 'hidden') { return false; }
        const r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) { return false; }
        const s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
      }
      function scopeOf(el) { return el.form || el.closest('form, [role=dialog], main, body') || document; }
      function passwords(scope) {
        return Array.from(scope.querySelectorAll('input[type=password]')).filter(visible);
      }
      function ac(el) { return (el.getAttribute('autocomplete') || '').toLowerCase(); }
      function isNewPassword(pw) {
        if (ac(pw).includes('new-password')) { return true; }
        if (ac(pw).includes('current-password')) { return false; }
        const all = passwords(scopeOf(pw));
        return all.length >= 2 && !all.some(p => ac(p).includes('current-password'));
      }
      function usernameFor(pw) {
        const scope = scopeOf(pw);
        const inputs = Array.from(scope.querySelectorAll('input')).filter(i => TEXTY.test(i.type) && visible(i));
        const tagged = inputs.find(i => /username|email/.test(ac(i)));
        if (tagged) { return tagged; }
        // The closest text field before the password field.
        let best = null;
        for (const i of inputs) {
          if (i.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) { best = i; }
        }
        if (best) { return best; }
        return inputs.find(i => USERISH.test(i.name + ' ' + i.id + ' ' + (i.placeholder || ''))) || null;
      }
      /// A field that asks only for the account, with the password on the next step.
      function isIdentifierOnly(el) {
        if (!TEXTY.test(el.type) || passwords(scopeOf(el)).length) { return false; }
        if (/username|email/.test(ac(el)) || el.type === 'email') { return true; }
        return USERISH.test(el.name + ' ' + el.id) && !!el.form;
      }

      document.addEventListener('focusin', (e) => {
        const el = e.target;
        if (!(el instanceof HTMLInputElement)) { return; }
        if (el.type === 'password') {
          post({ type: 'focus', kind: isNewPassword(el) ? 'new' : 'login' });
        } else if (TEXTY.test(el.type)) {
          const pws = passwords(scopeOf(el));
          if (pws.length && usernameFor(pws[0]) === el) {
            post({ type: 'focus', kind: isNewPassword(pws[0]) ? 'new' : 'login' });
          } else if (isIdentifierOnly(el)) {
            post({ type: 'focus', kind: 'login' });
          }
        }
      }, true);
      document.addEventListener('focusout', (e) => {
        if (e.target instanceof HTMLInputElement) { post({ type: 'blur' }); }
      }, true);

      function capture(from) {
        const scope = from ? scopeOf(from) : document;
        const pws = passwords(scope).filter(p => p.value);
        if (!pws.length) {
          const id = Array.from(scope.querySelectorAll('input')).find(i => isIdentifierOnly(i) && i.value);
          if (id) { post({ type: 'identifier', username: id.value }); }
          return;
        }
        let pw = pws.find(p => ac(p).includes('new-password'));
        if (!pw) { pw = pws.length >= 2 ? pws[pws.length - 1] : pws[0]; }
        const user = usernameFor(pws[0]);
        post({ type: 'submit', username: user ? user.value : '', password: pw.value, isNew: isNewPassword(pw) });
      }
      document.addEventListener('submit', (e) => capture(e.target), true);
      document.addEventListener('click', (e) => {
        const b = e.target instanceof Element ? e.target.closest('button, input[type=submit], input[type=button], [role=button]') : null;
        if (!b) { return; }
        const text = (b.innerText || b.value || b.getAttribute('aria-label') || '').trim();
        if (b.type === 'submit' || /log ?in|sign ?in|sign ?up|continue|next|submit|create|register|save|change|update|verify/i.test(text)) {
          capture(b);
        }
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target instanceof HTMLInputElement) { capture(e.target); }
      }, true);

      window.__tabmapPasswordsFill = function (username, password, mode) {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        function set(el, value) {
          el.focus();
          setter.call(el, value);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        const active = document.activeElement instanceof HTMLInputElement ? document.activeElement : null;
        const scope = active ? scopeOf(active) : document;
        const pws = passwords(scope);
        if (mode === 'new') {
          const targets = pws.filter(p => !ac(p).includes('current-password'));
          (targets.length ? targets : pws).forEach(p => set(p, password));
          return;
        }
        const pw = pws.find(p => !isNewPassword(p)) || pws[0];
        if (pw) {
          const user = usernameFor(pw);
          if (user && username && user.value !== username) { set(user, username); }
          set(pw, password);
        } else if (active && TEXTY.test(active.type) && username) {
          set(active, username); // identifier-first: only the account on this step
        }
      };
    })();
    """#

    /// Body for `callAsyncJavaScript`; arguments arrive as variables, never pasted into source.
    private static let fillCall = "window.__tabmapPasswordsFill(username, password, mode);"

    /// Runs in the page's own world, because that is where sites call WebAuthn. Without Apple's
    /// passkey entitlement WebKit refuses every passkey request, so: tell sites there is no
    /// platform authenticator (most then show their password form instead of a dead passkey
    /// button), and when a site asks anyway, let Tabmap offer to finish the sign-in in Safari.
    private static let passkeyScript = #"""
    (function () {
      if (!window.PublicKeyCredential || window.__tabmapPasskeys) { return; }
      window.__tabmapPasskeys = true;
      const PKC = window.PublicKeyCredential;
      try {
        PKC.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
        PKC.isConditionalMediationAvailable = () => Promise.resolve(false);
      } catch (e) {}
      const creds = navigator.credentials;
      if (!creds) { return; }
      const tell = () => { try { webkit.messageHandlers.tabmapPasskeys.postMessage({ type: 'passkey' }); } catch (e) {} };
      for (const name of ['get', 'create']) {
        const original = creds[name] && creds[name].bind(creds);
        if (!original) { continue; }
        creds[name] = function (options) {
          const wantsPasskey = options && options.publicKey && options.mediation !== 'conditional';
          return original(options).catch((err) => {
            if (wantsPasskey && err && (err.name === 'NotAllowedError' || err.name === 'NotSupportedError' || err.name === 'SecurityError')) { tell(); }
            throw err;
          });
        };
      }
    })();
    """#
}

// MARK: - The pill

/// Sits under the island, like find and downloads. Shows saved logins, a suggested password,
/// an offer to save, or the passkey fallback.
struct PasswordIsland: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var autofill = PasswordAutofill.shared
    @ObservedObject private var find = FindController.shared
    @ObservedObject private var downloads = DownloadStore.shared

    private var topInset: CGFloat {
        var top: CGFloat = store.chromeExpanded ? 54 : 7
        if downloads.pillVisible { top += 38 }
        if find.shown { top += 40 }
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

        case .fill(let host, let logins):
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundColor(.white.opacity(0.6))
                if logins.count == 1, let login = logins.first {
                    Button { autofill.fill(login) } label: {
                        Text(label(login)).lineLimit(1)
                    }
                    .help("Fill the saved password for \(host)")
                } else {
                    Menu {
                        ForEach(logins) { login in
                            Button(label(login)) { autofill.fill(login) }
                        }
                    } label: {
                        Text("Fill a saved login for \(host)")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button { autofill.hide() } label: { Image(systemName: "xmark") }
            }

        case .suggest(_, let password):
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundColor(.white.opacity(0.6))
                Text("Use strong password")
                Text(password)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                Button("Use") { autofill.useSuggested() }
                Button { autofill.hide() } label: { Image(systemName: "xmark") }
            }

        case .save(let host, let username, _, let update, _):
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundColor(.white.opacity(0.6))
                Text(update ? "Update the password for \(username.isEmpty ? host : username)?"
                            : "Save password\(username.isEmpty ? "" : " for \(username)") on \(host)?")
                    .lineLimit(1)
                Button(update ? "Update" : "Save") { autofill.confirmSave() }
                if !update { Button("Never for This Site") { autofill.neverForSite() } }
                Button("Not Now") { autofill.hide() }
            }

        case .notice(let text):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundColor(.white.opacity(0.6))
                Text(text).lineLimit(1)
            }

        case .passkey(let host, _):
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill").foregroundColor(.white.opacity(0.6))
                Text("\(host) wants a passkey. Tabmap can't use passkeys yet.").lineLimit(1)
                Button("Open in Safari") { autofill.openInSafari() }
                Button { autofill.hide() } label: { Image(systemName: "xmark") }
            }
        }
    }

    private func label(_ login: SavedLogin) -> String {
        let name = login.username.isEmpty ? "(no username)" : login.username
        return "\(name) · \(login.host)"
    }
}

// MARK: - Settings

struct PasswordSettingsSection: View {
    @AppStorage(PasswordStore.autofillKey) private var autofill = true
    @AppStorage(PasswordStore.offerSaveKey) private var offerSave = true
    @AppStorage(PasswordStore.requireUnlockKey) private var requireUnlock = true
    @State private var managing = false

    var body: some View {
        Section("Passwords") {
            Toggle("Fill saved passwords and suggest strong ones", isOn: $autofill)
            Toggle("Offer to save passwords", isOn: $offerSave)
            Toggle("Ask for Touch ID or your Mac password before filling", isOn: $requireUnlock)
            HStack {
                Button("Saved Passwords…") { managing = true }
                Button("Open Passwords App") { openPasswordsApp() }
            }
            Text(PasswordAutofill.hasPasskeyEntitlement
                 ? "Passwords are kept in your Mac's login keychain. Passkeys use iCloud Keychain."
                 : "Passwords are kept in your Mac's login keychain. To bring in iCloud passwords, export them from the Passwords app (File > Export) and import the file. Passkeys need Apple to approve Tabmap as a browser; until then, passkey sign-ins can be finished in Safari.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $managing) { SavedPasswordsView() }
    }

    private func openPasswordsApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.open(app)
        } else if let keychain = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.open(keychain)
        }
    }
}

/// A plain list of saved logins: search, reveal (after Touch ID), copy, delete.
struct SavedPasswordsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PasswordStore.shared
    @State private var query = ""
    @State private var revealed: [String: String] = [:]
    @State private var error: String?

    private var shown: [SavedLogin] {
        guard !query.isEmpty else { return store.logins }
        return store.logins.filter {
            $0.host.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Passwords").font(.headline)
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            List {
                ForEach(shown) { login in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(login.host)
                            Text(login.username.isEmpty ? "(no username)" : login.username)
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(revealed[login.id] ?? "••••••••")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Button { reveal(login) } label: { Image(systemName: revealed[login.id] == nil ? "eye" : "eye.slash") }
                            .buttonStyle(.borderless)
                            .help("Show password")
                        Button { copy(login) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy password")
                        Button { remove(login) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete")
                    }
                }
            }
            .frame(minHeight: 300)
            if !store.neverSaveSites.isEmpty {
                Text("Never saved on: " + store.neverSaveSites.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Button("Clear Never List") { for site in store.neverSaveSites { store.removeNeverSave(site) } }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundColor(.red) }
            HStack {
                Text("\(store.logins.count) logins").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 460)
        .onAppear { store.reload() }
    }

    private func reveal(_ login: SavedLogin) {
        if revealed[login.id] != nil { revealed[login.id] = nil; return }
        Task {
            do { revealed[login.id] = try await store.password(for: login, reason: "show the password for \(login.host)") }
            catch PasswordStore.StoreError.cancelled {}
            catch { self.error = error.localizedDescription }
        }
    }

    private func copy(_ login: SavedLogin) {
        Task {
            do {
                let password = try await store.password(for: login, reason: "copy the password for \(login.host)")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(password, forType: .string)
            } catch PasswordStore.StoreError.cancelled {}
            catch { self.error = error.localizedDescription }
        }
    }

    private func remove(_ login: SavedLogin) {
        do { try store.delete(login); revealed[login.id] = nil }
        catch { self.error = error.localizedDescription }
    }
}
