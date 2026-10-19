import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import ImageIO

public struct AVInfo {
    public var duration: Double = 0
    /// "h264", "hevc", "prores", "mpeg4", "mjpeg", "av1" or the raw four-character code.
    public var videoCodec: String?
    /// "aac", "mp3", "alac", "pcm", "ac3", "eac3", "flac", "opus" or the raw four-character code.
    public var audioCodec: String?
    /// Display size (rotation applied).
    public var width = 0
    public var height = 0
    public var fps = 0.0
    public var channels = 0
    public var sampleRate = 0.0
    /// Source bit depth for PCM and lossless audio, 0 for lossy codecs.
    public var audioBits = 0

    public var hasVideo: Bool { videoCodec != nil }
    public var hasAudio: Bool { audioCodec != nil }
}

/// Audio and video through AVFoundation, Core Audio and VideoToolbox (hardware encoding on every Mac).
public enum AVMedia {
    public static let nativeVideoExts: Set<String> = ["mp4", "m4v", "mov", "qt", "3gp", "3g2"]
    public static let nativeAudioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "m4b", "amr"]

    public static func canRead(_ path: String) -> Bool {
        let e = FileKinds.ext(path)
        return nativeVideoExts.contains(e) || nativeAudioExts.contains(e)
    }

    public static func isNativeVideo(_ path: String) -> Bool { nativeVideoExts.contains(FileKinds.ext(path)) }

    // ------------------------------------------------------------------ probing

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    static func videoCodecName(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1": return "hevc"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": return "prores"
        case "mp4v": return "mpeg4"
        case "jpeg", "mjpa", "mjpb": return "mjpeg"
        case "av01": return "av1"
        default: return fourCC(code).trimmingCharacters(in: .whitespaces)
        }
    }

    static func audioCodecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: return "aac"
        case kAudioFormatMPEGLayer3: return "mp3"
        case kAudioFormatAppleLossless: return "alac"
        case kAudioFormatLinearPCM: return "pcm"
        case kAudioFormatAC3: return "ac3"
        case kAudioFormatEnhancedAC3: return "eac3"
        case kAudioFormatFLAC: return "flac"
        case kAudioFormatOpus: return "opus"
        default: return fourCC(id).trimmingCharacters(in: .whitespaces)
        }
    }

    static func losslessBits(_ flags: AudioFormatFlags) -> Int {
        switch flags {
        case kAppleLosslessFormatFlag_16BitSourceData: return 16
        case kAppleLosslessFormatFlag_20BitSourceData: return 20
        case kAppleLosslessFormatFlag_24BitSourceData: return 24
        case kAppleLosslessFormatFlag_32BitSourceData: return 32
        default: return 0
        }
    }

    public static func info(_ path: String) async throws -> AVInfo {
        let asset = AVURLAsset(url: P.url(path))
        var info = AVInfo()
        let duration = try await asset.load(.duration)
        info.duration = duration.seconds.isFinite ? duration.seconds : 0
        if let v = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform, fps, descs) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            info.width = Int(abs(shown.width).rounded())
            info.height = Int(abs(shown.height).rounded())
            info.fps = Double(fps)
            if let d = descs.first { info.videoCodec = videoCodecName(CMFormatDescriptionGetMediaSubType(d)) }
        }
        if let a = try await asset.loadTracks(withMediaType: .audio).first {
            let descs = try await a.load(.formatDescriptions)
            if let d = descs.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                info.audioCodec = audioCodecName(asbd.mFormatID)
                info.channels = Int(asbd.mChannelsPerFrame)
                info.sampleRate = asbd.mSampleRate
                if asbd.mFormatID == kAudioFormatLinearPCM { info.audioBits = Int(asbd.mBitsPerChannel) }
                else if asbd.mFormatID == kAudioFormatAppleLossless || asbd.mFormatID == kAudioFormatFLAC { info.audioBits = losslessBits(asbd.mFormatFlags) }
            }
        }
        return info
    }

    // ------------------------------------------------------------------ export sessions (remux, presets)

    final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }

    public static func export(_ asset: AVAsset, to output: String, preset: String, fileType: AVFileType, timeRange: CMTimeRange? = nil,
                              videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil,
                              progress: ((Double) -> Void)?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw OpError("macOS can't export this file with \(preset).")
        }
        P.remove(output)
        session.outputURL = P.url(output)
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
        if let audioMix { session.audioMix = audioMix }
        let box = SessionBox(session)
        let ticker = Task {
            while !Task.isCancelled {
                progress?(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { c.resume() }
        }
        ticker.cancel()
        if session.status != .completed {
            throw OpError(session.error?.localizedDescription ?? "macOS couldn't export this file.")
        }
        progress?(1)
    }

    /// Container switch without re-encoding, when the codecs are allowed in the new container.
    public static func canRemux(_ info: AVInfo, to target: String) -> Bool {
        let video: Set<String>, audio: Set<String>
        switch target {
        case "mp4", "m4v":
            video = ["h264", "hevc", "av1", "mpeg4"]
            audio = ["aac", "mp3", "ac3", "eac3", "alac"]
        case "mov":
            video = ["h264", "hevc", "prores", "mpeg4", "mjpeg"]
            audio = ["aac", "mp3", "alac", "pcm", "ac3"]
        default:
            return false
        }
        let videoOK = info.videoCodec.map { video.contains($0) } ?? true
        let audioOK = info.audioCodec.map { audio.contains($0) } ?? true
        return videoOK && audioOK
    }

    public static func fileType(for ext: String) -> AVFileType {
        switch ext {
        case "mov", "qt": return .mov
        case "m4v": return .m4v
        case "m4a", "m4b": return .m4a
        case "wav", "wave": return .wav
        case "aiff", "aif": return .aiff
        case "aifc": return .aifc
        case "caf": return .caf
        default: return .mp4
        }
    }

    // ------------------------------------------------------------------ transcoding (reader -> writer)

    public enum AudioOut { case aac, pcmLittle, pcmBig }

    public struct Transcode {
        public var timeRange: CMTimeRange?
        public var includeVideo = true
        public var includeAudio = true
        /// Scale so the display height is at most this.
        public var maxHeight: Int?
        /// Scale to exactly this display height (keeping the aspect ratio).
        public var height: Int?
        public var rotateClockwise = false
        /// Video bits per second; nil picks one from `bitsPerPixel`.
        public var videoBitrate: Int?
        public var bitsPerPixel = 0.1
        public var codec: AVVideoCodecType = .h264
        public var audioOut: AudioOut = .aac
        public var audioBitrate = 192_000
        public var audioBits = 16
        /// 1 for mono. nil keeps mono or stereo (more channels are mixed down to stereo).
        public var audioChannels: Int?
        public var audioMix: AVAudioMix?
        public var fileType: AVFileType = .mp4
        public init() {}
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    static func audioSettings(_ out: AudioOut, channels: Int, rate: Double, bitrate: Int, bits: Int) -> [String: Any] {
        switch out {
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate, AVEncoderBitRateKey: bitrate]
        case .pcmLittle, .pcmBig:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
                    AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: out == .pcmBig,
                    AVLinearPCMIsNonInterleaved: false]
        }
    }

    /// Re-encodes `asset` into `output`, applying the orientation, scaling, trimming and audio changes in `o`.
    public static func transcode(_ asset: AVAsset, to output: String, _ o: Transcode, progress: ((Double) -> Void)?) async throws {
        let duration = try await asset.load(.duration)
        var videoTrack: AVAssetTrack?
        if o.includeVideo { videoTrack = try await asset.loadTracks(withMediaType: .video).first }
        var audioTracks: [AVAssetTrack] = []
        if o.includeAudio { audioTracks = try await asset.loadTracks(withMediaType: .audio) }
        if videoTrack == nil && audioTracks.isEmpty { throw OpError("No audio or video found.") }

        P.remove(output)
        let reader = try AVAssetReader(asset: asset)
        let range = o.timeRange ?? CMTimeRange(start: .zero, duration: duration)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: P.url(output), fileType: o.fileType)
        writer.shouldOptimizeForNetworkUse = true

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = []

        if let v = videoTrack {
            let (natural, transform, nominal) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            var t = transform
            if o.rotateClockwise { t = t.concatenating(CGAffineTransform(rotationAngle: .pi / 2)) }
            let shown = CGRect(origin: .zero, size: natural).applying(t)
            let dispW = max(1, abs(shown.width)), dispH = max(1, abs(shown.height))
            var outH = dispH
            if let mh = o.maxHeight, dispH > CGFloat(mh) { outH = CGFloat(mh) }
            if let h = o.height { outH = CGFloat(h) }
            let outW = dispW * outH / dispH
            let w = max(2, Int(outW / 2) * 2), h = max(2, Int(outH / 2) * 2)
            let fps = nominal > 0 ? Double(nominal) : 30

            let comp = AVMutableVideoComposition()
            comp.renderSize = CGSize(width: w, height: h)
            comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: v)
            let placed = t.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
                .concatenating(CGAffineTransform(scaleX: CGFloat(w) / dispW, y: CGFloat(h) / dispH))
            layer.setTransform(placed, at: .zero)
            instruction.layerInstructions = [layer]
            comp.instructions = [instruction]

            let out = AVAssetReaderVideoCompositionOutput(videoTracks: [v], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            out.videoComposition = comp
            out.alwaysCopiesSampleData = false
            let bitrate = o.videoBitrate ?? max(300_000, Int(Double(w * h) * fps * o.bitsPerPixel))
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: o.codec,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                    AVVideoMaxKeyFrameIntervalKey: max(1, Int(fps.rounded()) * 2),
                ] as [String: Any],
            ])
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else { throw OpError("macOS can't re-encode this video.") }
            reader.add(out)
            writer.add(input)
            pairs.append((out, input, true))
        }

        if !audioTracks.isEmpty {
            var srcChannels = 2
            var srcRate = 48_000.0
            if let d = try await audioTracks[0].load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                srcChannels = Int(asbd.mChannelsPerFrame)
                srcRate = asbd.mSampleRate
            }
            let channels = o.audioChannels ?? min(2, max(1, srcChannels))
            let rate = o.audioOut == .aac ? min(48_000, srcRate > 0 ? srcRate : 48_000) : (srcRate > 0 ? srcRate : 48_000)
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: rate,
            ])
            if let mix = o.audioMix { out.audioMix = mix }
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(o.audioOut, channels: channels, rate: rate,
                                                                                             bitrate: o.audioBitrate, bits: o.audioBits))
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(input) else { throw OpError("macOS can't re-encode this audio.") }
            reader.add(out)
            writer.add(input)
            pairs.append((out, input, videoTrack == nil))
        }

        guard writer.startWriting() else { throw OpError(writer.error?.localizedDescription ?? "Couldn't start writing.") }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw OpError(reader.error?.localizedDescription ?? "Couldn't read this file.")
        }
        writer.startSession(atSourceTime: range.start)

        let group = DispatchGroup()
        let failed = Flag()
        let total = range.duration.seconds
        let start = range.start.seconds
        for (out, input, reportsProgress) in pairs {
            group.enter()
            let finished = Flag()
            let queue = DispatchQueue(label: "satsuma.transcode")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished.value {
                    guard let sample = out.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        finished.value = true
                        group.leave()
                        return
                    }
                    if reportsProgress, total > 0 {
                        progress?(min(1, max(0, (CMSampleBufferGetPresentationTimeStamp(sample).seconds - start) / total)))
                    }
                    if !input.append(sample) {
                        failed.value = true
                        input.markAsFinished()
                        finished.value = true
                        group.leave()
                        return
                    }
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }
        if failed.value || reader.status == .failed || writer.status == .failed {
            let why = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "unknown error"
            reader.cancelReading()
            writer.cancelWriting()
            throw OpError("Re-encoding failed: \(why)")
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        if writer.status != .completed { throw OpError(writer.error?.localizedDescription ?? "Couldn't finish writing.") }
        progress?(1)
    }

    // ------------------------------------------------------------------ FLAC (Core Audio)

    /// Reads anything Core Audio can decode and writes FLAC.
    public static func writeFlac(from input: String, to output: String, bits: Int, progress: ((Double) -> Void)?) throws {
        var inRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(P.url(input) as CFURL, &inRef) == noErr, let inFile = inRef else {
            throw OpError("macOS can't read \(P.fileName(input)).")
        }
        defer { ExtAudioFileDispose(inFile) }
        var src = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(inFile, kExtAudioFileProperty_FileDataFormat, &size, &src)
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(inFile, kExtAudioFileProperty_FileLengthFrames, &size, &frames)

        let ch = max(1, src.mChannelsPerFrame)
        var client = AudioStreamBasicDescription(mSampleRate: src.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
                                                 mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileSetProperty(inFile, kExtAudioFileProperty_ClientDataFormat, clientSize, &client) == noErr else {
            throw OpError("macOS can't decode \(P.fileName(input)).")
        }

        var dst = AudioStreamBasicDescription()
        dst.mSampleRate = src.mSampleRate
        dst.mFormatID = kAudioFormatFLAC
        dst.mChannelsPerFrame = ch
        dst.mFormatFlags = bits > 16 ? kAppleLosslessFormatFlag_24BitSourceData : kAppleLosslessFormatFlag_16BitSourceData
        var infoSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &infoSize, &dst)

        P.remove(output)
        var outRef: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(P.url(output) as CFURL, kAudioFileFLACType, &dst, nil, AudioFileFlags.eraseFile.rawValue, &outRef)
        guard status == noErr, let outFile = outRef else { throw OpError("This Mac can't encode FLAC (\(status)).") }
        defer { ExtAudioFileDispose(outFile) }
        guard ExtAudioFileSetProperty(outFile, kExtAudioFileProperty_ClientDataFormat, clientSize, &client) == noErr else {
            throw OpError("This Mac can't encode FLAC.")
        }

        let chunk: UInt32 = 8192
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(chunk * ch))
        defer { buffer.deallocate() }
        var done: Int64 = 0
        while true {
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: ch, mDataByteSize: chunk * 4 * ch,
                                                                                    mData: UnsafeMutableRawPointer(buffer)))
            var n = chunk
            guard ExtAudioFileRead(inFile, &n, &list) == noErr else { throw OpError("Couldn't read \(P.fileName(input)).") }
            if n == 0 { break }
            list.mBuffers.mDataByteSize = n * 4 * ch
            guard ExtAudioFileWrite(outFile, n, &list) == noErr else { throw OpError("Couldn't write FLAC.") }
            done += Int64(n)
            if frames > 0 { progress?(Double(done) / Double(frames)) }
        }
    }

    // ------------------------------------------------------------------ GIF in and out

    static func gifDelay(_ src: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any],
              let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] else { return 0.1 }
        let d = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
        return d < 0.011 ? 0.1 : d
    }

    /// Animated GIF to H.264 MP4 (transparent areas become white).
    public static func gifToMp4(_ input: String, output: String) async throws {
        guard let src = CGImageSourceCreateWithURL(P.url(input) as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw OpError("macOS can't read \(P.fileName(input)).") }
        let count = CGImageSourceGetCount(src)
        let w = max(2, first.width / 2 * 2), h = max(2, first.height / 2 * 2)
        P.remove(output)
        let writer = try AVAssetWriter(outputURL: P.url(output), fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(1_000_000, w * h * 8)] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw OpError(writer.error?.localizedDescription ?? "Couldn't start writing.") }
        writer.startSession(atSourceTime: .zero)
        var t = 0.0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw OpError("Couldn't encode the video.") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw OpError("Couldn't encode the video.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.interpolationQuality = .high
                ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if !adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) {
                throw OpError(writer.error?.localizedDescription ?? "Couldn't encode the video.")
            }
            t += gifDelay(src, i)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: max(t, 0.1), preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        if writer.status != .completed { throw OpError(writer.error?.localizedDescription ?? "Couldn't finish the video.") }
    }

    /// Video to an animated GIF: at most 60 s, 15 fps and 640 px (12 fps and 480 px past 20 s), like the Windows app.
    public static func videoToGif(_ input: String, output: String, progress: ((Double) -> Void)?) async throws {
        let info = try await self.info(input)
        guard info.hasVideo, info.duration > 0 else { throw OpError("No video found.") }
        let duration = min(info.duration, 60)
        let width = min(info.width > 0 ? info.width : 480, duration > 20 ? 480 : 640)
        let fps = duration > 20 ? 12.0 : 15.0
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: P.url(input)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: width, height: width * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        let n = max(1, Int(duration * fps))
        guard var last = try? gen.copyCGImage(at: .zero, actualTime: nil) else { throw OpError("Couldn't read frames from this video.") }
        P.remove(output)
        guard let dest = CGImageDestinationCreateWithURL(P.url(output) as CFURL, "com.compuserve.gif" as CFString, n, nil) else {
            throw OpError("Couldn't create \(P.fileName(output)).")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: 1 / fps,
            kCGImagePropertyGIFUnclampedDelayTime as String: 1 / fps,
        ]] as CFDictionary
        for k in 0..<n {
            if k > 0, let img = try? gen.copyCGImage(at: CMTime(seconds: Double(k) / fps, preferredTimescale: 600), actualTime: nil) { last = img }
            CGImageDestinationAddImage(dest, last, frameProps)
            progress?(Double(k + 1) / Double(n))
            if k % 15 == 0 { try Task.checkCancellation() }
        }
        if !CGImageDestinationFinalize(dest) { throw OpError("Couldn't write \(P.fileName(output)).") }
    }

    /// One frame as PNG, at full size.
    public static func frame(_ input: String, at seconds: Double, output: String) throws {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: P.url(input)))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let image = try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        try ImageConverter.write(image, to: output, type: "public.png")
    }
}
