using Satsuma.Core;

namespace Satsuma.Ops;

/// <summary>Chooses where results go: next to the original (default), Downloads, or a custom folder.</summary>
public static class OutputPaths
{
    public static string DirectoryFor(string input)
    {
        var s = Settings.Current;
        if (s.Output == OutputLocation.Downloads) return AppPaths.Downloads;
        if (s.Output == OutputLocation.CustomFolder && !string.IsNullOrWhiteSpace(s.CustomOutputFolder) && Directory.Exists(s.CustomOutputFolder))
            return s.CustomOutputFolder!;
        var dir = Path.GetDirectoryName(input.TrimEnd('\\'));
        if (string.IsNullOrEmpty(dir) || IsTemp(dir) || !IsWritable(dir)) return AppPaths.Downloads;
        return dir;
    }

    static bool IsTemp(string dir) =>
        dir.StartsWith(AppPaths.TempDir, StringComparison.OrdinalIgnoreCase) && !Program.IsTestMode;

    static readonly Dictionary<string, bool> WritableCache = new(StringComparer.OrdinalIgnoreCase);

    static bool IsWritable(string dir)
    {
        lock (WritableCache)
        {
            if (WritableCache.TryGetValue(dir, out var ok)) return ok;
            try
            {
                var probe = Path.Combine(dir, ".satsuma-" + Guid.NewGuid().ToString("N")[..6]);
                using (File.Create(probe, 1, FileOptions.DeleteOnClose)) { }
                ok = true;
            }
            catch { ok = false; }
            WritableCache[dir] = ok;
            return ok;
        }
    }

    /// <summary>"photo.jpg" + "png" → "photo.png", or "photo 2.png" if taken.</summary>
    public static string For(string input, string newExt, string? suffix = null)
    {
        var dir = DirectoryFor(input);
        var baseName = FileKinds.BaseName(input) + (suffix ?? "");
        return Unique(dir, baseName, newExt);
    }

    public static string Unique(string dir, string baseName, string ext)
    {
        string dotExt = string.IsNullOrEmpty(ext) ? "" : "." + ext.TrimStart('.');
        string candidate = Path.Combine(dir, baseName + dotExt);
        for (int i = 2; File.Exists(candidate) || Directory.Exists(candidate); i++)
            candidate = Path.Combine(dir, $"{baseName} {i}{dotExt}");
        return candidate;
    }

    /// <summary>A fresh folder next to the input, e.g. "report pages".</summary>
    public static string FolderFor(string input, string suffix)
    {
        var dir = DirectoryFor(input);
        var path = Unique(dir, FileKinds.BaseName(input) + suffix, "");
        Directory.CreateDirectory(path);
        return path;
    }

    /// <summary>Deletes a partially written output after a failure.</summary>
    public static void Discard(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            if (File.Exists(path)) File.Delete(path);
            else if (Directory.Exists(path) && !Directory.EnumerateFileSystemEntries(path).Any()) Directory.Delete(path);
        }
        catch { }
    }
}
