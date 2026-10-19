using System.Diagnostics;
using Satsuma.Native;

namespace Satsuma.Core;

public static class Shell
{
    /// <summary>Opens Explorer with the given items selected (all must share a folder; otherwise the first folder wins).</summary>
    public static void RevealInExplorer(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        try
        {
            var first = paths[0].TrimEnd('\\');
            var folder = Path.GetDirectoryName(first);
            if (folder == null) { Open(first); return; }
            var same = paths.Where(p => string.Equals(Path.GetDirectoryName(p.TrimEnd('\\')), folder, StringComparison.OrdinalIgnoreCase)).ToList();
            IntPtr pidlFolder = Win32.ILCreateFromPath(folder);
            var items = same.Select(p => Win32.ILCreateFromPath(p.TrimEnd('\\'))).Where(p => p != IntPtr.Zero).ToArray();
            try
            {
                if (pidlFolder == IntPtr.Zero || Win32.SHOpenFolderAndSelectItems(pidlFolder, (uint)items.Length, items, 0) != 0)
                    Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{first}\"") { UseShellExecute = true });
            }
            finally
            {
                if (pidlFolder != IntPtr.Zero) Win32.ILFree(pidlFolder);
                foreach (var p in items) Win32.ILFree(p);
            }
        }
        catch (Exception ex) { Log.Warn("Reveal failed: " + ex.Message); }
    }

    public static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn("Open failed: " + ex.Message); }
    }

    /// <summary>Finds an executable on PATH or returns null.</summary>
    public static string? Which(string exe)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim().Trim('"'), exe);
                if (File.Exists(candidate)) return candidate;
            }
            catch { }
        }
        return null;
    }
}
