import Foundation

public enum FileKind {
    case unknown, folder, image, rawImage, svg, gif, video, audio, pdf, wordDoc, text, markdown, html, epub
    case slides, sheet, subtitle, archive
}

public enum FileKinds {
    static let map: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        func add(_ k: FileKind, _ exts: [String]) { for e in exts { m[e] = k } }
        add(.image, ["jpg", "jpeg", "jpe", "jfif", "png", "webp", "heic", "heif", "hif", "avif", "tif", "tiff", "bmp", "dib", "ico", "jxr", "wdp", "dds"])
        add(.rawImage, ["cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "srw", "pef", "nrw", "srf", "sr2", "3fr", "erf", "kdc", "mrw", "x3f"])
        add(.svg, ["svg"])
        add(.gif, ["gif"])
        add(.video, ["mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "mts", "ts", "3gp", "3g2", "ogv", "vob", "asf", "f4v"])
        add(.audio, ["mp3", "m4a", "aac", "wav", "wave", "flac", "ogg", "oga", "opus", "aif", "aiff", "aifc", "wma", "alac", "caf", "amr", "ac3", "mka", "m4b", "mp2", "weba"])
        add(.pdf, ["pdf"])
        add(.wordDoc, ["docx", "doc", "docm", "dotx", "odt", "rtf", "wpd", "pages"])
        add(.text, ["txt", "text", "log"])
        add(.markdown, ["md", "markdown", "mdown", "mkd"])
        add(.html, ["html", "htm", "xhtml", "mht", "mhtml"])
        add(.epub, ["epub"])
        add(.slides, ["pptx", "ppt", "pptm", "pps", "ppsx", "odp", "key"])
        add(.sheet, ["xlsx", "xls", "xlsm", "xlsb", "ods", "csv", "tsv", "tab"])
        add(.subtitle, ["srt", "vtt"])
        add(.archive, ["zip", "tar", "tgz", "gz", "gzip", "7z", "rar", "bz2", "tbz", "tbz2", "xz", "txz", "cab", "iso", "zst", "lzma"])
        return m
    }()

    /// Extension without the dot, lower-case. Handles double extensions like ".tar.gz".
    public static func ext(_ path: String) -> String {
        let name = P.fileName(path).lowercased()
        if name.hasSuffix(".tar.gz") { return "tgz" }
        if name.hasSuffix(".tar.bz2") { return "tbz2" }
        if name.hasSuffix(".tar.xz") { return "txz" }
        return (name as NSString).pathExtension
    }

    /// File name without extension (".tar.gz" counts as one extension).
    public static func baseName(_ path: String) -> String {
        let name = P.fileName(path)
        for dbl in [".tar.gz", ".tar.bz2", ".tar.xz"] where name.lowercased().hasSuffix(dbl) {
            return String(name.dropLast(dbl.count))
        }
        if P.isDir(path) { return name }
        return (name as NSString).deletingPathExtension
    }

    public static func kindOf(_ path: String) -> FileKind {
        if P.isDir(path) { return .folder }
        return map[ext(path)] ?? .unknown
    }

    public static func isImageLike(_ k: FileKind) -> Bool { k == .image || k == .rawImage || k == .gif || k == .svg }

    public static func describe(_ files: [String]) -> String {
        if files.isEmpty { return "" }
        if files.count > 1 { return "\(files.count) items" }
        return P.isDir(files[0]) ? "Folder" : ext(files[0]).uppercased()
    }

    public static func totalSize(_ files: [String]) -> Int64 {
        files.reduce(0) { $0 + (P.isFile($1) ? P.size($1) : 0) }
    }

    public static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes)
        var u = 0
        while v >= 1000 && u < units.count - 1 { v /= 1000; u += 1 }
        if u == 0 { return "\(bytes) B" }
        return v >= 100 ? "\(String(format: "%.0f", v)) \(units[u])" : "\(TextUtil.num(v, decimals: 1)) \(units[u])"
    }
}
