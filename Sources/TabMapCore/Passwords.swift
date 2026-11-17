import Foundation

// Pure rules behind password autofill: which saved logins belong to a page, what to offer after a
// form is sent, and how a suggested password looks. The keychain and the page script live in the app.

/// The part of a host name a login belongs to: "accounts.google.com" and "mail.google.com" both
/// belong to "google.com"; "shop.example.co.uk" belongs to "example.co.uk".
public enum LoginDomain {
    /// Two-part public suffixes that are common enough to matter. Not the full public suffix list,
    /// so an unknown one falls back to the last two labels, which only ever widens a match to
    /// sibling sites of the same registry (never across registries).
    static let twoPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.kr", "or.kr", "ne.kr",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.hk", "org.hk", "edu.hk", "gov.hk",
        "com.tw", "org.tw", "edu.tw", "gov.tw",
        "com.sg", "edu.sg", "gov.sg", "org.sg",
        "com.mx", "org.mx", "gob.mx",
        "com.ar", "com.tr", "com.ua", "com.pl", "com.my", "com.ph", "com.vn", "com.sa", "com.eg",
        "co.in", "net.in", "org.in", "gov.in", "ac.in",
        "co.za", "org.za", "gov.za",
        "co.il", "org.il", "ac.il",
        "co.id", "or.id", "ac.id",
        "co.th", "in.th", "ac.th",
        // Shared hosting where every subdomain is a different owner.
        "github.io", "gitlab.io", "pages.dev", "vercel.app", "netlify.app", "herokuapp.com",
        "web.app", "firebaseapp.com", "blogspot.com", "azurewebsites.net", "cloudfront.net",
        "glitch.me", "fly.dev", "onrender.com", "workers.dev", "repl.co", "ngrok.io",
    ]

    /// Lower case, no trailing dot, no "www.". Nil for an empty host.
    public static func normalizedHost(_ host: String?) -> String? {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www."), h.dropFirst(4).contains(".") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }

    /// The registrable domain of `host`. IP addresses and single-label hosts ("localhost") are their own domain.
    public static func registrable(_ host: String?) -> String? {
        guard let h = normalizedHost(host) else { return nil }
        if isIPAddress(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return h }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let keep = twoPartSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    static func isIPAddress(_ h: String) -> Bool {
        if h.contains(":") { return true } // IPv6
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Whether a login saved for `savedHost` may be offered on a page served from `pageHost`.
    public static func matches(savedHost: String, pageHost: String) -> Bool {
        guard let a = registrable(savedHost), let b = registrable(pageHost) else { return false }
        return a == b
    }
}

/// A saved login as the autofill sees it: no password, which stays in the keychain until it is filled.
public struct SavedLogin: Hashable, Identifiable {
    public var host: String
    public var username: String
    public var lastUsed: Date?
    public var id: String { "\(host)\u{1F}\(username)" }

    public init(host: String, username: String, lastUsed: Date? = nil) {
        self.host = host
        self.username = username
        self.lastUsed = lastUsed
    }
}

public enum LoginMatcher {
    /// The saved logins to offer on `pageHost`, best first: the exact host before its sibling
    /// subdomains, then the most recently used, then by name.
    public static func candidates(_ logins: [SavedLogin], pageHost: String) -> [SavedLogin] {
        guard let page = LoginDomain.normalizedHost(pageHost) else { return [] }
        let matching = logins.filter { LoginDomain.matches(savedHost: $0.host, pageHost: page) }
        return matching.sorted { a, b in
            let ea = LoginDomain.normalizedHost(a.host) == page
            let eb = LoginDomain.normalizedHost(b.host) == page
            if ea != eb { return ea }
            let ua = a.lastUsed ?? .distantPast, ub = b.lastUsed ?? .distantPast
            if ua != ub { return ua > ub }
            return a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending
        }
    }
}

/// What to offer after a page sends a username and password.
public enum SaveOffer: Equatable {
    /// Nothing: no password, or this exact login is already saved, or the site is on the never list.
    case none
    case save
    /// A login for this user exists with a different password.
    case update
}

public enum SaveDecision {
    /// `existing` maps saved usernames for the page's site to whether their password equals the
    /// one just sent (the app compares in the keychain so passwords never leave it in bulk).
    public static func offer(username: String, password: String, existing: [String: Bool],
                             neverSave: Bool) -> SaveOffer {
        if neverSave { return .none }
        guard !password.isEmpty, password.count <= 512 else { return .none }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let same = existing[user] else { return .save }
        return same ? .none : .update
    }
}

/// Passwords in the style Safari suggests: three groups of six letters and digits joined by
/// hyphens, with at least one capital and one digit, and no look-alike characters.
public enum PasswordGenerator {
    static let lower = Array("abcdefghijkmnopqrstuvwxyz")   // no l
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")    // no I, O
    static let digits = Array("23456789")                   // no 0, 1

    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    public static func generate<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let pool = lower + lower + upper + digits
        var chars = (0..<18).map { _ in pool.randomElement(using: &rng)! }
        // Guarantee one capital and one digit, at different positions.
        let capitalAt = Int.random(in: 0..<18, using: &rng)
        var digitAt = Int.random(in: 0..<17, using: &rng)
        if digitAt >= capitalAt { digitAt += 1 }
        chars[capitalAt] = upper.randomElement(using: &rng)!
        chars[digitAt] = digits.randomElement(using: &rng)!
        let s = String(chars)
        let a = s.prefix(6), b = s.dropFirst(6).prefix(6), c = s.suffix(6)
        return "\(a)-\(b)-\(c)"
    }
}
