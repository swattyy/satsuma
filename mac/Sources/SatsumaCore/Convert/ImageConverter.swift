import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public final class DecodedImage {
    /// Full-size image with the EXIF orientation already applied.
    public let image: CGImage
    /// Camera metadata to carry over (EXIF, GPS, TIFF, IPTC), orientation reset to "up".
    public let metadata: [String: Any]?
    public let hasAlpha: Bool

    public init(image: CGImage, metadata: [String: Any]?, hasAlpha: Bool) {
        self.image = image
        self.metadata = metadata
        self.hasAlpha = hasAlpha
    }

    public var width: Int { image.width }
    public var height: Int { image.height }
}

/// Image conversion. ImageIO reads everything macOS can open (HEIC, AVIF, WebP, camera RAW, TIFF...) and writes
/// JPEG, PNG, HEIC, TIFF, BMP and GIF. ICO and PDF are written here and WebP with the bundled libwebp; AVIF goes
/// through ImageIO when this macOS can write it and through FFmpeg otherwise.
public enum ImageConverter {
    public static let targets = ["jpg", "png", "webp", "heic", "avif", "pdf", "tiff", "bmp", "ico"]

    static let typeIds: [String: String] = [
        "jpg": "public.jpeg", "jpeg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff",
        "bmp": "com.microsoft.bmp", "gif": "com.compuserve.gif", "webp": "org.webmproject.webp", "avif": "public.avif",
        "icns": "com.apple.icns", "ico": "com.microsoft.ico",
    ]

