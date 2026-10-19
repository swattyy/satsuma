using System.Globalization;
using Satsuma.Core;
using Satsuma.Ops.Convert;

namespace Satsuma.Ops.Tools;

/// <summary>Audio/video tools built on FFmpeg.</summary>
public static class MediaTools
{
    static string F(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);

    static string KeepExt(string input, bool audio)
    {
        string ext = FileKinds.Ext(input);
        if (audio) return ext is "mp3" or "m4a" or "wav" or "flac" or "ogg" or "opus" or "aiff" or "wma" ? ext : "m4a";
        return ext is "mp4" or "mov" or "mkv" or "webm" ? ext : "mp4";
    }

    static string AudioCodecFor(string ext) => ext switch
    {
        "mp3" => "-c:a libmp3lame -q:a 2",
        "wav" => "-c:a pcm_s16le",
        "flac" => "-c:a flac",
        "ogg" => "-c:a libvorbis -q:a 6",
        "opus" => "-c:a libopus -b:a 160k",
        "aiff" => "-c:a pcm_s16be",
        "wma" => "-c:a wmav2 -b:a 192k",
        "webm" => "-c:a libopus -b:a 128k",
        _ => "-c:a aac -b:a 192k",
    };

    static string VideoCodecFor(string ext, int crf = 21) => ext == "webm"
        ? $"-c:v libvpx-vp9 -crf {crf + 11} -b:v 0 -row-mt 1 -deadline good -cpu-used 4"
        : $"-c:v libx264 -preset medium -crf {crf} -pix_fmt yuv420p";

    static async Task<string> Run(string input, string suffix, string ext, string args, Action<double> progress, CancellationToken ct, double? durationOverride = null)
    {
        var info = Ffmpeg.Probe(input);
        string output = OutputPaths.For(input, ext, suffix);
        try { await Ffmpeg.RunAsync(args.Replace("{in}", Ffmpeg.Q(input)).Replace("{out}", Ffmpeg.Q(output)), durationOverride ?? info.Duration, progress, ct); }
        catch { OutputPaths.Discard(output); throw; }
        return output;
    }

    public static bool IsAudioOnly(string input) => FileKinds.KindOf(input) == FileKind.Audio;

    // ------------------------------------------------------------------ compress

    public sealed record VideoCompressOptions(int Crf, int? MaxHeight, int AudioKbps, long? TargetBytes);

