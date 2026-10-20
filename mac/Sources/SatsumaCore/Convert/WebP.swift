import Foundation
import Accelerate
import CoreGraphics
import ImageIO
import CWebP

/// WebP output through the bundled libwebp (ImageIO reads WebP but can't write it). Like the Windows app,
/// quality 100 means lossless and photo metadata isn't carried over. Colors are converted to sRGB, which is
/// what viewers assume for a WebP without a color profile.
public enum WebP {
    /// The bundled libwebp version, for example "1.6.0".
    public static var version: String {
        let v = Int(SatsumaWebPEncoderVersion())
        return "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    public static func encode(_ image: CGImage, quality: Int) throws -> Data {
        let px = try Pixels(image)
        var out: UnsafeMutablePointer<UInt8>?
        let size = px.bytes.withUnsafeBufferPointer { buf in
            SatsumaWebPEncode(buf.baseAddress, Int32(px.width), Int32(px.height), Int32(px.stride), Float(quality),
                              quality >= 100 ? 1 : 0, &out)
        }
        guard size > 0, let out else { throw OpError("Couldn't encode this image as WebP.") }
        defer { SatsumaWebPFree(out) }
        return Data(bytes: out, count: size)
    }

    public static func write(_ image: CGImage, to path: String, quality: Int) throws {
        try encode(image, quality: quality).write(to: P.url(path))
    }

    /// Animated GIF to animated WebP, looping forever like the Windows app's FFmpeg command. ImageIO hands back
    /// each GIF frame already composited onto the canvas.
    public static func animate(gif input: String, to output: String, quality: Int) throws {
        guard let src = CGImageSourceCreateWithURL(P.url(input) as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw OpError("macOS can't read \(P.fileName(input)).")
        }
        let w = first.width, h = first.height
        guard let anim = SatsumaWebPAnimNew(Int32(w), Int32(h), Float(quality), 0) else {
            throw OpError("Couldn't start the WebP encoder.")
        }
        defer { SatsumaWebPAnimDelete(anim) }
        var t = 0
        for i in 0..<CGImageSourceGetCount(src) {
            try Task.checkCancellation()
            guard let frame = i == 0 ? first : CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let px = try Pixels(frame, canvas: (w, h))
            let ok = px.bytes.withUnsafeBufferPointer { SatsumaWebPAnimAdd(anim, $0.baseAddress, Int32(px.stride), Int32(t)) }
            guard ok != 0 else { throw OpError("Couldn't encode frame \(i + 1) as WebP.") }
            t += delayMs(src, i)
        }
        var out: UnsafeMutablePointer<UInt8>?
        let size = SatsumaWebPAnimFinish(anim, Int32(t), &out)
        guard size > 0, let out else { throw OpError("Couldn't finish the WebP animation.") }
        defer { SatsumaWebPFree(out) }
        try Data(bytes: out, count: size).write(to: P.url(output))
    }

    /// A GIF frame's delay in milliseconds. Like browsers, delays under 20 ms play at 100 ms.
    static func delayMs(_ src: CGImageSource, _ i: Int) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
        let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
        return d < 0.02 ? 100 : Int((d * 1000).rounded())
    }

    /// 8-bit sRGB RGBA with straight alpha, the layout libwebp imports. With a canvas size the image is drawn at
    /// its own size in the top-left corner.
    struct Pixels {
        let width: Int
        let height: Int
        let stride: Int
        let bytes: [UInt8]

        init(_ image: CGImage, canvas: (Int, Int)? = nil) throws {
            let w = canvas?.0 ?? image.width, h = canvas?.1 ?? image.height, s = w * 4
            var data = [UInt8](repeating: 0, count: s * h)
            let ok = data.withUnsafeMutableBytes { buf -> Bool in
                guard let base = buf.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: s,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: h - image.height, width: image.width, height: image.height))
                // Core Graphics only draws premultiplied alpha; libwebp wants it straight.
                var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: s)
                var dst = src
                return vImageUnpremultiplyData_RGBA8888(&src, &dst, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
            guard ok else { throw OpError("Couldn't read the image's pixels.") }
            width = w
            height = h
            stride = s
            bytes = data
        }
    }
}
