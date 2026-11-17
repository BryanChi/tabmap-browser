import Foundation
import LocalAuthentication
import Security
import TabMapCore

/// Saved website logins, kept as internet passwords in the login keychain (the same place
/// Keychain Access shows them, and where the importer writes logins from Chrome, Safari and the
/// Passwords app). Only usernames are read up front; a password is read when it is filled, after
/// Touch ID or the Mac's password when that setting is on.
///
/// Why not iCloud Keychain: macOS has no public API that lets a third-party browser read the
/// Passwords app's logins. See README "Passwords and passkeys" for the paths that need Apple.
@MainActor
final class PasswordStore: ObservableObject {
    static let shared = PasswordStore()

    static let autofillKey = "passwordsAutofill"
    static let offerSaveKey = "passwordsOfferSave"
    static let requireUnlockKey = "passwordsRequireUnlock"
    static let neverSaveKey = "passwordsNeverSave"
    private static let lastUsedKey = "passwordsLastUsed"

    enum SaveResult { case added, updated, unchanged }

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case cancelled
        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    /// Every saved web login, without passwords. Refreshed after each change.
    @Published private(set) var logins: [SavedLogin] = []

    private var unlockedUntil: Date = .distantPast
    private let unlockWindow: TimeInterval = 5 * 60

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.autofillKey: true,
            Self.offerSaveKey: true,
            Self.requireUnlockKey: true,
        ])
        reload()
    }

    var autofillEnabled: Bool { UserDefaults.standard.bool(forKey: Self.autofillKey) }
    var offerSaveEnabled: Bool { UserDefaults.standard.bool(forKey: Self.offerSaveKey) }
    var requireUnlock: Bool { UserDefaults.standard.bool(forKey: Self.requireUnlockKey) }

    // MARK: Reading

    func reload() {
        var found: [SavedLogin] = []
        var seen = Set<String>()
        let lastUsed = UserDefaults.standard.dictionary(forKey: Self.lastUsedKey) as? [String: Double] ?? [:]
        for proto in [kSecAttrProtocolHTTPS, kSecAttrProtocolHTTP] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrProtocol as String: proto,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[String: Any]] else { continue }
            for item in items {
                guard let server = item[kSecAttrServer as String] as? String,
                      let host = LoginDomain.normalizedHost(server) else { continue }
                let account = item[kSecAttrAccount as String] as? String ?? ""
                var login = SavedLogin(host: host, username: account)
                guard seen.insert(login.id).inserted else { continue }
                if let t = lastUsed[login.id] { login.lastUsed = Date(timeIntervalSince1970: t) }
                found.append(login)
            }
        }
        logins = found.sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    /// Saved logins to offer on a page from `host`, best first.
    func candidates(forHost host: String) -> [SavedLogin] {
        LoginMatcher.candidates(logins, pageHost: host)
    }

    /// The password for `login`, after asking for Touch ID or the Mac's password if that setting is
    /// on and it was not given in the last five minutes. Throws `.cancelled` if the person declines.
    func password(for login: SavedLogin, reason: String) async throws -> String {
        if requireUnlock, Date() > unlockedUntil {
            try await unlock(reason: reason)
        }
        let host = login.host, account = login.username
        let data: Data = try await Task.detached {
            try Self.readPassword(host: host, account: account)
        }.value
        markUsed(login)
        return String(decoding: data, as: UTF8.self)
    }

    /// Asks for Touch ID, an Apple Watch or the Mac's password.
    func unlock(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No password set on this Mac: nothing to ask for.
            unlockedUntil = Date().addingTimeInterval(unlockWindow)
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            unlockedUntil = Date().addingTimeInterval(unlockWindow)
        } catch {
            throw StoreError.cancelled
        }
    }

    /// For each saved username on the site of `host`, whether its password equals `password`.
    /// Used to decide between offering to save, to update, or nothing.
    func compare(host: String, password: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for login in logins where LoginDomain.normalizedHost(login.host) == LoginDomain.normalizedHost(host) {
            let stored = try? Self.readPassword(host: login.host, account: login.username)
            out[login.username] = stored.map { String(decoding: $0, as: UTF8.self) == password } ?? false
        }
        return out
    }

    nonisolated private static func readPassword(host: String, account: String) throws -> Data {
        for server in [host, "www." + host] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: server,
                kSecAttrAccount as String: account,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data { return data }
            if status == errSecUserCanceled || status == errSecAuthFailed { throw StoreError.cancelled }
            if status != errSecItemNotFound { throw StoreError.keychain(status) }
        }
        throw StoreError.keychain(errSecItemNotFound)
    }

    // MARK: Writing

    /// Adds a login, or changes the password of the saved login with the same site and username.
    @discardableResult
    func save(host rawHost: String, username: String, password: String, note: String? = nil,
              secure: Bool = true) throws -> SaveResult {
        guard let host = LoginDomain.normalizedHost(rawHost) else { throw StoreError.keychain(errSecParam) }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(password.utf8)
        let match: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: account,
        ]
        if let existing = try? Self.readPassword(host: host, account: account) {
            if existing == data { return .unchanged }
            var query = match
            // The item may have been saved under "www."; update whichever holds it.
            if SecItemCopyMatching(match as CFDictionary, nil) != errSecSuccess {
                query[kSecAttrServer as String] = "www." + host
            }
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw StoreError.keychain(status) }
            reload()
            return .updated
        }
        var add = match
        add[kSecAttrProtocol as String] = secure ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
        add[kSecAttrPath as String] = ""
        add[kSecAttrLabel as String] = host
        add[kSecValueData as String] = data
        if let note, !note.isEmpty { add[kSecAttrComment as String] = note }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        reload()
        return .added
    }

    func delete(_ login: SavedLogin) throws {
        for server in [login.host, "www." + login.host] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: server,
                kSecAttrAccount as String: login.username,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { throw StoreError.keychain(status) }
        }
        reload()
    }

    private func markUsed(_ login: SavedLogin) {
        var lastUsed = UserDefaults.standard.dictionary(forKey: Self.lastUsedKey) as? [String: Double] ?? [:]
        lastUsed[login.id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastUsed, forKey: Self.lastUsedKey)
        if let i = logins.firstIndex(where: { $0.id == login.id }) { logins[i].lastUsed = Date() }
    }

    // MARK: Sites never to offer saving on

    func neverSave(_ host: String) -> Bool {
        guard let site = LoginDomain.registrable(host) else { return false }
        return (UserDefaults.standard.stringArray(forKey: Self.neverSaveKey) ?? []).contains(site)
    }

    func addNeverSave(_ host: String) {
        guard let site = LoginDomain.registrable(host) else { return }
        var list = UserDefaults.standard.stringArray(forKey: Self.neverSaveKey) ?? []
        if !list.contains(site) { list.append(site) }
        UserDefaults.standard.set(list, forKey: Self.neverSaveKey)
        objectWillChange.send()
    }

    func removeNeverSave(_ site: String) {
        var list = UserDefaults.standard.stringArray(forKey: Self.neverSaveKey) ?? []
        list.removeAll { $0 == site }
        UserDefaults.standard.set(list, forKey: Self.neverSaveKey)
        objectWillChange.send()
    }

    var neverSaveSites: [String] { UserDefaults.standard.stringArray(forKey: Self.neverSaveKey) ?? [] }
}
