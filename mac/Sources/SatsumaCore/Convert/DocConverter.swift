import Foundation
import AppKit

/// Word processing, text, Markdown, HTML and EPUB conversions. Cocoa's text system plays the part Microsoft Word
/// plays on Windows (DOCX, DOC, RTF, ODT in and out); the built-in readers and writers cover the rest.
public enum DocConverter {
    static let ownReadable: Set<String> = ["docx", "docm", "dotx", "rtf", "odt", "txt", "text", "log", "md", "markdown", "mdown", "mkd", "html", "htm", "xhtml", "epub"]
    static let wordFamily: Set<String> = ["docx", "doc", "docm", "dotx", "odt", "rtf", "wpd"]
    static let markdownExts: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let htmlExts: Set<String> = ["html", "htm", "mht", "mhtml"]

    public static func targets(for ext: String) -> [String] {
        let flags = Engines.flags
        let word = ext == "wpd" ? flags.wordPerfect : flags.word
        let list: [String]
        switch ext {
        case "docx", "docm", "dotx": list = ["pdf", "txt", "md", "html", "rtf", "odt", "epub", "docx"]
        case "doc", "wpd": list = word ? ["pdf", "docx", "txt", "md", "html", "rtf", "odt", "epub"] : []
        case "odt": list = ["pdf", "docx", "txt", "md", "html", "rtf", "epub"]
        case "rtf": list = ["pdf", "docx", "txt", "md", "html", "odt", "epub"]
        case "txt", "text", "log": list = ["docx", "pdf", "md", "html", "epub", "rtf"]
        case "md", "markdown", "mdown", "mkd": list = ["html", "docx", "pdf", "txt", "epub", "rtf"]
        case "html", "htm", "xhtml", "mht", "mhtml": list = ["pdf", "docx", "md", "txt", "epub"]
        case "epub": list = ["txt", "md", "html", "docx", "pdf"]
        default: list = []
        }
        return list.filter { t in
            if t == ext || (t == "docx" && ["docm", "dotx"].contains(ext) && !word) { return false }
            if t == "odt" && !word { return false }
            if t == "docx" && ext == "docx" { return false }
            return true
        }
    }

    public static func convert(_ input: String, to target: String) async throws -> String {
        let ext = FileKinds.ext(input)
        let output = OutputPaths.path(for: input, ext: target)
        return try await OutputPaths.writing(output) { out in
            let wordInput = wordFamily.contains(ext)
            let htmlInput = htmlExts.contains(ext)
            let mdInput = markdownExts.contains(ext)
            if (wordInput && ["pdf", "docx", "rtf", "odt"].contains(target)) || (htmlInput && ["docx", "rtf", "odt"].contains(target)) {
                let attr = try await richText(input, ext)
                if target == "pdf" { try await WebRender.printAttributed(attr, to: out) }
                else { try RichText.write(attr, to: out, format: target) }
                return out
            }
            if mdInput && target == "html" {
                try P.writeText(out, try markdownHtml(input))
                return out
            }
            if target == "pdf" {
                // WebKit prints our styled HTML: crisp type, every script, small files.
                if htmlInput { try await WebRender.printFile(input, to: out) }
                else {
                    let html: String
                    if mdInput { html = try markdownHtml(input) } else { html = DocWriters.html(try await readModel(input, ext)) }
                    try await WebRender.printHTML(html, baseURL: P.url(P.dir(input) + "/"), to: out)
                }
                return out
            }
            try await DocWriters.write(try await readModel(input, ext), to: out, format: target)
            return out
        }
    }

    static func markdownHtml(_ input: String) throws -> String {
        let doc = DocReaders.markdown(try DocReaders.readText(input))
        let title = doc.guessTitle()
        return DocWriters.page(title.isEmpty ? FileKinds.baseName(input) : title, DocWriters.body(doc))
    }

    static func richText(_ input: String, _ ext: String) async throws -> NSAttributedString {
        if ext == "wpd" {
            let tmpDir = try AppPaths.newTempDir("wpd")
            defer { P.remove(tmpDir) }
            let tmp = P.join(tmpDir, FileKinds.baseName(input) + ".docx")
            try await LibreOffice.convert(input, to: "docx", output: tmp)
            return try await RichText.read(tmp)
        }
        return try await RichText.read(input)
    }

    /// Reads any supported document into a DocModel. Legacy formats go through DOCX first.
    public static func readModel(_ input: String, _ ext: String) async throws -> DocModel {
        if ownReadable.contains(ext) { return try DocReaders.read(input) }
        if wordFamily.contains(ext) || htmlExts.contains(ext) {
            let tmpDir = try AppPaths.newTempDir("doc")
            defer { P.remove(tmpDir) }
            let tmp = P.join(tmpDir, FileKinds.baseName(input) + ".docx")
            if ext == "wpd" { try await LibreOffice.convert(input, to: "docx", output: tmp) }
            else { try RichText.write(try await RichText.read(input), to: tmp, format: "docx") }
            let doc = try DocReaders.read(tmp)
            doc.title = FileKinds.baseName(input)
            return doc
        }
        throw OpError("Can't open .\(ext) files.")
    }
}

/// NSAttributedString's document import and export (the engine behind TextEdit).
public enum RichText {
    static func documentType(_ ext: String) -> NSAttributedString.DocumentType? {
        switch ext {
        case "docx", "docm", "dotx": return .officeOpenXML
        case "doc": return .docFormat
        case "rtf": return .rtf
        case "odt": return .openDocument
        case "html", "htm", "xhtml": return .html
        case "txt", "text", "log": return .plain
        default: return nil
        }
    }

    @MainActor static func readOnMain(_ path: String) throws -> NSAttributedString {
        let ext = FileKinds.ext(path)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let t = documentType(ext) { options[.documentType] = t }
        if ["html", "htm", "xhtml", "txt", "text", "log"].contains(ext) { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        do { return try NSAttributedString(url: P.url(path), options: options, documentAttributes: nil) }
        catch { throw OpError("macOS can't open \(P.fileName(path)).") }
    }

    public static func read(_ path: String) async throws -> NSAttributedString { try await readOnMain(path) }

    public static func write(_ text: NSAttributedString, to path: String, format: String) throws {
        let type: NSAttributedString.DocumentType
        switch format {
        case "docx": type = .officeOpenXML
        case "rtf": type = .rtf
        case "odt": type = .openDocument
        case "doc": type = .docFormat
        case "html": type = .html
        default: throw OpError("Can't write \(format.uppercased()) with the text system.")
        }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
        try data.write(to: P.url(path))
    }
}
