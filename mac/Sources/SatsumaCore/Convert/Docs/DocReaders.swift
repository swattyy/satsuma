import Foundation

/// Readers that turn common document formats into a DocModel (ported from the Windows app).
public enum DocReaders {
    public static func read(_ path: String) throws -> DocModel {
        let ext = FileKinds.ext(path)
        let doc: DocModel
        switch ext {
        case "md", "markdown", "mdown", "mkd": doc = markdown(try readText(path))
        case "html", "htm", "xhtml": doc = html(try readText(path))
        case "docx", "docm", "dotx": doc = try docx(path)
        case "epub": doc = try epub(path)
        case "rtf": doc = rtf([UInt8](try Data(contentsOf: P.url(path))))
        case "odt": doc = try odt(path)
        case "txt", "text", "log", "srt", "vtt", "csv": doc = text(try readText(path))
        default: throw OpError("Can't read .\(ext) documents.")
        }
        if doc.title.trimmingCharacters(in: .whitespaces).isEmpty { doc.title = FileKinds.baseName(path) }
        return doc.normalize()
    }

    public static func readText(_ path: String) throws -> String { try P.readText(path) }

    // ------------------------------------------------------------------ plain text

    static let blankLines = Rx("\\n[ \\t]*\\n+")

    public static func text(_ raw: String) -> DocModel {
        let doc = DocModel()
        let t = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for chunk in blankLines.split(t) {
            var c = chunk
            while c.last?.isWhitespace == true { c.removeLast() }
            if c.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if c.contains("\u{0C}") { doc.blocks.append(Block(type: .pageBreak)) }
            doc.blocks.append(.para(c.replacingOccurrences(of: "\u{0C}", with: "")))
        }
        return doc
    }

    // ------------------------------------------------------------------ Markdown (Foundation's CommonMark/GFM parser)

    public static func markdown(_ md: String) -> DocModel {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible, languageCode: nil)
        guard let attr = try? AttributedString(markdown: md, options: options) else { return text(md) }
        let doc = DocModel()

        var blockID: Int?
        var blockKinds: [PresentationIntent.Kind] = []
        var blockIDs: [Int] = []
        var inlines: [Inline] = []
        var emittedItems = Set<Int>()
        // Table being collected: identity, header cells, body rows.
        var tableID: Int?
        var header: [Int: String] = [:]
        var body: [Int: [Int: String]] = [:]

        func flushTable() {
            guard tableID != nil else { return }
            var rows: [[String]] = []
            func row(_ cells: [Int: String]) -> [String] {
                let n = (cells.keys.max() ?? -1) + 1
                return (0..<n).map { cells[$0] ?? "" }
            }
            if !header.isEmpty { rows.append(row(header)) }
            for k in body.keys.sorted() { rows.append(row(body[k]!)) }
            if !rows.isEmpty { let b = Block(type: .table); b.rows = rows; doc.blocks.append(b) }
            tableID = nil
            header = [:]
            body = [:]
        }

        func flushBlock() {
            defer { blockID = nil; inlines = []; blockKinds = []; blockIDs = [] }
            guard blockID != nil else { return }
            var heading: Int?
            var code = false, rule = false, quote = false
            var lists = 0
            var ordered: Bool?
            var ordinal = 1
            var itemID: Int?
            for (k, id) in zip(blockKinds, blockIDs) {
                switch k {
                case .header(let level): heading = level
                case .codeBlock: code = true
                case .thematicBreak: rule = true
                case .blockQuote: quote = true
                case .listItem(let n): if lists == 0 && itemID == nil { ordinal = n; itemID = id }
                case .orderedList: if ordered == nil { ordered = true }; lists += 1
                case .unorderedList: if ordered == nil { ordered = false }; lists += 1
                default: break
                }
            }
            if rule { doc.blocks.append(Block(type: .rule)); return }
            if code {
                let b = Block(type: .code)
                var t = inlines.map(\.text).joined()
                while t.hasSuffix("\n") || t.hasSuffix("\r") { t.removeLast() }
                b.codeText = t
                doc.blocks.append(b)
                return
            }
            let b: Block
            if let heading {
                b = Block(type: .heading)
                b.level = heading
            } else if lists > 0, let item = itemID, !emittedItems.contains(item) {
                emittedItems.insert(item)
                b = Block(type: .listItem)
                b.level = lists - 1
                b.ordered = ordered ?? false
                b.number = ordinal
            } else {
                b = Block(type: quote ? .quote : .paragraph)
            }
            b.inlines = inlines
            doc.blocks.append(b)
        }

