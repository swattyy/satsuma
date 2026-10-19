import Foundation

/// Set by the command line test modes (lets outputs land next to temp inputs).
public enum Runtime {
    public static var isTestMode = false
}

public enum AppPaths {
    public static let dataDir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return P.join(base, "Satsuma")
    }()

    public static let logDir: String = P.join(NSHomeDirectory(), "Library/Logs/Satsuma")

    /// Our own temp folder. Symlinks are resolved so /var and /private/var compare equal.
    public static let tempDir: String = {
        let raw = P.join(NSTemporaryDirectory(), "Satsuma")
        try? FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }()

    public static var settingsFile: String { P.join(dataDir, "settings.json") }
    public static var logFile: String { P.join(logDir, "satsuma.log") }

    public static var downloads: String {
        if let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path, P.isDir(dl) { return dl }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    public static func newTempDir(_ prefix: String) throws -> String {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let dir = P.join(tempDir, "\(prefix)-\(id)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

public enum Log {
    private static let lock = NSLock()
    private static var ready = false
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Also print to stderr (set SATSUMA_LOG_STDERR=1, used by CI).
    public static var echo = ProcessInfo.processInfo.environment["SATSUMA_LOG_STDERR"] == "1"

    public static func info(_ m: String) { write("INFO", m) }
    public static func warn(_ m: String) { write("WARN", m) }
    public static func error(_ m: String, _ error: Error? = nil) { write("ERROR", error.map { "\(m): \($0)" } ?? m) }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) [\(level)] \(message)\n"
        if echo { FileHandle.standardError.write(line.data(using: .utf8) ?? Data()) }
        do {
            if !ready {
                try FileManager.default.createDirectory(atPath: AppPaths.logDir, withIntermediateDirectories: true)
                if P.size(AppPaths.logFile) > 2_000_000 {
                    P.remove(AppPaths.logFile + ".old")
                    try? FileManager.default.moveItem(atPath: AppPaths.logFile, toPath: AppPaths.logFile + ".old")
                }
                ready = true
            }
            if !P.exists(AppPaths.logFile) { FileManager.default.createFile(atPath: AppPaths.logFile, contents: nil) }
            if let h = FileHandle(forWritingAtPath: AppPaths.logFile) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8) ?? Data())
                h.closeFile()
            }
        } catch {}
    }
}
