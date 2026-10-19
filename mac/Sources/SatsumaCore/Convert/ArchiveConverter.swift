import Foundation

/// ZIP, TAR, TAR.GZ and 7Z creation, and extraction of anything macOS's bsdtar can read (RAR, 7Z, XZ, ISO...).
public enum ArchiveConverter {
    static let tar = "/usr/bin/tar"
    /// Keeps Finder metadata out of archives (no "._name" AppleDouble files).
    static let env = ["COPYFILE_DISABLE": "1"]

    public static func archiveTargets(excluding sourceExt: String? = nil) -> [String] {
        ["zip", "tar", "tgz", "7z"].filter { t in
            if t == sourceExt { return false }
            if t == "7z" && !FileManager.default.isExecutableFile(atPath: tar) { return false }
            return true
        }
    }

    public static func label(_ target: String) -> String {
        switch target {
        case "tgz": return "TAR.GZ"
        case "extract": return "Extract"
        default: return target.uppercased()
        }
    }

    // ------------------------------------------------------------------ create

    /// Archives files and folders. A single folder "Photos" becomes "Photos.zip"; several items become "Archive.zip".
    public static func create(_ items: [String], format: String, progress: ((Double) -> Void)? = nil) async throws -> String {
        let first = P.trimSlash(items[0])
        let name = items.count == 1 ? FileKinds.baseName(first) : "Archive"
        let output = OutputPaths.unique(dir: OutputPaths.directoryFor(first), baseName: name, ext: format == "tgz" ? "tar.gz" : format)
        return try await OutputPaths.writing(output) { out in
            try await build(items, format: format, output: out, progress: progress)
            return out
        }
    }

    static func build(_ items: [String], format: String, output: String, progress: ((Double) -> Void)?) async throws {
        let total = max(1, countEntries(items))
        var args: [String]
        switch format {
        case "zip": args = ["--format", "zip", "-cvf", output]
        case "tar": args = ["--format", "pax", "-cvf", output]
        case "tgz": args = ["--format", "pax", "-czvf", output]
        case "7z": args = ["--format", "7zip", "-cvf", output]
        default: throw OpError("Unsupported archive format \(format)")
        }
        args += ["--exclude", ".DS_Store"]
        // Each item is stored under its own name, relative to its folder.
        for item in items.map(P.trimSlash) { args += ["-C", P.dir(item), P.fileName(item)] }
        let counter = Counter()
        // bsdtar lists each entry on stderr with -v, which makes a progress count.
        let r = try await Proc.run(tar, args, env: env, onErrLine: { _ in progress?(min(1, Double(counter.next()) / Double(total))) })
        if r.code != 0 || !P.exists(output) {
            let lines = r.stderr.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("a ") }
            throw OpError(clean(lines.last ?? "exit code \(r.code)"))
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    static func countEntries(_ items: [String]) -> Int {
        var n = 0
        for item in items {
            n += 1
            if P.isDir(item), let e = FileManager.default.enumerator(atPath: item) {
                while e.nextObject() != nil { n += 1 }
            }
        }
        return n
    }

    // ------------------------------------------------------------------ extract

    public static func extract(_ archive: String) async throws -> String {
        let ext = FileKinds.ext(archive)
        let dir = OutputPaths.directoryFor(archive)
        let baseName = FileKinds.baseName(archive)

        if (ext == "gz" || ext == "gzip") && !baseName.lowercased().hasSuffix(".tar") {
            // A single gzipped file: "notes.txt.gz" becomes "notes.txt".
            let target = OutputPaths.unique(dir: dir, baseName: (baseName as NSString).deletingPathExtension, ext: (baseName as NSString).pathExtension)
            let tmp = try AppPaths.newTempDir("gunzip")
            defer { P.remove(tmp) }
            let copy = P.join(tmp, "data.gz")
            try FileManager.default.copyItem(atPath: archive, toPath: copy)
            let r = try await Proc.run("/usr/bin/gzip", ["-d", "-f", copy])
            let plain = P.join(tmp, "data")
            if r.code != 0 || !P.exists(plain) { throw OpError("Couldn't extract: " + r.lastError) }
            try FileManager.default.moveItem(atPath: plain, toPath: target)
            return target
        }

        let dest = OutputPaths.unique(dir: dir, baseName: baseName, ext: "")
        try P.createDir(dest)
        do { try await unpack(archive, into: dest) }
        catch { P.remove(dest); throw error }
        return unwrap(dest)
    }

    static func unpack(_ archive: String, into dest: String) async throws {
        let r: Proc.Result
        if FileKinds.ext(archive) == "zip" { r = try await Proc.run("/usr/bin/ditto", ["-x", "-k", archive, dest], env: env) }
        else { r = try await Proc.run(tar, ["-xf", archive, "-C", dest], env: env) }
        if r.code != 0 { throw OpError("Couldn't extract: " + clean(r.lastError)) }
    }

    /// If the archive held a single top-level item, move it up instead of nesting "foo/foo".
    static func unwrap(_ dest: String) -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dest).filter({ $0 != ".DS_Store" && $0 != "__MACOSX" }),
              entries.count == 1 else { return dest }
        let only = P.join(dest, entries[0])
        let parent = P.dir(dest)
        let isDir = P.isDir(only)
        let name = entries[0]
        let temp = dest + ".unwrap-" + UUID().uuidString.prefix(6).lowercased()
        do {
            try FileManager.default.moveItem(atPath: only, toPath: temp)
            try FileManager.default.removeItem(atPath: dest)
            let final = isDir ? OutputPaths.unique(dir: parent, baseName: name, ext: "")
                              : OutputPaths.unique(dir: parent, baseName: (name as NSString).deletingPathExtension, ext: (name as NSString).pathExtension)
            try FileManager.default.moveItem(atPath: temp, toPath: final)
            return final
        } catch {
            return P.exists(dest) ? dest : temp
        }
    }

    public static func repack(_ archive: String, to format: String, progress: ((Double) -> Void)? = nil) async throws -> String {
        let tmp = try AppPaths.newTempDir("repack")
        defer { P.remove(tmp) }
        let inner = P.join(tmp, FileKinds.baseName(archive))
        try P.createDir(inner)
        try await unpack(archive, into: inner)
        let children = (try? FileManager.default.contentsOfDirectory(atPath: inner))?.filter { $0 != ".DS_Store" && $0 != "__MACOSX" }.map { P.join(inner, $0) } ?? []
        if children.isEmpty { throw OpError("The archive is empty.") }
        // Archive the extracted contents (not the temp folder itself) next to the original.
        let output = OutputPaths.unique(dir: OutputPaths.directoryFor(archive), baseName: FileKinds.baseName(archive), ext: format == "tgz" ? "tar.gz" : format)
        return try await OutputPaths.writing(output) { out in
            try await build(children, format: format, output: out, progress: progress)
            return out
        }
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "tar: ", with: "").replacingOccurrences(of: "ditto: ", with: "")
    }
}
