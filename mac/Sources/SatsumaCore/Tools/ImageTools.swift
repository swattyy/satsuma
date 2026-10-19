import Foundation
import CoreGraphics
import CoreImage
import Vision

/// Image tools: compress, resize, crop, rotate, metadata, OCR, redaction, backgrounds, PDF and collage.
/// Rectangles from Vision and for redaction use Core Graphics' bottom-left origin; crop uses top-left pixels.
public enum ImageTools {
    /// Output format for edits: keep the source format when we can write it, otherwise PNG or JPG.
    public static func editFormat(_ input: String, hasAlpha: Bool) -> String {
        let ext = FileKinds.ext(input)
        switch ext {
        case "jpg", "jpeg", "jfif", "jpe": return "jpg"
        case "png", "webp", "heic", "tiff", "bmp", "avif": return ext
        case "heif", "hif": return "heic"
        case "tif": return "tiff"
        default: return hasAlpha ? "png" : "jpg"
        }
    }

    static func saveEdit(_ img: DecodedImage, _ input: String, suffix: String, format: String? = nil, quality: Int? = nil, keepMeta: Bool = true) async throws -> String {
        let fmt = format ?? editFormat(input, hasAlpha: img.hasAlpha)
        let output = OutputPaths.path(for: input, ext: fmt, suffix: suffix)
        let copy = keepMeta ? img : DecodedImage(image: img.image, metadata: nil, hasAlpha: img.hasAlpha)
        return try await OutputPaths.writing(output) { out in
            try await ImageConverter.save(copy, to: out, format: fmt, quality: quality ?? Settings.current.imageQuality, sourceExt: FileKinds.ext(input))
            return out
        }
    }

