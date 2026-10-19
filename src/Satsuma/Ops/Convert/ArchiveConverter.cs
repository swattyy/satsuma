using System.Diagnostics;
using System.Formats.Tar;
using System.IO.Compression;
using Satsuma.Core;

namespace Satsuma.Ops.Convert;

/// <summary>ZIP / TAR / TAR.GZ / 7Z creation and extraction of anything Windows' bsdtar can read (RAR, 7Z, XZ, ISO…).</summary>
public static class ArchiveConverter
{
    static readonly string TarExe = Path.Combine(Environment.SystemDirectory, "tar.exe");
    static bool? _can7z;

    public static bool CanWrite7z
    {
        get
        {
            if (_can7z.HasValue) return _can7z.Value;
            try
            {
                var dir = AppPaths.NewTempDir("7ztest");
                File.WriteAllText(Path.Combine(dir, "a.txt"), "x");
                var (code, _, _) = Ffmpeg.RunCapture(TarExe, $"-a -cf \"{Path.Combine(dir, "t.7z")}\" -C \"{dir}\" a.txt", 10000);
                _can7z = code == 0 && File.Exists(Path.Combine(dir, "t.7z"));
                try { Directory.Delete(dir, true); } catch { }
            }
            catch { _can7z = false; }
            return _can7z.Value;
        }
    }

    public static IEnumerable<string> ArchiveTargets(string? sourceExt = null)
    {
        foreach (var t in new[] { "zip", "tar", "tgz", "7z" })
        {
            if (t == sourceExt) continue;
            if (t == "7z" && !File.Exists(TarExe)) continue;
            yield return t;
        }
    }

    public static string Label(string target) => target switch { "tgz" => "TAR.GZ", "extract" => "Extract", _ => target.ToUpperInvariant() };

    // ------------------------------------------------------------------ create

    /// <summary>Archives files/folders. A single folder "Photos" becomes "Photos.zip"; several items become "Archive.zip".</summary>
    public static async Task<string> CreateAsync(IReadOnlyList<string> items, string format, Action<double>? progress, CancellationToken ct, string? nameOverride = null)
    {
        var first = items[0].TrimEnd('\\');
        string dir = OutputPaths.DirectoryFor(first);
        string name = nameOverride ?? (items.Count == 1 ? FileKinds.BaseName(first) : "Archive");
        string output = OutputPaths.Unique(dir, name, format == "tgz" ? "tar.gz" : format);
        var entries = Collect(items).ToList();
        try
        {
            switch (format)
            {
                case "zip":
                    await Task.Run(() =>
                    {
                        using var zip = ZipFile.Open(output, ZipArchiveMode.Create);
                        int i = 0;
                        foreach (var (full, rel, isDir) in entries)
                        {
                            ct.ThrowIfCancellationRequested();
                            if (isDir) zip.CreateEntry(rel.Replace('\\', '/') + "/");
                            else zip.CreateEntryFromFile(full, rel.Replace('\\', '/'), CompressionLevel.Optimal);
                            progress?.Invoke(++i / (double)entries.Count);
                        }
                    }, ct);
                    break;
                case "tar":
                case "tgz":
                    await Task.Run(() =>
                    {
                        using var fs = File.Create(output);
                        using Stream s = format == "tgz" ? new GZipStream(fs, CompressionLevel.Optimal) : fs;
                        using var tar = new TarWriter(s, TarEntryFormat.Pax, leaveOpen: false);
                        int i = 0;
                        foreach (var (full, rel, _) in entries)
                        {
                            ct.ThrowIfCancellationRequested();
                            tar.WriteEntry(full, rel.Replace('\\', '/'));
                            progress?.Invoke(++i / (double)entries.Count);
                        }
                    }, ct);
                    break;
                case "7z":
                {
                    // bsdtar picks the 7-Zip writer from the extension (-a). Paths are relative to the common parent.
                    string parent = Path.GetDirectoryName(first)!;
                    var args = $"-a -cf \"{output}\" -C \"{parent}\" " + string.Join(" ", items.Select(p => "\"" + Path.GetFileName(p.TrimEnd('\\')) + "\""));
                    await RunTarAsync(args, ct);
                    break;
                }
                default: throw new OpException("Unsupported archive format " + format);
            }
            return output;
        }
        catch { OutputPaths.Discard(output); throw; }
    }

    /// <summary>(full path, path inside the archive, isDirectory) for every item, recursing into folders.</summary>
    static IEnumerable<(string full, string rel, bool isDir)> Collect(IReadOnlyList<string> items)
    {
        foreach (var item in items.Select(i => i.TrimEnd('\\')))
        {
            string name = Path.GetFileName(item);
            if (File.Exists(item)) { yield return (item, name, false); continue; }
            if (!Directory.Exists(item)) continue;
            yield return (item, name, true);
            foreach (var d in Directory.EnumerateDirectories(item, "*", SearchOption.AllDirectories))
                yield return (d, Path.Combine(name, Path.GetRelativePath(item, d)), true);
            foreach (var f in Directory.EnumerateFiles(item, "*", SearchOption.AllDirectories))
                yield return (f, Path.Combine(name, Path.GetRelativePath(item, f)), false);
        }
    }

