using System.Diagnostics;

namespace Satsuma.Core;

public static class AppPaths
{
    public static string DataDir { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Satsuma");
    public static string LocalDir { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Satsuma");
    public static string TempDir { get; } = Path.Combine(Path.GetTempPath(), "Satsuma");
    public static string SettingsFile => Path.Combine(DataDir, "settings.json");
    public static string LogFile => Path.Combine(LocalDir, "satsuma.log");
    public static string ExePath => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Satsuma.exe");

    public static string Downloads
    {
        get
        {
            var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var dl = Path.Combine(profile, "Downloads");
            return Directory.Exists(dl) ? dl : Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
        }
    }

    public static string NewTempDir(string prefix)
    {
        var dir = Path.Combine(TempDir, prefix + "-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(dir);
        return dir;
    }
}

public static class Log
{
    static readonly object Gate = new();
    static bool _init;

    static void Write(string level, string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] [{Environment.CurrentManagedThreadId}] {message}";
        Debug.WriteLine(line);
        lock (Gate)
        {
            try
            {
                if (!_init)
                {
                    Directory.CreateDirectory(AppPaths.LocalDir);
                    var fi = new FileInfo(AppPaths.LogFile);
                    if (fi.Exists && fi.Length > 2_000_000) File.Move(fi.FullName, fi.FullName + ".old", true);
                    _init = true;
                }
                File.AppendAllText(AppPaths.LogFile, line + Environment.NewLine);
            }
            catch { }
        }
    }

    public static void Info(string m) => Write("INFO", m);
    public static void Warn(string m) => Write("WARN", m);
    public static void Error(string m, Exception? ex = null) => Write("ERROR", ex == null ? m : $"{m}: {ex}");
}
