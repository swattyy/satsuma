import Foundation

/// PowerPoint, Keynote and OpenDocument slides through LibreOffice (the Windows app uses PowerPoint).
public enum SlidesConverter {
    public static func convert(_ input: String, to target: String) async throws -> String {
        let output = OutputPaths.path(for: input, ext: target)
        return try await OutputPaths.writing(output) { out in
            try await LibreOffice.convert(input, to: target, output: out)
            return out
        }
    }

    /// Every slide as an image (1920 px wide) in a "<name> slides" folder.
    public static func images(_ input: String, format: String) async throws -> String {
        let tmp = try AppPaths.newTempDir("slides")
        defer { P.remove(tmp) }
        let pdf = P.join(tmp, "slides.pdf")
        try await LibreOffice.convert(input, to: "pdf", output: pdf)
        let doc = try PdfConverter.open(pdf)
        let folder = try OutputPaths.folderFor(input, suffix: " slides")
        do {
            for i in 1...max(1, doc.numberOfPages) {
                guard let page = doc.page(at: i) else { continue }
                let size = PdfConverter.shownSize(page)
                let dpi = Int((1920 / max(1, size.width) * 72).rounded())
                guard let img = PdfConverter.renderImage(page, dpi: dpi) else { continue }
                let path = P.join(folder, "Slide \(String(format: "%02d", i)).\(format)")
                try ImageConverter.write(img, to: path, type: format == "png" ? "public.png" : "public.jpeg", quality: format == "png" ? nil : 0.92)
            }
        } catch {
            P.remove(folder)
            throw error
        }
        return folder
    }
}
