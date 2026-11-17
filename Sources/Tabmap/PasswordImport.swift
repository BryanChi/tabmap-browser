import Foundation
import Security
import TabMapCore

/// Saves imported logins to the login keychain as internet passwords, the same items the password autofill reads:
/// server = host, account = username, protocol https or http, label = host, comment = note, not synchronised.
/// A login already there for the same site and username has its password updated when it differs.
enum PasswordImport {
    struct Result {
        var added = 0
        var updated = 0
        var unchanged = 0
        var failed = 0
    }

    static func save(_ logins: [ImportedLogin]) -> Result {
        var result = Result()
        var seen = Set<String>()
        for login in logins {
            let host = login.host
            guard !host.isEmpty, seen.insert(host + "\u{0}" + login.username).inserted else { continue }
            switch save(login, host: host) {
            case .added: result.added += 1
            case .updated: result.updated += 1
            case .unchanged: result.unchanged += 1
            case .failed: result.failed += 1
            }
        }
        return result
    }

    private enum Outcome { case added, updated, unchanged, failed }

    private static func save(_ login: ImportedLogin, host: String) -> Outcome {
        let secret = Data(login.password.utf8)
        let proto = login.url.scheme?.lowercased() == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS
        let match: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: login.username,
        ]
        var lookup = match
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var existing: CFTypeRef?
        let found = SecItemCopyMatching(lookup as CFDictionary, &existing)
        if found == errSecSuccess {
            if (existing as? Data) == secret { return .unchanged }
            let change: [String: Any] = [kSecValueData as String: secret]
            return SecItemUpdate(match as CFDictionary, change as CFDictionary) == errSecSuccess ? .updated : .failed
        }
        var item = match
        item[kSecAttrProtocol as String] = proto
        item[kSecAttrPath as String] = ""
        item[kSecAttrLabel as String] = host
        if !login.note.isEmpty { item[kSecAttrComment as String] = login.note }
        item[kSecValueData as String] = secret
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? .added : .failed
    }
}
