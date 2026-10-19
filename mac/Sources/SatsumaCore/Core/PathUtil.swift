import Foundation

/// Path helpers named after System.IO.Path, so code ported from the Windows app reads the same.
public enum P {
    public static func trimSlash(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func fileName(_ path: String) -> String { (trimSlash(path) as NSString).lastPathComponent }
    public static func dir(_ path: String) -> String { (trimSlash(path) as NSString).deletingLastPathComponent }

    public static func join(_ first: String, _ rest: String...) -> String {
        rest.reduce(first) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// The extension with its dot (".png"), or "" like Path.GetExtension.
    public static func ext(_ path: String) -> String {
        let e = (fileName(path) as NSString).pathExtension
        return e.isEmpty ? "" : "." + e
    }

    /// File name without its last extension.
    public static func stem(_ path: String) -> String { (fileName(path) as NSString).deletingPathExtension }

    public static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    public static func isFile(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && !d.boolValue
    }

    public static func size(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    public static func createDir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public static func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    /// Like Path.GetFullPath: relative paths resolve against the working directory.
    public static func full(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let abs = expanded.hasPrefix("/") ? expanded : join(FileManager.default.currentDirectoryPath, expanded)
        return trimSlash((abs as NSString).standardizingPath)
    }

    public static func readText(_ path: String) throws -> String {
        let data = try Data(contentsOf: url(path))
        return TextUtil.decode(data)
    }

    public static func writeText(_ path: String, _ text: String, bom: Bool = false) throws {
        var data = Data()
        if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(text.data(using: .utf8) ?? Data())
        try data.write(to: url(path))
    }

    /// Moves a file, replacing whatever is at the destination.
    public static func move(_ from: String, _ to: String) throws {
        if exists(to) { try FileManager.default.removeItem(atPath: to) }
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }
}

public enum TextUtil {
    /// BOM-aware decoding, then strict UTF-8, then Windows-1252 (what most legacy text files on a Mac turn out to be).
    public static func decode(_ data: Data) -> String {
        let b = [UInt8](data.prefix(4))
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Formats a count with thousands separators ("12,345").
    public static func n0(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Invariant number formatting: "0.###"-style, no exponent, no grouping.
    public static func num(_ v: Double, decimals: Int = 3) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }
}
