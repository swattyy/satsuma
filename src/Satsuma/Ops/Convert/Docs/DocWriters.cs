using System.IO.Compression;
using System.Net;
using System.Security;
using System.Text;

namespace Satsuma.Ops.Convert.Docs;

/// <summary>Writers from <see cref="DocModel"/> to TXT, Markdown, HTML, DOCX, EPUB and RTF.</summary>
public static class DocWriters
{
    static readonly UTF8Encoding Utf8NoBom = new(false);

    public static void Write(DocModel doc, string path, string format)
    {
        switch (format)
        {
            case "txt": File.WriteAllText(path, doc.ToPlainText(), Utf8NoBom); break;
            case "md": File.WriteAllText(path, Markdown(doc), Utf8NoBom); break;
            case "html": File.WriteAllText(path, Html(doc), Utf8NoBom); break;
            case "docx": Docx(doc, path); break;
            case "epub": Epub(doc, path); break;
            case "rtf": File.WriteAllText(path, Rtf(doc), Encoding.ASCII); break;
            case "pdf": PdfLayout.Write(doc, path); break;
            default: throw new OpException($"Can't write {format.ToUpperInvariant()} documents.");
        }
    }

    // ------------------------------------------------------------------ Markdown

    public static string Markdown(DocModel doc)
    {
        var sb = new StringBuilder();
        BlockType? prev = null;
        foreach (var b in doc.Blocks)
        {
            if (prev != null && !(prev == BlockType.ListItem && b.Type == BlockType.ListItem)) sb.AppendLine();
            switch (b.Type)
            {
                case BlockType.Heading: sb.Append(new string('#', Math.Clamp(b.Level, 1, 6))).Append(' ').AppendLine(MdInlines(b.Inlines).Replace("\n", " ")); break;
                case BlockType.Paragraph: sb.AppendLine(MdInlines(b.Inlines).Replace("\n", "  \n")); break;
                case BlockType.Quote: sb.AppendLine("> " + MdInlines(b.Inlines).Replace("\n", "\n> ")); break;
                case BlockType.ListItem: sb.Append(new string(' ', b.Level * 3)).Append(b.Ordered ? $"{b.Number}. " : "- ").AppendLine(MdInlines(b.Inlines).Replace("\n", " ")); break;
                case BlockType.Code: sb.AppendLine("```").AppendLine(b.CodeText).AppendLine("```"); break;
                case BlockType.Rule: sb.AppendLine("---"); break;
                case BlockType.PageBreak: sb.AppendLine("---"); break;
                case BlockType.Table when b.Rows is { Count: > 0 }:
                    int cols = b.Rows.Max(r => r.Count);
                    string Row(List<string> r) => "| " + string.Join(" | ", Enumerable.Range(0, cols).Select(i => (i < r.Count ? r[i] : "").Replace("|", "\\|").Replace("\n", " "))) + " |";
                    sb.AppendLine(Row(b.Rows[0]));
                    sb.AppendLine("|" + string.Concat(Enumerable.Repeat(" --- |", cols)));
                    foreach (var r in b.Rows.Skip(1)) sb.AppendLine(Row(r));
                    break;
            }
            prev = b.Type;
        }
        return sb.ToString();
    }

    static string MdInlines(List<Inline> inlines)
    {
        var sb = new StringBuilder();
        foreach (var i in inlines)
        {
            string t = i.Code ? $"`{i.Text}`" : EscapeMd(i.Text);
            if (i.Text.Trim().Length > 0 && !i.Code)
            {
                // Keep surrounding spaces outside the markers: "**bold** text".
                string lead = t[..(t.Length - t.TrimStart().Length)], trail = t[t.TrimEnd().Length..];
                t = t.Trim();
                if (i.Bold && i.Italic) t = $"***{t}***";
                else if (i.Bold) t = $"**{t}**";
                else if (i.Italic) t = $"*{t}*";
                t = lead + t + trail;
            }
            if (i.Link != null && !i.Link.StartsWith('#')) t = $"[{t}]({i.Link})";
            sb.Append(t);
        }
        return sb.ToString();
    }

