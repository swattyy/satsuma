import Foundation

public struct Sheet {
    public var name: String
    public var rows: [[String]]
    public init(name: String, rows: [[String]]) { self.name = name; self.rows = rows }
}

/// Spreadsheets: XLSX, ODS, CSV and TSV are read and written here (ported from the Windows app);
/// XLS and XLSB need LibreOffice, which also does PDF output when it's installed.
public enum SheetConverter {
    public static func targets(for ext: String) -> [String] {
        let needsOffice = ext == "xls" || ext == "xlsb"
        if needsOffice && !Engines.flags.excel { return [] }
        let selfExt = ext == "tab" ? "tsv" : ext == "xlsm" ? "xlsx" : ext
        return ["xlsx", "csv", "tsv", "ods", "json", "pdf", "html"].filter { $0 != selfExt }
    }

    public static func convert(_ input: String, to target: String) async throws -> String {
        let ext = FileKinds.ext(input)
        let output = OutputPaths.path(for: input, ext: target)
        return try await OutputPaths.writing(output) { out in
            let office = LibreOffice.path != nil
            if office && (target == "pdf" || (["xls", "xlsb"].contains(ext) && ["xlsx", "ods"].contains(target))) {
                try await LibreOffice.convert(input, to: target, output: out)
                return out
            }
            var sheets: [Sheet]
            if ext == "xls" || ext == "xlsb" {
                let tmpDir = try AppPaths.newTempDir("xls")
                defer { P.remove(tmpDir) }
                let tmp = P.join(tmpDir, "book.xlsx")
                try await LibreOffice.convert(input, to: "xlsx", output: tmp)
                sheets = try readXlsx(tmp)
            } else {
                sheets = try read(input)
            }
            sheets = sheets.filter { !$0.rows.isEmpty }
            if sheets.isEmpty { throw OpError("The spreadsheet is empty.") }

            if (target == "csv" || target == "tsv") && sheets.count > 1 {
                // One file per sheet, in a folder.
                OutputPaths.discard(out)
                let folder = try OutputPaths.folderFor(input, suffix: " (\(target.uppercased()))")
                for s in sheets { try writeDelimited(s.rows, P.join(folder, safe(s.name) + "." + target), target == "csv" ? "," : "\t") }
                return folder
            }
            switch target {
            case "csv": try writeDelimited(sheets[0].rows, out, ",")
            case "tsv": try writeDelimited(sheets[0].rows, out, "\t")
            case "json": try P.writeText(out, json(sheets))
            case "xlsx": try writeXlsx(sheets, out)
            case "ods": try writeOds(sheets, out)
            case "html": try P.writeText(out, DocWriters.html(toDoc(sheets, FileKinds.baseName(input))))
            case "pdf": try await WebRender.printHTML(DocWriters.html(toDoc(sheets, FileKinds.baseName(input))), baseURL: nil, to: out)
            default: throw OpError("Unsupported spreadsheet format \(target)")
            }
            return out
        }
    }

