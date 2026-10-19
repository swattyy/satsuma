import Foundation

/// Writers from DocModel to TXT, Markdown, HTML, DOCX, EPUB, RTF and PDF (ported from the Windows app).
public enum DocWriters {
    public static func write(_ doc: DocModel, to path: String, format: String) async throws {
        switch format {
        case "txt": try P.writeText(path, doc.toPlainText())
        case "md": try P.writeText(path, markdown(doc))
        case "html": try P.writeText(path, html(doc))
        case "docx": try docx(doc, path)
        case "epub": try epub(doc, path)
        case "rtf": try Data(rtf(doc).utf8).write(to: P.url(path))
        case "pdf": try await WebRender.printHTML(html(doc), baseURL: nil, to: path)
        default: throw OpError("Can't write \(format.uppercased()) documents.")
        }
    }

    // ------------------------------------------------------------------ Markdown

    public static func markdown(_ doc: DocModel) -> String {
        var out = ""
        var prev: BlockType?
        for b in doc.blocks {
            if let p = prev, !(p == .listItem && b.type == .listItem) { out += "\n" }
            switch b.type {
            case .heading:
                out += String(repeating: "#", count: min(max(b.level, 1), 6)) + " " + mdInlines(b.inlines).replacingOccurrences(of: "\n", with: " ") + "\n"
            case .paragraph:
                out += mdInlines(b.inlines).replacingOccurrences(of: "\n", with: "  \n") + "\n"
            case .quote:
                out += "> " + mdInlines(b.inlines).replacingOccurrences(of: "\n", with: "\n> ") + "\n"
            case .listItem:
                out += String(repeating: " ", count: b.level * 3) + (b.ordered ? "\(b.number). " : "- ") + mdInlines(b.inlines).replacingOccurrences(of: "\n", with: " ") + "\n"
            case .code:
                out += "```\n" + (b.codeText ?? "") + "\n```\n"
            case .rule, .pageBreak:
                out += "---\n"
            case .table:
                guard let rows = b.rows, !rows.isEmpty else { break }
                let cols = rows.map(\.count).max() ?? 0
                func row(_ r: [String]) -> String {
                    "| " + (0..<cols).map { i in (i < r.count ? r[i] : "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: " | ") + " |"
                }
                out += row(rows[0]) + "\n"
                out += "|" + String(repeating: " --- |", count: cols) + "\n"
                for r in rows.dropFirst() { out += row(r) + "\n" }
            }
            prev = b.type
        }
        return out
    }

    static func mdInlines(_ inlines: [Inline]) -> String {
        var out = ""
        for i in inlines {
            var t = i.code ? "`\(i.text)`" : escapeMd(i.text)
            if !i.text.trimmingCharacters(in: .whitespaces).isEmpty && !i.code {
                // Keep surrounding spaces outside the markers: "**bold** text".
                let lead = String(t.prefix { $0.isWhitespace })
                let trail = String(t.reversed().prefix { $0.isWhitespace }.reversed())
                t = t.trimmingCharacters(in: .whitespaces)
                if i.bold && i.italic { t = "***\(t)***" }
                else if i.bold { t = "**\(t)**" }
                else if i.italic { t = "*\(t)*" }
                t = lead + t + trail
            }
            if let link = i.link, !link.hasPrefix("#") { t = "[\(t)](\(link))" }
            out += t
        }
        return out
    }

    static func escapeMd(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "`", with: "\\`")
    }

    // ------------------------------------------------------------------ HTML

    public static let css = """
    :root { color-scheme: light dark; }
    body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", system-ui, sans-serif; max-width: 46rem; margin: 3rem auto; padding: 0 1.25rem; color: #24201c; background: #fff; }
    @media (prefers-color-scheme: dark) { body { color: #ece7e2; background: #1c1b1f; } code, pre { background: #2a2930 !important; } th { background: #2a2930 !important; } td, th { border-color: #3a3940 !important; } }
    h1, h2, h3, h4 { line-height: 1.25; margin: 1.6em 0 .5em; } h1 { font-size: 2em; } h2 { font-size: 1.5em; }
    pre { background: #f5f2ee; padding: 1rem; border-radius: 8px; overflow: auto; } code { font-family: ui-monospace, Menlo, monospace; font-size: .92em; background: #f5f2ee; padding: .1em .3em; border-radius: 4px; }
    pre code { padding: 0; background: none; } blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid #ff7a1a; color: #6b625b; }
    table { border-collapse: collapse; margin: 1em 0; } td, th { border: 1px solid #ddd6cf; padding: .4em .7em; text-align: left; } th { background: #f5f2ee; }
    a { color: #e8650f; } hr { border: 0; border-top: 1px solid #ddd6cf; margin: 2em 0; } img { max-width: 100%; }
    @media print { body { max-width: none; margin: 0; padding: 0; font-size: 11pt; } pre, tr, img, blockquote { break-inside: avoid; } h1, h2, h3 { break-after: avoid; } }
    """

    public static func html(_ doc: DocModel, xhtml: Bool = false) -> String { page(doc.guessTitle(), body(doc, xhtml: xhtml), xhtml: xhtml) }

    public static func page(_ title: String, _ body: String, xhtml: Bool = false) -> String {
        let head = xhtml
            ? "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
            : "<!doctype html>\n<html lang=\"en\">"
        let style = xhtml ? "<link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>" : "<style>\(css)</style>"
        let close = xhtml ? "/" : ""
        return "\(head)\n<head>\n<meta charset=\"utf-8\"\(close)>\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"\(close)>\n<title>\(Html.escape(title))</title>\n\(style)\n</head>\n<body>\n\(body)</body>\n</html>\n"
    }

    public static func body(_ doc: DocModel, xhtml: Bool = false) -> String {
        var out = ""
        var open: [Bool] = []
        let br = xhtml ? "<br/>" : "<br>"
        func closeLists(_ depth: Int) { while open.count > depth { out += open.removeLast() ? "</li></ol>\n" : "</li></ul>\n" } }

        for b in doc.blocks {
            if b.type != .listItem { closeLists(0) }
            switch b.type {
            case .heading:
                let h = min(max(b.level, 1), 6)
                out += "<h\(h)>\(htmlInlines(b.inlines, br))</h\(h)>\n"
            case .paragraph: out += "<p>\(htmlInlines(b.inlines, br))</p>\n"
            case .quote: out += "<blockquote><p>\(htmlInlines(b.inlines, br))</p></blockquote>\n"
            case .code: out += "<pre><code>\(Html.escape(b.codeText ?? ""))</code></pre>\n"
            case .rule: out += xhtml ? "<hr/>\n" : "<hr>\n"
            case .pageBreak: out += xhtml ? "<hr/>\n" : "<hr style=\"page-break-after:always;border:0\">\n"
            case .listItem:
                let depth = b.level + 1
                if open.count >= depth {
                    closeLists(depth)
                    out += "</li>"
                }
                while open.count < depth {
                    if b.ordered { out += b.number != 1 && open.count == depth - 1 ? "<ol start=\"\(b.number)\">" : "<ol>" }
                    else { out += "<ul>" }
                    open.append(b.ordered)
                }
                out += "<li>\(htmlInlines(b.inlines, br))"
            case .table:
                guard let rows = b.rows, !rows.isEmpty else { break }
                out += "<table>\n"
                for (r, row) in rows.enumerated() {
                    let tag = r == 0 ? "th" : "td"
                    out += "<tr>" + row.map { "<\(tag)>\(Html.escape($0).replacingOccurrences(of: "\n", with: br))</\(tag)>" }.joined() + "</tr>\n"
                }
                out += "</table>\n"
            }
        }
        closeLists(0)
        return out
    }

    static func htmlInlines(_ inlines: [Inline], _ br: String) -> String {
        inlines.map { i in
            var t = Html.escape(i.text).replacingOccurrences(of: "\n", with: br)
            if i.code { t = "<code>\(t)</code>" }
            if i.italic { t = "<em>\(t)</em>" }
            if i.bold { t = "<strong>\(t)</strong>" }
            if let link = i.link { t = "<a href=\"\(Html.escape(link))\">\(t)</a>" }
            return t
        }.joined()
    }

    // ------------------------------------------------------------------ DOCX

    static func iso8601() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    public static func docx(_ doc: DocModel, _ path: String) throws {
        let X = xmlEscape
        var links: [String] = []
        var nums: [Bool] = [] // one <w:num> per list run; true = ordered
        var body = ""
        var currentNum = 0
        var prev: BlockType?

        func runs(_ inlines: [Inline]) -> String {
            var sb = ""
            for i in inlines {
                var rpr = ""
                if i.link != nil { rpr += "<w:rStyle w:val=\"Hyperlink\"/>" }
                if i.bold { rpr += "<w:b/>" }
                if i.italic { rpr += "<w:i/>" }
                if i.code { rpr += "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F0EC\"/>" }
                let props = rpr.isEmpty ? "" : "<w:rPr>\(rpr)</w:rPr>"
                var run = ""
                for (p, part) in i.text.components(separatedBy: "\n").enumerated() {
                    if p > 0 { run += "<w:br/>" }
                    for (t, tab) in part.components(separatedBy: "\t").enumerated() {
                        if t > 0 { run += "<w:tab/>" }
                        if !tab.isEmpty { run += "<w:t xml:space=\"preserve\">\(X(tab))</w:t>" }
                    }
                }
                var r = "<w:r>\(props)\(run)</w:r>"
                if let link = i.link, let url = URL(string: link), url.scheme != nil {
                    links.append(link)
                    r = "<w:hyperlink r:id=\"rIdL\(links.count)\">\(r)</w:hyperlink>"
                }
                sb += r
            }
            return sb
        }

        for b in doc.blocks {
            switch b.type {
            case .heading:
                body += "<w:p><w:pPr><w:pStyle w:val=\"Heading\(min(max(b.level, 1), 6))\"/></w:pPr>\(runs(b.inlines))</w:p>"
            case .paragraph:
                body += "<w:p>\(runs(b.inlines))</w:p>"
            case .quote:
                body += "<w:p><w:pPr><w:pStyle w:val=\"Quote\"/></w:pPr>\(runs(b.inlines))</w:p>"
            case .listItem:
                if prev != .listItem { nums.append(b.ordered); currentNum = nums.count }
                body += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(min(max(b.level, 0), 8))\"/><w:numId w:val=\"\(currentNum)\"/></w:numPr></w:pPr>\(runs(b.inlines))</w:p>"
            case .code:
                for line in (b.codeText ?? "").components(separatedBy: "\n") {
                    var l = line
                    if l.hasSuffix("\r") { l.removeLast() }
                    body += "<w:p><w:pPr><w:pStyle w:val=\"Code\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(X(l))</w:t></w:r></w:p>"
                }
            case .rule:
                body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D6CFC8\"/></w:pBdr></w:pPr></w:p>"
            case .pageBreak:
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            case .table:
                guard let rows = b.rows, !rows.isEmpty else { break }
                let cols = rows.map(\.count).max() ?? 0
                body += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/></w:tblPr><w:tblGrid>"
                body += String(repeating: "<w:gridCol/>", count: cols) + "</w:tblGrid>"
                for (r, row) in rows.enumerated() {
                    body += "<w:tr>"
                    for c in 0..<cols {
                        let text = c < row.count ? row[c] : ""
                        let rpr = r == 0 ? "<w:rPr><w:b/></w:rPr>" : ""
                        body += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>"
                        for line in text.components(separatedBy: "\n") { body += "<w:p><w:r>\(rpr)<w:t xml:space=\"preserve\">\(X(line))</w:t></w:r></w:p>" }
                        body += "</w:tc>"
                    }
                    body += "</w:tr>"
                }
                body += "</w:tbl><w:p/>"
            }
            prev = b.type
        }

        let zip = Zip.Writer()
        zip.add("[Content_Types].xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
                "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
                "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>" +
                "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>" +
                "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>" +
                "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>")
        zip.add("_rels/.rels",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
                "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>" +
                "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>")
        zip.add("docProps/core.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" +
                "<dc:title>\(X(doc.guessTitle()))</dc:title><dc:creator>Satsuma</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">\(iso8601())</dcterms:created></cp:coreProperties>")
        var rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rIdS\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" +
            "<Relationship Id=\"rIdN\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
        for (i, l) in links.enumerated() {
            rels += "<Relationship Id=\"rIdL\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(X(l))\" TargetMode=\"External\"/>"
        }
        rels += "</Relationships>"
        zip.add("word/_rels/document.xml.rels", rels)
        zip.add("word/document.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>" +
                body + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>")

        var styles = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
            "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault>" +
            "<w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>" +
            "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        let sizes = [40, 32, 28, 24, 22, 22]
        for h in 1...6 {
            styles += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(h)\"><w:name w:val=\"heading \(h)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>" +
                "<w:pPr><w:keepNext/><w:spacing w:before=\"\(h <= 2 ? 360 : 240)\" w:after=\"120\"/><w:outlineLvl w:val=\"\(h - 1)\"/></w:pPr><w:rPr><w:b/><w:color w:val=\"\(h == 1 ? "1F1A16" : "2B2622")\"/><w:sz w:val=\"\(sizes[h - 1])\"/></w:rPr></w:style>"
        }
        styles += "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:ind w:left=\"567\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"FF7A1A\"/></w:pBdr></w:pPr><w:rPr><w:i/><w:color w:val=\"6B625B\"/></w:rPr></w:style>" +
            "<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F0EC\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:sz w:val=\"19\"/></w:rPr></w:style>" +
            "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"60\"/><w:contextualSpacing/></w:pPr></w:style>" +
            "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>" +
            "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:tblPr><w:tblBorders>" +
            "<w:top w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/><w:left w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/><w:right w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/>" +
            "<w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/></w:tblBorders><w:tblCellMar><w:left w:w=\"108\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>" +
            "</w:styles>"
        zip.add("word/styles.xml", styles)

        var numbering = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        let bullets = ["•", "◦", "▪"]
        numbering += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        for l in 0..<9 {
            numbering += "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bullets[l % 3])\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + 360 * l)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        numbering += "</w:abstractNum><w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        let fmts = ["decimal", "lowerLetter", "lowerRoman"]
        for l in 0..<9 {
            numbering += "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmts[l % 3])\"/><w:lvlText w:val=\"%\(l + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + 360 * l)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        numbering += "</w:abstractNum>"
        for (n, ordered) in nums.enumerated() {
            numbering += "<w:num w:numId=\"\(n + 1)\"><w:abstractNumId w:val=\"\(ordered ? 1 : 0)\"/>\(ordered ? "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" : "")</w:num>"
        }
        numbering += "</w:numbering>"
        zip.add("word/numbering.xml", numbering)
        P.remove(path)
        try zip.write(to: path)
    }

    // ------------------------------------------------------------------ EPUB 3

    public static func epub(_ doc: DocModel, _ path: String) throws {
        var title = doc.guessTitle()
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = P.stem(path) }

        // Split into chapters at H1 (or H2 if there are no H1s).
        let splitLevel = doc.blocks.contains { $0.type == .heading && $0.level == 1 } ? 1 : 2
        var chapters: [DocModel] = []
        var current = DocModel()
        for b in doc.blocks {
            if b.type == .pageBreak { continue }
            if b.type == .heading && b.level <= splitLevel && !current.blocks.isEmpty { chapters.append(current); current = DocModel() }
            current.blocks.append(b)
        }
        if !current.blocks.isEmpty || chapters.isEmpty { chapters.append(current) }

        let zip = Zip.Writer()
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("META-INF/container.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
        zip.add("OEBPS/style.css", css)
        var manifest = "", spine = "", nav = ""
        for (i, ch) in chapters.enumerated() {
            let file = "chapter-\(String(format: "%03d", i + 1)).xhtml"
            let chTitle = ch.blocks.first { $0.type == .heading }?.plainText ?? (chapters.count == 1 ? title : "Part \(i + 1)")
            zip.add("OEBPS/" + file, page(chTitle, body(ch, xhtml: true), xhtml: true))
            manifest += "<item id=\"c\(i + 1)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(i + 1)\"/>"
            nav += "<li><a href=\"\(file)\">\(Html.escape(chTitle))</a></li>"
        }
        zip.add("OEBPS/nav.xhtml", page(title, "<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>\(nav)</ol></nav>\n", xhtml: true))
        zip.add("OEBPS/content.opf",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"uid\">" +
                "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"uid\">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier><dc:title>\(Html.escape(title))</dc:title><dc:language>en</dc:language>" +
                "<meta property=\"dcterms:modified\">\(iso8601())</meta></metadata>" +
                "<manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\(manifest)</manifest>" +
                "<spine>\(spine)</spine></package>")
        P.remove(path)
        try zip.write(to: path)
    }

    // ------------------------------------------------------------------ RTF

    public static func rtf(_ doc: DocModel) -> String {
        var sb = "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Calibri;}{\\f1\\fmodern Consolas;}}\\viewkind4\\uc1\\pard\\sa160\\sl264\\slmult1\\f0\\fs22 "
        let hs = [40, 32, 28, 24, 22, 22]
        func r(_ s: String) -> String {
            var o = ""
            for u in s.utf16 {
                switch u {
                case 0x5C: o += "\\\\"
                case 0x7B: o += "\\{"
                case 0x7D: o += "\\}"
                case 0x0A: o += "\\line "
                case 0x09: o += "\\tab "
                case 0x0D: break
                default:
                    if u > 127 { o += "\\u\(Int16(bitPattern: u))?" }
                    else { o.unicodeScalars.append(Unicode.Scalar(UInt8(u))) }
                }
            }
            return o
        }
        func rInl(_ inlines: [Inline]) -> String {
            inlines.map { i in
                (i.bold ? "{\\b " : "") + (i.italic ? "{\\i " : "") + (i.code ? "{\\f1 " : "") + r(i.text) + (i.code ? "}" : "") + (i.italic ? "}" : "") + (i.bold ? "}" : "")
            }.joined()
        }
        for b in doc.blocks {
            switch b.type {
            case .heading: sb += "\\pard\\sb240\\sa120\\b\\fs\(hs[min(max(b.level, 1), 6) - 1]) \(r(b.plainText))\\b0\\fs22\\par "
            case .listItem: sb += "\\pard\\li\(360 + 360 * b.level)\\fi-240 \(b.ordered ? "\(b.number)." : "\\bullet")\\tab \(rInl(b.inlines))\\par "
            case .code: sb += "\\pard\\f1\\fs19 \(r(b.codeText ?? ""))\\f0\\fs22\\par "
            case .quote: sb += "\\pard\\li567\\i \(rInl(b.inlines))\\i0\\par "
            case .rule: sb += "\\pard\\brdrb\\brdrs\\brdrw10\\brsp20 \\par "
            case .pageBreak: sb += "\\page "
            case .table: for row in b.rows ?? [] { sb += "\\pard \(r(row.joined(separator: "\t")))\\par " }
            default: sb += "\\pard\\sa160 \(rInl(b.inlines))\\par "
            }
        }
        return sb + "}"
    }
}
