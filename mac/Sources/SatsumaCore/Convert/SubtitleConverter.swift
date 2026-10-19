import Foundation

/// SRT and WebVTT, either way round, and either to plain text.
public enum SubtitleConverter {
    struct Cue { let start: Double; let end: Double; let text: String }

    static let timing = Rx("((?:\\d+:)?\\d{1,2}:\\d{2}[,.]\\d{1,3})\\s*-->\\s*((?:\\d+:)?\\d{1,2}:\\d{2}[,.]\\d{1,3})")
    static let tags = Rx("<[^>]+>|\\{\\\\[^}]*\\}")

    public static func targets(for ext: String) -> [String] { ["srt", "vtt", "txt"].filter { $0 != ext } }

    public static func convert(_ input: String, to target: String) async throws -> String {
        let cues = parse(try DocReaders.readText(input))
        if cues.isEmpty { throw OpError("No subtitle cues found.") }
        let output = OutputPaths.path(for: input, ext: target)
        var out = ""
        switch target {
        case "srt":
            for (i, c) in cues.enumerated() {
                out += "\(i + 1)\r\n\(fmt(c.start, ",")) --> \(fmt(c.end, ","))\r\n" + c.text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n"
            }
        case "vtt":
            out = "WEBVTT\n\n"
            for c in cues { out += "\(fmt(c.start, ".")) --> \(fmt(c.end, "."))\n\(c.text)\n\n" }
        default:
            for c in cues { out += tags.replace(c.text, "").replacingOccurrences(of: "\n", with: " ") + "\n" }
        }
        return try await OutputPaths.writing(output) { o in
            try P.writeText(o, out)
            return o
        }
    }

    static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            if let m = timing.first(lines[i]), let a = Rx.group(m, 1, in: lines[i]), let b = Rx.group(m, 2, in: lines[i]) {
                var body: [String] = []
                var j = i + 1
                while j < lines.count && !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    var l = lines[j]
                    while l.last?.isWhitespace == true { l.removeLast() }
                    body.append(l)
                    j += 1
                }
                cues.append(Cue(start: seconds(a), end: seconds(b), text: body.joined(separator: "\n")))
                i = j
            }
            i += 1
        }
        return cues
    }

    static func seconds(_ s: String) -> Double {
        let parts = s.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        let sec = Double(parts[parts.count - 1]) ?? 0
        let min = parts.count >= 2 ? Double(parts[parts.count - 2]) ?? 0 : 0
        let hours = parts.count > 2 ? Double(parts[parts.count - 3]) ?? 0 : 0
        return hours * 3600 + min * 60 + sec
    }

    static func fmt(_ t: Double, _ sep: String) -> String {
        let totalMs = Int((t * 1000).rounded())
        let h = totalMs / 3_600_000, m = totalMs / 60_000 % 60, s = totalMs / 1000 % 60, ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, ms)
    }
}
