import Foundation

// The plain rules behind "Let Claude control Tabmap": reading HTTP requests for the local MCP server,
// deciding who may connect, naming keys, and spotting a human check (CAPTCHA) on a page.
// No AppKit here, so all of it is unit tested.

/// One HTTP/1.1 request, as read off a local socket.
public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum HTTPParse: Equatable {
    /// More bytes are needed.
    case incomplete
    case request(HTTPRequest, consumed: Int)
    case invalid(String)
}

public enum HTTPRequestParser {
    /// Requests bigger than this are refused. Tool calls are small.
    public static let maxBody = 4 * 1024 * 1024
    public static let maxHead = 64 * 1024

    public static func parse(_ data: Data) -> HTTPParse {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = data.range(of: separator) else {
            return data.count > maxHead ? .invalid("headers too large") : .incomplete
        }
        guard let head = String(data: data.subdata(in: data.startIndex..<headEnd.lowerBound), encoding: .utf8) else {
            return .invalid("headers are not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid("empty request") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid("bad request line") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid("chunked bodies are not supported")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .invalid("bad content length") }
        let bodyStart = headEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        let request = HTTPRequest(method: String(requestLine[0]).uppercased(), path: String(requestLine[1]),
                                  headers: headers, body: body)
        return .request(request, consumed: bodyStart + length - data.startIndex)
    }
}

public enum HTTPResponse {
    public static func encode(status: Int, reason: String, headers: [String: String] = [:], body: Data = Data()) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Cache-Control"] = all["Cache-Control"] ?? "no-store"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Who may talk to the control server: only programs on this Mac that know the token, and never a web page.
public enum AgentAccess {
    public enum Verdict: Equatable {
        case allowed
        /// 401: no or wrong token.
        case unauthorized
        /// 403: a web page (or a DNS-rebinding trick) is trying to reach the server.
        case forbidden(String)
    }

    public static func check(_ request: HTTPRequest, token: String) -> Verdict {
        // A browser always sends Origin on cross-site requests; programs like Claude Code don't.
        if let origin = request.headers["origin"], !origin.isEmpty, origin != "null" {
            return .forbidden("requests from web pages are not allowed")
        }
        // The Host must be this Mac, so a site that points its own name at 127.0.0.1 gets nowhere.
        let host = (request.headers["host"] ?? "").lowercased()
        let hostName: String
        if host.hasPrefix("[") {
            hostName = String(host.prefix { $0 != "]" }.dropFirst())
        } else {
            hostName = String(host.split(separator: ":").first ?? "")
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(hostName) else {
            return .forbidden("unexpected host")
        }
        guard !token.isEmpty, let header = request.headers["authorization"] else { return .unauthorized }
        let prefix = "bearer "
        guard header.lowercased().hasPrefix(prefix) else { return .unauthorized }
        let given = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return constantTimeEqual(given, token) ? .allowed : .unauthorized
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// A fresh random token: 32 bytes as hex.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

/// A key Claude asks to press, like "Enter", "cmd+a" or "shift+Tab".
public struct AgentKey: Equatable {
    public enum Modifier: String, CaseIterable { case command, shift, option, control }

    public var keyCode: UInt16
    /// What the key types (empty for keys like the arrows).
    public var characters: String
    public var modifiers: Set<Modifier>

    /// macOS virtual key codes (kVK_*) for the keys a page cares about.
    static let named: [String: (UInt16, String)] = [
        "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "),
        "backspace": (51, "\u{8}"), "delete": (51, "\u{8}"), "forwarddelete": (117, "\u{7F}"),
        "escape": (53, "\u{1B}"), "esc": (53, "\u{1B}"),
        "arrowleft": (123, "\u{F702}"), "left": (123, "\u{F702}"),
        "arrowright": (124, "\u{F703}"), "right": (124, "\u{F703}"),
        "arrowdown": (125, "\u{F701}"), "down": (125, "\u{F701}"),
        "arrowup": (126, "\u{F700}"), "up": (126, "\u{F700}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"),
        "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
    ]

    /// US-layout key codes for letters and digits, so shortcuts like cmd+a reach the page as that key.
    static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
    ]

    public init(keyCode: UInt16, characters: String, modifiers: Set<Modifier> = []) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
    }

    /// Parses "Enter", "cmd+a", "Shift+Tab", "ctrl+option+ArrowUp". Nil when the key is unknown.
    public static func parse(_ spec: String) -> AgentKey? {
        let parts = spec.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let last = parts.last, !last.isEmpty else {
            // "cmd++" style: the key itself is "+".
            return spec.hasSuffix("+") ? AgentKey(keyCode: 24, characters: "+", modifiers: [.shift]) : nil
        }
        var modifiers: Set<Modifier> = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmd", "command", "meta", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "alt", "option", "opt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            default: return nil
            }
        }
        if let (code, chars) = named[last.lowercased()] {
            return AgentKey(keyCode: code, characters: chars, modifiers: modifiers)
        }
        if last.count == 1, let ch = last.first {
            let lower = Character(ch.lowercased())
            if ch.isUppercase { modifiers.insert(.shift) }
            return AgentKey(keyCode: letters[lower] ?? 0, characters: String(ch), modifiers: modifiers)
        }
        return nil
    }

    /// The key code to send with a typed character (0 when the layout position is unknown; the
    /// character itself is what the page receives).
    public static func keyCode(forTyped ch: Character) -> UInt16 {
        if let (code, _) = named[ch == "\n" ? "enter" : ch == "\t" ? "tab" : ch == " " ? "space" : ""] { return code }
        return letters[Character(ch.lowercased())] ?? 0
    }
}

/// Signs that a page is asking "are you human?". Claude never tries to get past these: it stops and
/// hands the page to the person.
public struct PageSignals: Equatable {
    public var title: String
    public var url: String
    /// Addresses of the page's frames (iframes), which is where CAPTCHA widgets live.
    public var frameURLs: [String]
    /// Ids and classes found on the page that belong to known human-check widgets.
    public var markers: [String]
    /// Whether a widget's box is actually on screen (hidden "invisible" reCAPTCHA badges don't count).
    public var visibleWidget: Bool

