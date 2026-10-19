using Satsuma.Core;

namespace Satsuma.Ops.Convert;

/// <summary>Audio and video conversion through FFmpeg, remuxing instead of re-encoding whenever codecs allow.</summary>
public static class MediaConverter
{
    public static readonly string[] VideoTargets = { "mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3" };
    public static readonly string[] AudioTargets = { "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma" };

    static bool? _nvencWorks;

    public static async Task<string> ConvertAsync(string input, string target, Action<double> progress, CancellationToken ct)
    {
        var info = Ffmpeg.Probe(input);
        bool isAudioTarget = AudioTargets.Contains(target) && target != "mp4";
        if (isAudioTarget && info.Audio == null) throw new OpException($"{Path.GetFileName(input)} has no audio track.");
        if (!isAudioTarget && target != "gif" && info.Video == null && info.Audio == null) throw new OpException("No audio or video found.");

        string output = OutputPaths.For(input, target);
        try
        {
            if (isAudioTarget) await Ffmpeg.RunAsync(AudioArgs(input, output, target, info), info.Duration, progress, ct);
            else if (target == "gif") await GifAsync(input, output, info, progress, ct);
            else await VideoAsync(input, output, target, info, progress, ct);
            return output;
        }
        catch { OutputPaths.Discard(output); throw; }
    }

    // ------------------------------------------------------------------ audio

    static string AudioArgs(string input, string output, string target, MediaInfo info)
    {
        var a = info.Audio!;
        int bits = a.BitsPerSample > 0 ? a.BitsPerSample : (a.SampleFmt is "s32" or "s32p" or "flt" or "fltp" or "dbl" ? 24 : 16);
        bool hiRes = bits > 16;
        bool coverOk = info.HasCover && target is "mp3" or "m4a" or "flac";
        string map = coverOk ? "-map 0:a:0 -map 0:v:0? -c:v copy -disposition:v:0 attached_pic" : "-map 0:a:0 -vn";
        string codec = target switch
        {
            "mp3" => "-c:a libmp3lame -q:a 2" + (a.Channels > 2 ? " -ac 2" : "") + " -id3v2_version 3",
            "m4a" => a.Codec == "aac" ? "-c:a copy" : "-c:a aac -b:a 256k",
            "wav" => hiRes ? "-c:a pcm_s24le" : "-c:a pcm_s16le",
            "flac" => "-c:a flac -compression_level 5" + (hiRes ? " -sample_fmt s32" : ""),
            "ogg" => a.Codec == "vorbis" ? "-c:a copy" : "-c:a libvorbis -q:a 6",
            "opus" => a.Codec == "opus" ? "-c:a copy" : "-c:a libopus -b:a 160k -vbr on",
            "aiff" => hiRes ? "-c:a pcm_s24be" : "-c:a pcm_s16be",
            "wma" => "-c:a wmav2 -b:a 192k" + (a.Channels > 2 ? " -ac 2" : ""),
            _ => throw new OpException("Unsupported audio format " + target),
        };
        if (target == "m4a" && coverOk) map = "-map 0:a:0 -map 0:v:0? -c:v copy -disposition:v:0 attached_pic";
        return $"-i {Ffmpeg.Q(input)} {map} -map_metadata 0 {codec} {Ffmpeg.Q(output)}";
    }

    // ------------------------------------------------------------------ video

    static readonly Dictionary<string, (string[] video, string[] audio)> Compatible = new()
    {
        ["mp4"] = (new[] { "h264", "hevc", "av1", "mpeg4" }, new[] { "aac", "mp3", "ac3", "eac3", "alac" }),
        ["mov"] = (new[] { "h264", "hevc", "prores", "mpeg4", "mjpeg" }, new[] { "aac", "mp3", "alac", "pcm_s16le", "pcm_s24le", "ac3" }),
        ["mkv"] = (new[] { "*" }, new[] { "*" }),
        ["webm"] = (new[] { "vp8", "vp9", "av1" }, new[] { "opus", "vorbis" }),
        ["avi"] = (new[] { "mpeg4", "h264", "mjpeg" }, new[] { "mp3", "ac3", "pcm_s16le" }),
        ["wmv"] = (Array.Empty<string>(), Array.Empty<string>()),
    };

