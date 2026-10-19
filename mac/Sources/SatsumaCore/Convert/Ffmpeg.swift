import Foundation

/// Joins argument lists; long `+` chains of array literals are slow for the type checker.
func cat(_ parts: [String]...) -> [String] { parts.flatMap { $0 } }

public struct MediaStream {
    public let type: String
    public let codec: String
    public let width: Int
    public let height: Int
    public let channels: Int
    public let pixFmt: String
    public let bitsPerSample: Int
    public let sampleFmt: String
    public let attachedPic: Bool
}

public struct MediaInfo {
    public let duration: Double
    public let streams: [MediaStream]
    public let format: String

    public var video: MediaStream? { streams.first { $0.type == "video" && !$0.attachedPic } }
    public var audio: MediaStream? { streams.first { $0.type == "audio" } }
    public var hasCover: Bool { streams.contains { $0.attachedPic } }

    public static let empty = MediaInfo(duration: 0, streams: [], format: "")
}

/// Locates and drives ffmpeg/ffprobe (Homebrew, MacPorts or a path set in Settings). FFmpeg is never bundled.
public enum Ffmpeg {
    private static let lock = NSLock()
    private static var located = false
    private static var ffmpegPath: String?
    private static var ffprobePath: String?
    private static var encoders: Set<String>?

    public static var path: String? { locate(); return ffmpegPath }
    public static var available: Bool { path != nil }

    public static func reset() {
        lock.lock()
        located = false
        ffmpegPath = nil
        ffprobePath = nil
        encoders = nil
        lock.unlock()
    }

    static func locate() {
        lock.lock()
        defer { lock.unlock() }
        if located { return }
        located = true
        var candidates: [String] = []
        if let custom = Settings.current.ffmpegPath, !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates.append(P.isDir(custom) ? P.join(custom, "ffmpeg") : custom)
        }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        if let onPath = Proc.which("ffmpeg") { candidates.append(onPath) }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            ffmpegPath = c
            let real = URL(fileURLWithPath: c).resolvingSymlinksInPath().path
            ffprobePath = [P.join(P.dir(c), "ffprobe"), P.join(P.dir(real), "ffprobe")].first { FileManager.default.isExecutableFile(atPath: $0) }
            Log.info("ffmpeg: \(c)")
            return
        }
    }

    /// Where Homebrew lives, for the install button in Settings.
    public static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func require() throws -> String {
        guard let p = path else { throw OpError("FFmpeg isn't installed. Open Satsuma Settings > Engines to install it.") }
        return p
    }

    public static func hasEncoder(_ name: String) -> Bool {
        guard let exe = path else { return false }
        lock.lock()
        let cached = encoders
        lock.unlock()
        if let cached { return cached.contains(name) }
        var set = Set<String>()
        let r = Proc.capture(exe, ["-hide_banner", "-encoders"], timeout: 15)
        for line in r.stdout.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 && parts[0].count == 6 { set.insert(String(parts[1])) }
        }
        lock.lock()
        encoders = set
        lock.unlock()
        return set.contains(name)
    }

    public static func probe(_ file: String) -> MediaInfo {
        locate()
        guard let probe = ffprobePath else { return .empty }
        let r = Proc.capture(probe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", file], timeout: 30)
        guard r.code == 0, let data = r.stdout.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .empty }
        var duration = 0.0
        var format = ""
        if let fmt = root["format"] as? [String: Any] {
            duration = Double(fmt["duration"] as? String ?? "") ?? 0
            format = fmt["format_name"] as? String ?? ""
        }
        var streams: [MediaStream] = []
        for s in root["streams"] as? [[String: Any]] ?? [] {
            func str(_ k: String) -> String { s[k] as? String ?? "" }
            func int(_ k: String) -> Int {
                if let n = s[k] as? Int { return n }
                if let t = s[k] as? String, let n = Int(t) { return n }
                return 0
            }
            let attached = ((s["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            if duration <= 0, let d = s["duration"] as? String, let v = Double(d) { duration = v }
            streams.append(MediaStream(type: str("codec_type"), codec: str("codec_name"), width: int("width"), height: int("height"),
                                       channels: int("channels"), pixFmt: str("pix_fmt"), bitsPerSample: int("bits_per_raw_sample"),
                                       sampleFmt: str("sample_fmt"), attachedPic: attached))
        }
        return MediaInfo(duration: duration, streams: streams, format: format)
    }

    /// Runs ffmpeg with progress parsing. Throws with ffmpeg's last error line on failure.
    public static func run(_ args: [String], duration: Double, progress: ((Double) -> Void)?) async throws {
        let exe = try require()
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + args
        Log.info("ffmpeg " + full.joined(separator: " "))
        let r = try await Proc.run(exe, full) { line in
            guard let progress, duration > 0 else { return }
            for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
                if let us = Double(line.dropFirst(key.count)) { progress(min(max(us / 1_000_000 / duration, 0), 1)) }
            }
        }
        if r.code != 0 {
            Log.warn("ffmpeg failed: \(r.stderr)")
            throw OpError("FFmpeg: " + r.lastError)
        }
    }
}
