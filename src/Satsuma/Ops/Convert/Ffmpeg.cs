using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Satsuma.Core;

namespace Satsuma.Ops.Convert;

public sealed record MediaStream(string Type, string Codec, int Width, int Height, int Channels, string? PixFmt, int BitsPerSample, string? SampleFmt, bool AttachedPic);
public sealed record MediaInfo(double Duration, IReadOnlyList<MediaStream> Streams, string Format)
{
    public MediaStream? Video => Streams.FirstOrDefault(s => s.Type == "video" && !s.AttachedPic);
    public MediaStream? Audio => Streams.FirstOrDefault(s => s.Type == "audio");
    public bool HasCover => Streams.Any(s => s.AttachedPic);
}

/// <summary>Locates and drives ffmpeg/ffprobe with progress reporting.</summary>
public static class Ffmpeg
{
    static string? _ffmpeg, _ffprobe;
    static readonly object Gate = new();
    static HashSet<string>? _encoders;

    public static string? FfmpegPath { get { Locate(); return _ffmpeg; } }
    public static bool Available => FfmpegPath != null;

    public static void Reset() { lock (Gate) { _ffmpeg = _ffprobe = null; _encoders = null; } }

    static void Locate()
    {
        lock (Gate)
        {
            if (_ffmpeg != null) return;
            var candidates = new List<string>();
            var custom = Settings.Current.FfmpegPath;
            if (!string.IsNullOrWhiteSpace(custom)) candidates.Add(Directory.Exists(custom) ? Path.Combine(custom, "ffmpeg.exe") : custom);
            candidates.Add(Path.Combine(AppContext.BaseDirectory, "ffmpeg", "ffmpeg.exe"));
            candidates.Add(Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe"));
            if (Shell.Which("ffmpeg.exe") is { } onPath) candidates.Add(onPath);
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            candidates.Add(Path.Combine(local, "Microsoft", "WinGet", "Links", "ffmpeg.exe"));
            try
            {
                var pkgs = Path.Combine(local, "Microsoft", "WinGet", "Packages");
                if (Directory.Exists(pkgs))
                    foreach (var d in Directory.EnumerateDirectories(pkgs, "*FFmpeg*"))
                        candidates.AddRange(Directory.EnumerateFiles(d, "ffmpeg.exe", SearchOption.AllDirectories));
            }
            catch { }
            foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"C:\ffmpeg" })
                candidates.Add(Path.Combine(root, "ffmpeg", "bin", "ffmpeg.exe"));
            candidates.Add(@"C:\ffmpeg\bin\ffmpeg.exe");
            candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "scoop", "shims", "ffmpeg.exe"));
            candidates.Add(@"C:\ProgramData\chocolatey\bin\ffmpeg.exe");

            foreach (var c in candidates)
            {
                try
                {
                    if (!File.Exists(c)) continue;
                    // WinGet "Links" are symlinks; resolve so ffprobe can be found next to the real binary.
                    var real = new FileInfo(c).ResolveLinkTarget(true)?.FullName ?? c;
                    var probe = Path.Combine(Path.GetDirectoryName(real)!, "ffprobe.exe");
                    _ffmpeg = real;
                    _ffprobe = File.Exists(probe) ? probe : null;
                    Log.Info($"ffmpeg: {_ffmpeg}");
                    return;
                }
                catch { }
            }
        }
    }

    public static string Require()
    {
        return FfmpegPath ?? throw new OpException("FFmpeg isn't installed. Open Satsuma settings → Engines to install it.");
    }

    public static bool HasEncoder(string name)
    {
        if (_encoders == null)
        {
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                var (_, stdout, _) = RunCapture(Require(), "-hide_banner -encoders", 10000);
                foreach (var line in stdout.Split('\n'))
                {
                    var parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length >= 2 && parts[0].Length == 6) set.Add(parts[1]);
                }
            }
            catch { }
            _encoders = set;
        }
        return _encoders.Contains(name);
    }

    public static MediaInfo Probe(string file)
    {
        Require();
        if (_ffprobe == null) return new MediaInfo(0, Array.Empty<MediaStream>(), "");
        var (code, json, _) = RunCapture(_ffprobe, $"-v error -print_format json -show_format -show_streams {Q(file)}", 30000);
        if (code != 0 || string.IsNullOrWhiteSpace(json)) return new MediaInfo(0, Array.Empty<MediaStream>(), "");
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        double duration = 0;
        string format = "";
        if (root.TryGetProperty("format", out var fmt))
        {
            if (fmt.TryGetProperty("duration", out var d)) double.TryParse(d.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out duration);
            if (fmt.TryGetProperty("format_name", out var fn)) format = fn.GetString() ?? "";
        }
        var streams = new List<MediaStream>();
        if (root.TryGetProperty("streams", out var arr))
        {
            foreach (var s in arr.EnumerateArray())
            {
                string Str(string k) => s.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
                int Int(string k) => s.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() :
                    (s.TryGetProperty(k, out var v2) && v2.ValueKind == JsonValueKind.String && int.TryParse(v2.GetString(), out var i) ? i : 0);
                bool attached = s.TryGetProperty("disposition", out var disp) && disp.TryGetProperty("attached_pic", out var ap) && ap.GetInt32() == 1;
                if (duration <= 0 && s.TryGetProperty("duration", out var sd)) double.TryParse(sd.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out duration);
                streams.Add(new MediaStream(Str("codec_type"), Str("codec_name"), Int("width"), Int("height"), Int("channels"),
                    Str("pix_fmt"), Int("bits_per_raw_sample"), Str("sample_fmt"), attached));
            }
        }
        return new MediaInfo(duration, streams, format);
    }

    /// <summary>Runs ffmpeg with progress parsing. Throws <see cref="OpException"/> with ffmpeg's last error line on failure.</summary>
    public static async Task RunAsync(string args, double durationSeconds, Action<double>? progress, CancellationToken ct)
    {
        var exe = Require();
        var psi = new ProcessStartInfo(exe, $"-hide_banner -nostdin -y -loglevel error -progress pipe:1 -nostats {args}")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        Log.Info("ffmpeg " + psi.Arguments);
        using var proc = new Process { StartInfo = psi };
        var errors = new StringBuilder();
        proc.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (errors) errors.AppendLine(e.Data); };
        proc.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null || progress == null || durationSeconds <= 0) return;
            if (e.Data.StartsWith("out_time_us=") || e.Data.StartsWith("out_time_ms="))
            {
                if (long.TryParse(e.Data[(e.Data.IndexOf('=') + 1)..], out var us))
                    progress(Math.Clamp(us / 1_000_000.0 / durationSeconds, 0, 1));
            }
        };
        proc.Start();
        try { proc.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        proc.BeginErrorReadLine();
        proc.BeginOutputReadLine();
        using (ct.Register(() => { try { proc.Kill(true); } catch { } }))
            await proc.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (proc.ExitCode != 0)
        {
            string err;
            lock (errors) err = errors.ToString().Trim();
            var last = err.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0) ?? $"exit code {proc.ExitCode}";
            Log.Warn("ffmpeg failed: " + err);
            throw new OpException("FFmpeg: " + last);
        }
    }

    public static (int code, string stdout, string stderr) RunCapture(string exe, string args, int timeoutMs)
    {
        var psi = new ProcessStartInfo(exe, args)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        using var p = Process.Start(psi)!;
        var outTask = p.StandardOutput.ReadToEndAsync();
        var errTask = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } }
        return (p.HasExited ? p.ExitCode : -1, outTask.Result, errTask.Result);
    }

    public static string Q(string path) => "\"" + path.Replace("\"", "\\\"") + "\"";
}