    static async Task VideoAsync(string input, string output, string target, MediaInfo info, Action<double> progress, CancellationToken ct)
    {
        var (okVideo, okAudio) = Compatible[target];
        var v = info.Video;
        var a = info.Audio;
        bool copyVideo = v != null && (okVideo.Contains("*") || okVideo.Contains(v.Codec));
        bool copyAudio = a != null && (okAudio.Contains("*") || okAudio.Contains(a.Codec));

        string audioEnc = target switch
        {
            "webm" => "-c:a libopus -b:a 128k",
            "avi" => "-c:a libmp3lame -q:a 3",
            "wmv" => "-c:a wmav2 -b:a 192k",
            _ => "-c:a aac -b:a 192k",
        };
        string audioPart = a == null ? "-an" : copyAudio ? "-c:a copy" : audioEnc;
        string maps = "-map 0:v:0? -map 0:a?";
        string fast = target is "mp4" or "mov" ? "-movflags +faststart" : "";
        string hvc = copyVideo && v?.Codec == "hevc" && target is "mp4" or "mov" ? "-tag:v hvc1" : "";

        if (copyVideo)
        {
            await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(input)} {maps} -map_metadata 0 -c:v copy {hvc} {audioPart} {fast} {Ffmpeg.Q(output)}", info.Duration, progress, ct);
            return;
        }

        string even = "-vf \"scale=trunc(iw/2)*2:trunc(ih/2)*2\"";
        switch (target)
        {
            case "webm":
                await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(input)} {maps} -map_metadata 0 -c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1 -deadline good -cpu-used 4 {audioPart} {Ffmpeg.Q(output)}", info.Duration, progress, ct);
                return;
            case "avi":
                await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(input)} {maps} -c:v mpeg4 -q:v 3 -vtag xvid {audioPart} {Ffmpeg.Q(output)}", info.Duration, progress, ct);
                return;
            case "wmv":
                await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(input)} {maps} -c:v wmv2 -q:v 3 {audioPart} {Ffmpeg.Q(output)}", info.Duration, progress, ct);
                return;
        }

        // mp4 / mov / mkv → H.264, on the GPU when possible.
        string pix = "-pix_fmt yuv420p";
        if (Settings.Current.HardwareVideoEncoding && _nvencWorks != false && Ffmpeg.HasEncoder("h264_nvenc"))
        {
            try
            {
                await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(input)} {maps} -map_metadata 0 {even} -c:v h264_nvenc -preset p5 -rc vbr -cq 21 -b:v 0 {pix} {audioPart} {fast} {Ffmpeg.Q(output)}", info.Duration, progress, ct);
                _nvencWorks = true;
                return;
            }
            catch (OpException ex) when (_nvencWorks == null)
            {
                Log.Info("NVENC unavailable, falling back to x264: " + ex.Message);
                _nvencWorks = false;
            }
        }
        await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(input)} {maps} -map_metadata 0 {even} -c:v libx264 -preset medium -crf 20 {pix} {audioPart} {fast} {Ffmpeg.Q(output)}", info.Duration, progress, ct);
    }

    static async Task GifAsync(string input, string output, MediaInfo info, Action<double> progress, CancellationToken ct)
    {
        double duration = info.Duration > 0 ? Math.Min(info.Duration, 60) : 0;
        int width = info.Video is { Width: > 0 } vid ? Math.Min(vid.Width, duration > 20 ? 480 : 640) : 480;
        int fps = duration > 20 ? 12 : 15;
        string limit = info.Duration > 60 ? "-t 60" : "";
        string filter = $"fps={fps},scale={width}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=sierra2_4a";
        await Ffmpeg.RunAsync($"{limit} -i {Ffmpeg.Q(input)} -filter_complex \"{filter}\" -loop 0 {Ffmpeg.Q(output)}", duration, progress, ct);
    }
}
