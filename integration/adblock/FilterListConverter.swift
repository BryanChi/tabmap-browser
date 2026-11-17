import Foundation

// Turns Adblock Plus style filter lists (EasyList, EasyPrivacy) into WebKit content rules,
// the JSON that WKContentRuleListStore compiles. Pure Foundation so it can be unit tested.
//
// Supported: network filters (`||host^`, `|start`, `end|`, `*`, `^`), `@@` exceptions,
// options third-party / first-party, resource types (and `~type`), domain=, match-case, popup,
// `@@...$document` / `$elemhide` page exceptions, element hiding `##` (generic and per site)
// with `#@#` exceptions.
// Skipped (counted in `skipped`): regex filters, scriptlets and extended CSS (`#$#`, `#?#`,
// `##+js`, `:has-text` ...), redirect / csp / removeparam and other options WebKit cannot express.

/// One WebKit content rule. Field names are WebKit's.
public struct ContentRule: Codable, Equatable, Sendable {
    public struct Trigger: Codable, Equatable, Sendable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
        }
    }

    public struct Action: Codable, Equatable, Sendable {
        public var type: String
        public var selector: String?
    }

    public var trigger: Trigger
    public var action: Action

    public static func block(_ trigger: Trigger) -> ContentRule {
        ContentRule(trigger: trigger, action: Action(type: "block"))
    }
    public static func allow(_ trigger: Trigger) -> ContentRule {
        ContentRule(trigger: trigger, action: Action(type: "ignore-previous-rules"))
    }
    public static func hide(_ selector: String, _ trigger: Trigger) -> ContentRule {
        ContentRule(trigger: trigger, action: Action(type: "css-display-none", selector: selector))
    }
}

/// The rules from one or more filter lists, sorted into the groups WebKit needs in a fixed order.
public struct ConvertedFilters: Equatable, Sendable {
    /// Blocks requests.
    public var blocks: [ContentRule] = []
    /// `@@` request exceptions; must come after the blocks they cancel, in the same list.
    public var exceptions: [ContentRule] = []
    /// Element hiding.
    public var hides: [ContentRule] = []
    /// Whole-page exceptions (`@@||site^$document`), which cancel blocks and hiding alike.
    public var pageExceptions: [ContentRule] = []
    /// Lines that were understood but cannot be expressed, or were not understood.
    public var skipped = 0

    public var ruleCount: Int { blocks.count + exceptions.count + hides.count + pageExceptions.count }

    /// Rule lists to compile, each under WebKit's per-list limit. WebKit only lets an exception
    /// cancel rules in its own list, so every request chunk carries all the request exceptions,
    /// and every chunk carries the page exceptions. Hiding goes in lists of its own, so a selector
    /// WebKit rejects never costs the request blocking.
    public func chunks(maxRules: Int = 60_000) -> [[ContentRule]] {
        var out: [[ContentRule]] = []
        let blockRoom = max(1, maxRules - exceptions.count - pageExceptions.count)
        var i = 0
        while i < blocks.count {
            let end = min(blocks.count, i + blockRoom)
            out.append(Array(blocks[i..<end]) + exceptions + pageExceptions)
            i = end
        }
        let hideRoom = max(1, maxRules - pageExceptions.count)
        i = 0
        while i < hides.count {
            let end = min(hides.count, i + hideRoom)
            out.append(Array(hides[i..<end]) + pageExceptions)
            i = end
        }
        return out
    }