        for run in attr.runs {
            let comps = run.presentationIntent?.components ?? []
            let text = String(attr[run.range].characters)
            // Table cells: collect, emit the table when it ends.
            if let cell = comps.first(where: { if case .tableCell = $0.kind { return true } else { return false } }) {
                guard case .tableCell(let col) = cell.kind else { continue }
                let table = comps.first { if case .table = $0.kind { return true } else { return false } }?.identity
                if blockID != nil { flushBlock() }
                if table != tableID { flushTable(); tableID = table }
                if comps.contains(where: { if case .tableHeaderRow = $0.kind { return true } else { return false } }) {
                    header[col, default: ""] += text
                } else if let rowComp = comps.first(where: { if case .tableRow = $0.kind { return true } else { return false } }),
                          case .tableRow(let r) = rowComp.kind {
                    body[r, default: [:]][col, default: ""] += text
                }
                continue
            }
            if tableID != nil { flushTable() }
            let id = comps.first?.identity ?? -1
            if id != blockID {
                flushBlock()
                blockID = id
                blockKinds = comps.map(\.kind)
                blockIDs = comps.map(\.identity)
            }
            let style = run.inlinePresentationIntent ?? []
            if run.imageURL != nil { inlines.append(Inline("[image]")); continue }
            var t = text
            if style.contains(.lineBreak) { t = "\n" }
            else if style.contains(.softBreak) { t = " " }
            if style.contains(.inlineHTML) || style.contains(.blockHTML) {
                t = Html.decode(Rx("<[^>]+>").replace(t, " "))
            }
            inlines.append(Inline(t, bold: style.contains(.stronglyEmphasized), italic: style.contains(.emphasized),
                                  code: style.contains(.code), link: run.link?.absoluteString))
        }
        flushBlock()
        flushTable()
        return doc
    }

    // ------------------------------------------------------------------ HTML (tolerant tokenizer)

    static let token = Rx("<!--.*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>|([^<]+)", [.dotMatchesLineSeparators])
    static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "pre", "blockquote", "tr", "table", "section",
                                         "article", "header", "footer", "ul", "ol", "dd", "dt", "figure", "figcaption", "body", "main", "aside", "nav"]
    static let titleRx = Rx("<title[^>]*>(.*?)</title>", [.dotMatchesLineSeparators, .caseInsensitive])
    static let bodyRx = Rx("<body[^>]*>(.*)</body>", [.dotMatchesLineSeparators, .caseInsensitive])
    static let dropRx = Rx("<(script|style|head|noscript|svg)[^>]*>.*?</\\1>", [.dotMatchesLineSeparators, .caseInsensitive])
    static let hrefRx = Rx("href\\s*=\\s*[\"']([^\"']*)[\"']", [.caseInsensitive])
    static let altRx = Rx("alt\\s*=\\s*[\"']([^\"']*)[\"']", [.caseInsensitive])
    static let startRx = Rx("start\\s*=\\s*[\"']?(\\d+)", [.caseInsensitive])
    static let spaces = Rx("[ \\t\\r\\n]+")
    static let anySpace = Rx("\\s+")

    public static func html(_ source: String) -> DocModel {
        let doc = DocModel()
        if let m = titleRx.first(source), let t = Rx.group(m, 1, in: source) { doc.title = Html.decode(t).trimmingCharacters(in: .whitespacesAndNewlines) }
        var content = source
        if let m = bodyRx.first(source), let b = Rx.group(m, 1, in: source) { content = b }
        content = dropRx.replace(content, "")

        var current: Block?
        var bold = 0, italic = 0, code = 0, pre = 0, quote = 0
        var link: String?
        var lists: [(ordered: Bool, counter: Int)] = []
        var table: [[String]]?
        var cell: String?
        var preText: String?

        func flush() {
            if let c = current, c.inlines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                // Collapse whitespace like a browser would.
                for i in c.inlines where !i.code { i.text = spaces.replace(i.text, " ") }
                while c.inlines[0].text.first?.isWhitespace == true { c.inlines[0].text.removeFirst() }
                while c.inlines[c.inlines.count - 1].text.last?.isWhitespace == true { c.inlines[c.inlines.count - 1].text.removeLast() }
                doc.blocks.append(c)
            }
            current = nil
        }
        func cur(_ type: BlockType = .paragraph) -> Block {
            if let c = current { return c }
            let b = Block(type: quote > 0 && type == .paragraph ? .quote : type)
            current = b
            return b
        }

        for m in token.matches(content) {
            guard let whole = Rx.group(m, 0, in: content) else { continue }
            if whole.hasPrefix("<!--") { continue }
            if let raw = Rx.group(m, 4, in: content) {
                let t = Html.decode(raw)
                if preText != nil { preText! += t; continue }
                if cell != nil { cell! += t; continue }
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && current == nil { continue }
                cur().inlines.append(Inline(t, bold: bold > 0, italic: italic > 0, code: code > 0, link: link))
                continue
            }
            let closing = Rx.group(m, 1, in: content) == "/"
            let tag = (Rx.group(m, 2, in: content) ?? "").lowercased()
            let attrs = Rx.group(m, 3, in: content) ?? ""
            switch tag {
            case "b", "strong": bold += closing ? -1 : 1
            case "i", "em", "cite": italic += closing ? -1 : 1
            case "code" where pre == 0, "kbd" where pre == 0, "samp" where pre == 0: code += closing ? -1 : 1
            case "a":
                if closing { link = nil }
                else { link = hrefRx.first(attrs).flatMap { Rx.group($0, 1, in: attrs) }.map(Html.decode) }
            case "br":
                if cell != nil { cell! += " " }
                else if preText != nil { preText! += "\n" }
                else { cur().inlines.append(Inline("\n", bold: bold > 0, italic: italic > 0)) }
            case "hr":
                flush()
                doc.blocks.append(Block(type: .rule))
            case "img":
                if let alt = altRx.first(attrs).flatMap({ Rx.group($0, 1, in: attrs) }), !alt.isEmpty, cell == nil {
                    cur().inlines.append(Inline("[\(Html.decode(alt))]"))
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !closing { let b = Block(type: .heading); b.level = Int(String(tag.last!)) ?? 1; current = b }
            case "ul", "ol":
                flush()
                if closing { if !lists.isEmpty { lists.removeLast() } }
                else {
                    let start = startRx.first(attrs).flatMap { Rx.group($0, 1, in: attrs) }.flatMap { Int($0) } ?? 1
                    lists.append((ordered: tag == "ol", counter: start))
                }
            case "li":
                flush()
                if !closing {
                    let top = lists.popLast() ?? (ordered: false, counter: 1)
                    lists.append((ordered: top.ordered, counter: top.counter + 1))
                    let b = Block(type: .listItem)
                    b.level = max(0, lists.count - 1)
                    b.ordered = top.ordered
                    b.number = top.counter
                    current = b
                }
            case "pre":
                flush()
                if !closing { pre += 1; preText = "" }
                else {
                    pre = max(0, pre - 1)
                    if let t = preText {
                        let b = Block(type: .code)
                        b.codeText = t.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                        doc.blocks.append(b)
                    }
                    preText = nil
                }
            case "blockquote":
                flush()
                quote += closing ? -1 : 1
            case "table":
                flush()
                if !closing { table = [] }
                else if let t = table {
                    if !t.isEmpty { let b = Block(type: .table); b.rows = t; doc.blocks.append(b) }
                    table = nil
                }
            case "tr":
                if !closing && table != nil { table!.append([]) }
            case "td", "th":
                if !closing { cell = "" }
                else if let c = cell {
                    if table != nil && !table!.isEmpty {
                        table![table!.count - 1].append(anySpace.replace(c, " ").trimmingCharacters(in: .whitespaces))
                    }
                    cell = nil
                }
            default:
                if blockTags.contains(tag) { flush() }
            }
        }
        flush()
        return doc
    }

    // ------------------------------------------------------------------ DOCX (Office Open XML)

    static let W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let PR = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let headingRx = Rx("^heading\\s*(\\d)")

    public static func docx(_ path: String) throws -> DocModel {
        let zip = try Zip.Reader(path: path)
        let doc = DocModel()
        guard let document = zip.xml("word/document.xml"), let body = document.rootElement()?.kid("body", W) else { return doc }
        let styles = zip.xml("word/styles.xml")
        let numbering = zip.xml("word/numbering.xml")
        let rels = zip.xml("word/_rels/document.xml.rels")

        var links: [String: String] = [:]
        for r in rels?.descendants("Relationship", PR) ?? [] { links[r.attr("Id") ?? ""] = r.attr("Target") ?? "" }
        var styleNames: [String: String] = [:]
        for s in styles?.descendants("style", W) ?? [] {
            styleNames[s.attr("styleId", W) ?? ""] = (s.kid("name", W)?.attr("val", W) ?? "").lowercased()
        }
        // numId -> abstractNumId, abstractNumId -> (ilvl -> numFmt)
        var formats: [String: [Int: String]] = [:]
        for a in numbering?.descendants("abstractNum", W) ?? [] {
            var lv: [Int: String] = [:]
            for l in a.kids("lvl", W) { lv[Int(l.attr("ilvl", W) ?? "0") ?? 0] = l.kid("numFmt", W)?.attr("val", W) ?? "bullet" }
            formats[a.attr("abstractNumId", W) ?? ""] = lv
        }
        var numToAbstract: [String: String] = [:]
        for n in numbering?.descendants("num", W) ?? [] { numToAbstract[n.attr("numId", W) ?? ""] = n.kid("abstractNumId", W)?.attr("val", W) ?? "" }
        var counters: [String: Int] = [:]

        func isOn(_ e: XMLElement?) -> Bool {
            guard let e else { return false }
            let v = e.attr("val", W)
            return v == nil || v == "1" || v == "true" || v == "on"
        }

        func runs(_ p: XMLElement) -> [Inline] {
            var list: [Inline] = []
            func addRun(_ r: XMLElement, _ url: String?) {
                let rpr = r.kid("rPr", W)
                let b = isOn(rpr?.kid("b", W)), i = isOn(rpr?.kid("i", W))
                let font = rpr?.kid("rFonts", W)?.attr("ascii", W) ?? ""
                let mono = font.contains("Consolas") || font.contains("Courier") || font.contains("Mono")
                for c in r.elementChildren {
                    if c.named("t", W) { list.append(Inline(c.stringValue ?? "", bold: b, italic: i, code: mono, link: url)) }
                    else if c.named("tab", W) { list.append(Inline("\t", bold: b, italic: i, code: mono, link: url)) }
                    else if c.named("br", W) && c.attr("type", W) != "page" { list.append(Inline("\n", bold: b, italic: i, code: mono, link: url)) }
                }
            }
            for node in p.elementChildren {
                if node.named("r", W) { addRun(node, nil) }
                else if node.named("hyperlink", W) {
                    let url = node.attr("id", R).flatMap { links[$0] }
                    for r in node.kids("r", W) { addRun(r, url) }
                } else if node.named("ins", W) || node.named("smartTag", W) || node.named("sdt", W) {
                    for r in node.descendants("r", W) { addRun(r, nil) }
                }
            }
            return list
        }

        func addParagraph(_ p: XMLElement) {
            let ppr = p.kid("pPr", W)
            let styleId = ppr?.kid("pStyle", W)?.attr("val", W) ?? ""
            let styleName = styleNames[styleId] ?? styleId.lowercased()
            let inl = runs(p)
            if p.descendants("br", W).contains(where: { $0.attr("type", W) == "page" }) { doc.blocks.append(Block(type: .pageBreak)) }
            let block = Block(type: .paragraph)
            block.inlines = inl
            if let m = headingRx.first(styleName), let level = Rx.group(m, 1, in: styleName) {
                block.type = .heading
                block.level = Int(level) ?? 1
            } else if styleName == "title" { block.type = .heading; block.level = 1 }
            else if styleName == "subtitle" { block.type = .heading; block.level = 2 }
            else if styleName.contains("quote") { block.type = .quote }
            if let numPr = ppr?.kid("numPr", W), block.type == .paragraph {
                let numId = numPr.kid("numId", W)?.attr("val", W) ?? ""
                let ilvl = Int(numPr.kid("ilvl", W)?.attr("val", W) ?? "0") ?? 0
                if numId != "0" {
                    let fmt = numToAbstract[numId].flatMap { formats[$0] }?[ilvl] ?? "bullet"
                    let key = "\(numId)|\(ilvl)"
                    counters[key] = (counters[key] ?? 0) + 1
                    // Deeper levels restart when a shallower item appears.
                    for k in counters.keys {
                        let parts = k.split(separator: "|")
                        if parts.count == 2, parts[0] == numId, let l = Int(parts[1]), l > ilvl { counters.removeValue(forKey: k) }
                    }
                    block.type = .listItem
                    block.level = ilvl
                    block.ordered = fmt != "bullet" && fmt != "none"
                    block.number = counters[key] ?? 1
                }
            }
            if !block.inlines.isEmpty || block.type != .paragraph { doc.blocks.append(block) }
        }

        for el in body.elementChildren {
            if el.named("p", W) { addParagraph(el) }
            else if el.named("tbl", W) {
                let rows = el.kids("tr", W).map { tr in
                    tr.kids("tc", W).map { tc in tc.kids("p", W).map { runs($0).map(\.text).joined() }.joined(separator: "\n") }
                }
                if !rows.isEmpty { let b = Block(type: .table); b.rows = rows; doc.blocks.append(b) }
            } else if el.named("sdt", W) {
                for p in el.descendants("p", W) { addParagraph(p) }
            }
        }
        return doc
    }

    // ------------------------------------------------------------------ EPUB

    public static func epub(_ path: String) throws -> DocModel {
        let zip = try Zip.Reader(path: path)
        guard let container = zip.xml("META-INF/container.xml"),
              let opfPath = container.descendants("rootfile").first?.attr("full-path"),
              let opf = zip.xml(opfPath) else { throw OpError("Not a valid EPUB file.") }
        let baseDir = opfPath.contains("/") ? String(opfPath[...opfPath.lastIndex(of: "/")!]) : ""
        var manifest: [String: String] = [:]
        for item in opf.descendants("item") { manifest[item.attr("id") ?? ""] = item.attr("href") ?? "" }
        let doc = DocModel()
        doc.title = opf.descendants("title").first?.stringValue ?? ""
        for itemref in opf.descendants("itemref") {
            guard let href = manifest[itemref.attr("idref") ?? ""] else { continue }
            let chapter = html(zip.text(baseDir + (href.removingPercentEncoding ?? href)) ?? "")
            if !doc.blocks.isEmpty && !chapter.blocks.isEmpty { doc.blocks.append(Block(type: .pageBreak)) }
            doc.blocks += chapter.blocks
        }
        return doc
    }

    // ------------------------------------------------------------------ RTF

    static func encoding(codePage: Int) -> String.Encoding {
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
        if cf == kCFStringEncodingInvalidId { return .windowsCP1252 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    public static func rtf(_ src: [UInt8]) -> DocModel {
        let doc = DocModel()
        var para = Block(type: .paragraph)
        var text = ""
        var bold = false, italic = false
        var stack: [(Bool, Bool, Bool)] = []
        var skip = false
        var ucSkip = 1, pendingSkip = 0
        var enc = String.Encoding.windowsCP1252
        var bytes: [UInt8] = []

        func flushBytes() {
            if !bytes.isEmpty { text += String(data: Data(bytes), encoding: enc) ?? String(decoding: bytes, as: UTF8.self); bytes = [] }
        }
        func flushText() {
            flushBytes()
            if !text.isEmpty { para.inlines.append(Inline(text, bold: bold, italic: italic)); text = "" }
        }
        func endPara() {
            flushText()
            if !para.inlines.isEmpty { doc.blocks.append(para) }
            para = Block(type: .paragraph)
        }
        func isLetter(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }
        func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }

        var i = 0
        while i < src.count {
            let ch = src[i]
            if ch == UInt8(ascii: "{") { flushText(); stack.append((bold, italic, skip)); i += 1; continue }
            if ch == UInt8(ascii: "}") {
                flushText()
                if let s = stack.popLast() { (bold, italic, skip) = s }
                i += 1
                continue
            }
            if ch == UInt8(ascii: "\\") {
                if i + 1 >= src.count { break }
                let next = src[i + 1]
                if next == UInt8(ascii: "'") && i + 3 < src.count {
                    if !skip {
                        if pendingSkip > 0 { pendingSkip -= 1 }
                        else if let h = hex(src[i + 2]), let l = hex(src[i + 3]) { bytes.append(h << 4 | l) }
                    }
                    i += 4
                    continue
                }
                if next == UInt8(ascii: "\\") || next == UInt8(ascii: "{") || next == UInt8(ascii: "}") {
                    if !skip { flushBytes(); text.append(Character(Unicode.Scalar(next))) }
                    i += 2
                    continue
                }
                if next == UInt8(ascii: "*") { skip = true; i += 2; continue }
                if next == UInt8(ascii: "~") { if !skip { flushBytes(); text.append("\u{00A0}") }; i += 2; continue }
                if !isLetter(next) { i += 2; continue }
                var j = i + 1
                while j < src.count && isLetter(src[j]) { j += 1 }
                let word = String(decoding: src[(i + 1)..<j], as: UTF8.self)
                var k = j
                if k < src.count && (src[k] == UInt8(ascii: "-") || isDigit(src[k])) {
                    k += 1
                    while k < src.count && isDigit(src[k]) { k += 1 }
                }
                let param = String(decoding: src[j..<k], as: UTF8.self)
                if k < src.count && src[k] == UInt8(ascii: " ") { k += 1 }
                i = k
                let num = Int(param) ?? 0
                switch word {
                case "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header", "footer", "listtable", "listoverridetable",
                     "rsidtbl", "generator", "themedata", "datastore", "latentstyles":
                    skip = true
                case "ansicpg": enc = encoding(codePage: num)
                case "par", "sect": if !skip { endPara() }
                case "line": if !skip { flushText(); text += "\n" }
                case "tab": if !skip { flushBytes(); text += "\t" }
                case "b": flushText(); bold = param != "0"
                case "i": flushText(); italic = param != "0"
                case "plain": flushText(); bold = false; italic = false
                case "uc": ucSkip = num
                case "u":
                    if !skip {
                        flushBytes()
                        let v = num < 0 ? num + 65536 : num
                        if let u = Unicode.Scalar(UInt32(v)) { text.unicodeScalars.append(u) }
                        pendingSkip = ucSkip
                    }
                case "emdash": if !skip { flushBytes(); text += "—" }
                case "endash": if !skip { flushBytes(); text += "–" }
                case "bullet": if !skip { flushBytes(); text += "•" }
                case "lquote": if !skip { flushBytes(); text += "‘" }
                case "rquote": if !skip { flushBytes(); text += "’" }
                case "ldblquote": if !skip { flushBytes(); text += "“" }
                case "rdblquote": if !skip { flushBytes(); text += "”" }
                default: break
                }
                continue
            }
            i += 1
            if ch == 13 || ch == 10 { continue }
            if skip { continue }
            if pendingSkip > 0 { pendingSkip -= 1; continue }
            if ch < 0x80 { flushBytes(); text.append(Character(Unicode.Scalar(ch))) }
            else { bytes.append(ch) }
        }
        endPara()
        return doc
    }

    // ------------------------------------------------------------------ ODT

    static let ODT_TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    static let ODT_TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    static let ODT_OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"

    public static func odt(_ path: String) throws -> DocModel {
        let zip = try Zip.Reader(path: path)
        guard let content = zip.xml("content.xml") else { throw OpError("Not an OpenDocument text file.") }
        let doc = DocModel()
        guard let body = content.descendants("text", ODT_OFFICE).first else { return doc }

        func flat(_ e: XMLElement) -> String {
            var s = ""
            for node in e.children ?? [] {
                if node.kind == .text { s += node.stringValue ?? "" }
                else if let x = node as? XMLElement {
                    if x.named("s", ODT_TEXT) { s += String(repeating: " ", count: Int(x.attr("c", ODT_TEXT) ?? "1") ?? 1) }
                    else if x.named("tab", ODT_TEXT) { s += "\t" }
                    else if x.named("line-break", ODT_TEXT) { s += "\n" }
                    else if x.localName == "note" || x.localName == "annotation" { continue }
                    else { s += flat(x) }
                }
            }
            return s
        }

        func walk(_ parent: XMLElement, _ level: Int) {
            for el in parent.elementChildren {
                if el.named("h", ODT_TEXT) {
                    doc.blocks.append(.heading(Int(el.attr("outline-level", ODT_TEXT) ?? "1") ?? 1, flat(el)))
                } else if el.named("p", ODT_TEXT) {
                    doc.blocks.append(.para(flat(el)))
                } else if el.named("list", ODT_TEXT) {
                    walkList(el, level)
                } else if el.named("table", ODT_TABLE) {
                    let rows = el.descendants("table-row", ODT_TABLE).map { r in
                        r.kids("table-cell", ODT_TABLE).map { c in c.kids("p", ODT_TEXT).map(flat).joined(separator: "\n") }
                    }
                    let b = Block(type: .table)
                    b.rows = rows
                    doc.blocks.append(b)
                } else if el.named("section", ODT_TEXT) {
                    walk(el, level)
                }
            }
        }

        func walkList(_ list: XMLElement, _ level: Int) {
            var n = 1
            for item in list.kids("list-item", ODT_TEXT) {
                for child in item.elementChildren {
                    if child.named("p", ODT_TEXT) || child.named("h", ODT_TEXT) {
                        let b = Block(type: .listItem)
                        b.level = level
                        b.number = n
                        b.inlines = [Inline(flat(child))]
                        doc.blocks.append(b)
                    } else if child.named("list", ODT_TEXT) {
                        walkList(child, level + 1)
                    }
                }
                n += 1
            }
        }

        walk(body, 0)
        return doc
    }
}