    // ------------------------------------------------------------------ extract

    public static async Task<string> ExtractAsync(string archive, CancellationToken ct)
    {
        string ext = FileKinds.Ext(archive);
        string dir = OutputPaths.DirectoryFor(archive);
        string baseName = FileKinds.BaseName(archive);

        if (ext is "gz" or "gzip" && !baseName.EndsWith(".tar", StringComparison.OrdinalIgnoreCase))
        {
            // A single gzipped file: "notes.txt.gz" → "notes.txt".
            string target = OutputPaths.Unique(dir, Path.GetFileNameWithoutExtension(baseName), Path.GetExtension(baseName).TrimStart('.'));
            await using var input = File.OpenRead(archive);
            await using var gz = new GZipStream(input, CompressionMode.Decompress);
            await using var output = File.Create(target);
            await gz.CopyToAsync(output, ct);
            return target;
        }

        string dest = OutputPaths.Unique(dir, baseName, "");
        Directory.CreateDirectory(dest);
        try
        {
            switch (ext)
            {
                case "zip":
                    await Task.Run(() => ZipFile.ExtractToDirectory(archive, dest, overwriteFiles: false), ct);
                    break;
                case "tar":
                    await Task.Run(() => TarFile.ExtractToDirectory(archive, dest, overwriteFiles: false), ct);
                    break;
                case "tgz" or "gz" or "gzip":
                    await Task.Run(() =>
                    {
                        using var fs = File.OpenRead(archive);
                        using var gz = new GZipStream(fs, CompressionMode.Decompress);
                        TarFile.ExtractToDirectory(gz, dest, overwriteFiles: false);
                    }, ct);
                    break;
                default:
                    if (!File.Exists(TarExe)) throw new OpException($".{ext} archives need Windows 10 1803 or newer.");
                    await RunTarAsync($"-xf \"{archive}\" -C \"{dest}\"", ct);
                    break;
            }
        }
        catch (Exception ex) when (ex is InvalidDataException or IOException && ex is not OpException)
        {
            try { Directory.Delete(dest, true); } catch { }
            throw new OpException("Couldn't extract: " + ex.Message);
        }
        return Unwrap(dest);
    }

    /// <summary>If the archive held a single top-level item, move it up instead of nesting "foo/foo".</summary>
    static string Unwrap(string dest)
    {
        try
        {
            var entries = Directory.EnumerateFileSystemEntries(dest).ToList();
            if (entries.Count != 1) return dest;
            string only = entries[0];
            string parent = Path.GetDirectoryName(dest)!;
            bool isDir = Directory.Exists(only);
            string name = Path.GetFileName(only);
            string tempName = dest + ".unwrap-" + Guid.NewGuid().ToString("N")[..6];
            if (isDir) Directory.Move(only, tempName); else File.Move(only, tempName);
            Directory.Delete(dest);
            string final = isDir
                ? OutputPaths.Unique(parent, name, "")
                : OutputPaths.Unique(parent, Path.GetFileNameWithoutExtension(name), Path.GetExtension(name).TrimStart('.'));
            if (isDir) Directory.Move(tempName, final); else File.Move(tempName, final);
            return final;
        }
        catch { return dest; }
    }

    public static async Task<string> RepackAsync(string archive, string format, Action<double>? progress, CancellationToken ct)
    {
        var tmp = AppPaths.NewTempDir("repack");
        try
        {
            var inner = Path.Combine(tmp, FileKinds.BaseName(archive));
            Directory.CreateDirectory(inner);
            string ext = FileKinds.Ext(archive);
            if (ext == "zip") ZipFile.ExtractToDirectory(archive, inner);
            else if (ext == "tar") TarFile.ExtractToDirectory(archive, inner, false);
            else if (ext is "tgz" or "gz")
            {
                using var fs = File.OpenRead(archive);
                using var gz = new GZipStream(fs, CompressionMode.Decompress);
                TarFile.ExtractToDirectory(gz, inner, false);
            }
            else await RunTarAsync($"-xf \"{archive}\" -C \"{inner}\"", ct);

            // Archive the extracted contents (not the temp folder itself) next to the original.
            var children = Directory.EnumerateFileSystemEntries(inner).ToList();
            if (children.Count == 0) throw new OpException("The archive is empty.");
            var output = OutputPaths.Unique(OutputPaths.DirectoryFor(archive), FileKinds.BaseName(archive), format == "tgz" ? "tar.gz" : format);
            var built = await CreateAsync(children, format, progress, ct, nameOverride: Path.GetFileNameWithoutExtension(output));
            if (!string.Equals(Path.GetDirectoryName(built), Path.GetDirectoryName(output), StringComparison.OrdinalIgnoreCase))
            {
                File.Move(built, output);
                return output;
            }
            return built;
        }
        finally { try { Directory.Delete(tmp, true); } catch { } }
    }

    static async Task RunTarAsync(string args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(TarExe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        using var p = Process.Start(psi)!;
        var err = p.StandardError.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct);
        if (p.ExitCode != 0)
        {
            var msg = (await err).Trim().Split('\n').LastOrDefault()?.Trim() ?? "tar failed";
            throw new OpException(msg.Replace("tar.exe: ", ""));
        }
    }
}
