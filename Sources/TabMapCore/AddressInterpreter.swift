import Foundation

/// Turns what was typed in the address field into a URL: an address if it looks like one, a search otherwise.
public enum AddressInterpreter {
    public static func url(from input: String, searchTemplate: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains(" ") {
            let lower = text.lowercased()
            for scheme in ["http://", "https://", "file://", "about:"] where lower.hasPrefix(scheme) {
                if let u = URL(string: text) { return u }
            }
            let hostAndPort = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? text
            let host = hostAndPort.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? hostAndPort
            let isIP = !host.isEmpty && host.allSatisfy { $0.isNumber || $0 == "." } && host.contains(".")
            let isLocal = host.lowercased() == "localhost"
            let isDomain = host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
                && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            if isLocal || isIP {
                if let u = URL(string: "http://" + text) { return u }
            } else if isDomain {
                if let u = URL(string: "https://" + text) { return u }
            }
        }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: q))
    }
}