    public init(title: String, url: String, frameURLs: [String], markers: [String], visibleWidget: Bool) {
        self.title = title
        self.url = url
        self.frameURLs = frameURLs
        self.markers = markers
        self.visibleWidget = visibleWidget
    }
}

public enum HumanCheck {
    static let frameHints: [(String, String)] = [
        ("google.com/recaptcha", "reCAPTCHA"), ("recaptcha.net", "reCAPTCHA"),
        ("hcaptcha.com", "hCaptcha"), ("challenges.cloudflare.com", "Cloudflare check"),
        ("arkoselabs.com", "Arkose check"), ("funcaptcha.com", "Arkose check"),
        ("captcha-delivery.com", "DataDome check"), ("geo.captcha", "CAPTCHA"),
    ]
    static let titleHints: [(String, String)] = [
        ("just a moment", "Cloudflare check"), ("attention required", "Cloudflare check"),
        ("are you a robot", "robot check"), ("are you human", "robot check"),
        ("human verification", "robot check"), ("security check", "security check"),
        ("verify you are human", "robot check"), ("bot verification", "robot check"),
    ]
    static let markerHints: [(String, String)] = [
        ("cf-turnstile", "Cloudflare check"), ("challenge-form", "Cloudflare check"),
        ("cf-challenge", "Cloudflare check"), ("g-recaptcha", "reCAPTCHA"),
        ("h-captcha", "hCaptcha"), ("px-captcha", "PerimeterX check"), ("captcha", "CAPTCHA"),
    ]

    /// What kind of human check the page shows, or nil if none.
    public static func detect(_ signals: PageSignals) -> String? {
        let title = signals.title.lowercased()
        for (hint, name) in titleHints where title.contains(hint) { return name }
        let url = signals.url.lowercased()
        if url.contains("/sorry/") && url.contains("google.") { return "Google robot check" }
        if url.contains("captcha") { return "CAPTCHA" }
        // Widgets only count when they are visible: many sites keep an invisible reCAPTCHA around.
        guard signals.visibleWidget else { return nil }
        for frame in signals.frameURLs.map({ $0.lowercased() }) {
            for (hint, name) in frameHints where frame.contains(hint) {
                // The invisible reCAPTCHA badge loads an "anchor" frame with size=invisible.
                if frame.contains("size=invisible") { continue }
                return name
            }
        }
        for marker in signals.markers.map({ $0.lowercased() }) {
            for (hint, name) in markerHints where marker.contains(hint) { return name }
        }
        return nil
    }
}

/// A smooth pointer path from one point to another, eased in and out, the way a hand moves a mouse.
public enum PointerPath {
    public static func points(from a: (x: Double, y: Double), to b: (x: Double, y: Double)) -> [(x: Double, y: Double)] {
        let distance = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        if distance < 1 { return [b] }
        let steps = max(2, min(24, Int(distance / 28) + 4))
        // A slight arc rather than a ruler-straight line.
        let bend = min(40, distance * 0.08)
        let nx = distance > 0 ? -(b.y - a.y) / distance : 0
        let ny = distance > 0 ? (b.x - a.x) / distance : 0
        return (1...steps).map { i in
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let arc = sin(Double.pi * t) * bend
            return (a.x + (b.x - a.x) * e + nx * arc, a.y + (b.y - a.y) * e + ny * arc)
        }
    }
}
