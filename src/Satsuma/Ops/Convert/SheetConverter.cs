using System.Globalization;
using System.IO.Compression;
using System.Security;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Satsuma.Core;
using Satsuma.Ops.Convert.Docs;

namespace Satsuma.Ops.Convert;

public sealed record Sheet(string Name, List<List<string>> Rows);

/// <summary>Spreadsheets: XLSX/ODS/CSV/TSV read natively; XLS/XLSB and PDF output use Excel when it's installed.</summary>
public static class SheetConverter
{
    public static IEnumerable<string> TargetsFor(string ext)
    {
        bool needsExcel = ext is "xls" or "xlsb";
        if (needsExcel && !Office.HasExcel) yield break;
        string self = ext is "tab" ? "tsv" : ext is "xlsm" ? "xlsx" : ext;
        foreach (var t in new[] { "xlsx", "csv", "tsv", "ods", "json", "pdf", "html" })
            if (t != self) yield return t;
    }

    public static async Task<string> ConvertAsync(string input, string target, CancellationToken ct)
    {
        string ext = FileKinds.Ext(input);
        string output = OutputPaths.For(input, target);
        try
        {
            if (Office.HasExcel && (target == "pdf" || ext is "xls" or "xlsb" && target is "xlsx" or "ods"))
            {
                int? fmt = target switch { "pdf" => null, "xlsx" => Office.XlFormat.Xlsx, _ => Office.XlFormat.Ods };
                await Office.ExcelAsync(input, output, fmt);
                return output;
            }
            List<Sheet> sheets;
            if (ext is "xls" or "xlsb")
            {
                // Excel converts the binary workbook to XLSX, then we read that.
                var tmpDir = AppPaths.NewTempDir("xls");
                var tmp = Path.Combine(tmpDir, "book.xlsx");
                try { await Office.ExcelAsync(input, tmp, Office.XlFormat.Xlsx); sheets = ReadXlsx(tmp); }
                finally { try { Directory.Delete(tmpDir, true); } catch { } }
            }
            else sheets = await Task.Run(() => Read(input), ct);
            sheets = sheets.Where(s => s.Rows.Count > 0).ToList();
            if (sheets.Count == 0) throw new OpException("The spreadsheet is empty.");

            if (target is "csv" or "tsv" && sheets.Count > 1)
            {
                // One file per sheet, in a folder.
                OutputPaths.Discard(output);
                var folder = OutputPaths.FolderFor(input, $" ({target.ToUpperInvariant()})");
                foreach (var s in sheets)
                    WriteDelimited(s.Rows, Path.Combine(folder, Safe(s.Name) + "." + target), target == "csv" ? ',' : '\t');
                return folder;
            }
            switch (target)
            {
                case "csv": WriteDelimited(sheets[0].Rows, output, ','); break;
                case "tsv": WriteDelimited(sheets[0].Rows, output, '\t'); break;
                case "json": WriteJson(sheets, output); break;
                case "xlsx": WriteXlsx(sheets, output); break;
                case "ods": WriteOds(sheets, output); break;
                case "html": File.WriteAllText(output, DocWriters.Html(ToDoc(sheets, FileKinds.BaseName(input))), new UTF8Encoding(false)); break;
                case "pdf":
                    if (EdgeRenderer.Available) await EdgeRenderer.HtmlToPdfAsync(DocWriters.Html(ToDoc(sheets, FileKinds.BaseName(input))), null, output, ct);
                    else PdfLayout.Write(ToDoc(sheets, FileKinds.BaseName(input)), output);
                    break;
                default: throw new OpException("Unsupported spreadsheet format " + target);
            }
            return output;
        }
        catch { OutputPaths.Discard(output); throw; }
    }

    static string Safe(string name)
    {
        var s = string.Join("_", name.Split(Path.GetInvalidFileNameChars())).Trim();
        return s.Length > 0 ? s : "Sheet";
    }

