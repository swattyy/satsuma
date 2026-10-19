import Foundation
import CoreGraphics
import PDFKit

/// Split, merge, pick pages, save embedded images and "flatten-compress" PDFs.
public enum PdfTools {
    static func load(_ path: String) throws -> PDFDocument {
        guard let doc = PDFDocument(url: P.url(path)) else { throw OpError("macOS can't read \(P.fileName(path)).") }
        if doc.isLocked && !doc.unlock(withPassword: "") { throw OpError("This PDF is password-protected.") }
        return doc
    }

    static func save(_ doc: PDFDocument, _ path: String) throws {
        if !doc.write(to: P.url(path)) { throw OpError("Couldn't write \(P.fileName(path)).") }
    }

    public static func merge(_ files: [String]) throws -> String {
        let merged = PDFDocument()
        for f in files {
            let doc = try load(f)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let output = OutputPaths.unique(dir: OutputPaths.directoryFor(files[0]), baseName: "Merged", ext: "pdf")
        do { try save(merged, output) } catch { OutputPaths.discard(output); throw error }
        return output
    }

    public static func split(_ input: String, progress: (Double) -> Void) throws -> String {
        let doc = try load(input)
        let n = doc.pageCount
        if n < 2 { throw OpError("This PDF only has one page.") }
        let folder = try OutputPaths.folderFor(input, suffix: " pages")
        do {
            for p in 0..<n {
                let single = PDFDocument()
                if let page = doc.page(at: p)?.copy() as? PDFPage { single.insert(page, at: 0) }
                try save(single, P.join(folder, "\(FileKinds.baseName(input)) - \(String(format: "%03d", p + 1)).pdf"))
                progress(Double(p + 1) / Double(n))
            }
        } catch { P.remove(folder); throw error }
        return folder
    }

    public static func extractPages(_ input: String, _ pages: [Int]) throws -> String {
        let doc = try load(input)
        let out = PDFDocument()
        for p in pages where p >= 1 && p <= doc.pageCount {
            if let page = doc.page(at: p - 1)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
        }
        if out.pageCount == 0 { throw OpError("None of those pages are in this PDF.") }
        let output = OutputPaths.path(for: input, ext: "pdf", suffix: " (selected pages)")
        do { try save(out, output) } catch { OutputPaths.discard(output); throw error }
        return output
    }

    // ------------------------------------------------------------------ embedded images

    final class Found { var items: [(Data, String)] = [] }

    public static func extractImages(_ input: String, progress: (Double) -> Void) throws -> [String] {
        let doc = try PdfConverter.open(input)
        var folder: String?
        var index = 0
        let n = doc.numberOfPages
        for p in 1...max(1, n) {
            guard let page = doc.page(at: p), let dict = page.dictionary else { continue }
            let found = Found()
            collect(dict, found, depth: 0)
            for (data, ext) in found.items where data.count >= 512 {
                if folder == nil { folder = try OutputPaths.folderFor(input, suffix: " images") }
                index += 1
                try data.write(to: P.url(P.join(folder!, "Image \(String(format: "%03d", index)).\(ext)")))
            }
            progress(Double(p) / Double(max(1, n)))
        }
        guard let folder else { throw OpError("No embedded images found.") }
        return [folder]
    }

    static func collect(_ dict: CGPDFDictionaryRef, _ found: Found, depth: Int) {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let res = resources else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xo = xobjects else { return }
        CGPDFDictionaryApplyBlock(xo, { _, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let s = stream, let sd = CGPDFStreamGetDictionary(s) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(sd, "Subtype", &subtype), let st = subtype else { return true }
            switch String(cString: st) {
            case "Image": if let image = imageData(s, sd) { found.items.append(image) }
            case "Form": if depth < 4 { collect(sd, found, depth: depth + 1) }
            default: break
            }
            return true
        }, nil)
    }

    static func imageData(_ stream: CGPDFStreamRef, _ dict: CGPDFDictionaryRef) -> (Data, String)? {
        var format = CGPDFDataFormat.raw
        guard let cf = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cf as Data
        switch format {
        case .jpegEncoded: return (data, "jpg")  // DCT streams are complete JPEG files
        case .JPEG2000: return (data, "jp2")
        default: break
        }
        var w = 0, h = 0, bpc = 0
        var v: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dict, "Width", &v) { w = v }
        if CGPDFDictionaryGetInteger(dict, "Height", &v) { h = v }
        if CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &v) { bpc = v }
        guard w > 0, h > 0, bpc == 8, let cs = colorSpace(dict), data.count >= w * h * cs.1,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        let comps = cs.1
        guard let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * comps, bytesPerRow: w * comps, space: cs.0,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        // CMYK and odd spaces are drawn into RGB first so the PNG opens everywhere.
        let rgb = comps == 4 ? ImageConverter.flatten(img) : img
        return ImageConverter.encode(rgb, type: "public.png").map { ($0, "png") }
    }

    static func colorSpace(_ dict: CGPDFDictionaryRef) -> (CGColorSpace, Int)? {
        func named(_ name: String) -> (CGColorSpace, Int)? {
            switch name {
            case "DeviceRGB", "CalRGB": return (CGColorSpace(name: CGColorSpace.sRGB)!, 3)
            case "DeviceGray", "CalGray": return (CGColorSpaceCreateDeviceGray(), 1)
            case "DeviceCMYK": return (CGColorSpace(name: CGColorSpace.genericCMYK)!, 4)
            default: return nil
            }
        }
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dict, "ColorSpace", &name), let n = name { return named(String(cString: n)) }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "ColorSpace", &array), let a = array else { return nil }
        var first: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(a, 0, &first), let f = first else { return nil }
        if String(cString: f) == "ICCBased" {
            var icc: CGPDFStreamRef?
            guard CGPDFArrayGetStream(a, 1, &icc), let s = icc, let sd = CGPDFStreamGetDictionary(s) else { return nil }
            var n: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(sd, "N", &n) else { return nil }
            switch n {
            case 1: return named("DeviceGray")
            case 3: return named("DeviceRGB")
            case 4: return named("DeviceCMYK")
            default: return nil
            }
        }
        return named(String(cString: f))
    }

    // ------------------------------------------------------------------ compress

    /// Re-renders every page as a JPEG. Shrinks scans and image-heavy PDFs; text stops being selectable.
    public static func flattenCompress(_ input: String, dpi: Int, quality: Int, progress: (Double) -> Void) async throws -> String {
        let doc = try PdfConverter.open(input)
        let output = OutputPaths.path(for: input, ext: "pdf", suffix: " (compressed)")
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(P.url(output) as CFURL, mediaBox: &media, [kCGPDFContextCreator as String: "Satsuma"] as CFDictionary) else {
            throw OpError("Couldn't create \(P.fileName(output)).")
        }
        let n = doc.numberOfPages
        do {
            for i in 1...max(1, n) {
                try Task.checkCancellation()
                guard let page = doc.page(at: i), let img = PdfConverter.renderImage(page, dpi: dpi),
                      let jpeg = ImageConverter.jpegBacked(img, quality: Double(quality) / 100) else { continue }
                var box = CGRect(origin: .zero, size: PdfConverter.shownSize(page))
                pdf.beginPage(mediaBox: &box)
                pdf.draw(jpeg, in: box)
                pdf.endPage()
                progress(Double(i) / Double(max(1, n)))
            }
            pdf.closePDF()
        } catch {
            pdf.closePDF()
            OutputPaths.discard(output)
            throw error
        }
        if P.size(output) >= Int64(Double(P.size(input)) * 0.95) {
            OutputPaths.discard(output)
            throw OpError("This PDF is already compact; flattening wouldn't make it smaller.")
        }
        return output
    }

    public static func allText(_ input: String) throws -> String {
        let doc = try load(input)
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n\n")
    }
}