    static string EscapeMd(string s) => s.Replace("\\", "\\\\").Replace("*", "\\*").Replace("_", "\\_").Replace("`", "\\`");

    // ------------------------------------------------------------------ HTML

    public const string Css = @"
:root { color-scheme: light dark; }
body { font: 16px/1.6 'Segoe UI Variable Text', 'Segoe UI', system-ui, sans-serif; max-width: 46rem; margin: 3rem auto; padding: 0 1.25rem; color: #24201c; background: #fff; }
@media (prefers-color-scheme: dark) { body { color: #ece7e2; background: #1c1b1f; } code, pre { background: #2a2930 !important; } th { background: #2a2930 !important; } td, th { border-color: #3a3940 !important; } }
h1, h2, h3, h4 { line-height: 1.25; margin: 1.6em 0 .5em; } h1 { font-size: 2em; } h2 { font-size: 1.5em; }
pre { background: #f5f2ee; padding: 1rem; border-radius: 8px; overflow: auto; } code { font-family: 'Cascadia Mono', Consolas, monospace; font-size: .92em; background: #f5f2ee; padding: .1em .3em; border-radius: 4px; }
pre code { padding: 0; background: none; } blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid #ff7a1a; color: #6b625b; }
table { border-collapse: collapse; margin: 1em 0; } td, th { border: 1px solid #ddd6cf; padding: .4em .7em; text-align: left; } th { background: #f5f2ee; }
a { color: #e8650f; } hr { border: 0; border-top: 1px solid #ddd6cf; margin: 2em 0; } img { max-width: 100%; }";

    public static string Html(DocModel doc, bool xhtml = false) => Page(doc.GuessTitle(), Body(doc, xhtml), xhtml);

    public static string Page(string title, string body, bool xhtml = false)
    {
        string head = xhtml
            ? "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
            : "<!doctype html>\n<html lang=\"en\">";
        string css = xhtml ? "<link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>" : $"<style>{Css}</style>";
        return $"{head}\n<head>\n<meta charset=\"utf-8\"{(xhtml ? "/" : "")}>\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"{(xhtml ? "/" : "")}>\n<title>{Esc(title)}</title>\n{css}\n</head>\n<body>\n{body}</body>\n</html>\n";
    }

    public static string Body(DocModel doc, bool xhtml = false)
    {
        var sb = new StringBuilder();
        var openLists = new Stack<bool>();
        string br = xhtml ? "<br/>" : "<br>";
        void CloseLists(int toDepth) { while (openLists.Count > toDepth) { sb.AppendLine(openLists.Pop() ? "</li></ol>" : "</li></ul>"); } }

        foreach (var b in doc.Blocks)
        {
            if (b.Type != BlockType.ListItem) CloseLists(0);
            switch (b.Type)
            {
                case BlockType.Heading: int h = Math.Clamp(b.Level, 1, 6); sb.AppendLine($"<h{h}>{HtmlInlines(b.Inlines, br)}</h{h}>"); break;
                case BlockType.Paragraph: sb.AppendLine($"<p>{HtmlInlines(b.Inlines, br)}</p>"); break;
                case BlockType.Quote: sb.AppendLine($"<blockquote><p>{HtmlInlines(b.Inlines, br)}</p></blockquote>"); break;
                case BlockType.Code: sb.AppendLine($"<pre><code>{Esc(b.CodeText ?? "")}</code></pre>"); break;
                case BlockType.Rule: sb.AppendLine(xhtml ? "<hr/>" : "<hr>"); break;
                case BlockType.PageBreak: sb.AppendLine(xhtml ? "<hr/>" : "<hr style=\"page-break-after:always;border:0\">"); break;
                case BlockType.ListItem:
                    int depth = b.Level + 1;
                    if (openLists.Count >= depth)
                    {
                        CloseLists(depth);
                        sb.Append("</li>");
                    }
                    while (openLists.Count < depth)
                    {
                        sb.Append(b.Ordered ? (b.Number != 1 && openLists.Count == depth - 1 ? $"<ol start=\"{b.Number}\">" : "<ol>") : "<ul>");
                        openLists.Push(b.Ordered);
                    }
                    sb.Append($"<li>{HtmlInlines(b.Inlines, br)}");
                    break;
                case BlockType.Table when b.Rows is { Count: > 0 }:
                    sb.AppendLine("<table>");
                    for (int r = 0; r < b.Rows.Count; r++)
                    {
                        string tag = r == 0 ? "th" : "td";
                        sb.Append("<tr>");
                        foreach (var cell in b.Rows[r]) sb.Append($"<{tag}>{Esc(cell).Replace("\n", br)}</{tag}>");
                        sb.AppendLine("</tr>");
                    }
                    sb.AppendLine("</table>");
                    break;
            }
        }
        CloseLists(0);
        return sb.ToString();
    }

    static string HtmlInlines(List<Inline> inlines, string br)
    {
        var sb = new StringBuilder();
        foreach (var i in inlines)
        {
            string t = Esc(i.Text).Replace("\n", br);
            if (i.Code) t = $"<code>{t}</code>";
            if (i.Italic) t = $"<em>{t}</em>";
            if (i.Bold) t = $"<strong>{t}</strong>";
            if (i.Link != null) t = $"<a href=\"{Esc(i.Link)}\">{t}</a>";
            sb.Append(t);
        }
        return sb.ToString();
    }

    public static string Esc(string s) => WebUtility.HtmlEncode(s).Replace("&#39;", "'");

    // ------------------------------------------------------------------ DOCX

    public static void Docx(DocModel doc, string path)
    {
        if (File.Exists(path)) File.Delete(path);
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        void Add(string name, string xml)
        {
            var e = zip.CreateEntry(name, CompressionLevel.Optimal);
            using var w = new StreamWriter(e.Open(), Utf8NoBom);
            w.Write(xml);
        }
        var links = new List<string>();
        var nums = new List<bool>(); // one <w:num> per list run; true = ordered
        var body = new StringBuilder();
        int currentNum = 0;
        BlockType? prev = null;
        foreach (var b in doc.Blocks)
        {
            switch (b.Type)
            {
                case BlockType.Heading:
                    body.Append($"<w:p><w:pPr><w:pStyle w:val=\"Heading{Math.Clamp(b.Level, 1, 6)}\"/></w:pPr>{Runs(b.Inlines)}</w:p>");
                    break;
                case BlockType.Paragraph:
                    body.Append($"<w:p>{Runs(b.Inlines)}</w:p>");
                    break;
                case BlockType.Quote:
                    body.Append($"<w:p><w:pPr><w:pStyle w:val=\"Quote\"/></w:pPr>{Runs(b.Inlines)}</w:p>");
                    break;
                case BlockType.ListItem:
                    if (prev != BlockType.ListItem) { nums.Add(b.Ordered); currentNum = nums.Count; }
                    body.Append($"<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"{Math.Clamp(b.Level, 0, 8)}\"/><w:numId w:val=\"{currentNum}\"/></w:numPr></w:pPr>{Runs(b.Inlines)}</w:p>");
                    break;
                case BlockType.Code:
                    foreach (var line in (b.CodeText ?? "").Split('\n'))
                        body.Append($"<w:p><w:pPr><w:pStyle w:val=\"Code\"/></w:pPr><w:r><w:t xml:space=\"preserve\">{X(line.TrimEnd('\r'))}</w:t></w:r></w:p>");
                    break;
                case BlockType.Rule:
                    body.Append("<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D6CFC8\"/></w:pBdr></w:pPr></w:p>");
                    break;
                case BlockType.PageBreak:
                    body.Append("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>");
                    break;
                case BlockType.Table when b.Rows is { Count: > 0 }:
                    int cols = b.Rows.Max(r => r.Count);
                    body.Append("<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/></w:tblPr><w:tblGrid>");
                    for (int c = 0; c < cols; c++) body.Append("<w:gridCol/>");
                    body.Append("</w:tblGrid>");
                    for (int r = 0; r < b.Rows.Count; r++)
                    {
                        body.Append("<w:tr>");
                        for (int c = 0; c < cols; c++)
                        {
                            string text = c < b.Rows[r].Count ? b.Rows[r][c] : "";
                            string rpr = r == 0 ? "<w:rPr><w:b/></w:rPr>" : "";
                            body.Append("<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>");
                            foreach (var line in text.Split('\n'))
                                body.Append($"<w:p><w:r>{rpr}<w:t xml:space=\"preserve\">{X(line)}</w:t></w:r></w:p>");
                            body.Append("</w:tc>");
                        }
                        body.Append("</w:tr>");
                    }
                    body.Append("</w:tbl><w:p/>");
                    break;
            }
            prev = b.Type;
        }

        string Runs(List<Inline> inlines)
        {
            var sb = new StringBuilder();
            foreach (var i in inlines)
            {
                var rpr = new StringBuilder();
                if (i.Link != null) rpr.Append("<w:rStyle w:val=\"Hyperlink\"/>");
                if (i.Bold) rpr.Append("<w:b/>");
                if (i.Italic) rpr.Append("<w:i/>");
                if (i.Code) rpr.Append("<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F0EC\"/>");
                string props = rpr.Length > 0 ? $"<w:rPr>{rpr}</w:rPr>" : "";
                var parts = i.Text.Split('\n');
                var run = new StringBuilder();
                for (int p = 0; p < parts.Length; p++)
                {
                    if (p > 0) run.Append("<w:br/>");
                    var tabs = parts[p].Split('\t');
                    for (int t = 0; t < tabs.Length; t++)
                    {
                        if (t > 0) run.Append("<w:tab/>");
                        if (tabs[t].Length > 0) run.Append($"<w:t xml:space=\"preserve\">{X(tabs[t])}</w:t>");
                    }
                }
                string r = $"<w:r>{props}{run}</w:r>";
                if (i.Link != null && Uri.TryCreate(i.Link, UriKind.Absolute, out _))
                {
                    links.Add(i.Link);
                    r = $"<w:hyperlink r:id=\"rIdL{links.Count}\">{r}</w:hyperlink>";
                }
                sb.Append(r);
            }
            return sb.ToString();
        }

        Add("[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>" +
            "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>" +
            "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>" +
            "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>");
        Add("_rels/.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>" +
            "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>");
        Add("docProps/core.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" +
            $"<dc:title>{X(doc.GuessTitle())}</dc:title><dc:creator>Satsuma</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}</dcterms:created></cp:coreProperties>");

        var rels = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rIdS\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" +
            "<Relationship Id=\"rIdN\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>");
        for (int i = 0; i < links.Count; i++)
            rels.Append($"<Relationship Id=\"rIdL{i + 1}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"{X(links[i])}\" TargetMode=\"External\"/>");
        rels.Append("</Relationships>");
        Add("word/_rels/document.xml.rels", rels.ToString());

        Add("word/document.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>" +
            body + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>");

        var styles = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
            "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault>" +
            "<w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>" +
            "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>");
        int[] sizes = { 40, 32, 28, 24, 22, 22 };
        for (int h = 1; h <= 6; h++)
            styles.Append($"<w:style w:type=\"paragraph\" w:styleId=\"Heading{h}\"><w:name w:val=\"heading {h}\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>" +
                          $"<w:pPr><w:keepNext/><w:spacing w:before=\"{(h <= 2 ? 360 : 240)}\" w:after=\"120\"/><w:outlineLvl w:val=\"{h - 1}\"/></w:pPr><w:rPr><w:b/><w:color w:val=\"{(h == 1 ? "1F1A16" : "2B2622")}\"/><w:sz w:val=\"{sizes[h - 1]}\"/></w:rPr></w:style>");
        styles.Append("<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:ind w:left=\"567\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"FF7A1A\"/></w:pBdr></w:pPr><w:rPr><w:i/><w:color w:val=\"6B625B\"/></w:rPr></w:style>" +
                      "<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F0EC\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:sz w:val=\"19\"/></w:rPr></w:style>" +
                      "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"60\"/><w:contextualSpacing/></w:pPr></w:style>" +
                      "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>" +
                      "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:tblPr><w:tblBorders>" +
                      "<w:top w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/><w:left w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/><w:right w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/>" +
                      "<w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"D6CFC8\"/></w:tblBorders><w:tblCellMar><w:left w:w=\"108\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>" +
                      "</w:styles>");
        Add("word/styles.xml", styles.ToString());

        var numbering = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">");
        string[] bullets = { "•", "◦", "▪" };
        numbering.Append("<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>");
        for (int l = 0; l < 9; l++)
            numbering.Append($"<w:lvl w:ilvl=\"{l}\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"{bullets[l % 3]}\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"{720 + 360 * l}\" w:hanging=\"360\"/></w:pPr></w:lvl>");
        numbering.Append("</w:abstractNum><w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>");
        string[] fmts = { "decimal", "lowerLetter", "lowerRoman" };
        for (int l = 0; l < 9; l++)
            numbering.Append($"<w:lvl w:ilvl=\"{l}\"><w:start w:val=\"1\"/><w:numFmt w:val=\"{fmts[l % 3]}\"/><w:lvlText w:val=\"%{l + 1}.\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"{720 + 360 * l}\" w:hanging=\"360\"/></w:pPr></w:lvl>");
        numbering.Append("</w:abstractNum>");
        for (int n = 0; n < nums.Count; n++)
            numbering.Append($"<w:num w:numId=\"{n + 1}\"><w:abstractNumId w:val=\"{(nums[n] ? 1 : 0)}\"/>{(nums[n] ? "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" : "")}</w:num>");
        numbering.Append("</w:numbering>");
        Add("word/numbering.xml", numbering.ToString());
    }

    static string X(string s) => SecurityElement.Escape(StripInvalidXml(s)) ?? "";

    static string StripInvalidXml(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s) if (ch == '\t' || ch == '\n' || ch == '\r' || ch >= 0x20 && ch != 0xFFFE && ch != 0xFFFF) sb.Append(ch);
        return sb.ToString();
    }

    // ------------------------------------------------------------------ EPUB 3

    public static void Epub(DocModel doc, string path)
    {
        if (File.Exists(path)) File.Delete(path);
        string title = doc.GuessTitle();
        if (string.IsNullOrWhiteSpace(title)) title = Path.GetFileNameWithoutExtension(path);

        // Split into chapters at H1 (or H2 if there are no H1s).
        int splitLevel = doc.Blocks.Any(b => b.Type == BlockType.Heading && b.Level == 1) ? 1 : 2;
        var chapters = new List<DocModel>();
        var current = new DocModel();
        foreach (var b in doc.Blocks)
        {
            if (b.Type == BlockType.PageBreak) continue;
            if (b.Type == BlockType.Heading && b.Level <= splitLevel && current.Blocks.Count > 0) { chapters.Add(current); current = new DocModel(); }
            current.Blocks.Add(b);
        }
        if (current.Blocks.Count > 0 || chapters.Count == 0) chapters.Add(current);

        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        var mime = zip.CreateEntry("mimetype", CompressionLevel.NoCompression);
        using (var w = new StreamWriter(mime.Open(), Encoding.ASCII)) w.Write("application/epub+zip");
        void Add(string name, string text)
        {
            var e = zip.CreateEntry(name, CompressionLevel.Optimal);
            using var w = new StreamWriter(e.Open(), Utf8NoBom);
            w.Write(text);
        }
        Add("META-INF/container.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>");
        Add("OEBPS/style.css", Css);

        var manifest = new StringBuilder();
        var spine = new StringBuilder();
        var nav = new StringBuilder();
        for (int i = 0; i < chapters.Count; i++)
        {
            string file = $"chapter-{i + 1:000}.xhtml";
            string chTitle = chapters[i].Blocks.FirstOrDefault(b => b.Type == BlockType.Heading)?.PlainText ?? (chapters.Count == 1 ? title : $"Part {i + 1}");
            Add("OEBPS/" + file, Page(chTitle, Body(chapters[i], xhtml: true), xhtml: true));
            manifest.Append($"<item id=\"c{i + 1}\" href=\"{file}\" media-type=\"application/xhtml+xml\"/>");
            spine.Append($"<itemref idref=\"c{i + 1}\"/>");
            nav.Append($"<li><a href=\"{file}\">{Esc(chTitle)}</a></li>");
        }
        Add("OEBPS/nav.xhtml", Page(title, $"<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>{nav}</ol></nav>\n", xhtml: true));
        Add("OEBPS/content.opf",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"uid\">" +
            $"<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"uid\">urn:uuid:{Guid.NewGuid()}</dc:identifier><dc:title>{Esc(title)}</dc:title><dc:language>en</dc:language>" +
            $"<meta property=\"dcterms:modified\">{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}</meta></metadata>" +
            $"<manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>{manifest}</manifest>" +
            $"<spine>{spine}</spine></package>");
    }

    // ------------------------------------------------------------------ RTF

    public static string Rtf(DocModel doc)
    {
        var sb = new StringBuilder(@"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Calibri;}{\f1\fmodern Consolas;}}\viewkind4\uc1\pard\sa160\sl264\slmult1\f0\fs22 ");
        int[] hs = { 40, 32, 28, 24, 22, 22 };
        foreach (var b in doc.Blocks)
        {
            switch (b.Type)
            {
                case BlockType.Heading: sb.Append($@"\pard\sb240\sa120\b\fs{hs[Math.Clamp(b.Level, 1, 6) - 1]} {R(b.PlainText)}\b0\fs22\par "); break;
                case BlockType.ListItem: sb.Append($@"\pard\li{360 + 360 * b.Level}\fi-240 {(b.Ordered ? b.Number + "." : @"\bullet")}\tab {RInl(b.Inlines)}\par "); break;
                case BlockType.Code: sb.Append($@"\pard\f1\fs19 {R(b.CodeText ?? "").Replace("\n", @"\line ")}\f0\fs22\par "); break;
                case BlockType.Quote: sb.Append($@"\pard\li567\i {RInl(b.Inlines)}\i0\par "); break;
                case BlockType.Rule: sb.Append(@"\pard\brdrb\brdrs\brdrw10\brsp20 \par "); break;
                case BlockType.PageBreak: sb.Append(@"\page "); break;
                case BlockType.Table when b.Rows != null:
                    foreach (var row in b.Rows) sb.Append($@"\pard {R(string.Join("\t", row))}\par ");
                    break;
                default: sb.Append($@"\pard\sa160 {RInl(b.Inlines)}\par "); break;
            }
        }
        sb.Append('}');
        return sb.ToString();

        static string RInl(List<Inline> inlines) => string.Concat(inlines.Select(i =>
            (i.Bold ? @"{\b " : "") + (i.Italic ? @"{\i " : "") + (i.Code ? @"{\f1 " : "") + R(i.Text) + (i.Code ? "}" : "") + (i.Italic ? "}" : "") + (i.Bold ? "}" : "")));

        static string R(string s)
        {
            var o = new StringBuilder();
            foreach (char ch in s)
            {
                if (ch == '\\' || ch == '{' || ch == '}') o.Append('\\').Append(ch);
                else if (ch == '\n') o.Append(@"\line ");
                else if (ch == '\t') o.Append(@"\tab ");
                else if (ch > 127) o.Append($@"\u{(short)ch}?");
                else o.Append(ch);
            }
            return o.ToString();
        }
    }
}