    public static async Task<string> CompressVideoAsync(string input, VideoCompressOptions o, Action<double> progress, CancellationToken ct)
    {
        var info = Ffmpeg.Probe(input);
        string scale = o.MaxHeight is int mh && info.Video is { Height: > 0 } v && v.Height > mh ? $"-vf \"scale=-2:{mh}\"" : "-vf \"scale=trunc(iw/2)*2:trunc(ih/2)*2\"";
        string ext = FileKinds.Ext(input) == "webm" ? "webm" : "mp4";
        string audio = info.Audio == null ? "-an" : ext == "webm" ? $"-c:a libopus -b:a {o.AudioKbps}k" : $"-c:a aac -b:a {o.AudioKbps}k";
        if (o.TargetBytes is long target && info.Duration > 0)
        {
            // Two-pass ABR to hit a size: total kbps from the budget, minus audio, with 4% container overhead.
            double totalKbps = target * 8 / 1000.0 / info.Duration * 0.96;
            int videoKbps = (int)Math.Max(80, totalKbps - (info.Audio == null ? 0 : o.AudioKbps));
            var tmp = AppPaths.NewTempDir("2pass");
            string log = Path.Combine(tmp, "pass");
            string output = OutputPaths.For(input, ext, " (compressed)");
            try
            {
                string codec = ext == "webm" ? "-c:v libvpx-vp9 -row-mt 1 -cpu-used 4" : "-c:v libx264 -preset medium -pix_fmt yuv420p";
                await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(input)} {scale} {codec} -b:v {videoKbps}k -pass 1 -passlogfile {Ffmpeg.Q(log)} -an -f null NUL", info.Duration, p => progress(p * 0.5), ct);
                await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(input)} {scale} {codec} -b:v {videoKbps}k -pass 2 -passlogfile {Ffmpeg.Q(log)} {audio} -movflags +faststart {Ffmpeg.Q(output)}", info.Duration, p => progress(0.5 + p * 0.5), ct);
                return output;
            }
            catch { OutputPaths.Discard(output); throw; }
            finally { try { Directory.Delete(tmp, true); } catch { } }
        }
        return await Run(input, " (compressed)", ext,
            $"-i {{in}} -map 0:v:0 -map 0:a? {scale} {VideoCodecFor(ext, o.Crf)} {audio} -movflags +faststart {{out}}", progress, ct);
    }

    public static Task<string> CompressAudioAsync(string input, int kbps, Action<double> progress, CancellationToken ct)
    {
        string ext = FileKinds.Ext(input) is "ogg" or "opus" ? FileKinds.Ext(input) : FileKinds.Ext(input) == "m4a" ? "m4a" : "mp3";
        string codec = ext switch { "ogg" => $"-c:a libvorbis -b:a {kbps}k", "opus" => $"-c:a libopus -b:a {kbps}k", "m4a" => $"-c:a aac -b:a {kbps}k", _ => $"-c:a libmp3lame -b:a {kbps}k" };
        return Run(input, " (compressed)", ext, $"-i {{in}} -map 0:a:0 -map_metadata 0 {codec} {{out}}", progress, ct);
    }

    // ------------------------------------------------------------------ trim / edit

    public static Task<string> TrimAsync(string input, double start, double end, Action<double> progress, CancellationToken ct)
    {
        bool audio = IsAudioOnly(input);
        string ext = KeepExt(input, audio);
        string range = $"-ss {F(start)} -to {F(end)}";
        // Re-encode for frame-accurate cuts (stream copy can only cut on keyframes).
        string args = audio
            ? $"{range} -i {{in}} -map 0:a:0 -map_metadata 0 {AudioCodecFor(ext)} {{out}}"
            : $"{range} -i {{in}} -map 0:v:0 -map 0:a? -map_metadata 0 {VideoCodecFor(ext, 19)} {AudioCodecFor(ext)} -movflags +faststart {{out}}";
        return Run(input, " (trimmed)", ext, args, progress, ct, end - start);
    }

    public static Task<string> MuteAsync(string input, Action<double> progress, CancellationToken ct) =>
        Run(input, " (muted)", KeepExt(input, false), "-i {in} -map 0:v -c copy -an -map_metadata 0 {out}", progress, ct);

    public static Task<string> ResizeVideoAsync(string input, int height, Action<double> progress, CancellationToken ct)
    {
        string ext = KeepExt(input, false);
        return Run(input, $" ({height}p)", ext, $"-i {{in}} -map 0:v:0 -map 0:a? -vf \"scale=-2:{height}\" {VideoCodecFor(ext)} -c:a copy -movflags +faststart {{out}}", progress, ct);
    }

    public static Task<string> RotateVideoAsync(string input, bool clockwise, Action<double> progress, CancellationToken ct)
    {
        string ext = KeepExt(input, false);
        return Run(input, " (rotated)", ext, $"-i {{in}} -map 0:v:0 -map 0:a? -vf \"transpose={(clockwise ? 1 : 2)}\" {VideoCodecFor(ext, 19)} -c:a copy -movflags +faststart {{out}}", progress, ct);
    }

    public static async Task<string> SnapshotAsync(string input, double? at, CancellationToken ct)
    {
        var info = Ffmpeg.Probe(input);
        double t = at ?? Math.Min(info.Duration * 0.1, 10);
        string stamp = t < 60 ? $"{t:0.#}s" : TimeSpan.FromSeconds(t).ToString(@"m\mss\s");
        string output = OutputPaths.For(input, "png", $" (frame {stamp})");
        try { await Ffmpeg.RunAsync($"-ss {F(t)} -i {Ffmpeg.Q(input)} -frames:v 1 -update 1 {Ffmpeg.Q(output)}", 0, null, ct); }
        catch { OutputPaths.Discard(output); throw; }
        return output;
    }

    public static Task<string> NormalizeAsync(string input, Action<double> progress, CancellationToken ct)
    {
        bool audio = IsAudioOnly(input);
        string ext = KeepExt(input, audio);
        string maps = audio ? "-map 0:a:0" : "-map 0:v:0? -map 0:a -c:v copy";
        return Run(input, " (normalized)", ext, $"-i {{in}} {maps} -af loudnorm=I=-16:TP=-1.5:LRA=11 -ar 48000 {AudioCodecFor(ext)} -map_metadata 0 {{out}}", progress, ct);
    }

    public static Task<string> MonoAsync(string input, Action<double> progress, CancellationToken ct)
    {
        string ext = KeepExt(input, true);
        return Run(input, " (mono)", ext, $"-i {{in}} -map 0:a:0 -ac 1 {AudioCodecFor(ext)} -map_metadata 0 {{out}}", progress, ct);
    }

    public static async Task<string> FadeAsync(string input, double seconds, Action<double> progress, CancellationToken ct)
    {
        var info = Ffmpeg.Probe(input);
        double d = Math.Min(seconds, Math.Max(0.1, info.Duration / 4));
        double outStart = Math.Max(0, info.Duration - d);
        string ext = KeepExt(input, true);
        return await Run(input, " (faded)", ext, $"-i {{in}} -map 0:a:0 -af \"afade=t=in:d={F(d)},afade=t=out:st={F(outStart)}:d={F(d)}\" {AudioCodecFor(ext)} -map_metadata 0 {{out}}", progress, ct);
    }

    /// <summary>Joins clips end to end (re-encoded so differing sizes/codecs still work).</summary>
    public static async Task<string> MergeAsync(IReadOnlyList<string> files, Action<double> progress, CancellationToken ct)
    {
        bool audio = files.All(IsAudioOnly);
        var infos = files.Select(Ffmpeg.Probe).ToList();
        double total = infos.Sum(i => i.Duration);
        string ext = audio ? KeepExt(files[0], true) : "mp4";
        string output = OutputPaths.Unique(OutputPaths.DirectoryFor(files[0]), "Merged", ext);
        string inputs = string.Join(" ", files.Select(f => "-i " + Ffmpeg.Q(f)));
        string filter;
        if (audio)
            filter = string.Concat(files.Select((_, i) => $"[{i}:a:0]")) + $"concat=n={files.Count}:v=0:a=1[a]";
        else
        {
            var v = infos.First(i => i.Video != null).Video!;
            int w = v.Width / 2 * 2, h = v.Height / 2 * 2;
            var parts = new List<string>();
            for (int i = 0; i < files.Count; i++)
            {
                parts.Add($"[{i}:v:0]scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v{i}]");
                parts.Add(infos[i].Audio != null ? $"[{i}:a:0]aresample=48000,aformat=channel_layouts=stereo[a{i}]" : $"anullsrc=r=48000:cl=stereo,atrim=0:{F(infos[i].Duration)}[a{i}]");
            }
            filter = string.Join(";", parts) + ";" + string.Concat(Enumerable.Range(0, files.Count).Select(i => $"[v{i}][a{i}]")) + $"concat=n={files.Count}:v=1:a=1[v][a]";
        }
        string maps = audio ? "-map \"[a]\"" : "-map \"[v]\" -map \"[a]\"";
        string codecs = audio ? AudioCodecFor(ext) : $"{VideoCodecFor("mp4")} -c:a aac -b:a 192k -movflags +faststart";
        try { await Ffmpeg.RunAsync($"{inputs} -filter_complex \"{filter}\" {maps} {codecs} {Ffmpeg.Q(output)}", total, progress, ct); }
        catch { OutputPaths.Discard(output); throw; }
        return output;
    }
}
