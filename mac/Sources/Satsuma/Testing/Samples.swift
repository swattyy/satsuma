import AppKit
import AVFoundation
import CoreText
import ImageIO
import SatsumaCore

/// Writes real sample files for the CI conversion checks: photos with EXIF, transparent PNG, animated GIF,
/// a two-page PDF with text and a photo, a short video with sound, audio, documents, sheets and subtitles.
enum Samples {
    static func make(in dir: String) async throws -> [String] {
        try P.createDir(dir)
        var made: [String] = []
        func add(_ name: String) -> String { let p = P.join(dir, name); made.append(p); return p }

        let photo = drawPhoto(width: 1600, height: 1067)
        try writeJPEGWithExif(photo, to: add("photo.jpg"))
        try ImageConverter.write(drawLogo(size: 512), to: add("logo.png"), type: "public.png")
        try writeGif(to: add("anim.gif"))
        try writePdf(to: add("doc.pdf"), photo: photo)
        try writeWav(to: add("tone.wav"), seconds: 2)
        try await writeMovie(to: add("clip.mov"), audio: P.join(dir, "tone.wav"))

        try P.writeText(add("notes.md"), """
        # Field notes

        A short **Markdown** file with *emphasis*, `code` and a [link](https://example.com).

        ## List

        - first item
        - second item
          - nested item

        1. one
        2. two

        | Name | Count |
        | --- | --- |
        | apples | 3 |
        | pears | 5 |

        ```
        let answer = 42
        ```

        > A quote to finish.
        """)
        try P.writeText(add("notes.txt"), "Plain text notes.\n\nSecond paragraph with more words in it.\n")
        try P.writeText(add("page.html"), "<!doctype html><html><head><title>Sample page</title></head><body><h1>Sample page</h1><p>Some <b>bold</b> text and a <a href=\"https://example.com\">link</a>.</p><ul><li>one</li><li>two</li></ul><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table></body></html>")

        let doc = DocReaders.markdown(try P.readText(P.join(dir, "notes.md")))
        doc.title = "Report"
        try DocWriters.docx(doc, add("report.docx"))
        let rich = NSAttributedString(string: "Rich text report\n\nWritten by the Cocoa text system.\n",
                                      attributes: [.font: NSFont.systemFont(ofSize: 14)])
        try RichText.write(rich, to: add("report.rtf"), format: "rtf")
        try RichText.write(rich, to: add("report.odt"), format: "odt")

        try P.writeText(add("table.csv"), "name,count,price\napples,3,1.25\npears,5,0.8\n\"quoted, cell\",7,2\n")
        let sheet = Sheet(name: "Fruit", rows: [["name", "count"], ["apples", "3"], ["pears", "5"]])
        try SheetConverter.writeXlsx([sheet, Sheet(name: "Other", rows: [["a", "b"], ["1", "2"]])], add("table.xlsx"))
        try SheetConverter.writeOds([sheet], add("table.ods"))

        try P.writeText(add("subs.srt"), "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello there.\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\n<i>General</i> Kenobi.\r\n\r\n")

        let folder = add("Project")
        try P.createDir(folder)
        try P.writeText(P.join(folder, "readme.txt"), "inside the folder\n")
        try P.createDir(P.join(folder, "sub"))
        try P.writeText(P.join(folder, "sub", "more.txt"), "nested\n")
        return made
    }

    // ------------------------------------------------------------------ images