    public static func encode(_ rules: [ContentRule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum FilterListConverter {
    /// Bump when the conversion changes, so stored compiled lists are rebuilt.
    public static let version = 1

    /// Resource types used when a filter names none. Includes "document" so ad frames are
    /// blocked; a page opened directly on a blocked address shows an explanation instead.
    static let allTypes = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media"]

    static let typeMap: [String: [String]] = [
        "script": ["script"],
        "image": ["image", "svg-document"],
        "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "font": ["font"],
        "media": ["media"],
        "xmlhttprequest": ["raw"], "xhr": ["raw"],
        "websocket": ["raw"], "ping": ["raw"], "other": ["raw"], "object": ["media"],
        "subdocument": ["document"], "frame": ["document"],
        "popup": ["popup"],
    ]
    /// Options that do not change what is blocked.
    static let ignoredOptions: Set<String> = ["important", "collapse", "~collapse", "match-case-insensitive"]
    /// Pseudo-classes and syntax only uBlock / AdGuard understand. WebKit would reject the list.
    static let extendedCSS = [":-abp-", ":has-text", ":contains", ":xpath", ":upward", ":remove", ":style",
                              ":matches-css", ":min-text-length", ":watch-attr", ":nth-ancestor",
                              ":matches-path", ":matches-attr", ":matches-prop", ":others", ":if(", ":if-not",
                              "[-ext-", "{", "}", "\\"]

    /// How many generic selectors share one rule. Fewer rules compile and match faster.
    static let selectorsPerRule = 400

    public static func convert(_ text: String) -> ConvertedFilters {
        convert([text])
    }

    public static func convert(_ texts: [String]) -> ConvertedFilters {
        var out = ConvertedFilters()
        // Generic selectors, and the sites where each must not apply (from `site#@#selector`).
        var generic: [String] = []
        var genericSeen: Set<String> = []
        var genericExceptions: [String: Set<String>] = [:]

        for text in texts {
            text.enumerateLines { raw, _ in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return }
                if line.contains("#") {
                    switch cosmetic(line) {
                    case .notCosmetic:
                        break
                    case .skip:
                        out.skipped += 1; return
                    case let .hide(selector, include, exclude):
                        if include.isEmpty {
                            if exclude.isEmpty {
                                if genericSeen.insert(selector).inserted { generic.append(selector) }
                            } else {
                                genericExceptions[selector, default: []].formUnion(exclude)
                                if genericSeen.insert(selector).inserted { generic.append(selector) }
                            }
                        } else {
                            out.hides.append(.hide(selector, Trigger(urlFilter: ".*", ifDomain: wildcard(include))))
                        }
                        return
                    case let .unhide(selector, sites):
                        // Only generic hiding can be cancelled per site; a site rule is simply left out.
                        genericExceptions[selector, default: []].formUnion(sites)
                        return
                    }
                }
                guard let rule = network(line) else { out.skipped += 1; return }
                switch rule {
                case let .block(r): out.blocks.append(r)
                case let .allow(r): out.exceptions.append(r)
                case let .page(r): out.pageExceptions.append(r)
                }
            }
        }

        // Generic hiding: batch the selectors nobody excepts; one rule per excepted selector.
        var batch: [String] = []
        func flush() {
            guard !batch.isEmpty else { return }
            out.hides.insert(.hide(batch.joined(separator: ", "), Trigger(urlFilter: ".*")), at: 0)
            batch = []
        }
        var excepted: [ContentRule] = []
        for selector in generic {
            if let sites = genericExceptions[selector], !sites.isEmpty {
                excepted.append(.hide(selector, Trigger(urlFilter: ".*", unlessDomain: wildcard(sites))))
            } else {
                batch.append(selector)
                if batch.count == selectorsPerRule { flush() }
            }
        }
        flush()
        out.hides.insert(contentsOf: excepted, at: 0)
        return out
    }

    typealias Trigger = ContentRule.Trigger

    // MARK: Element hiding

    enum Cosmetic: Equatable {
        case notCosmetic
        case skip
        case hide(String, include: Set<String>, exclude: Set<String>)
        case unhide(String, sites: Set<String>)
    }

    static func cosmetic(_ line: String) -> Cosmetic {
        let separators = ["#@#", "##", "#?#", "#@?#", "#$#", "#@$#", "#%#", "#@%#", "$$", "$@$"]
        // Find the first separator. A network filter can contain "#" (e.g. in an address), so a
        // line is cosmetic only if one of these appears.
        var found: (Range<String.Index>, String)?
        for sep in separators {
            if let r = line.range(of: sep), found == nil || r.lowerBound < found!.0.lowerBound {
                found = (r, sep)
            }
        }
        guard let hit = found else { return .notCosmetic }
        let (range, sep) = hit
        let domainsPart = String(line[..<range.lowerBound])
        // A network filter with "#" somewhere after an option or path (rare): not cosmetic.
        if domainsPart.contains("/") || domainsPart.contains("$") || domainsPart.contains("|") || domainsPart.contains("^") {
            return .notCosmetic
        }
        guard sep == "##" || sep == "#@#" else { return .skip }
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard isPlainSelector(selector) else { return .skip }
        var include: Set<String> = [], exclude: Set<String> = []
        for d in domainsPart.split(separator: ",") {
            var d = String(d).trimmingCharacters(in: .whitespaces).lowercased()
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            guard isPlainDomain(d) else { return .skip }
            if negated { exclude.insert(d) } else { include.insert(d) }
        }
        if sep == "#@#" {
            guard !include.isEmpty else { return .skip }
            return .unhide(selector, sites: include)
        }
        return .hide(selector, include: include, exclude: exclude)
    }

    static func isPlainSelector(_ s: String) -> Bool {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII }), !s.hasPrefix("+js("), !s.hasPrefix("^") else { return false }
        return !extendedCSS.contains { s.contains($0) }
    }

