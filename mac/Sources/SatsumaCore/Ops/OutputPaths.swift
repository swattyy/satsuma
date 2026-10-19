import Foundation

/// Chooses where results go: next to the original (default), Downloads, or a custom folder.
public enum OutputPaths {
    public static func directoryFor(_ input: String) -> String {
        let s = Settings.current
        if s.output == .downloads { return AppPaths.downloads }
        if s.output == .customFolder, let custom = s.customOutputFolder,
           !custom.trimmingCharacters(in: .whitespaces).isEmpty, P.isDir(custom) {
            return custom
        }
        let dir = P.dir(input)
        if dir.isEmpty || isTemp(dir) || !isWritable(dir) { return AppPaths.downloads }
        return dir
    }

    static func isTemp(_ dir: String) -> Bool {
        if Runtime.isTestMode { return false }
        let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        return resolved.hasPrefix(AppPaths.tempDir)
    }

    private static var writable: [String: Bool] = [:]
    private static let lock = NSLock()

    static func isWritable(_ dir: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let ok = writable[dir] { return ok }
        let probe = P.join(dir, ".satsuma-" + UUID().uuidString.prefix(6).lowercased())
        let ok = FileManager.default.createFile(atPath: probe, contents: nil)
        if ok { P.remove(probe) }
        writable[dir] = ok
        return ok
    }

    /// "photo.jpg" + "png" gives "photo.png", or "photo 2.png" if that's taken.
    public static func path(for input: String, ext newExt: String, suffix: String? = nil) -> String {
        unique(dir: directoryFor(input), baseName: FileKinds.baseName(input) + (suffix ?? ""), ext: newExt)
    }

    public static func unique(dir: String, baseName: String, ext: String) -> String {
        var e = ext
        while e.hasPrefix(".") { e.removeFirst() }
        let dotExt = e.isEmpty ? "" : "." + e
        var candidate = P.join(dir, baseName + dotExt)
        var i = 2
        while P.exists(candidate) {
            candidate = P.join(dir, "\(baseName) \(i)\(dotExt)")
            i += 1
        }
        return candidate
    }

    /// A fresh folder next to the input, e.g. "report pages".
    public static func folderFor(_ input: String, suffix: String) throws -> String {
        let path = unique(dir: directoryFor(input), baseName: FileKinds.baseName(input) + suffix, ext: "")
        try P.createDir(path)
        return path
    }

    /// Deletes a partially written output after a failure. Folders are only removed when empty.
    public static func discard(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        if P.isFile(path) { P.remove(path) }
        else if P.isDir(path), (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true { P.remove(path) }
    }

    /// Runs `body` with a fresh output path and removes the partial file if it throws.
    public static func writing<T>(_ output: String, _ body: (String) async throws -> T) async throws -> T {
        do { return try await body(output) }
        catch { discard(output); throw error }
    }
}
