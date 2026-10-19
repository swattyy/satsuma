import Foundation
import AVFoundation

/// Audio and video tools. Files macOS can read are handled with AVFoundation; other formats, MP3/OGG/OPUS/WMA
/// output and loudness normalization use FFmpeg, with the same settings as the Windows app.
public enum MediaTools {
    static func f(_ v: Double) -> String { TextUtil.num(v) }

    static func keepExt(_ input: String, audio: Bool) -> String {
        let ext = FileKinds.ext(input)
        if audio { return ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"].contains(ext) ? ext : "m4a" }
        return ["mp4", "mov", "mkv", "webm"].contains(ext) ? ext : "mp4"
    }

    static let nativeAudioWrite: Set<String> = ["m4a", "wav", "aiff", "flac"]
    static let nativeVideoWrite: Set<String> = ["mp4", "mov"]

    public static func isAudioOnly(_ input: String) -> Bool { FileKinds.kindOf(input) == .audio }

    /// Output format and engine for an audio edit: keep the format when we can write it, otherwise use FFmpeg,
    /// and without FFmpeg fall back to M4A.
    static func audioPlan(_ input: String) -> (ext: String, native: Bool) {
        let ext = keepExt(input, audio: true)
        let readable = AVMedia.canRead(input)
        if readable && nativeAudioWrite.contains(ext) { return (ext, true) }
        if Ffmpeg.available { return (ext, false) }
        return (readable ? "m4a" : ext, readable)
    }

    static func videoPlan(_ input: String) -> (ext: String, native: Bool) {
        let ext = keepExt(input, audio: false)
        if AVMedia.isNativeVideo(input) && nativeVideoWrite.contains(ext) { return (ext, true) }
        return (ext, false)
    }

    static func audioCodecArgs(_ ext: String) -> [String] {
        switch ext {
        case "mp3": return ["-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "flac": return ["-c:a", "flac"]
        case "ogg": return ["-c:a", "libvorbis", "-q:a", "6"]
        case "opus": return ["-c:a", "libopus", "-b:a", "160k"]
        case "aiff": return ["-c:a", "pcm_s16be"]
        case "wma": return ["-c:a", "wmav2", "-b:a", "192k"]
        case "webm": return ["-c:a", "libopus", "-b:a", "128k"]
        default: return ["-c:a", "aac", "-b:a", "192k"]
        }
    }

    static func videoCodecArgs(_ ext: String, crf: Int = 21) -> [String] {
        ext == "webm"
            ? ["-c:v", "libvpx-vp9", "-crf", "\(crf + 11)", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            : ["-c:v", "libx264", "-preset", "medium", "-crf", "\(crf)", "-pix_fmt", "yuv420p"]
    }

    /// Runs an FFmpeg edit into "name (suffix).ext"; `{in}` and `{out}` in the arguments are replaced.
    static func ffmpeg(_ input: String, suffix: String, ext: String, _ args: [String], progress: @escaping (Double) -> Void,
                       duration: Double? = nil) async throws -> String {
        _ = try Ffmpeg.require()
        let info = Ffmpeg.probe(input)
        let output = OutputPaths.path(for: input, ext: ext, suffix: suffix)
        return try await OutputPaths.writing(output) { out in
            let full = args.map { $0 == "{in}" ? input : $0 == "{out}" ? out : $0 }
            try await Ffmpeg.run(full, duration: duration ?? info.duration, progress: progress)
            return out
        }
    }

    /// Writes an audio edit natively: AVAssetWriter for M4A, WAV and AIFF; FLAC goes through a temporary WAV.
    static func writeAudio(_ asset: AVAsset, to output: String, ext: String, _ o: AVMedia.Transcode, progress: @escaping (Double) -> Void) async throws {
        var t = o
        t.includeVideo = false
        switch ext {
        case "wav": t.audioOut = .pcmLittle; t.fileType = .wav
        case "aiff": t.audioOut = .pcmBig; t.fileType = .aiff
        case "flac":
            let tmp = try AppPaths.newTempDir("flac")
            defer { P.remove(tmp) }
            let wav = P.join(tmp, "audio.wav")
            t.audioOut = .pcmLittle
            t.fileType = .wav
            try await AVMedia.transcode(asset, to: wav, t) { progress($0 * 0.8) }
            try AVMedia.writeFlac(from: wav, to: output, bits: t.audioBits) { progress(0.8 + $0 * 0.2) }
            return
        default: t.audioOut = .aac; t.fileType = .m4a
        }
        try await AVMedia.transcode(asset, to: output, t, progress: progress)
    }

    // ------------------------------------------------------------------ compress

    public static func compressVideo(_ input: String, _ o: VideoCompressOptions, progress: @escaping (Double) -> Void) async throws -> String {
        if AVMedia.isNativeVideo(input) {
            let info = try await AVMedia.info(input)
            let output = OutputPaths.path(for: input, ext: "mp4", suffix: " (compressed)")
            return try await OutputPaths.writing(output) { out in
                var t = AVMedia.Transcode()
                t.maxHeight = o.maxHeight
                t.audioBitrate = o.audioKbps * 1000
                let audioBps = info.hasAudio ? o.audioKbps * 1000 : 0
                if let target = o.targetBytes, info.duration > 0 {
                    // Aim just under the size: total bitrate from the budget, minus audio, with 4% container overhead.
                    let totalBps = Double(target) * 8 / info.duration * 0.96
                    t.videoBitrate = max(80_000, Int(totalBps) - audioBps)
                } else {
                    // Rough match for x264 CRF 23 / 28 / 32, never above 70% of the source's own bitrate.
                    t.bitsPerPixel = o.crf <= 23 ? 0.075 : o.crf <= 28 ? 0.045 : 0.03
                    let h = Double(min(info.height, o.maxHeight ?? info.height))
                    let w = info.height > 0 ? Double(info.width) * h / Double(info.height) : 1280
                    let estimate = Int(w * h * max(info.fps, 24) * t.bitsPerPixel)
                    if info.duration > 0 {
                        let sourceBps = Double(P.size(input)) * 8 / info.duration
                        t.videoBitrate = max(150_000, min(estimate, Int(sourceBps * 0.7) - audioBps))
                    }
                }
                try await AVMedia.transcode(AVURLAsset(url: P.url(input)), to: out, t, progress: progress)
                return out
            }
        }
        _ = try Ffmpeg.require()
        let info = Ffmpeg.probe(input)
        let scale: [String]
        if let mh = o.maxHeight, let v = info.video, v.height > mh { scale = ["-vf", "scale=-2:\(mh)"] }
        else { scale = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"] }
        let ext = FileKinds.ext(input) == "webm" ? "webm" : "mp4"
        let audio: [String]
        if info.audio == nil { audio = ["-an"] }
        else if ext == "webm" { audio = ["-c:a", "libopus", "-b:a", "\(o.audioKbps)k"] }
        else { audio = ["-c:a", "aac", "-b:a", "\(o.audioKbps)k"] }
        let inArgs: [String] = ["-i", input]
        if let target = o.targetBytes, info.duration > 0 {
            // Two-pass ABR to hit a size.
            let totalKbps = Double(target) * 8 / 1000 / info.duration * 0.96
            let videoKbps = Int(max(80, totalKbps - Double(info.audio == nil ? 0 : o.audioKbps)))
            let tmp = try AppPaths.newTempDir("2pass")
            defer { P.remove(tmp) }
            let log = P.join(tmp, "pass")
            let codec: [String] = ext == "webm" ? ["-c:v", "libvpx-vp9", "-row-mt", "1", "-cpu-used", "4"] : ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"]
            let rate: [String] = ["-b:v", "\(videoKbps)k"]
            let output = OutputPaths.path(for: input, ext: ext, suffix: " (compressed)")
            return try await OutputPaths.writing(output) { out in
                let pass1: [String] = ["-pass", "1", "-passlogfile", log, "-an", "-f", "null", "/dev/null"]
                let pass2: [String] = ["-pass", "2", "-passlogfile", log]
                let tail: [String] = ["-movflags", "+faststart", out]
                try await Ffmpeg.run(cat(inArgs, scale, codec, rate, pass1), duration: info.duration) { progress($0 * 0.5) }
                try await Ffmpeg.run(cat(inArgs, scale, codec, rate, pass2, audio, tail), duration: info.duration) { progress(0.5 + $0 * 0.5) }
                return out
            }
        }
        let head: [String] = ["-i", "{in}", "-map", "0:v:0", "-map", "0:a?"]
        let tail: [String] = ["-movflags", "+faststart", "{out}"]
        return try await ffmpeg(input, suffix: " (compressed)", ext: ext, cat(head, scale, videoCodecArgs(ext, crf: o.crf), audio, tail), progress: progress)
    }

    public static func compressAudio(_ input: String, kbps: Int, progress: @escaping (Double) -> Void) async throws -> String {
        let src = FileKinds.ext(input)
        var ext = ["ogg", "opus"].contains(src) ? src : src == "m4a" ? "m4a" : "mp3"
        if ext == "mp3" && !Ffmpeg.available && AVMedia.canRead(input) { ext = "m4a" }
        if ext == "m4a" && AVMedia.canRead(input) {
            let output = OutputPaths.path(for: input, ext: "m4a", suffix: " (compressed)")
            return try await OutputPaths.writing(output) { out in
                var t = AVMedia.Transcode()
                t.audioBitrate = kbps * 1000
                try await writeAudio(AVURLAsset(url: P.url(input)), to: out, ext: "m4a", t, progress: progress)
                return out
            }
        }
        let codec: [String]
        switch ext {
        case "ogg": codec = ["-c:a", "libvorbis", "-b:a", "\(kbps)k"]
        case "opus": codec = ["-c:a", "libopus", "-b:a", "\(kbps)k"]
        case "m4a": codec = ["-c:a", "aac", "-b:a", "\(kbps)k"]
        default: codec = ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
        }
        return try await ffmpeg(input, suffix: " (compressed)", ext: ext, cat(["-i", "{in}", "-map", "0:a:0", "-map_metadata", "0"], codec, ["{out}"]), progress: progress)
    }

    // ------------------------------------------------------------------ trim / edit

    static func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }

    public static func trim(_ input: String, start: Double, end: Double, progress: @escaping (Double) -> Void) async throws -> String {
        let audio = isAudioOnly(input)
        let plan = audio ? audioPlan(input) : videoPlan(input)
        if plan.native {
            let output = OutputPaths.path(for: input, ext: plan.ext, suffix: " (trimmed)")
            let asset = AVURLAsset(url: P.url(input))
            return try await OutputPaths.writing(output) { out in
                if audio {
                    var t = AVMedia.Transcode()
                    t.timeRange = range(start, end)
                    let info = try await AVMedia.info(input)
                    t.audioBits = info.audioBits > 16 ? 24 : 16
                    try await writeAudio(asset, to: out, ext: plan.ext, t, progress: progress)
                } else {
                    // Re-encoded for frame-accurate cuts (a passthrough export can only cut on keyframes).
                    try await AVMedia.export(asset, to: out, preset: AVAssetExportPresetHighestQuality, fileType: AVMedia.fileType(for: plan.ext),
                                             timeRange: range(start, end), progress: progress)
                }
                return out
            }
        }
        let ext = plan.ext
        let r: [String] = ["-ss", f(start), "-to", f(end)]
        let args: [String]
        if audio {
            args = cat(r, ["-i", "{in}", "-map", "0:a:0", "-map_metadata", "0"], audioCodecArgs(ext), ["{out}"])
        } else {
            args = cat(r, ["-i", "{in}", "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0"], videoCodecArgs(ext, crf: 19), audioCodecArgs(ext),
                       ["-movflags", "+faststart", "{out}"])
        }
        return try await ffmpeg(input, suffix: " (trimmed)", ext: ext, args, progress: progress, duration: end - start)
    }

    public static func mute(_ input: String, progress: @escaping (Double) -> Void) async throws -> String {
        let plan = videoPlan(input)
        if plan.native {
            let output = OutputPaths.path(for: input, ext: plan.ext, suffix: " (muted)")
            return try await OutputPaths.writing(output) { out in
                let asset = AVURLAsset(url: P.url(input))
                let comp = AVMutableComposition()
                let duration = try await asset.load(.duration)
                guard let v = try await asset.loadTracks(withMediaType: .video).first,
                      let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw OpError("No video found.")
                }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: v, at: .zero)
                track.preferredTransform = try await v.load(.preferredTransform)
                try await AVMedia.export(comp, to: out, preset: AVAssetExportPresetPassthrough, fileType: AVMedia.fileType(for: plan.ext), progress: progress)
                return out
            }
        }
        return try await ffmpeg(input, suffix: " (muted)", ext: plan.ext, ["-i", "{in}", "-map", "0:v", "-c", "copy", "-an", "-map_metadata", "0", "{out}"], progress: progress)
    }

    public static func resizeVideo(_ input: String, height: Int, progress: @escaping (Double) -> Void) async throws -> String {
        let plan = videoPlan(input)
        if plan.native {
            let output = OutputPaths.path(for: input, ext: plan.ext, suffix: " (\(height)p)")
            return try await OutputPaths.writing(output) { out in
                var t = AVMedia.Transcode()
                t.height = height
                t.bitsPerPixel = 0.09
                t.fileType = AVMedia.fileType(for: plan.ext)
                try await AVMedia.transcode(AVURLAsset(url: P.url(input)), to: out, t, progress: progress)
                return out
            }
        }
        let head: [String] = ["-i", "{in}", "-map", "0:v:0", "-map", "0:a?", "-vf", "scale=-2:\(height)"]
        let tail: [String] = ["-c:a", "copy", "-movflags", "+faststart", "{out}"]
        return try await ffmpeg(input, suffix: " (\(height)p)", ext: plan.ext, cat(head, videoCodecArgs(plan.ext), tail), progress: progress)
    }

    /// Native rotation only changes the track's orientation matrix, so it's instant and lossless.
    public static func rotateVideo(_ input: String, clockwise: Bool, progress: @escaping (Double) -> Void) async throws -> String {
        let plan = videoPlan(input)
        if plan.native {
            let output = OutputPaths.path(for: input, ext: plan.ext, suffix: " (rotated)")
            return try await OutputPaths.writing(output) { out in
                let asset = AVURLAsset(url: P.url(input))
                let comp = AVMutableComposition()
                let duration = try await asset.load(.duration)
                let all = CMTimeRange(start: .zero, duration: duration)
                guard let v = try await asset.loadTracks(withMediaType: .video).first,
                      let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw OpError("No video found.")
                }
                try vt.insertTimeRange(all, of: v, at: .zero)
                let (natural, transform) = try await v.load(.naturalSize, .preferredTransform)
                let turned = transform.concatenating(CGAffineTransform(rotationAngle: clockwise ? .pi / 2 : -.pi / 2))
                let box = CGRect(origin: .zero, size: natural).applying(turned)
                vt.preferredTransform = turned.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
                for a in try await asset.loadTracks(withMediaType: .audio) {
                    if let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try at.insertTimeRange(all, of: a, at: .zero)
                    }
                }
                try await AVMedia.export(comp, to: out, preset: AVAssetExportPresetPassthrough, fileType: AVMedia.fileType(for: plan.ext), progress: progress)
                return out
            }
        }
        let head: [String] = ["-i", "{in}", "-map", "0:v:0", "-map", "0:a?", "-vf", "transpose=\(clockwise ? 1 : 2)"]
        let tail: [String] = ["-c:a", "copy", "-movflags", "+faststart", "{out}"]
        return try await ffmpeg(input, suffix: " (rotated)", ext: plan.ext, cat(head, videoCodecArgs(plan.ext, crf: 19), tail), progress: progress)
    }

    public static func snapshot(_ input: String, at: Double?) async throws -> String {
        var duration = 0.0
        if AVMedia.isNativeVideo(input) { duration = try await AVMedia.info(input).duration }
        else { _ = try Ffmpeg.require(); duration = Ffmpeg.probe(input).duration }
        let t = at ?? min(duration * 0.1, 10)
        let stamp: String
        if t < 60 { stamp = TextUtil.num(t, decimals: 1) + "s" }
        else { stamp = "\(Int(t) / 60)m\(String(format: "%02d", Int(t) % 60))s" }
        let output = OutputPaths.path(for: input, ext: "png", suffix: " (frame \(stamp))")
        return try await OutputPaths.writing(output) { out in
            if AVMedia.isNativeVideo(input) { try AVMedia.frame(input, at: t, output: out) }
            else { try await Ffmpeg.run(["-ss", f(t), "-i", input, "-frames:v", "1", "-update", "1", out], duration: 0, progress: nil) }
            return out
        }
    }

    public static func normalize(_ input: String, progress: @escaping (Double) -> Void) async throws -> String {
        if !Ffmpeg.available { throw OpError("Loudness needs FFmpeg. Open Satsuma Settings > Engines to install it.") }
        let audio = isAudioOnly(input)
        let ext = keepExt(input, audio: audio)
        let maps: [String] = audio ? ["-map", "0:a:0"] : ["-map", "0:v:0?", "-map", "0:a", "-c:v", "copy"]
        let filter: [String] = ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000"]
        return try await ffmpeg(input, suffix: " (normalized)", ext: ext,
                                cat(["-i", "{in}"], maps, filter, audioCodecArgs(ext), ["-map_metadata", "0", "{out}"]), progress: progress)
    }

    public static func mono(_ input: String, progress: @escaping (Double) -> Void) async throws -> String {
        let plan = audioPlan(input)
        if plan.native {
            let output = OutputPaths.path(for: input, ext: plan.ext, suffix: " (mono)")
            return try await OutputPaths.writing(output) { out in
                var t = AVMedia.Transcode()
                t.audioChannels = 1
                t.audioBitrate = 128_000
                try await writeAudio(AVURLAsset(url: P.url(input)), to: out, ext: plan.ext, t, progress: progress)
                return out
            }
        }
        return try await ffmpeg(input, suffix: " (mono)", ext: plan.ext,
                                cat(["-i", "{in}", "-map", "0:a:0", "-ac", "1"], audioCodecArgs(plan.ext), ["-map_metadata", "0", "{out}"]), progress: progress)
    }

    public static func fade(_ input: String, seconds: Double, progress: @escaping (Double) -> Void) async throws -> String {
        let plan = audioPlan(input)
        if plan.native {
            let asset = AVURLAsset(url: P.url(input))
            let duration = try await asset.load(.duration).seconds
            let d = min(seconds, max(0.1, duration / 4))
            let output = OutputPaths.path(for: input, ext: plan.ext, suffix: " (faded)")
            return try await OutputPaths.writing(output) { out in
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw OpError("No audio found.") }
                let params = AVMutableAudioMixInputParameters(track: track)
                let fadeTime = CMTime(seconds: d, preferredTimescale: 600)
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: fadeTime))
                params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: CMTime(seconds: max(0, duration - d), preferredTimescale: 600), duration: fadeTime))
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                var t = AVMedia.Transcode()
                t.audioMix = mix
                let info = try await AVMedia.info(input)
                t.audioBits = info.audioBits > 16 ? 24 : 16
                try await writeAudio(asset, to: out, ext: plan.ext, t, progress: progress)
                return out
            }
        }
        _ = try Ffmpeg.require()
        let info = Ffmpeg.probe(input)
        let d = min(seconds, max(0.1, info.duration / 4))
        let outStart = max(0, info.duration - d)
        let fades = "afade=t=in:d=\(f(d)),afade=t=out:st=\(f(outStart)):d=\(f(d))"
        return try await ffmpeg(input, suffix: " (faded)", ext: plan.ext,
                                cat(["-i", "{in}", "-map", "0:a:0", "-af", fades], audioCodecArgs(plan.ext), ["-map_metadata", "0", "{out}"]), progress: progress)
    }

    // ------------------------------------------------------------------ merge

    /// Joins clips end to end. Clips of different sizes are fitted into the first clip's frame.
    public static func merge(_ files: [String], progress: @escaping (Double) -> Void) async throws -> String {
        let audio = files.allSatisfy(isAudioOnly)
        let native = audio
            ? files.allSatisfy(AVMedia.canRead) && (nativeAudioWrite.contains(keepExt(files[0], audio: true)) || !Ffmpeg.available)
            : files.allSatisfy(AVMedia.isNativeVideo)
        if native { return try await mergeNative(files, audio: audio, progress: progress) }

        _ = try Ffmpeg.require()
        let infos = files.map(Ffmpeg.probe)
        let total = infos.reduce(0) { $0 + $1.duration }
        let ext = audio ? keepExt(files[0], audio: true) : "mp4"
        let output = OutputPaths.unique(dir: OutputPaths.directoryFor(files[0]), baseName: "Merged", ext: ext)
        var inputs: [String] = []
        for f in files { inputs += ["-i", f] }
        let filter: String
        if audio {
            filter = files.indices.map { "[\($0):a:0]" }.joined() + "concat=n=\(files.count):v=0:a=1[a]"
        } else {
            guard let v = infos.first(where: { $0.video != nil })?.video else { throw OpError("No video found.") }
            let w = v.width / 2 * 2, h = v.height / 2 * 2
            var parts: [String] = []
            for i in files.indices {
                parts.append("[\(i):v:0]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(i)]")
                parts.append(infos[i].audio != nil ? "[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(i)]"
                                                   : "anullsrc=r=48000:cl=stereo,atrim=0:\(f(infos[i].duration))[a\(i)]")
            }
            filter = parts.joined(separator: ";") + ";" + files.indices.map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(files.count):v=1:a=1[v][a]"
        }
        let maps: [String] = audio ? ["-map", "[a]"] : ["-map", "[v]", "-map", "[a]"]
        let codecs: [String] = audio ? audioCodecArgs(ext) : cat(videoCodecArgs("mp4"), ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"])
        let graph: [String] = ["-filter_complex", filter]
        return try await OutputPaths.writing(output) { out in
            try await Ffmpeg.run(cat(inputs, graph, maps, codecs, [out]), duration: total, progress: progress)
            return out
        }
    }

    static func mergeNative(_ files: [String], audio: Bool, progress: @escaping (Double) -> Void) async throws -> String {
        let comp = AVMutableComposition()
        var cursor = CMTime.zero
        let videoTrack = audio ? nil : comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var segments: [(AVAssetTrack, CMTimeRange, CGSize, CGAffineTransform)] = []
        var renderSize = CGSize.zero
        for f in files {
            let asset = AVURLAsset(url: P.url(f))
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let vt = videoTrack, let v = try await asset.loadTracks(withMediaType: .video).first {
                try vt.insertTimeRange(range, of: v, at: cursor)
                let (natural, transform) = try await v.load(.naturalSize, .preferredTransform)
                let shown = CGRect(origin: .zero, size: natural).applying(transform)
                if renderSize == .zero { renderSize = CGSize(width: Int(abs(shown.width)) / 2 * 2, height: Int(abs(shown.height)) / 2 * 2) }
                segments.append((v, CMTimeRange(start: cursor, duration: duration), natural, transform))
            }
            if let at = audioTrack, let a = try await asset.loadTracks(withMediaType: .audio).first {
                try at.insertTimeRange(range, of: a, at: cursor)
            }
            cursor = cursor + duration
        }
        let ext = audio ? (nativeAudioWrite.contains(keepExt(files[0], audio: true)) ? keepExt(files[0], audio: true) : "m4a") : "mp4"
        let output = OutputPaths.unique(dir: OutputPaths.directoryFor(files[0]), baseName: "Merged", ext: ext)
        return try await OutputPaths.writing(output) { out in
            if audio {
                try await writeAudio(comp, to: out, ext: ext, AVMedia.Transcode(), progress: progress)
                return out
            }
            guard let vt = videoTrack, renderSize != .zero else { throw OpError("No video found.") }
            // One instruction per clip, fitting each into the first clip's frame.
            let videoComp = AVMutableVideoComposition()
            videoComp.renderSize = renderSize
            videoComp.frameDuration = CMTime(value: 1, timescale: 30)
            var instructions: [AVMutableVideoCompositionInstruction] = []
            for (_, range, natural, transform) in segments {
                let shown = CGRect(origin: .zero, size: natural).applying(transform)
                let k = min(renderSize.width / abs(shown.width), renderSize.height / abs(shown.height))
                let w = abs(shown.width) * k, h = abs(shown.height) * k
                let placed = transform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
                    .concatenating(CGAffineTransform(scaleX: k, y: k))
                    .concatenating(CGAffineTransform(translationX: (renderSize.width - w) / 2, y: (renderSize.height - h) / 2))
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
                layer.setTransform(placed, at: range.start)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = range
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
            videoComp.instructions = instructions
            try await AVMedia.export(comp, to: out, preset: AVAssetExportPresetHighestQuality, fileType: .mp4, videoComposition: videoComp, progress: progress)
            return out
        }
    }
}
