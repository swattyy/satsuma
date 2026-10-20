import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SatsumaCore

/// The bundled libwebp, checked by reading its output back with ImageIO.
final class WebPTests: XCTestCase {
    /// Straight-alpha RGBA pixels: red, green, blue / white, half-transparent gray-blue, fully transparent.
    let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
                           255, 255, 255, 255, 40, 80, 120, 128, 0, 0, 0, 0]

    func image(_ px: [UInt8], width: Int, height: Int) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(px) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Decodes WebP data with ImageIO into straight-alpha RGBA.
    func decode(_ data: Data) throws -> (CGImage, [UInt8]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        return (img, try WebP.Pixels(img).bytes)
    }

    func testVersion() {
        XCTAssertEqual(WebP.version, "1.6.0")
    }

    func testLosslessKeepsEveryPixel() throws {
        let data = try WebP.encode(try image(pixels, width: 3, height: 2), quality: 100)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WEBP")
        let (img, back) = try decode(data)
        XCTAssertEqual(img.width, 3)
        XCTAssertEqual(img.height, 2)
        for i in 0..<pixels.count where i < 16 || i >= 20 {
            XCTAssertEqual(back[i], pixels[i], "byte \(i)")
        }
        // The half-transparent pixel goes through premultiplication on the way in and out.
        for i in 16..<20 { XCTAssertLessThanOrEqual(abs(Int(back[i]) - Int(pixels[i])), 2, "byte \(i)") }
    }

    func testLossyIsSmallerAndClose() throws {
        // A smooth 256x256 gradient: lossy WebP should be much smaller than raw and close in color.
        let w = 256, h = 256
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let i = (y * w + x) * 4; px[i] = UInt8(x); px[i + 1] = UInt8(y); px[i + 2] = 128 } }
        let data = try WebP.encode(try image(px, width: w, height: h), quality: 80)
        XCTAssertLessThan(data.count, w * h * 4 / 10)
        let (img, back) = try decode(data)
        XCTAssertEqual(img.width, w)
        var worst = 0
        for i in stride(from: 0, to: back.count, by: 4) { for c in 0..<3 { worst = max(worst, abs(Int(back[i + c]) - Int(px[i + c]))) } }
        XCTAssertLessThan(worst, 24)
    }

    func testAnimatedGifKeepsFramesAndTiming() throws {
        let dir = try AppPaths.newTempDir("webp-test")
        defer { P.remove(dir) }
        let gif = P.join(dir, "anim.gif"), out = P.join(dir, "anim.webp")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(P.url(gif) as CFURL, UTType.gif.identifier as CFString, 3, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (i, color) in [[255, 0, 0], [0, 255, 0], [0, 0, 255]].enumerated() {
            var px = [UInt8](repeating: 255, count: 16 * 16 * 4)
            for p in stride(from: 0, to: px.count, by: 4) { px[p] = UInt8(color[0]); px[p + 1] = UInt8(color[1]); px[p + 2] = UInt8(color[2]) }
            let delay = i == 1 ? 0.3 : 0.1
            CGImageDestinationAddImage(dest, try image(px, width: 16, height: 16),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        try WebP.animate(gif: gif, to: out, quality: 90)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(P.url(out) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 3)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 1, nil) as? [String: Any]
        let webp = props?[kCGImagePropertyWebPDictionary as String] as? [String: Any]
        let delay = (webp?[kCGImagePropertyWebPUnclampedDelayTime as String] as? Double) ?? (webp?[kCGImagePropertyWebPDelayTime as String] as? Double)
        XCTAssertEqual(try XCTUnwrap(delay), 0.3, accuracy: 0.011)
    }
}