    static func isPlainDomain(_ d: String) -> Bool {
        guard !d.isEmpty, d.contains("."), !d.hasPrefix("."), !d.hasSuffix(".") else { return false }
        return d.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    static func wildcard(_ domains: Set<String>) -> [String] {
        domains.sorted().map { "*" + $0 }
    }

    // MARK: Network filters

    enum Network: Equatable {
        case block(ContentRule)
        case allow(ContentRule)
        case page(ContentRule)
    }

    static func network(_ line: String) -> Network? {
        var body = line
        let isException = body.hasPrefix("@@")
        if isException { body.removeFirst(2) }

        // Options follow the last "$" (a "$" inside the address is rare and never followed by "=" alone).
        var options: [String] = []
        if let dollar = body.lastIndex(of: "$") {
            let tail = body[body.index(after: dollar)...]
            if !tail.isEmpty, !tail.contains("/") {
                options = tail.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                body = String(body[..<dollar])
            }
        }

        var trigger = Trigger(urlFilter: ".*")
        var types: [String] = []
        var negatedTypes: [String] = []
        var pageLevel = false
        for option in options {
            let lower = option.lowercased()
            let name = lower.split(separator: "=", maxSplits: 1).first.map(String.init) ?? lower
            if ignoredOptions.contains(lower) { continue }
            switch name {
            case "third-party", "3p":
                trigger.loadType = ["third-party"]
            case "~third-party", "first-party", "1p":
                trigger.loadType = ["first-party"]
            case "~first-party":
                trigger.loadType = ["third-party"]
            case "match-case":
                trigger.urlFilterIsCaseSensitive = true
            case "domain", "from":
                guard let value = option.split(separator: "=", maxSplits: 1).last.map(String.init),
                      applyDomains(value, to: &trigger) else { return nil }
            case "document", "doc", "elemhide", "ehide":
                guard isException else { return nil }
                pageLevel = true
            case "all":
                types.append(contentsOf: allTypes + ["popup"])
            default:
                if let mapped = typeMap[name] {
                    types.append(contentsOf: mapped)
                } else if name.hasPrefix("~"), let mapped = typeMap[String(name.dropFirst())] {
                    negatedTypes.append(contentsOf: mapped)
                } else {
                    // redirect, csp, removeparam, generichide, badfilter, denyallow ...
                    return nil
                }
            }
        }

        guard let filter = urlFilter(body) else { return nil }
        trigger.urlFilter = filter
        // A filter that matches every address needs a site restriction, or it blocks the web.
        if filter == ".*", trigger.ifDomain == nil, !isException { return nil }

        if pageLevel {
            // `@@||site^$document`: everything on that site's pages is allowed.
            guard let site = pageSite(body) else { return nil }
            var page = Trigger(urlFilter: ".*")
            page.ifDomain = ["*" + site]
            return .page(.allow(page))
        }

        if !types.isEmpty {
            trigger.resourceType = unique(types)
        } else if !negatedTypes.isEmpty {
            trigger.resourceType = allTypes.filter { !negatedTypes.contains($0) }
            if trigger.resourceType!.isEmpty { return nil }
        } else {
            trigger.resourceType = allTypes
        }
        return isException ? .allow(.allow(trigger)) : .block(.block(trigger))
    }

    /// Fills if-domain / unless-domain from `a.com|~b.com`. WebKit allows only one of the two;
    /// with both, the sites it applies on win (exclusions are subdomains of them in practice).
    static func applyDomains(_ value: String, to trigger: inout Trigger) -> Bool {
        var include: Set<String> = [], exclude: Set<String> = []
        for part in value.split(separator: "|") {
            var d = String(part).lowercased()
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            // `example.*` (any top-level domain) cannot be expressed; drop that one site.
            guard isPlainDomain(d) else { continue }
            if negated { exclude.insert(d) } else { include.insert(d) }
        }
        if !include.isEmpty {
            trigger.ifDomain = wildcard(include)
        } else if !exclude.isEmpty {
            trigger.unlessDomain = wildcard(exclude)
        } else {
            return false
        }
        return true
    }

    /// The site of `||example.com^` style page exceptions.
    static func pageSite(_ body: String) -> String? {
        guard body.hasPrefix("||") else { return nil }
        var site = String(body.dropFirst(2))
        while let last = site.last, last == "^" || last == "/" || last == "|" { site.removeLast() }
        site = site.lowercased()
        return isPlainDomain(site) ? site : nil
    }

    /// ABP address pattern to the regular expression subset WebKit accepts
    /// (no alternation, no counted repeats).
    static func urlFilter(_ pattern: String) -> String? {
        var p = Substring(pattern)
        // `/regex/` filters use syntax WebKit may not support.
        if p.count > 1, p.hasPrefix("/"), p.hasSuffix("/") { return nil }
        guard p.allSatisfy({ $0.isASCII }) else { return nil }

        var out = ""
        if p.hasPrefix("||") {
            p = p.dropFirst(2)
            out = "^[^:]+://+([^:/]+\\.)?"
        } else if p.hasPrefix("|") {
            p = p.dropFirst()
            out = "^"
        }
        var anchoredEnd = false
        if p.hasSuffix("|") {
            p = p.dropLast()
            anchoredEnd = true
        }
        while p.hasPrefix("*") { p = p.dropFirst() }
        while p.hasSuffix("*"), !anchoredEnd { p = p.dropLast() }
        if p.isEmpty { return out.isEmpty || out == "^" ? ".*" : nil }

        let chars = Array(p)
        for (i, c) in chars.enumerated() {
            switch c {
            case "*": out += ".*"
            case "^":
                out += i == chars.count - 1 ? "([/:?=&].*)?$" : "[/:?=&]"
            case "|", "{", "}":
                return nil
            case ".", "+", "?", "(", ")", "[", "]", "\\", "$":
                out += "\\" + String(c)
            default: out.append(c)
            }
        }
        if anchoredEnd, !out.hasSuffix("$") { out += "$" }
        return out
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

/// Sites where the user turned blocking off. A site covers its subdomains; "www." is ignored.
public struct BlockingAllowlist: Equatable {
    public private(set) var sites: Set<String>

    public init(_ sites: [String] = []) {
        self.sites = Set(sites.compactMap(Self.site(of:)))
    }

    /// The name a host is listed under: lowercased, without "www.".
    public static func site(of host: String) -> String? {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }

    public func allows(host: String?) -> Bool {
        guard let host, var h = Self.site(of: host) else { return false }
        while true {
            if sites.contains(h) { return true }
            guard let dot = h.firstIndex(of: ".") else { return false }
            h = String(h[h.index(after: dot)...])
        }
    }

    /// Turns blocking off for `host` (true) or back on (false). Turning it back on also clears a
    /// listed parent site, so the page in front is blocked again.
    public mutating func set(host: String, allowed: Bool) {
        guard let site = Self.site(of: host) else { return }
        if allowed {
            sites.insert(site)
        } else {
            sites = sites.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        }
    }
}