    static func drawPhoto(width w: Int, height h: Int) -> CGImage {
        let ctx = ImageConverter.context(width: w, height: h, opaque: true)!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [CGColor(srgbRed: 1, green: 0.72, blue: 0.42, alpha: 1), CGColor(srgbRed: 0.95, green: 0.36, blue: 0.33, alpha: 1),
                      CGColor(srgbRed: 0.48, green: 0.36, blue: 0.94, alpha: 1)]
        let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        for i in 0..<9 {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18 + 0.06 * Double(i % 3)))
            let r = 60 + CGFloat(i % 4) * 30
            ctx.fillEllipse(in: CGRect(x: CGFloat(i) * 170 + 40, y: CGFloat((i * 37) % 700) + 100, width: r * 2, height: r * 2))
        }
        drawText(ctx, "Satsuma", size: 140, at: CGPoint(x: 330, y: 470), color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        drawText(ctx, "SAMPLE PHOTO 2026", size: 44, at: CGPoint(x: 520, y: 380), color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        return ctx.makeImage()!
    }

    static func drawLogo(size: Int) -> CGImage {
        let ctx = ImageConverter.context(width: size, height: size)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.48, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 48, y: 48, width: size - 96, height: size - 96))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.fillEllipse(in: CGRect(x: size / 2 - 60, y: size / 2 - 60, width: 120, height: 120))
        return ctx.makeImage()!
    }

    static func drawText(_ ctx: CGContext, _ text: String, size: CGFloat, at p: CGPoint, color: CGColor) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                 NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    static func writeJPEGWithExif(_ image: CGImage, to path: String) throws {
        let exif: [String: Any] = [
            kCGImagePropertyExifDateTimeOriginal as String: "2026:10:19 12:34:56",
            kCGImagePropertyExifLensModel as String: "Sample Lens 35mm",
        ]
        let tiff: [String: Any] = [kCGImagePropertyTIFFMake as String: "Satsuma", kCGImagePropertyTIFFModel as String: "Test Camera"]
        let gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: 37.33, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 122.01, kCGImagePropertyGPSLongitudeRef as String: "W",
        ]
        try ImageConverter.write(image, to: path, type: "public.jpeg", quality: 0.9, metadata: [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff,
            kCGImagePropertyGPSDictionary as String: gps,
        ])
    }

    static func writeGif(to path: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(P.url(path) as CFURL, "com.compuserve.gif" as CFString, 4, nil) else { throw OpError("gif") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        let hues: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.48, 0.1), (0.2, 0.6, 1), (0.3, 0.8, 0.4), (0.9, 0.3, 0.6)]
        for (i, c) in hues.enumerated() {
            let ctx = ImageConverter.context(width: 240, height: 180)!
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 20 + i * 40, y: 30, width: 80, height: 120))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.25]] as CFDictionary)
        }
        if !CGImageDestinationFinalize(dest) { throw OpError("gif") }
    }

    // ------------------------------------------------------------------ PDF

    static func writePdf(to path: String, photo: CGImage) throws {
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(P.url(path) as CFURL, mediaBox: &media, [kCGPDFContextTitle as String: "Field notes"] as CFDictionary) else { throw OpError("pdf") }
        let ink = CGColor(srgbRed: 0.15, green: 0.12, blue: 0.1, alpha: 1)
        let body = "Satsuma converts files while you drag them. This sample page has a heading, a few paragraphs of body text and an embedded photo, so text extraction, page rendering and image extraction all have something to work on."
        pdf.beginPDFPage(nil)
        drawText(pdf, "Field notes", size: 28, at: CGPoint(x: 60, y: 760), color: ink)
        var y: CGFloat = 720
        for line in wrap(body, width: 75) {
            drawText(pdf, line, size: 12, at: CGPoint(x: 60, y: y), color: ink)
            y -= 16
        }
        if let jpeg = ImageConverter.encode(photo, type: "public.jpeg", quality: 0.85),
           let provider = CGDataProvider(data: jpeg as CFData),
           let img = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            pdf.draw(img, in: CGRect(x: 60, y: 300, width: 475, height: 317))
        }
        pdf.endPDFPage()
        pdf.beginPDFPage(nil)
        drawText(pdf, "Second page", size: 20, at: CGPoint(x: 60, y: 770), color: ink)
        y = 740
        for line in wrap(body + " " + body, width: 75) {
            drawText(pdf, line, size: 12, at: CGPoint(x: 60, y: y), color: ink)
            y -= 16
        }
        pdf.endPDFPage()
        pdf.closePDF()
    }

    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if line.count + word.count + 1 > width { lines.append(line); line = "" }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    // ------------------------------------------------------------------ audio and video

    static func writeWav(to path: String, seconds: Double) throws {
        let rate = 44_100, channels = 2
        let frames = Int(Double(rate) * seconds)
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + frames * channels * 2); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
        d.append(Data("data".utf8)); u32(frames * channels * 2)
        for i in 0..<frames {
            let t = Double(i) / Double(rate)
            let left = Int16(sin(2 * .pi * 440 * t) * 0.3 * 32767)
            let right = Int16(sin(2 * .pi * 660 * t) * 0.3 * 32767)
            u16(Int(UInt16(bitPattern: left)))
            u16(Int(UInt16(bitPattern: right)))
        }
        try d.write(to: P.url(path))
    }

    /// Two seconds of 640x360 H.264 with the tone as sound, written by AVFoundation.
    static func writeMovie(to path: String, audio: String) async throws {
        let tmp = try AppPaths.newTempDir("sample")
        defer { P.remove(tmp) }
        let silent = P.join(tmp, "video.mov")
        let w = 640, h = 360, fps = 30
        let writer = try AVAssetWriter(outputURL: P.url(silent), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for f in 0..<(fps * 2) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let buffer = pb else { throw OpError("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            let t = CGFloat(f) / CGFloat(fps * 2)
            ctx.setFillColor(CGColor(srgbRed: 0.1 + 0.8 * t, green: 0.3, blue: 0.9 - 0.7 * t, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.48, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 40 + t * 480, y: 120, width: 120, height: 120))
            drawText(ctx, "frame \(f)", size: 28, at: CGPoint(x: 24, y: 24), color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        if writer.status != .completed { throw OpError("sample video: \(writer.error?.localizedDescription ?? "?")") }

        // Add the tone as an AAC track.
        let comp = AVMutableComposition()
        let video = AVURLAsset(url: P.url(silent)), sound = AVURLAsset(url: P.url(audio))
        let duration = try await video.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        if let v = try await video.loadTracks(withMediaType: .video).first,
           let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try vt.insertTimeRange(range, of: v, at: .zero)
        }
        if let a = try await sound.loadTracks(withMediaType: .audio).first,
           let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try at.insertTimeRange(range, of: a, at: .zero)
        }
        var t = AVMedia.Transcode()
        t.fileType = .mov
        t.videoBitrate = 2_000_000
        try await AVMedia.transcode(comp, to: path, t, progress: nil)
    }
}