    public static func resample(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage { ImageConverter.resample(img, width: w, height: h) }

    // ------------------------------------------------------------------ compress / resize

    public static func compress(_ input: String, _ o: CompressOptions) async throws -> String {
        let img = try await ImageConverter.decode(input)
        var bitmap = img.image
        if let max = o.maxDimension, Swift.max(img.width, img.height) > max {
            let k = Double(max) / Double(Swift.max(img.width, img.height))
            bitmap = resample(img.image, Int((Double(img.width) * k).rounded()), Int((Double(img.height) * k).rounded()))
        }
        let work = DecodedImage(image: bitmap, metadata: o.stripMetadata ? nil : img.metadata, hasAlpha: img.hasAlpha)
        var fmt = o.format ?? editFormat(input, hasAlpha: img.hasAlpha)
        if ["png", "bmp", "tiff"].contains(fmt) && !img.hasAlpha { fmt = "jpg" } // lossless formats can't get smaller by "quality"
        let output = OutputPaths.path(for: input, ext: fmt, suffix: " (compressed)")
        return try await OutputPaths.writing(output) { out in
            if let target = o.targetBytes, ["jpg", "webp", "heic", "avif"].contains(fmt) {
                // Binary-search the quality that lands just under the requested size.
                var lo = 5, hi = 95, best = 5
                for _ in 0..<7 where lo <= hi {
                    let q = (lo + hi) / 2
                    try await ImageConverter.save(work, to: out, format: fmt, quality: q, sourceExt: FileKinds.ext(input))
                    if P.size(out) <= target { best = q; lo = q + 1 } else { hi = q - 1 }
                }
                try await ImageConverter.save(work, to: out, format: fmt, quality: best, sourceExt: FileKinds.ext(input))
            } else {
                try await ImageConverter.save(work, to: out, format: fmt, quality: o.quality, sourceExt: FileKinds.ext(input))
            }
            return out
        }
    }

    public static func resize(_ input: String, scale: Double?, width: Int?, height: Int?) async throws -> String {
        let img = try await ImageConverter.decode(input)
        let w: Int, h: Int
        if let s = scale { w = Int((Double(img.width) * s).rounded()); h = Int((Double(img.height) * s).rounded()) }
        else if let fw = width, let fh = height { w = fw; h = fh }
        else if let ow = width { w = ow; h = Int((Double(img.height) * Double(ow) / Double(img.width)).rounded()) }
        else if let oh = height { h = oh; w = Int((Double(img.width) * Double(oh) / Double(img.height)).rounded()) }
        else { throw OpError("No size given.") }
        let resized = resample(img.image, max(1, w), max(1, h))
        return try await saveEdit(DecodedImage(image: resized, metadata: img.metadata, hasAlpha: img.hasAlpha), input, suffix: " (\(max(1, w))×\(max(1, h)))")
    }

    // ------------------------------------------------------------------ crop / rotate / metadata

    public static func crop(_ input: String, _ rect: PixelRect) async throws -> String {
        let img = try await ImageConverter.decode(input)
        let r = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard r.width >= 1, r.height >= 1, let cropped = img.image.cropping(to: r.integral) else { throw OpError("Nothing left to keep after cropping.") }
        return try await saveEdit(DecodedImage(image: cropped, metadata: img.metadata, hasAlpha: img.hasAlpha), input, suffix: " (cropped)")
    }

    public static func rotate(_ input: String, degrees: Int) async throws -> String {
        let img = try await ImageConverter.decode(input)
        let swap = abs(degrees) % 180 == 90
        let w = swap ? img.height : img.width, h = swap ? img.width : img.height
        guard let ctx = ImageConverter.context(width: w, height: h, space: ImageConverter.rgbSpace(img.image)) else { throw OpError("Couldn't rotate the image.") }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        // Core Graphics' y axis points up, so a clockwise turn is a negative angle.
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180)
        ctx.draw(img.image, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
        guard let rotated = ctx.makeImage() else { throw OpError("Couldn't rotate the image.") }
        return try await saveEdit(DecodedImage(image: rotated, metadata: img.metadata, hasAlpha: img.hasAlpha), input, suffix: " (rotated)")
    }

    public static func stripMetadata(_ input: String) async throws -> String {
        let img = try await ImageConverter.decode(input)
        // Re-encoding without copying properties drops EXIF, GPS, XMP and maker notes.
        return try await saveEdit(img, input, suffix: " (no metadata)", quality: 95, keepMeta: false)
    }

    // ------------------------------------------------------------------ OCR and detection (Vision)

    public static func recognizeText(_ input: String) async throws -> String {
        let img = try await ImageConverter.decode(input)
        return try recognize(img.image).map(\.text).joined(separator: "\n")
    }

    /// Text lines, top to bottom, with their boxes in pixels (bottom-left origin).
    public static func recognize(_ image: CGImage) throws -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = image.width, h = image.height
        let lines = (request.results ?? []).compactMap { obs -> (String, CGRect)? in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return (s, VNImageRectForNormalizedRect(obs.boundingBox, w, h))
        }
        return lines.sorted { a, b in abs(a.1.midY - b.1.midY) > min(a.1.height, b.1.height) / 2 ? a.1.midY > b.1.midY : a.1.minX < b.1.minX }
            .map { (text: $0.0, box: $0.1) }
    }

    /// Face boxes in pixels (bottom-left origin), grown to cover hair and chin like the Windows app.
    public static func detectFaces(_ image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map { f in
            let r = VNImageRectForNormalizedRect(f.boundingBox, image.width, image.height)
            return r.insetBy(dx: -r.width * 0.18, dy: -r.height * 0.25)
        }
    }

    public static func detectText(_ image: CGImage) throws -> [CGRect] {
        try recognize(image).map { $0.box.insetBy(dx: -$0.box.height * 0.15, dy: -$0.box.height * 0.2) }
    }

    static let ci = CIContext(options: [.cacheIntermediates: false])