    public static var writableTypes: [String] { (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [] }
    public static var readableTypes: [String] { (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [] }
    static func canWrite(_ typeId: String) -> Bool { writableTypes.contains(typeId) }


    // ------------------------------------------------------------------ decode

    public static func decode(_ path: String) async throws -> DecodedImage {
        if FileKinds.ext(path) == "svg" {
            let img = try await WebRender.rasterizeSVG(path)
            return DecodedImage(image: img, metadata: nil, hasAlpha: true)
        }
        return try decodeSync(path)
    }

    public static func decodeSync(_ path: String) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithURL(P.url(path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else {
            throw OpError("macOS can't read \(P.fileName(path)).")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
        guard let image else { throw OpError("macOS can't read \(P.fileName(path)).") }
        return DecodedImage(image: image, metadata: carriedMetadata(props), hasAlpha: hasTransparency(image))
    }

    /// The metadata dictionaries worth keeping, with orientation reset because the pixels are already upright.
    static func carriedMetadata(_ props: [String: Any]) -> [String: Any]? {
        var meta: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
            if let v = props[key as String] { meta[key as String] = v }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            meta[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return meta.isEmpty ? nil : meta
    }

    public static func hasTransparency(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let k = min(1.0, 600.0 / Double(max(img.width, img.height)))
        let w = max(1, Int(Double(img.width) * k)), h = max(1, Int(Double(img.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = ctx.data else { return true }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var i = 3
        while i < w * h * 4 {
            if p[i] != 255 { return true }
            i += 4
        }
        return false
    }

    // ------------------------------------------------------------------ convert

    public static func convert(_ input: String, to target: String) async throws -> String {
        let inExt = FileKinds.ext(input)
        if inExt == "gif" && ["mp4", "webm", "webp"].contains(target) { return try await animatedGif(input, to: target) }
        let img = try await decode(input)
        let output = OutputPaths.path(for: input, ext: target)
        return try await OutputPaths.writing(output) { out in
            try await save(img, to: out, format: target, quality: Settings.current.imageQuality, sourceExt: inExt)
            return out
        }
    }

    public static func save(_ img: DecodedImage, to output: String, format target: String, quality: Int, sourceExt: String) async throws {
        let meta = Settings.current.keepMetadata ? img.metadata : nil
        let q = Double(min(max(quality, 1), 100)) / 100
        switch target {
        case "png":
            try write(img.image, to: output, type: "public.png")
        case "jpg", "jpeg":
            try write(flatten(img.image), to: output, type: "public.jpeg", quality: q, metadata: meta)
        case "heic":
            do { try write(flatten(img.image), to: output, type: "public.heic", quality: q, metadata: meta) }
            catch { throw OpError("This Mac couldn't encode HEIC.") }
        case "tiff":
            var m = meta ?? [:]
            var tiff = (m[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = 5 // LZW
            m[kCGImagePropertyTIFFDictionary as String] = tiff
            try write(img.image, to: output, type: "public.tiff", metadata: m)
        case "bmp":
            try write(flatten(img.image), to: output, type: "com.microsoft.bmp")
        case "gif":
            try write(img.image, to: output, type: "com.compuserve.gif")
        case "icns":
            try write(squared(img.image, side: 1024), to: output, type: "com.apple.icns")
        case "ico":
            try buildIco(img.image).write(to: P.url(output))
        case "webp":
            try WebP.write(img.image, to: output, quality: quality)
        case "avif":
            if canWrite("public.avif") { try write(img.hasAlpha ? img.image : flatten(img.image), to: output, type: "public.avif", quality: q, metadata: meta) }
            else { try await ffmpegAvif(img, output, quality: quality) }
        case "pdf":
            try pdfFromImages([(img, sourceExt)], output: output)
        default:
            throw OpError("Can't write \(target.uppercased()) images.")
        }
    }

    // ------------------------------------------------------------------ ImageIO helpers

    public static func write(_ image: CGImage, to path: String, type: String, quality: Double? = nil, metadata: [String: Any]? = nil) throws {
        guard let dest = CGImageDestinationCreateWithURL(P.url(path) as CFURL, type as CFString, 1, nil) else {
            throw OpError("macOS can't write \(P.ext(path).dropFirst().uppercased()) images.")
        }
        var props = metadata ?? [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality as String] = quality }
        props[kCGImagePropertyOrientation as String] = 1
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw OpError("Couldn't write \(P.fileName(path)).") }
    }

    public static func encode(_ image: CGImage, type: String, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }
        var props: [String: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality as String] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func rgbSpace(_ img: CGImage) -> CGColorSpace {
        if let cs = img.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// An 8-bit RGBA context; `opaque` drops the alpha channel.
    public static func context(width: Int, height: Int, opaque: Bool = false, space: CGColorSpace? = nil) -> CGContext? {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let cs = space ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if let c = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) {
            return c
        }
        return CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
    }

    public static func flatten(_ img: CGImage, background: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) -> CGImage {
        guard let ctx = context(width: img.width, height: img.height, opaque: true, space: rgbSpace(img)) else { return img }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(background)
        ctx.fill(r)
        ctx.draw(img, in: r)
        return ctx.makeImage() ?? img
    }

    /// High quality resample to exactly `width` x `height`.
    public static func resample(_ img: CGImage, width: Int, height: Int) -> CGImage {
        guard let ctx = context(width: width, height: height, space: rgbSpace(img)) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height)))
        return ctx.makeImage() ?? img
    }

    /// The image centered on a transparent square canvas, scaled to `side`.
    static func squared(_ img: CGImage, side: Int) -> CGImage {
        guard let ctx = context(width: side, height: side) else { return img }
        ctx.interpolationQuality = .high
        let k = Double(side) / Double(max(img.width, img.height))
        let w = Double(img.width) * k, h = Double(img.height) * k
        ctx.draw(img, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    // ------------------------------------------------------------------ FFmpeg fallbacks (AVIF, GIF to WebM)

    static func ffmpegAvif(_ img: DecodedImage, _ output: String, quality: Int) async throws {
        if !Ffmpeg.available { throw OpError("AVIF output needs FFmpeg. Open Satsuma Settings > Engines to install it.") }
        let tmpDir = try AppPaths.newTempDir("still")
        defer { P.remove(tmpDir) }
        let tmp = P.join(tmpDir, "frame.png")
        try write(img.image, to: tmp, type: "public.png")
        let crf = min(max(Int((63 - Double(quality) * 0.45).rounded()), 10), 50) // q90 is crf 22
        let scale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        if Ffmpeg.hasEncoder("libaom-av1") {
            let args: [String] = img.hasAlpha
                ? ["-i", tmp, "-filter_complex", "[0:v]\(scale),format=yuva444p,split[c][a];[a]alphaextract[al]", "-map", "[c]", "-map", "[al]",
                   "-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(crf)", "-cpu-used", "6", "-row-mt", "1", output]
                : ["-i", tmp, "-vf", "\(scale),format=yuv420p", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(crf)",
                   "-cpu-used", "6", "-row-mt", "1", output]
            try await Ffmpeg.run(args, duration: 0, progress: nil)
        } else if Ffmpeg.hasEncoder("libsvtav1") {
            try await Ffmpeg.run(["-i", tmp, "-vf", "\(scale),format=yuv420p", "-c:v", "libsvtav1", "-crf", "\(crf)", "-preset", "8",
                                  "-frames:v", "1", output], duration: 0, progress: nil)
        } else {
            throw OpError("This FFmpeg build can't write AVIF.")
        }
    }

    static func animatedGif(_ input: String, to target: String) async throws -> String {
        let output = OutputPaths.path(for: input, ext: target)
        return try await OutputPaths.writing(output) { out in
            if target == "mp4" {
                try await AVMedia.gifToMp4(input, output: out)
                return out
            }
            if target == "webp" {
                try WebP.animate(gif: input, to: out, quality: Settings.current.imageQuality)
                return out
            }
            if !Ffmpeg.available { throw OpError("\(target.uppercased()) output needs FFmpeg. Open Satsuma Settings > Engines to install it.") }
            let info = Ffmpeg.probe(input)
            let args = ["-i", input, "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuva420p", out]
            try await Ffmpeg.run(args, duration: info.duration, progress: nil)
            return out
        }
    }

    // ------------------------------------------------------------------ ICO

    public static func buildIco(_ source: CGImage) throws -> Data {
        let sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
        let side = max(source.width, source.height)
        let square = squared(source, side: side)
        var frames: [Data] = []
        for s in sizes {
            let scaled = resample(square, width: s, height: s)
            guard let png = encode(scaled, type: "public.png") else { throw OpError("Couldn't build the icon.") }
            frames.append(png)
        }
        return writeIco(sizes: sizes, pngFrames: frames)
    }

    public static func writeIco(sizes: [Int], pngFrames: [Data]) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: Int) { for i in 0..<4 { d.append(UInt8((v >> (8 * i)) & 0xFF)) } }
        u16(0); u16(1); u16(pngFrames.count)
        var offset = 6 + 16 * pngFrames.count
        for (i, frame) in pngFrames.enumerated() {
            let s = sizes[i]
            d.append(UInt8(s >= 256 ? 0 : s)); d.append(UInt8(s >= 256 ? 0 : s))
            d.append(0); d.append(0)
            u16(1); u16(32)
            u32(frame.count); u32(offset)
            offset += frame.count
        }
        for f in pngFrames { d.append(f) }
        return d
    }

    // ------------------------------------------------------------------ PDF from images

    static let lossyExts: Set<String> = ["jpg", "jpeg", "jfif", "jpe", "heic", "heif", "hif", "avif", "webp"]

    /// One page per image (long side on A4's 842 pt). Photos are embedded as JPEG, graphics losslessly.
    public static func pdfFromImages(_ images: [(DecodedImage, String)], output: String) throws {
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(P.url(output) as CFURL, mediaBox: &media,
                                  [kCGPDFContextCreator as String: "Satsuma"] as CFDictionary) else {
            throw OpError("Couldn't create \(P.fileName(output)).")
        }
        for (img, ext) in images {
            let k = 842.0 / Double(max(img.width, img.height))
            var box = CGRect(x: 0, y: 0, width: Double(img.width) * k, height: Double(img.height) * k)
            pdf.beginPage(mediaBox: &box)
            var page = img.image
            if lossyExts.contains(ext) || (!img.hasAlpha && img.width * img.height > 4_000_000) {
                if let jpeg = jpegBacked(flatten(img.image), quality: 0.92) { page = jpeg }
            }
            pdf.interpolationQuality = .high
            pdf.draw(page, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
    }

    /// A CGImage backed by JPEG data, which Quartz embeds in PDFs as-is instead of re-compressing.
    static func jpegBacked(_ img: CGImage, quality: Double) -> CGImage? {
        guard let data = encode(img, type: "public.jpeg", quality: quality), let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
