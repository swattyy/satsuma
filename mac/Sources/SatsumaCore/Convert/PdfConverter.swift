import Foundation
import AppKit
import PDFKit

/// PDF to page images (Quartz), to text, Markdown, HTML, EPUB and DOCX (PDFKit text with headings guessed
/// from font size), and to PPTX through LibreOffice.
public enum PdfConverter {
    public static func targets() -> [String] {
        var t = ["docx", "png", "jpg", "txt", "md", "html", "epub"]
        if Engines.flags.pdfToPptx { t.append("pptx") }
        return t
    }

    public static func convert(_ input: String, to target: String, progress: @escaping (Double) -> Void) async throws -> [String] {
        switch target {
        case "png", "jpg":
            return try renderPages(input, format: target, dpi: Settings.current.pdfRenderDpi, progress: progress)
        case "pptx":
            let output = OutputPaths.path(for: input, ext: "pptx")
            return [try await OutputPaths.writing(output) { out in
                try await LibreOffice.convert(input, to: "pptx", output: out, inFilter: "impress_pdf_import")
                return out
            }]
        default:
            let doc = try readText(input, progress: progress)
            let output = OutputPaths.path(for: input, ext: target)
            return [try await OutputPaths.writing(output) { out in
                try await DocWriters.write(doc, to: out, format: target)
                return out
            }]
        }
    }

    public static func open(_ path: String) throws -> CGPDFDocument {
        guard let doc = CGPDFDocument(P.url(path) as CFURL) else { throw OpError("macOS can't read \(P.fileName(path)).") }
        if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") { throw OpError("This PDF is password-protected.") }
        return doc
    }

    /// Renders every page. One page gives a single file; several give a folder of pages.
    public static func renderPages(_ input: String, format: String, dpi: Int, progress: ((Double) -> Void)?, folderOverride: String? = nil) throws -> [String] {
        let pdf = try open(input)
        let count = pdf.numberOfPages
        if count == 0 { throw OpError("This PDF has no pages.") }
        let folder = try folderOverride ?? (count > 1 ? OutputPaths.folderFor(input, suffix: " pages") : nil)
        var outputs: [String] = []
        for i in 1...count {
            try Task.checkCancellation()
            guard let page = pdf.page(at: i) else { continue }
            let path = folder.map { P.join($0, "\(FileKinds.baseName(input)) - \(String(format: "%03d", i)).\(format)") }
                ?? OutputPaths.path(for: input, ext: format)
            try renderPage(page, to: path, format: format, dpi: dpi)
            outputs.append(path)
            progress?(Double(i) / Double(count))
        }
        if let folder, folderOverride == nil { return [folder] }
        return outputs
    }