    /// Covers the regions (pixels, bottom-left origin) with a blur, pixels or black boxes.
    public static func applyRedactions(_ image: CGImage, _ regions: [(rect: CGRect, oval: Bool)], style: RedactStyle) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = ImageConverter.context(width: w, height: h, space: ImageConverter.rgbSpace(image)) else { return image }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: full)
        let source = CIImage(cgImage: image)
        for (rect, oval) in regions {
            let r = rect.intersection(full)
            if r.isEmpty { continue }
            ctx.saveGState()
            let radius = min(r.height * 0.2, r.width / 2)
            ctx.addPath(oval ? CGPath(ellipseIn: rect, transform: nil) : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            switch style {
            case .box:
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(r)
            case .pixelate:
                let block = max(6, min(r.width, r.height) / 9)
                let sw = max(1, Int(r.width / block)), sh = max(1, Int(r.height / block))
                // CGImage cropping counts rows from the top.
                let topLeft = CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height).integral
                if let piece = image.cropping(to: topLeft), let tiny = ImageConverter.context(width: sw, height: sh) {
                    tiny.interpolationQuality = .medium
                    tiny.draw(piece, in: CGRect(x: 0, y: 0, width: sw, height: sh))
                    if let small = tiny.makeImage() {
                        ctx.interpolationQuality = .none
                        ctx.draw(small, in: r)
                    }
                }
            case .blur:
                let sigma = Double(max(8, min(r.width, r.height) / 5))
                let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: source.extent)
                if let piece = ci.createCGImage(blurred, from: r) { ctx.draw(piece, in: r) }
            }
            ctx.restoreGState()
        }
        return ctx.makeImage() ?? image
    }

    public static func redact(_ input: String, faces: Bool, text: Bool, style: RedactStyle) async throws -> (output: String, count: Int) {
        let img = try await ImageConverter.decode(input)
        var regions: [(rect: CGRect, oval: Bool)] = []
        if faces { regions += try detectFaces(img.image).map { (rect: $0, oval: true) } }
        if text { regions += try detectText(img.image).map { (rect: $0, oval: false) } }
        if regions.isEmpty { throw OpError(faces && text ? "No faces or text found." : faces ? "No faces found." : "No text found.") }
        let covered = applyRedactions(img.image, regions, style: style)
        let output = try await saveEdit(DecodedImage(image: covered, metadata: nil, hasAlpha: img.hasAlpha), input, suffix: " (redacted)", keepMeta: false)
        return (output, regions.count)
    }

    // ------------------------------------------------------------------ background

    public static func composeBackground(_ src: CGImage, _ o: BackgroundOptions) -> CGImage? {
        let sw = Double(src.width), sh = Double(src.height)
        let pad = max(sw, sh) * o.paddingFraction
        var w = sw + pad * 2, h = sh + pad * 2
        if let a = o.aspect, a > 0 { if w / h < a { w = h * a } else { h = w / a } }
        let W = Int(w.rounded()), H = Int(h.rounded())
        guard let ctx = ImageConverter.context(width: W, height: H) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if o.colors.count > 1, let gradient = CGGradient(colorsSpace: space, colors: o.colors.map(\.cgColor) as CFArray, locations: nil) {
            // Top-left to bottom-right (Core Graphics' origin is bottom-left).
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            ctx.setFillColor((o.colors.first ?? .white).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        let rect = CGRect(x: (Double(W) - sw) / 2, y: (Double(H) - sh) / 2, width: sw, height: sh)
        let radius = CGFloat(o.radius * min(sw, sh))
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if o.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.12), blur: CGFloat(max(6, pad * 0.25) * 2),
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 90.0 / 255))
            ctx.addPath(shape)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(src, in: rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    public static func background(_ input: String, _ o: BackgroundOptions) async throws -> String {
        let img = try await ImageConverter.decode(input)
        guard let composed = composeBackground(img.image, o) else { throw OpError("Couldn't draw the background.") }
        return try await saveEdit(DecodedImage(image: composed, metadata: nil, hasAlpha: false), input, suffix: " (background)", format: "png")
    }

    // ------------------------------------------------------------------ several images

    public static func makePdf(_ files: [String], progress: (Double) -> Void) async throws -> String {
        var decoded: [(DecodedImage, String)] = []
        for (i, f) in files.enumerated() {
            decoded.append((try await ImageConverter.decode(f), FileKinds.ext(f)))
            progress(Double(i + 1) / Double(files.count) * 0.8)
        }
        let output = OutputPaths.unique(dir: OutputPaths.directoryFor(files[0]), baseName: files.count == 1 ? FileKinds.baseName(files[0]) : "Combined", ext: "pdf")
        return try await OutputPaths.writing(output) { out in
            try ImageConverter.pdfFromImages(decoded, output: out)
            return out
        }
    }

    /// Lays images out (top-left coordinates) and draws them cover-fitted with rounded corners.
    public static func composeCollage(_ images: [CGImage], _ o: CollageOptions) -> CGImage? {
        let n = images.count
        if n == 0 { return nil }
        let gap = o.spacing
        var cells: [CGRect] = []
        let W = Double(o.width)
        var H: Double
        switch o.layout {
        case .row:
            // Same height, widths by aspect.
            let sumAspect = images.reduce(0.0) { $0 + Double($1.width) / Double($1.height) }
            let h = (W - gap * Double(n + 1)) / sumAspect
            H = h + gap * 2
            var x = gap
            for b in images {
                let w = h * Double(b.width) / Double(b.height)
                cells.append(CGRect(x: x, y: gap, width: w, height: h))
                x += w + gap
            }
        case .column:
            let w = W - gap * 2
            var y = gap
            for b in images {
                let h = w * Double(b.height) / Double(b.width)
                cells.append(CGRect(x: gap, y: y, width: w, height: h))
                y += h + gap
            }
            H = y
        case .featured where n >= 2:
            let bigW = (W - gap * 3) * 0.62, smallW = W - gap * 3 - bigW
            let rest = n - 1
            let smallH = smallW * 0.75
            H = max(Double(rest) * smallH + gap * Double(rest + 1), bigW * 0.75 + gap * 2)
            cells.append(CGRect(x: gap, y: gap, width: bigW, height: H - gap * 2))
            let sh = (H - gap * Double(rest + 1)) / Double(rest)
            for i in 0..<rest { cells.append(CGRect(x: gap * 2 + bigW, y: gap + Double(i) * (sh + gap), width: smallW, height: sh)) }
        default:
            let cols = Int(Double(n).squareRoot().rounded(.up))
            let rows = Int((Double(n) / Double(cols)).rounded(.up))
            let cw = (W - gap * Double(cols + 1)) / Double(cols), ch = cw * 0.75
            H = Double(rows) * ch + gap * Double(rows + 1)
            for i in 0..<n {
                cells.append(CGRect(x: gap + Double(i % cols) * (cw + gap), y: gap + Double(i / cols) * (ch + gap), width: cw, height: ch))
            }
        }
        let iw = Int(W.rounded()), ih = Int(H.rounded())
        guard let ctx = ImageConverter.context(width: iw, height: ih) else { return nil }
        ctx.setFillColor(o.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: iw, height: ih))
        ctx.interpolationQuality = .high
        for (i, cellTL) in cells.enumerated() where i < n {
            let b = images[i]
            let cell = CGRect(x: cellTL.minX, y: Double(ih) - cellTL.maxY, width: cellTL.width, height: cellTL.height)
            // Cover-fit: fill the cell, crop the overflow.
            let k = max(cell.width / CGFloat(b.width), cell.height / CGFloat(b.height))
            let sw = cell.width / k, sh = cell.height / k
            let src = CGRect(x: (CGFloat(b.width) - sw) / 2, y: (CGFloat(b.height) - sh) / 2, width: sw, height: sh).integral
            guard let piece = b.cropping(to: src) else { continue }
            let r = CGFloat(o.radius) * min(cell.width, cell.height)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: cell, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
            ctx.draw(piece, in: cell)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    public static func collage(_ files: [String], _ o: CollageOptions, progress: (Double) -> Void) async throws -> String {
        var bitmaps: [CGImage] = []
        for (i, f) in files.enumerated() {
            let d = try await ImageConverter.decode(f)
            // Keep memory sane: no source needs to be bigger than the canvas.
            let k = min(1, Double(o.width) / Double(d.width))
            bitmaps.append(k < 1 ? resample(d.image, Int(Double(d.width) * k), Int(Double(d.height) * k)) : d.image)
            progress(Double(i + 1) / Double(files.count) * 0.7)
        }
        guard let collage = composeCollage(bitmaps, o) else { throw OpError("Couldn't make the collage.") }
        let output = OutputPaths.unique(dir: OutputPaths.directoryFor(files[0]), baseName: "Collage", ext: "png")
        return try await OutputPaths.writing(output) { out in
            try ImageConverter.write(collage, to: out, type: "public.png")
            return out
        }
    }
}
