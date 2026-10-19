import Foundation
import AVFoundation

/// Audio and video conversion. AVFoundation handles what macOS can read and write natively (MP4, MOV, M4A, WAV,
/// AIFF, FLAC, video to GIF), remuxing when the codecs already fit. Everything else goes through FFmpeg.
public enum MediaConverter {
    public static let videoTargets = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"]
    public static let audioTargets = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]

    static let nativeAudioOut: Set<String> = ["m4a", "wav", "aiff", "flac"]

    public static func convert(_ input: String, to target: String, progress: @escaping (Double) -> Void) async throws -> String {
        let output = OutputPaths.path(for: input, ext: target)
        return try await OutputPaths.writing(output) { out in
            if AVMedia.canRead(input), try await native(input, target, out, progress) { return out }
            try await viaFfmpeg(input, target, out, progress)
            return out
        }
    }

    /// Returns false when this conversion needs FFmpeg.
    static func native(_ input: String, _ target: String, _ output: String, _ progress: @escaping (Double) -> Void) async throws -> Bool {
        let isAudioTarget = audioTargets.contains(target)
        if isAudioTarget && !nativeAudioOut.contains(target) { return false }
        if !isAudioTarget && !["mp4", "mov", "gif"].contains(target) { return false }
        let info = try await AVMedia.info(input)
        let asset = AVURLAsset(url: P.url(input))

        if isAudioTarget {
            if !info.hasAudio { throw OpError("\(P.fileName(input)) has no audio track.") }
            let hiRes = info.audioBits > 16 || info.audioBits == 0
            switch target {
            case "m4a":
                if info.audioCodec == "aac" && !info.hasVideo {
                    try await AVMedia.export(asset, to: output, preset: AVAssetExportPresetPassthrough, fileType: .m4a, progress: progress)
                } else {
                    var o = AVMedia.Transcode()
                    o.includeVideo = false
                    o.audioBitrate = 256_000
                    o.fileType = .m4a
                    try await AVMedia.transcode(asset, to: output, o, progress: progress)
                }
            case "wav", "aiff":
                var o = AVMedia.Transcode()
                o.includeVideo = false
                o.audioOut = target == "wav" ? .pcmLittle : .pcmBig
                o.audioBits = hiRes ? 24 : 16
                o.audioChannels = max(1, info.channels)
                o.fileType = target == "wav" ? .wav : .aiff
                try await AVMedia.transcode(asset, to: output, o, progress: progress)
            case "flac":
                do { try AVMedia.writeFlac(from: input, to: output, bits: hiRes ? 24 : 16, progress: progress) }
                catch let e where Ffmpeg.available {
                    Log.info("Core Audio FLAC failed, using FFmpeg: \(e.localizedDescription)")
                    return false
                }
            default:
                return false
            }
            return true
        }

        if !info.hasVideo && target != "gif" && !info.hasAudio { throw OpError("No audio or video found.") }
        if target == "gif" {
            try await AVMedia.videoToGif(input, output: output, progress: progress)
            return true
        }
        let type: AVFileType = target == "mov" ? .mov : .mp4
        if AVMedia.canRemux(info, to: target) {
            do {
                try await AVMedia.export(asset, to: output, preset: AVAssetExportPresetPassthrough, fileType: type, progress: progress)
                return true
            } catch {
                Log.info("Remux to \(target) failed, re-encoding: \(error.localizedDescription)")
            }
        }
        try await AVMedia.export(asset, to: output, preset: AVAssetExportPresetHighestQuality, fileType: type, progress: progress)
        return true
    }

    // ------------------------------------------------------------------ FFmpeg (ported from the Windows app)

    static func viaFfmpeg(_ input: String, _ target: String, _ output: String, _ progress: @escaping (Double) -> Void) async throws {
        _ = try Ffmpeg.require()
        let info = Ffmpeg.probe(input)
        let isAudioTarget = audioTargets.contains(target)
        if isAudioTarget && info.audio == nil { throw OpError("\(P.fileName(input)) has no audio track.") }
        if !isAudioTarget && target != "gif" && info.video == nil && info.audio == nil { throw OpError("No audio or video found.") }
        if isAudioTarget { try await Ffmpeg.run(audioArgs(input, output, target, info), duration: info.duration, progress: progress) }
        else if target == "gif" { try await gif(input, output, info, progress) }
        else { try await video(input, output, target, info, progress) }
    }

    static func audioArgs(_ input: String, _ output: String, _ target: String, _ info: MediaInfo) throws -> [String] {
        let a = info.audio!
        let bits = a.bitsPerSample > 0 ? a.bitsPerSample : (["s32", "s32p", "flt", "fltp", "dbl"].contains(a.sampleFmt) ? 24 : 16)
        let hiRes = bits > 16
        let coverOK = info.hasCover && ["mp3", "m4a", "flac"].contains(target)
        let map: [String] = coverOK ? ["-map", "0:a:0", "-map", "0:v:0?", "-c:v", "copy", "-disposition:v:0", "attached_pic"] : ["-map", "0:a:0", "-vn"]
        let stereo: [String] = a.channels > 2 ? ["-ac", "2"] : []
        let codec: [String]
        switch target {
        case "mp3": codec = cat(["-c:a", "libmp3lame", "-q:a", "2"], stereo, ["-id3v2_version", "3"])
        case "m4a": codec = a.codec == "aac" ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "256k"]
        case "wav": codec = ["-c:a", hiRes ? "pcm_s24le" : "pcm_s16le"]
        case "flac": codec = cat(["-c:a", "flac", "-compression_level", "5"], hiRes ? ["-sample_fmt", "s32"] : [])
        case "ogg": codec = a.codec == "vorbis" ? ["-c:a", "copy"] : ["-c:a", "libvorbis", "-q:a", "6"]
        case "opus": codec = a.codec == "opus" ? ["-c:a", "copy"] : ["-c:a", "libopus", "-b:a", "160k", "-vbr", "on"]
        case "aiff": codec = ["-c:a", hiRes ? "pcm_s24be" : "pcm_s16be"]
        case "wma": codec = cat(["-c:a", "wmav2", "-b:a", "192k"], stereo)
        default: throw OpError("Unsupported audio format \(target)")
        }
        return cat(["-i", input], map, ["-map_metadata", "0"], codec, [output])
    }

    static let compatible: [String: (video: [String], audio: [String])] = [
        "mp4": (["h264", "hevc", "av1", "mpeg4"], ["aac", "mp3", "ac3", "eac3", "alac"]),
        "mov": (["h264", "hevc", "prores", "mpeg4", "mjpeg"], ["aac", "mp3", "alac", "pcm_s16le", "pcm_s24le", "ac3"]),
        "mkv": (["*"], ["*"]),
        "webm": (["vp8", "vp9", "av1"], ["opus", "vorbis"]),
        "avi": (["mpeg4", "h264", "mjpeg"], ["mp3", "ac3", "pcm_s16le"]),
        "wmv": ([], []),
    ]

    static var videoToolboxWorks: Bool?

    static func video(_ input: String, _ output: String, _ target: String, _ info: MediaInfo, _ progress: @escaping (Double) -> Void) async throws {
        let ok = compatible[target] ?? (video: [], audio: [])
        let v = info.video, a = info.audio
        let copyVideo = v != nil && (ok.video.contains("*") || ok.video.contains(v!.codec))
        let copyAudio = a != nil && (ok.audio.contains("*") || ok.audio.contains(a!.codec))
        let audioEnc: [String]
        switch target {
        case "webm": audioEnc = ["-c:a", "libopus", "-b:a", "128k"]
        case "avi": audioEnc = ["-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": audioEnc = ["-c:a", "wmav2", "-b:a", "192k"]
        default: audioEnc = ["-c:a", "aac", "-b:a", "192k"]
        }
        let audioPart: [String] = a == nil ? ["-an"] : copyAudio ? ["-c:a", "copy"] : audioEnc
        let maps: [String] = ["-map", "0:v:0?", "-map", "0:a?"]
        let fast: [String] = ["mp4", "mov"].contains(target) ? ["-movflags", "+faststart"] : []
        let isHevc = v?.codec == "hevc"
        let hvc: [String] = copyVideo && isHevc && ["mp4", "mov"].contains(target) ? ["-tag:v", "hvc1"] : []
        let d = info.duration
        let inArgs: [String] = ["-i", input]
        let outArgs: [String] = [output]

        if copyVideo {
            try await Ffmpeg.run(cat(inArgs, maps, ["-map_metadata", "0", "-c:v", "copy"], hvc, audioPart, fast, outArgs), duration: d, progress: progress)
            return
        }
        let even: [String] = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        switch target {
        case "webm":
            let vp9: [String] = ["-map_metadata", "0", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            try await Ffmpeg.run(cat(inArgs, maps, vp9, audioPart, outArgs), duration: d, progress: progress)
            return
        case "avi":
            try await Ffmpeg.run(cat(inArgs, maps, ["-c:v", "mpeg4", "-q:v", "3", "-vtag", "xvid"], audioPart, outArgs), duration: d, progress: progress)
            return
        case "wmv":
            try await Ffmpeg.run(cat(inArgs, maps, ["-c:v", "wmv2", "-q:v", "3"], audioPart, outArgs), duration: d, progress: progress)
            return
        default:
            break
        }
        // mp4 / mov / mkv: H.264, on the Mac's hardware encoder when possible.
        let pix: [String] = ["-pix_fmt", "yuv420p"]
        if Settings.current.hardwareVideoEncoding && videoToolboxWorks != false && Ffmpeg.hasEncoder("h264_videotoolbox") {
            let w = max(v?.width ?? 1280, 2), h = max(v?.height ?? 720, 2)
            let kbps = max(1500, Int(Double(w * h) * 30 * 0.1 / 1000))
            let vt: [String] = ["-c:v", "h264_videotoolbox", "-b:v", "\(kbps)k"]
            do {
                try await Ffmpeg.run(cat(inArgs, maps, ["-map_metadata", "0"], even, vt, pix, audioPart, fast, outArgs), duration: d, progress: progress)
                videoToolboxWorks = true
                return
            } catch let e as OpError where videoToolboxWorks == nil {
                Log.info("VideoToolbox through FFmpeg failed, falling back to x264: \(e.message)")
                videoToolboxWorks = false
            }
        }
        let x264: [String] = ["-c:v", "libx264", "-preset", "medium", "-crf", "20"]
        try await Ffmpeg.run(cat(inArgs, maps, ["-map_metadata", "0"], even, x264, pix, audioPart, fast, outArgs), duration: d, progress: progress)
    }

    static func gif(_ input: String, _ output: String, _ info: MediaInfo, _ progress: @escaping (Double) -> Void) async throws {
        let duration = info.duration > 0 ? min(info.duration, 60) : 0
        let width = info.video.map { $0.width > 0 ? min($0.width, duration > 20 ? 480 : 640) : 480 } ?? 480
        let fps = duration > 20 ? 12 : 15
        let limit = info.duration > 60 ? ["-t", "60"] : []
        let filter = "fps=\(fps),scale=\(width):-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=sierra2_4a"
        try await Ffmpeg.run(limit + ["-i", input, "-filter_complex", filter, "-loop", "0", output], duration: duration, progress: progress)
    }
}