    /// Size in points with the page's rotation applied.
    static func shownSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let r = (page.rotationAngle % 360 + 360) % 360
        return r == 90 || r == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    public static func renderImage(_ page: CGPDFPage, dpi: Int, maxPixels: Double = 60_000_000) -> CGImage? {
        let size = shownSize(page)
        var w = size.width * CGFloat(dpi) / 72, h = size.height * CGFloat(dpi) / 72
        let cap = sqrt(maxPixels / max(1, Double(w * h)))
        if cap < 1 { w *= CGFloat(cap); h *= CGFloat(cap) }
        let iw = max(1, Int(w.rounded())), ih = max(1, Int(h.rounded()))
        guard let ctx = ImageConverter.context(width: iw, height: ih, opaque: true) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: iw, height: ih))
        ctx.interpolationQuality = .high
        ctx.setRenderingIntent(.defaultIntent)
        ctx.scaleBy(x: CGFloat(iw) / size.width, y: CGFloat(ih) / size.height)
        // At 1:1 the drawing transform only handles the crop box origin and the page's rotation.
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    static func renderPage(_ page: CGPDFPage, to path: String, format: String, dpi: Int) throws {
        guard let img = renderImage(page, dpi: dpi) else { throw OpError("Couldn't render the page.") }
        try ImageConverter.write(img, to: path, type: format == "jpg" ? "public.jpeg" : "public.png", quality: format == "jpg" ? 0.92 : nil)
    }

    // ------------------------------------------------------------------ text

    /// Extracts text in reading order, guessing headings from font size, like the Windows app does with PdfPig.
    public static func readText(_ input: String, progress: ((Double) -> Void)? = nil) throws -> DocModel {
        guard let pdf = PDFDocument(url: P.url(input)) else { throw OpError("macOS can't read \(P.fileName(input)).") }
        if pdf.isLocked && !pdf.unlock(withPassword: "") { throw OpError("This PDF is password-protected.") }
        let doc = DocModel()
        doc.title = FileKinds.baseName(input)
        var pages: [[(text: String, size: Double)]] = []
        var sizes: [Double] = []
        let n = pdf.pageCount
        for p in 0..<n {
            guard let page = pdf.page(at: p) else { pages.append([]); continue }
            let blocks = blocksOf(page)
            for b in blocks where b.size > 0 { sizes.append(b.size) }
            pages.append(blocks)
            progress?(Double(p + 1) / Double(max(1, n)) * 0.9)
        }
        if sizes.isEmpty { throw OpError("This PDF has no selectable text (it may be a scan).") }
        sizes.sort()
        let median = sizes[sizes.count / 2]
        for (i, blocks) in pages.enumerated() {
            if i > 0 { doc.blocks.append(Block(type: .pageBreak)) }
            for (text, size) in blocks {
                let joined = joinLines(text)
                let short = joined.count < 120 && !joined.hasSuffix(".")
                if size > median * 1.6 && short { doc.blocks.append(.heading(1, joined)) }
                else if size > median * 1.25 && short { doc.blocks.append(.heading(2, joined)) }
                else if size > median * 1.1 && short && joined.count < 80 { doc.blocks.append(.heading(3, joined)) }
                else { doc.blocks.append(.para(joined)) }
            }
        }
        return doc.normalize()
    }

    /// Lines grouped into blocks: a block ends at a gap taller than the text, or when the font size changes.
    static func blocksOf(_ page: PDFPage) -> [(text: String, size: Double)] {
        guard let attr = page.attributedString, attr.length > 0 else { return [] }
        let ns = attr.string as NSString
        struct Line { var text: String; var size: Double; var top: CGFloat; var bottom: CGFloat }
        var lines: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { sub, range, _, _ in
            let text = (sub ?? "").trimmingCharacters(in: .whitespaces)
            var total = 0.0, count = 0
            attr.enumerateAttribute(.font, in: range, options: []) { value, r, _ in
                if let font = value as? NSFont { total += Double(font.pointSize) * Double(r.length); count += r.length }
            }
            let bounds = page.selection(for: range)?.bounds(for: page) ?? .zero
            lines.append(Line(text: text, size: count > 0 ? total / Double(count) : 0, top: bounds.maxY, bottom: bounds.minY))
        }
        var blocks: [(text: String, size: Double)] = []
        var current: [Line] = []
        func flush() {
            guard !current.isEmpty else { return }
            let sizesInBlock = current.map(\.size).filter { $0 > 0 }
            let avg = sizesInBlock.isEmpty ? 0 : sizesInBlock.reduce(0, +) / Double(sizesInBlock.count)
            blocks.append((current.map(\.text).joined(separator: "\n"), avg))
            current = []
        }
        for line in lines {
            if line.text.isEmpty { flush(); continue }
            if let prev = current.last {
                let gap = prev.bottom - line.top
                let lineHeight = max(prev.size, line.size, 1)
                let sizeChanged = prev.size > 0 && line.size > 0 && abs(prev.size - line.size) / max(prev.size, line.size) > 0.1
                if sizeChanged || gap > CGFloat(lineHeight * 0.8) || line.top > prev.top { flush() }
            }
            current.append(line)
        }
        flush()
        return blocks
    }

    /// Re-flows hard-wrapped lines into paragraphs, fixing hyphenation at line ends.
    static func joinLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out = ""
        for (i, raw) in lines.enumerated() {
            var line = raw
            while line.last?.isWhitespace == true { line.removeLast() }
            let last = i == lines.count - 1
            if !last && line.count > 1 && line.hasSuffix("-") && line.dropLast().last?.isLetter == true {
                out += line.dropLast()
            } else {
                out += line
                if !last { out += " " }
            }
        }
        return out
    }
}