    static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0")
        let s = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Sheet" : s
    }

    static func toDoc(_ sheets: [Sheet], _ title: String) -> DocModel {
        let doc = DocModel()
        doc.title = title
        for s in sheets {
            if sheets.count > 1 { doc.blocks.append(.heading(2, s.name)) }
            let b = Block(type: .table)
            b.rows = s.rows
            doc.blocks.append(b)
        }
        return doc
    }

    public static func read(_ path: String) throws -> [Sheet] {
        switch FileKinds.ext(path) {
        case "xlsx", "xlsm": return try readXlsx(path)
        case "ods": return try readOds(path)
        case "csv": return [Sheet(name: "Sheet1", rows: readDelimited(try DocReaders.readText(path), nil))]
        case "tsv", "tab": return [Sheet(name: "Sheet1", rows: readDelimited(try DocReaders.readText(path), "\t"))]
        default: throw OpError("Can't read .\(FileKinds.ext(path)) spreadsheets without LibreOffice.")
        }
    }

    // ------------------------------------------------------------------ CSV / TSV

    public static func readDelimited(_ raw: String, _ delimiter: Character?) -> [[String]] {
        var text = raw
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let d = delimiter ?? sniff(text)
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        let dq: Unicode.Scalar = "\""
        let dScalar = d.unicodeScalars.first!
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == dq {
                    if i + 1 < chars.count && chars[i + 1] == dq { cell.unicodeScalars.append(dq); i += 1 }
                    else { quoted = false }
                } else { cell.unicodeScalars.append(c) }
                i += 1
                continue
            }
            if c == dq && cell.isEmpty { quoted = true }
            else if c == dScalar { row.append(cell); cell = "" }
            else if c == "\r" || c == "\n" {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(cell)
                cell = ""
                rows.append(row)
                row = []
            } else { cell.unicodeScalars.append(c) }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        return rows
    }

    static func sniff(_ text: String) -> Character {
        let first = text.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: false).prefix(5).joined(separator: "\n")
        let candidates: [Character] = [",", ";", "\t", "|"]
        let counts: [(Character, Int)] = candidates.map { ch in (ch, first.filter { $0 == ch }.count) }
        let best = counts.max { $0.1 < $1.1 }!
        return best.1 > 0 ? best.0 : ","
    }

    static func writeDelimited(_ rows: [[String]], _ path: String, _ d: Character) throws {
        var out = ""
        for row in rows {
            out += row.map { c -> String in
                if d == "\t" { return c.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ") }
                let needs = c.contains(d) || c.contains("\"") || c.contains("\n") || c.contains("\r") || c.hasPrefix(" ") || c.hasSuffix(" ")
                return needs ? "\"" + c.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : c
            }.joined(separator: String(d))
            out += "\r\n"
        }
        // BOM so Excel detects UTF-8.
        try P.writeText(path, out, bom: true)
    }

    // ------------------------------------------------------------------ JSON

    static let numeric = Rx("^-?(0|[1-9]\\d*)(\\.\\d+)?([eE][+-]?\\d+)?$")
    static func looksNumeric(_ v: String) -> Bool { numeric.test(v) }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func jsonNumber(_ v: String) -> String? {
        guard looksNumeric(v), let d = Double(v), d.isFinite else { return nil }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// Rows as objects keyed by the header row, in column order, like the Windows writer.
    static func json(_ sheets: [Sheet]) -> String {
        func sheetJSON(_ s: Sheet, _ indent: String) -> String {
            var header = s.rows[0].enumerated().map { i, h in h.trimmingCharacters(in: .whitespaces).isEmpty ? "column\(i + 1)" : h.trimmingCharacters(in: .whitespaces) }
            var seen: [String: Int] = [:]
            for i in header.indices {
                if let n = seen[header[i]] { seen[header[i]] = n + 1; header[i] = "\(header[i])_\(n + 1)" } else { seen[header[i]] = 1 }
            }
            var objects: [String] = []
            for row in s.rows.dropFirst() {
                var fields: [String] = []
                for (i, h) in header.enumerated() {
                    let v = i < row.count ? row[i] : ""
                    let value: String
                    if v.isEmpty { value = "null" }
                    else if let n = jsonNumber(v) { value = n }
                    else if v == "TRUE" || v == "true" { value = "true" }
                    else if v == "FALSE" || v == "false" { value = "false" }
                    else { value = jsonString(v) }
                    fields.append("\(indent)    \(jsonString(h)): \(value)")
                }
                objects.append("\(indent)  {\n" + fields.joined(separator: ",\n") + "\n\(indent)  }")
            }
            return objects.isEmpty ? "[]" : "[\n" + objects.joined(separator: ",\n") + "\n\(indent)]"
        }
        if sheets.count == 1 { return sheetJSON(sheets[0], "") + "\n" }
        let parts = sheets.map { "  \(jsonString($0.name)): \(sheetJSON($0, "  "))" }
        return "{\n" + parts.joined(separator: ",\n") + "\n}\n"
    }

    // ------------------------------------------------------------------ XLSX

    static let S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let PKG = "http://schemas.openxmlformats.org/package/2006/relationships"

    public static func readXlsx(_ path: String) throws -> [Sheet] {
        let zip = try Zip.Reader(path: path)
        let shared = (zip.xml("xl/sharedStrings.xml")?.rootElement()?.kids("si", S) ?? []).map { si in
            si.descendants("t", S).map { $0.stringValue ?? "" }.joined()
        }
        let styles = zip.xml("xl/styles.xml")?.rootElement()
        var custom: [Int: String] = [:]
        for f in styles?.kid("numFmts", S)?.kids("numFmt", S) ?? [] { custom[Int(f.attr("numFmtId") ?? "0") ?? 0] = f.attr("formatCode") ?? "" }
        let xfIsDate: [Bool] = (styles?.kid("cellXfs", S)?.kids("xf", S) ?? []).map { xf in
            let id = Int(xf.attr("numFmtId") ?? "0") ?? 0
            if (14...22).contains(id) || (45...47).contains(id) { return true }
            return custom[id].map(isDateFormat) ?? false
        }
        var rels: [String: String] = [:]
        for r in zip.xml("xl/_rels/workbook.xml.rels")?.descendants("Relationship", PKG) ?? [] { rels[r.attr("Id") ?? ""] = r.attr("Target") ?? "" }
        guard let workbook = zip.xml("xl/workbook.xml") else { throw OpError("Not a valid XLSX file.") }
        var result: [Sheet] = []
        for sheet in workbook.descendants("sheet", S) {
            let name = sheet.attr("name") ?? "Sheet\(result.count + 1)"
            guard let target = rels[sheet.attr("id", REL) ?? ""] else { continue }
            let part = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let xml = zip.xml(part) else { continue }
            var rows: [[String]] = []
            for row in xml.descendants("row", S) {
                let rIndex = (Int(row.attr("r") ?? "") ?? rows.count + 1) - 1
                while rows.count < rIndex { rows.append([]) }
                var cells: [String] = []
                for c in row.kids("c", S) {
                    let ref = c.attr("r") ?? ""
                    let col = ref.isEmpty ? cells.count : columnIndex(ref)
                    while cells.count < col { cells.append("") }
                    let t = c.attr("t") ?? "n"
                    let style = Int(c.attr("s") ?? "0") ?? 0
                    let v = c.kid("v", S)?.stringValue ?? ""
                    let value: String
                    switch t {
                    case "s": value = Int(v).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                    case "inlineStr": value = c.descendants("t", S).map { $0.stringValue ?? "" }.joined()
                    case "b": value = v == "1" ? "TRUE" : "FALSE"
                    case "str", "e": value = v
                    default:
                        if style < xfIsDate.count && xfIsDate[style], let d = Double(v) { value = formatDate(d) } else { value = v }
                    }
                    cells.append(value)
                }
                rows.append(cells)
            }
            trim(&rows)
            result.append(Sheet(name: name, rows: rows))
        }
        return result
    }

    static func trim(_ rows: inout [[String]]) {
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        let width = rows.map { r -> Int in
            var i = r.count
            while i > 0 && r[i - 1].isEmpty { i -= 1 }
            return i
        }.max() ?? 0
        for i in rows.indices {
            if rows[i].count > width { rows[i].removeLast(rows[i].count - width) }
            while rows[i].count < width { rows[i].append("") }
        }
    }

    static func isDateFormat(_ code: String) -> Bool {
        let stripped = Rx("\"[^\"]*\"|\\[[^\\]]*\\]|\\\\.").replace(code, "")
        return Rx("[dmyhs]", [.caseInsensitive]).test(stripped) && !stripped.contains("#") && !stripped.contains("0")
    }

    static func formatDate(_ serial: Double) -> String {
        // Excel serial dates count days from 1899-12-30.
        let date = Date(timeIntervalSince1970: (serial - 25569) * 86400)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = serial == serial.rounded(.down) ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    static func columnIndex(_ ref: String) -> Int {
        var col = 0
        for ch in ref.uppercased().unicodeScalars {
            guard ch.value >= 65 && ch.value <= 90 else { break }
            col = col * 26 + Int(ch.value - 64)
        }
        return col - 1
    }

    static func columnName(_ index: Int) -> String {
        var s = ""
        var i = index + 1
        while i > 0 {
            s.insert(Character(Unicode.Scalar(UInt8(65 + (i - 1) % 26))), at: s.startIndex)
            i = (i - 1) / 26
        }
        return s
    }

    public static func writeXlsx(_ sheets: [Sheet], _ path: String) throws {
        let X = xmlEscape
        let zip = Zip.Writer()
        var ct = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        var wbSheets = ""
        var wbRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        var used = Set<String>()
        for (i, sheet) in sheets.enumerated() {
            var name = Rx("[\\[\\]\\*\\?/\\\\:]").replace(sheet.name, "_")
            if name.count > 31 { name = String(name.prefix(31)) }
            if name.isEmpty || used.contains(name.lowercased()) { name = "Sheet\(i + 1)" }
            used.insert(name.lowercased())
            ct += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            wbSheets += "<sheet name=\"\(X(name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            wbRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
            var data = ""
            for (r, row) in sheet.rows.enumerated() {
                data += "<row r=\"\(r + 1)\">"
                for (c, v) in row.enumerated() where !v.isEmpty {
                    let ref = columnName(c) + String(r + 1)
                    let style = r == 0 ? " s=\"1\"" : ""
                    if looksNumeric(v) && v.count < 16 { data += "<c r=\"\(ref)\"\(style)><v>\(v)</v></c>" }
                    else { data += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(X(v))</t></is></c>" }
                }
                data += "</row>"
            }
            zip.add("xl/worksheets/sheet\(i + 1).xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><sheetData>" + data + "</sheetData></worksheet>")
        }
        ct += "</Types>"
        wbRels += "</Relationships>"
        zip.add("[Content_Types].xml", ct)
        zip.add("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        zip.add("xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>" + wbSheets + "</sheets></workbook>")
        zip.add("xl/_rels/workbook.xml.rels", wbRels)
        zip.add("xl/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs></styleSheet>")
        P.remove(path)
        try zip.write(to: path)
    }

    // ------------------------------------------------------------------ ODS

    static let OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    static let TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"

    public static func readOds(_ path: String) throws -> [Sheet] {
        let zip = try Zip.Reader(path: path)
        guard let content = zip.xml("content.xml") else { throw OpError("Not an OpenDocument spreadsheet.") }
        var result: [Sheet] = []
        for table in content.descendants("table", TABLE) {
            var rows: [[String]] = []
            for row in table.descendants("table-row", TABLE) {
                var cells: [String] = []
                for cell in row.elementChildren where cell.named("table-cell", TABLE) || cell.named("covered-table-cell", TABLE) {
                    let repeatCount = min(Int(cell.attr("number-columns-repeated", TABLE) ?? "1") ?? 1, 512)
                    let type = cell.attr("value-type", OFFICE) ?? ""
                    let value: String
                    switch type {
                    case "float", "percentage", "currency": value = cell.attr("value", OFFICE) ?? ""
                    case "date": value = (cell.attr("date-value", OFFICE) ?? "").replacingOccurrences(of: "T00:00:00", with: "")
                    case "boolean": value = cell.attr("boolean-value", OFFICE) == "true" ? "TRUE" : "FALSE"
                    default: value = cell.kids("p", TEXT).map { $0.stringValue ?? "" }.joined(separator: "\n")
                    }
                    for _ in 0..<max(1, repeatCount) { cells.append(value) }
                }
                let rowRepeat = min(Int(row.attr("number-rows-repeated", TABLE) ?? "1") ?? 1, 1024)
                for _ in 0..<max(1, rowRepeat) { rows.append(cells) }
            }
            trim(&rows)
            result.append(Sheet(name: table.attr("name", TABLE) ?? "Sheet\(result.count + 1)", rows: rows))
        }
        return result
    }

    public static func writeOds(_ sheets: [Sheet], _ path: String) throws {
        let X = xmlEscape
        let zip = Zip.Writer()
        zip.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet", compress: false)
        zip.add("META-INF/manifest.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>")
        var body = ""
        for s in sheets {
            body += "<table:table table:name=\"\(X(s.name))\">"
            for row in s.rows {
                body += "<table:table-row>"
                for v in row {
                    if v.isEmpty { body += "<table:table-cell/>" }
                    else if looksNumeric(v) { body += "<table:table-cell office:value-type=\"float\" office:value=\"\(v)\"><text:p>\(v)</text:p></table:table-cell>" }
                    else { body += "<table:table-cell office:value-type=\"string\"><text:p>\(X(v))</text:p></table:table-cell>" }
                }
                body += "</table:table-row>"
            }
            body += "</table:table>"
        }
        zip.add("content.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:spreadsheet>" + body + "</office:spreadsheet></office:body></office:document-content>")
        P.remove(path)
        try zip.write(to: path)
    }
}