    static DocModel ToDoc(List<Sheet> sheets, string title)
    {
        var doc = new DocModel { Title = title };
        foreach (var s in sheets)
        {
            if (sheets.Count > 1) doc.Blocks.Add(Block.Heading(2, s.Name));
            doc.Blocks.Add(new Block { Type = BlockType.Table, Rows = s.Rows });
        }
        return doc;
    }

    public static List<Sheet> Read(string path)
    {
        string ext = FileKinds.Ext(path);
        return ext switch
        {
            "xlsx" or "xlsm" => ReadXlsx(path),
            "ods" => ReadOds(path),
            "csv" => new() { new Sheet("Sheet1", ReadDelimited(DocReaders.ReadText(path), null)) },
            "tsv" or "tab" => new() { new Sheet("Sheet1", ReadDelimited(DocReaders.ReadText(path), '\t')) },
            _ => throw new OpException($"Can't read .{ext} spreadsheets without Excel."),
        };
    }

    // ------------------------------------------------------------------ CSV / TSV

    public static List<List<string>> ReadDelimited(string text, char? delimiter)
    {
        if (text.Length > 0 && text[0] == '﻿') text = text[1..];
        char d = delimiter ?? Sniff(text);
        var rows = new List<List<string>>();
        var row = new List<string>();
        var cell = new StringBuilder();
        bool quoted = false;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (quoted)
            {
                if (c == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"') { cell.Append('"'); i++; }
                    else quoted = false;
                }
                else cell.Append(c);
                continue;
            }
            if (c == '"' && cell.Length == 0) quoted = true;
            else if (c == d) { row.Add(cell.ToString()); cell.Clear(); }
            else if (c == '\r' || c == '\n')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(cell.ToString()); cell.Clear();
                rows.Add(row); row = new List<string>();
            }
            else cell.Append(c);
        }
        if (cell.Length > 0 || row.Count > 0) { row.Add(cell.ToString()); rows.Add(row); }
        while (rows.Count > 0 && rows[^1].All(string.IsNullOrEmpty)) rows.RemoveAt(rows.Count - 1);
        return rows;
    }

    static char Sniff(string text)
    {
        var firstLines = string.Join("\n", text.Split('\n').Take(5));
        var counts = new[] { ',', ';', '\t', '|' }.Select(ch => (ch, n: firstLines.Count(x => x == ch))).OrderByDescending(x => x.n).ToList();
        return counts[0].n > 0 ? counts[0].ch : ',';
    }

    static void WriteDelimited(List<List<string>> rows, string path, char d)
    {
        var sb = new StringBuilder();
        foreach (var row in rows)
        {
            sb.Append(string.Join(d, row.Select(c =>
            {
                if (d == '\t') return c.Replace('\t', ' ').Replace("\r", "").Replace('\n', ' ');
                return c.IndexOfAny(new[] { d, '"', '\n', '\r' }) >= 0 || c.StartsWith(' ') || c.EndsWith(' ') ? "\"" + c.Replace("\"", "\"\"") + "\"" : c;
            })));
            sb.Append("\r\n");
        }
        // BOM so Excel detects UTF-8.
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(true));
    }

    // ------------------------------------------------------------------ JSON

    static void WriteJson(List<Sheet> sheets, string path)
    {
        using var fs = File.Create(path);
        using var w = new Utf8JsonWriter(fs, new JsonWriterOptions { Indented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        void WriteSheet(Sheet s)
        {
            var header = s.Rows[0].Select((h, i) => string.IsNullOrWhiteSpace(h) ? $"column{i + 1}" : h.Trim()).ToList();
            var seen = new Dictionary<string, int>();
            for (int i = 0; i < header.Count; i++)
            {
                if (seen.TryGetValue(header[i], out var n)) { seen[header[i]] = n + 1; header[i] = $"{header[i]}_{n + 1}"; }
                else seen[header[i]] = 1;
            }
            w.WriteStartArray();
            foreach (var row in s.Rows.Skip(1))
            {
                w.WriteStartObject();
                for (int i = 0; i < header.Count; i++)
                {
                    string v = i < row.Count ? row[i] : "";
                    w.WritePropertyName(header[i]);
                    if (v.Length == 0) w.WriteNullValue();
                    else if (LooksNumeric(v) && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var num)) w.WriteNumberValue(num);
                    else if (v is "TRUE" or "true") w.WriteBooleanValue(true);
                    else if (v is "FALSE" or "false") w.WriteBooleanValue(false);
                    else w.WriteStringValue(v);
                }
                w.WriteEndObject();
            }
            w.WriteEndArray();
        }
        if (sheets.Count == 1) WriteSheet(sheets[0]);
        else
        {
            w.WriteStartObject();
            foreach (var s in sheets) { w.WritePropertyName(s.Name); WriteSheet(s); }
            w.WriteEndObject();
        }
    }

    static bool LooksNumeric(string v) =>
        Regex.IsMatch(v, @"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$");

    // ------------------------------------------------------------------ XLSX

    static readonly XNamespace S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    static readonly XNamespace Rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    static readonly XNamespace PkgRel = "http://schemas.openxmlformats.org/package/2006/relationships";

    public static List<Sheet> ReadXlsx(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        XDocument? Load(string name)
        {
            var e = zip.GetEntry(name) ?? zip.Entries.FirstOrDefault(x => x.FullName.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (e == null) return null;
            using var s = e.Open();
            return XDocument.Load(s);
        }
        var shared = Load("xl/sharedStrings.xml")?.Root?.Elements(S + "si").Select(si => string.Concat(si.Descendants(S + "t").Select(t => t.Value))).ToList() ?? new();
        var styles = Load("xl/styles.xml");
        var customFormats = styles?.Root?.Element(S + "numFmts")?.Elements(S + "numFmt")
            .ToDictionary(f => (int?)f.Attribute("numFmtId") ?? 0, f => (string?)f.Attribute("formatCode") ?? "") ?? new();
        var xfIsDate = styles?.Root?.Element(S + "cellXfs")?.Elements(S + "xf").Select(xf =>
        {
            int id = (int?)xf.Attribute("numFmtId") ?? 0;
            if (id is >= 14 and <= 22 or >= 45 and <= 47) return true;
            return customFormats.TryGetValue(id, out var code) && IsDateFormat(code);
        }).ToList() ?? new();
        var rels = Load("xl/_rels/workbook.xml.rels")?.Root?.Elements(PkgRel + "Relationship")
            .ToDictionary(r => (string?)r.Attribute("Id") ?? "", r => (string?)r.Attribute("Target") ?? "") ?? new();
        var workbook = Load("xl/workbook.xml") ?? throw new OpException("Not a valid XLSX file.");
        var result = new List<Sheet>();
        foreach (var sheet in workbook.Descendants(S + "sheet"))
        {
            string name = (string?)sheet.Attribute("name") ?? $"Sheet{result.Count + 1}";
            string rid = (string?)sheet.Attribute(Rel + "id") ?? "";
            if (!rels.TryGetValue(rid, out var target)) continue;
            string part = target.StartsWith('/') ? target.TrimStart('/') : "xl/" + target;
            var xml = Load(part);
            if (xml == null) continue;
            var rows = new List<List<string>>();
            foreach (var row in xml.Descendants(S + "row"))
            {
                int rIndex = ((int?)row.Attribute("r") ?? rows.Count + 1) - 1;
                while (rows.Count < rIndex) rows.Add(new List<string>());
                var cells = new List<string>();
                foreach (var c in row.Elements(S + "c"))
                {
                    string r = (string?)c.Attribute("r") ?? "";
                    int col = r.Length > 0 ? ColumnIndex(r) : cells.Count;
                    while (cells.Count < col) cells.Add("");
                    string t = (string?)c.Attribute("t") ?? "n";
                    int style = (int?)c.Attribute("s") ?? 0;
                    string v = c.Element(S + "v")?.Value ?? "";
                    string value = t switch
                    {
                        "s" => int.TryParse(v, out var si) && si < shared.Count ? shared[si] : "",
                        "inlineStr" => string.Concat(c.Descendants(S + "t").Select(x => x.Value)),
                        "b" => v == "1" ? "TRUE" : "FALSE",
                        "str" or "e" => v,
                        _ => style < xfIsDate.Count && xfIsDate[style] && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? FormatDate(d) : v,
                    };
                    cells.Add(value);
                }
                rows.Add(cells);
            }
            Trim(rows);
            result.Add(new Sheet(name, rows));
        }
        return result;
    }

    static void Trim(List<List<string>> rows)
    {
        while (rows.Count > 0 && rows[^1].All(string.IsNullOrEmpty)) rows.RemoveAt(rows.Count - 1);
        int width = rows.Count == 0 ? 0 : rows.Max(r => { int i = r.Count; while (i > 0 && string.IsNullOrEmpty(r[i - 1])) i--; return i; });
        foreach (var r in rows) { if (r.Count > width) r.RemoveRange(width, r.Count - width); while (r.Count < width) r.Add(""); }
    }

    static bool IsDateFormat(string code)
    {
        var stripped = Regex.Replace(code, "\"[^\"]*\"|\\[[^\\]]*\\]|\\\\.", "");
        return Regex.IsMatch(stripped, "[dmyhs]", RegexOptions.IgnoreCase) && !stripped.Contains('#') && !stripped.Contains('0');
    }

    static string FormatDate(double serial)
    {
        try
        {
            var dt = DateTime.FromOADate(serial);
            return dt.TimeOfDay == TimeSpan.Zero ? dt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : dt.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        }
        catch { return serial.ToString(CultureInfo.InvariantCulture); }
    }

    static int ColumnIndex(string cellRef)
    {
        int col = 0;
        foreach (char ch in cellRef)
        {
            if (!char.IsLetter(ch)) break;
            col = col * 26 + (char.ToUpperInvariant(ch) - 'A' + 1);
        }
        return col - 1;
    }

    static string ColumnName(int index)
    {
        var sb = new StringBuilder();
        for (index++; index > 0; index = (index - 1) / 26) sb.Insert(0, (char)('A' + (index - 1) % 26));
        return sb.ToString();
    }

    static string X(string s) => SecurityElement.Escape(new string(s.Where(ch => ch == '\t' || ch == '\n' || ch == '\r' || ch >= 0x20).ToArray())) ?? "";

    public static void WriteXlsx(List<Sheet> sheets, string path)
    {
        if (File.Exists(path)) File.Delete(path);
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        void Add(string name, string xml)
        {
            using var w = new StreamWriter(zip.CreateEntry(name, CompressionLevel.Optimal).Open(), new UTF8Encoding(false));
            w.Write(xml);
        }
        var ct = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>");
        var wbSheets = new StringBuilder();
        var wbRels = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>");
        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < sheets.Count; i++)
        {
            string name = Regex.Replace(sheets[i].Name, @"[\[\]\*\?/\\:]", "_");
            if (name.Length > 31) name = name[..31];
            if (name.Length == 0 || !usedNames.Add(name)) { name = $"Sheet{i + 1}"; usedNames.Add(name); }
            ct.Append($"<Override PartName=\"/xl/worksheets/sheet{i + 1}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>");
            wbSheets.Append($"<sheet name=\"{X(name)}\" sheetId=\"{i + 1}\" r:id=\"rId{i + 1}\"/>");
            wbRels.Append($"<Relationship Id=\"rId{i + 1}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{i + 1}.xml\"/>");
            var data = new StringBuilder();
            var rows = sheets[i].Rows;
            for (int r = 0; r < rows.Count; r++)
            {
                data.Append($"<row r=\"{r + 1}\">");
                for (int c = 0; c < rows[r].Count; c++)
                {
                    string v = rows[r][c];
                    if (v.Length == 0) continue;
                    string cellRef = ColumnName(c) + (r + 1);
                    string style = r == 0 ? " s=\"1\"" : "";
                    if (LooksNumeric(v) && v.Length < 16) data.Append($"<c r=\"{cellRef}\"{style}><v>{v}</v></c>");
                    else data.Append($"<c r=\"{cellRef}\" t=\"inlineStr\"{style}><is><t xml:space=\"preserve\">{X(v)}</t></is></c>");
                }
                data.Append("</row>");
            }
            Add($"xl/worksheets/sheet{i + 1}.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><sheetData>" + data + "</sheetData></worksheet>");
        }
        ct.Append("</Types>");
        wbRels.Append("</Relationships>");
        Add("[Content_Types].xml", ct.ToString());
        Add("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
        Add("xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>" + wbSheets + "</sheets></workbook>");
        Add("xl/_rels/workbook.xml.rels", wbRels.ToString());
        Add("xl/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs></styleSheet>");
    }

    // ------------------------------------------------------------------ ODS

    static readonly XNamespace OOffice = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
    static readonly XNamespace OTable = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
    static readonly XNamespace OText = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";

    public static List<Sheet> ReadOds(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        var entry = zip.GetEntry("content.xml") ?? throw new OpException("Not an OpenDocument spreadsheet.");
        XDocument content;
        using (var s = entry.Open()) content = XDocument.Load(s);
        var result = new List<Sheet>();
        foreach (var table in content.Descendants(OTable + "table"))
        {
            var rows = new List<List<string>>();
            foreach (var row in table.Descendants(OTable + "table-row"))
            {
                var cells = new List<string>();
                foreach (var cell in row.Elements().Where(e => e.Name == OTable + "table-cell" || e.Name == OTable + "covered-table-cell"))
                {
                    int repeat = Math.Min((int?)cell.Attribute(OTable + "number-columns-repeated") ?? 1, 512);
                    string type = (string?)cell.Attribute(OOffice + "value-type") ?? "";
                    string value = type switch
                    {
                        "float" or "percentage" or "currency" => (string?)cell.Attribute(OOffice + "value") ?? "",
                        "date" => ((string?)cell.Attribute(OOffice + "date-value") ?? "").Replace("T00:00:00", ""),
                        "boolean" => ((string?)cell.Attribute(OOffice + "boolean-value")) == "true" ? "TRUE" : "FALSE",
                        _ => string.Join("\n", cell.Elements(OText + "p").Select(p => p.Value)),
                    };
                    for (int i = 0; i < repeat; i++) cells.Add(value);
                }
                int rowRepeat = Math.Min((int?)row.Attribute(OTable + "number-rows-repeated") ?? 1, 1024);
                for (int i = 0; i < rowRepeat; i++) rows.Add(new List<string>(cells));
            }
            Trim(rows);
            result.Add(new Sheet((string?)table.Attribute(OTable + "name") ?? $"Sheet{result.Count + 1}", rows));
        }
        return result;
    }

    public static void WriteOds(List<Sheet> sheets, string path)
    {
        if (File.Exists(path)) File.Delete(path);
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        using (var w = new StreamWriter(zip.CreateEntry("mimetype", CompressionLevel.NoCompression).Open(), Encoding.ASCII))
            w.Write("application/vnd.oasis.opendocument.spreadsheet");
        void Add(string name, string xml)
        {
            using var w = new StreamWriter(zip.CreateEntry(name, CompressionLevel.Optimal).Open(), new UTF8Encoding(false));
            w.Write(xml);
        }
        Add("META-INF/manifest.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>");
        var body = new StringBuilder();
        foreach (var s in sheets)
        {
            body.Append($"<table:table table:name=\"{X(s.Name)}\">");
            foreach (var row in s.Rows)
            {
                body.Append("<table:table-row>");
                foreach (var v in row)
                {
                    if (v.Length == 0) body.Append("<table:table-cell/>");
                    else if (LooksNumeric(v)) body.Append($"<table:table-cell office:value-type=\"float\" office:value=\"{v}\"><text:p>{v}</text:p></table:table-cell>");
                    else body.Append($"<table:table-cell office:value-type=\"string\"><text:p>{X(v)}</text:p></table:table-cell>");
                }
                body.Append("</table:table-row>");
            }
            body.Append("</table:table>");
        }
        Add("content.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:spreadsheet>" + body + "</office:spreadsheet></office:body></office:document-content>");
    }
}
