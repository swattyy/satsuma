import Foundation

/// NSRegularExpression with the handful of helpers the ported code needs.
public struct Rx {
    public let re: NSRegularExpression

    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func ns(_ s: String) -> NSRange { NSRange(s.startIndex..<s.endIndex, in: s) }

    public func matches(_ s: String) -> [NSTextCheckingResult] { re.matches(in: s, range: Rx.ns(s)) }
    public func first(_ s: String) -> NSTextCheckingResult? { re.firstMatch(in: s, range: Rx.ns(s)) }
    public func test(_ s: String) -> Bool { first(s) != nil }
    public func count(_ s: String) -> Int { re.numberOfMatches(in: s, range: Rx.ns(s)) }

    /// Replaces matches with a template ("$1" refers to groups).
    public func replace(_ s: String, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: Rx.ns(s), withTemplate: template)
    }

    /// Splits around matches, like Regex.Split.
    public func split(_ s: String) -> [String] {
        var parts: [String] = []
        var last = s.startIndex
        for m in matches(s) {
            guard let r = Range(m.range, in: s) else { continue }
            parts.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(s[last...]))
        return parts
    }

    /// The text of group `i`, or nil when it didn't take part in the match.
    public static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
        return String(s[range])
    }
}

public enum Html {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•",
        "middot": "·", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "times": "×", "divide": "÷", "deg": "°",
        "laquo": "«", "raquo": "»", "sect": "§", "para": "¶", "plusmn": "±", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß",
        "ccedil": "ç", "ntilde": "ñ", "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "shy": "\u{00AD}", "zwj": "\u{200D}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
    ]
    static let entity = Rx("&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")

    /// Decodes character references like WebUtility.HtmlDecode (common named entities plus all numeric ones).
    public static func decode(_ s: String) -> String {
        if !s.contains("&") { return s }
        var out = ""
        var last = s.startIndex
        for m in entity.matches(s) {
            guard let r = Range(m.range, in: s), let name = Rx.group(m, 1, in: s) else { continue }
            out += s[last..<r.lowerBound]
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
            } else if name.hasPrefix("#") {
                if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
            } else {
                replacement = named[name]
            }
            out += replacement ?? String(s[r])
            last = r.upperBound
        }
        out += s[last...]
        return out
    }

    /// Escaping like WebUtility.HtmlEncode, keeping apostrophes readable.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
