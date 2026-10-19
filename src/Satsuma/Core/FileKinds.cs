namespace Satsuma.Core;

public enum FileKind
{
    Unknown, Folder, Image, RawImage, Svg, Gif, Video, Audio, Pdf, WordDoc, Text, Markdown, Html, Epub,
    Slides, Sheet, Subtitle, Archive,
}

public static class FileKinds
{
    static readonly Dictionary<string, FileKind> Map = new(StringComparer.OrdinalIgnoreCase);

    static FileKinds()
    {
        void Add(FileKind k, params string[] exts) { foreach (var e in exts) Map[e] = k; }
        Add(FileKind.Image, "jpg", "jpeg", "jpe", "jfif", "png", "webp", "heic", "heif", "hif", "avif", "tif", "tiff", "bmp", "dib", "ico", "jxr", "wdp", "dds");
        Add(FileKind.RawImage, "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "srw", "pef", "nrw", "srf", "sr2", "3fr", "erf", "kdc", "mrw", "x3f");
        Add(FileKind.Svg, "svg");
        Add(FileKind.Gif, "gif");
        Add(FileKind.Video, "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "mts", "ts", "3gp", "3g2", "ogv", "vob", "asf", "f4v");
        Add(FileKind.Audio, "mp3", "m4a", "aac", "wav", "wave", "flac", "ogg", "oga", "opus", "aif", "aiff", "aifc", "wma", "alac", "caf", "amr", "ac3", "mka", "m4b", "mp2", "weba");
        Add(FileKind.Pdf, "pdf");
        Add(FileKind.WordDoc, "docx", "doc", "docm", "dotx", "odt", "rtf", "wpd", "pages");
        Add(FileKind.Text, "txt", "text", "log");
        Add(FileKind.Markdown, "md", "markdown", "mdown", "mkd");
        Add(FileKind.Html, "html", "htm", "xhtml", "mht", "mhtml");
        Add(FileKind.Epub, "epub");
        Add(FileKind.Slides, "pptx", "ppt", "pptm", "pps", "ppsx", "odp", "key");
        Add(FileKind.Sheet, "xlsx", "xls", "xlsm", "xlsb", "ods", "csv", "tsv", "tab");
        Add(FileKind.Subtitle, "srt", "vtt");
        Add(FileKind.Archive, "zip", "tar", "tgz", "gz", "gzip", "7z", "rar", "bz2", "tbz", "tbz2", "xz", "txz", "cab", "iso", "zst", "lzma");
    }

    /// <summary>Extension without the dot, lower-case. Handles double extensions like ".tar.gz".</summary>
    public static string Ext(string path)
    {
        var name = Path.GetFileName(path).ToLowerInvariant();
        if (name.EndsWith(".tar.gz")) return "tgz";
        if (name.EndsWith(".tar.bz2")) return "tbz2";
        if (name.EndsWith(".tar.xz")) return "txz";
        var e = Path.GetExtension(name);
        return e.Length > 1 ? e[1..] : "";
    }

    /// <summary>File name without extension (".tar.gz" counts as one extension).</summary>
    public static string BaseName(string path)
    {
        var name = Path.GetFileName(path.TrimEnd('\\', '/'));
        foreach (var dbl in new[] { ".tar.gz", ".tar.bz2", ".tar.xz" })
            if (name.EndsWith(dbl, StringComparison.OrdinalIgnoreCase)) return name[..^dbl.Length];
        if (Directory.Exists(path)) return name;
        return Path.GetFileNameWithoutExtension(name);
    }

    public static FileKind KindOf(string path)
    {
        if (Directory.Exists(path)) return FileKind.Folder;
        return Map.TryGetValue(Ext(path), out var k) ? k : FileKind.Unknown;
    }

    public static bool IsImageLike(FileKind k) => k is FileKind.Image or FileKind.RawImage or FileKind.Gif or FileKind.Svg;

    public static string Describe(IReadOnlyList<string> files)
    {
        if (files.Count == 0) return "";
        if (files.Count > 1) return $"{files.Count} items";
        return Directory.Exists(files[0]) ? "Folder" : Ext(files[0]).ToUpperInvariant();
    }

    public static long TotalSize(IReadOnlyList<string> files)
    {
        long total = 0;
        foreach (var f in files)
        {
            try { if (File.Exists(f)) total += new FileInfo(f).Length; } catch { }
        }
        return total;
    }

    public static string HumanSize(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double v = bytes; int u = 0;
        while (v >= 1000 && u < units.Length - 1) { v /= 1000; u++; }
        return u == 0 ? $"{bytes} B" : v >= 100 ? $"{v:0} {units[u]}" : $"{v:0.#} {units[u]}";
    }
}
