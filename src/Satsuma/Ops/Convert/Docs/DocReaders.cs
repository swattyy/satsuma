using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Satsuma.Core;

namespace Satsuma.Ops.Convert.Docs;

/// <summary>Readers that turn common document formats into a <see cref="DocModel"/>.</summary>
public static class DocReaders
{
    public static DocModel Read(string path)
    {
        var ext = FileKinds.Ext(path);
        var doc = ext switch
        {
            "md" or "markdown" or "mdown" or "mkd" => Markdown(ReadText(path)),
            "html" or "htm" or "xhtml" => Html(ReadText(path)),
            "docx" or "docm" or "dotx" => Docx(path),
            "epub" => Epub(path),
            "rtf" => Rtf(File.ReadAllText(path, Encoding.Latin1)),
            "odt" => Odt(path),
            "txt" or "text" or "log" or "srt" or "vtt" or "csv" => Text(ReadText(path)),
            _ => throw new OpException($"Can't read .{ext} documents without Microsoft Word."),
        };
        if (string.IsNullOrWhiteSpace(doc.Title)) doc.Title = FileKinds.BaseName(path);
        return doc.Normalize();
    }

    public static string ReadText(string path)
    {
        var bytes = File.ReadAllBytes(path);
        // BOM-aware, then strict UTF-8, then the system ANSI code page.
        if (bytes.Length >= 2 && (bytes[0] == 0xFF && bytes[1] == 0xFE || bytes[0] == 0xFE && bytes[1] == 0xFF) || bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return new StreamReader(new MemoryStream(bytes), true).ReadToEnd();
        try { return new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException)
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(System.Globalization.CultureInfo.CurrentCulture.TextInfo.ANSICodePage).GetString(bytes);
        }
    }

    // ------------------------------------------------------------------ plain text

    public static DocModel Text(string text)
    {
        var doc = new DocModel();
        text = text.Replace("\r\n", "\n").Replace('\r', '\n');
        foreach (var chunk in Regex.Split(text, @"\n[ \t]*\n+"))
        {
            var t = chunk.TrimEnd();
            if (t.Trim().Length == 0) continue;
            if (t.Contains('\f')) doc.Blocks.Add(new Block { Type = BlockType.PageBreak });
            doc.Blocks.Add(Block.Para(t.Replace("\f", "")));
        }
        return doc;
    }

    // ------------------------------------------------------------------ markdown (Markdig AST)

    public static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder().UseAdvancedExtensions().Build();

    public static DocModel Markdown(string md)
    {
        var doc = new DocModel();
        var ast = Markdig.Markdown.Parse(md, Pipeline);
        foreach (var block in ast) AddMdBlock(doc, block, 0, false);
        return doc;
    }

    static void AddMdBlock(DocModel doc, Markdig.Syntax.Block block, int listLevel, bool inQuote)
    {
        switch (block)
        {
            case HeadingBlock h:
                doc.Blocks.Add(new Block { Type = BlockType.Heading, Level = h.Level, Inlines = MdInlines(h.Inline) });
                break;
            case ParagraphBlock p:
                doc.Blocks.Add(new Block { Type = inQuote ? BlockType.Quote : BlockType.Paragraph, Inlines = MdInlines(p.Inline) });
                break;
            case ListBlock list:
                int n = int.TryParse(list.OrderedStart, out var start) ? start : 1;
                foreach (var child in list)
                {
                    if (child is not ListItemBlock item) continue;
                    bool first = true;
                    foreach (var sub in item)
                    {
                        if (sub is ParagraphBlock para && first)
                        {
                            doc.Blocks.Add(new Block { Type = BlockType.ListItem, Level = listLevel, Ordered = list.IsOrdered, Number = n, Inlines = MdInlines(para.Inline) });
                            first = false;
                        }
                        else AddMdBlock(doc, sub, listLevel + 1, inQuote);
                    }
                    n++;
                }
                break;
            case FencedCodeBlock or CodeBlock:
                var code = (LeafBlock)block;
                doc.Blocks.Add(new Block { Type = BlockType.Code, CodeText = code.Lines.ToString().TrimEnd('\n', '\r') });
                break;
            case QuoteBlock q:
                foreach (var sub in q) AddMdBlock(doc, sub, listLevel, true);
                break;
            case ThematicBreakBlock:
                doc.Blocks.Add(new Block { Type = BlockType.Rule });
                break;
            case Table table:
                var rows = new List<List<string>>();
                foreach (var r in table)
                {
                    if (r is not TableRow row) continue;
                    var cells = new List<string>();
                    foreach (var c in row)
                        if (c is TableCell cell)
                            cells.Add(string.Join(" ", cell.OfType<ParagraphBlock>().Select(pb => string.Concat(MdInlines(pb.Inline).Select(i => i.Text)))));
                    rows.Add(cells);
                }
                doc.Blocks.Add(new Block { Type = BlockType.Table, Rows = rows });
                break;
            case HtmlBlock html:
                var text = WebUtility.HtmlDecode(Regex.Replace(html.Lines.ToString(), "<[^>]+>", " ")).Trim();
                if (text.Length > 0) doc.Blocks.Add(Block.Para(text));
                break;
            case ContainerBlock container:
                foreach (var sub in container) AddMdBlock(doc, sub, listLevel, inQuote);
                break;
        }
    }

    static List<Inline> MdInlines(ContainerInline? container)
    {
        var result = new List<Inline>();
        if (container != null) Walk(container, new Inline(), result);
        return result;

        static void Walk(ContainerInline c, Inline style, List<Inline> output)
        {
            foreach (var inline in c)
            {
                switch (inline)
                {
                    case LiteralInline lit: output.Add(style.With(lit.Content.ToString())); break;
                    case CodeInline code: output.Add(new Inline(code.Content, style.Bold, style.Italic, true, style.Link)); break;
                    case LineBreakInline: output.Add(style.With(inline is LineBreakInline { IsHard: true } ? "\n" : " ")); break;
                    case EmphasisInline em:
                        var s = new Inline("", style.Bold || em.DelimiterCount >= 2, style.Italic || em.DelimiterCount == 1 || em.DelimiterCount == 3, style.Code, style.Link);
                        Walk(em, s, output);
                        break;
                    case LinkInline link when link.IsImage:
                        output.Add(style.With("[image]"));
                        break;
                    case LinkInline link:
                        Walk(link, new Inline("", style.Bold, style.Italic, style.Code, link.Url), output);
                        break;
                    case AutolinkInline auto: output.Add(new Inline(auto.Url, style.Bold, style.Italic, false, auto.Url)); break;
                    case HtmlEntityInline ent: output.Add(style.With(ent.Transcoded.ToString())); break;
                    case ContainerInline other: Walk(other, style, output); break;
                }
            }
        }
    }

    // ------------------------------------------------------------------ HTML (tolerant tokenizer)

    static readonly Regex Token = new(@"<!--.*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>|([^<]+)", RegexOptions.Singleline | RegexOptions.Compiled);
    static readonly HashSet<string> BlockTags = new(StringComparer.OrdinalIgnoreCase)
        { "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "pre", "blockquote", "tr", "table", "section", "article", "header", "footer", "ul", "ol", "dd", "dt", "figure", "figcaption", "body", "main", "aside", "nav" };

    public static DocModel Html(string html)
    {
        var doc = new DocModel();
        var title = Regex.Match(html, @"<title[^>]*>(.*?)</title>", RegexOptions.Singleline | RegexOptions.IgnoreCase);
        if (title.Success) doc.Title = WebUtility.HtmlDecode(title.Groups[1].Value).Trim();
        var body = Regex.Match(html, @"<body[^>]*>(.*)</body>", RegexOptions.Singleline | RegexOptions.IgnoreCase);
        string content = body.Success ? body.Groups[1].Value : html;
        content = Regex.Replace(content, @"<(script|style|head|noscript|svg)[^>]*>.*?</\1>", "", RegexOptions.Singleline | RegexOptions.IgnoreCase);

        Block? current = null;
        int bold = 0, italic = 0, code = 0, pre = 0, quote = 0;
        string? link = null;
        var lists = new Stack<(bool ordered, int counter)>();
        List<List<string>>? table = null;
        List<string>? row = null;
        StringBuilder? cell = null;
        StringBuilder? preText = null;

        void Flush()
        {
            if (current != null && current.Inlines.Any(i => i.Text.Trim().Length > 0))
            {
                // Collapse whitespace like a browser would.
                foreach (var i in current.Inlines) if (!i.Code) i.Text = Regex.Replace(i.Text, @"[ \t\r\n]+", " ");
                current.Inlines[0].Text = current.Inlines[0].Text.TrimStart();
                current.Inlines[^1].Text = current.Inlines[^1].Text.TrimEnd();
                doc.Blocks.Add(current);
            }
            current = null;
        }
        Block Current(BlockType type = BlockType.Paragraph)
        {
            current ??= new Block { Type = quote > 0 && type == BlockType.Paragraph ? BlockType.Quote : type };
            return current;
        }

        foreach (Match m in Token.Matches(content))
        {
            if (m.Value.StartsWith("<!--")) continue;
            if (m.Groups[4].Success)
            {
                var text = WebUtility.HtmlDecode(m.Groups[4].Value);
                if (preText != null) { preText.Append(text); continue; }
                if (cell != null) { cell.Append(text); continue; }
                if (text.Trim().Length == 0 && current == null) continue;
                Current().Inlines.Add(new Inline(text, bold > 0, italic > 0, code > 0, link));
                continue;
            }
            bool closing = m.Groups[1].Value == "/";
            string tag = m.Groups[2].Value.ToLowerInvariant();
            string attrs = m.Groups[3].Value;
            switch (tag)
            {
                case "b" or "strong": bold += closing ? -1 : 1; break;
                case "i" or "em" or "cite": italic += closing ? -1 : 1; break;
                case "code" or "kbd" or "samp" when pre == 0: code += closing ? -1 : 1; break;
                case "a":
                    if (closing) link = null;
                    else { var href = Regex.Match(attrs, "href\\s*=\\s*[\"']([^\"']*)[\"']"); link = href.Success ? WebUtility.HtmlDecode(href.Groups[1].Value) : null; }
                    break;
                case "br":
                    if (cell != null) cell.Append(' ');
                    else if (preText != null) preText.Append('\n');
                    else Current().Inlines.Add(new Inline("\n", bold > 0, italic > 0));
                    break;
                case "hr": Flush(); doc.Blocks.Add(new Block { Type = BlockType.Rule }); break;
                case "img":
                    var alt = Regex.Match(attrs, "alt\\s*=\\s*[\"']([^\"']*)[\"']");
                    if (alt.Success && alt.Groups[1].Value.Length > 0 && cell == null) Current().Inlines.Add(new Inline($"[{WebUtility.HtmlDecode(alt.Groups[1].Value)}]"));
                    break;
                case "h1" or "h2" or "h3" or "h4" or "h5" or "h6":
                    Flush();
                    if (!closing) current = new Block { Type = BlockType.Heading, Level = tag[1] - '0' };
                    break;
                case "ul" or "ol":
                    Flush();
                    if (closing) { if (lists.Count > 0) lists.Pop(); }
                    else
                    {
                        var startAttr = Regex.Match(attrs, "start\\s*=\\s*[\"']?(\\d+)");
                        lists.Push((tag == "ol", startAttr.Success ? int.Parse(startAttr.Groups[1].Value) : 1));
                    }
                    break;
                case "li":
                    Flush();
                    if (!closing)
                    {
                        var (ordered, counter) = lists.Count > 0 ? lists.Pop() : (false, 1);
                        lists.Push((ordered, counter + 1));
                        current = new Block { Type = BlockType.ListItem, Level = Math.Max(0, lists.Count - 1), Ordered = ordered, Number = counter };
                    }
                    break;
                case "pre":
                    Flush();
                    if (!closing) { pre++; preText = new StringBuilder(); }
                    else
                    {
                        pre = Math.Max(0, pre - 1);
                        if (preText != null) doc.Blocks.Add(new Block { Type = BlockType.Code, CodeText = preText.ToString().Trim('\n') });
                        preText = null;
                    }
                    break;
                case "blockquote": Flush(); quote += closing ? -1 : 1; break;
                case "table":
                    Flush();
                    if (!closing) table = new List<List<string>>();
                    else if (table != null) { if (table.Count > 0) doc.Blocks.Add(new Block { Type = BlockType.Table, Rows = table }); table = null; }
                    break;
                case "tr":
                    if (!closing && table != null) { row = new List<string>(); table.Add(row); }
                    break;
                case "td" or "th":
                    if (!closing) cell = new StringBuilder();
                    else if (cell != null) { row?.Add(Regex.Replace(cell.ToString(), @"\s+", " ").Trim()); cell = null; }
                    break;
                default:
                    if (BlockTags.Contains(tag)) Flush();
                    break;
            }
        }
        Flush();
        return doc;
    }

    // ------------------------------------------------------------------ DOCX (Office Open XML)

    static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    static readonly XNamespace R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

    public static DocModel Docx(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        XDocument Load(string name) { var e = zip.GetEntry(name); if (e == null) return new XDocument(); using var s = e.Open(); return XDocument.Load(s); }
        var document = Load("word/document.xml");
        var styles = Load("word/styles.xml");
        var numbering = Load("word/numbering.xml");
        var rels = Load("word/_rels/document.xml.rels");
        XNamespace pr = "http://schemas.openxmlformats.org/package/2006/relationships";
        var links = rels.Descendants(pr + "Relationship").ToDictionary(r => (string?)r.Attribute("Id") ?? "", r => (string?)r.Attribute("Target") ?? "");
        var styleNames = styles.Descendants(W + "style").ToDictionary(
            s => (string?)s.Attribute(W + "styleId") ?? "", s => ((string?)s.Element(W + "name")?.Attribute(W + "val") ?? "").ToLowerInvariant());

        // numId → (ilvl → isBullet)
        var abstractFormats = numbering.Descendants(W + "abstractNum").ToDictionary(
            a => (string?)a.Attribute(W + "abstractNumId") ?? "",
            a => a.Elements(W + "lvl").ToDictionary(l => (int?)l.Attribute(W + "ilvl") ?? 0, l => (string?)l.Element(W + "numFmt")?.Attribute(W + "val") ?? "bullet"));
        var numToAbstract = numbering.Descendants(W + "num").ToDictionary(
            n => (string?)n.Attribute(W + "numId") ?? "", n => (string?)n.Element(W + "abstractNumId")?.Attribute(W + "val") ?? "");
        var counters = new Dictionary<(string, int), int>();

        var doc = new DocModel();
        var body = document.Root?.Element(W + "body");
        if (body == null) return doc;
        foreach (var el in body.Elements())
        {
            if (el.Name == W + "p") AddParagraph(el);
            else if (el.Name == W + "tbl")
            {
                var rows = el.Elements(W + "tr").Select(tr => tr.Elements(W + "tc")
                    .Select(tc => string.Join("\n", tc.Elements(W + "p").Select(p => string.Concat(Runs(p).Select(r => r.Text))))).ToList()).ToList();
                if (rows.Count > 0) doc.Blocks.Add(new Block { Type = BlockType.Table, Rows = rows });
            }
            else if (el.Name == W + "sdt")
                foreach (var p in el.Descendants(W + "p")) AddParagraph(p);
        }
        return doc;

        void AddParagraph(XElement p)
        {
            var ppr = p.Element(W + "pPr");
            string styleId = (string?)ppr?.Element(W + "pStyle")?.Attribute(W + "val") ?? "";
            string styleName = styleNames.TryGetValue(styleId, out var sn) ? sn : styleId.ToLowerInvariant();
            var inlines = Runs(p);
            if (p.Descendants(W + "br").Any(b => (string?)b.Attribute(W + "type") == "page"))
                doc.Blocks.Add(new Block { Type = BlockType.PageBreak });
            var block = new Block { Type = BlockType.Paragraph, Inlines = inlines };
            var heading = Regex.Match(styleName, @"^heading\s*(\d)");
            if (heading.Success) { block.Type = BlockType.Heading; block.Level = int.Parse(heading.Groups[1].Value); }
            else if (styleName is "title") { block.Type = BlockType.Heading; block.Level = 1; }
            else if (styleName is "subtitle") { block.Type = BlockType.Heading; block.Level = 2; }
            else if (styleName.Contains("quote")) block.Type = BlockType.Quote;
            var numPr = ppr?.Element(W + "numPr");
            if (numPr != null && block.Type == BlockType.Paragraph)
            {
                string numId = (string?)numPr.Element(W + "numId")?.Attribute(W + "val") ?? "";
                int ilvl = (int?)numPr.Element(W + "ilvl")?.Attribute(W + "val") ?? 0;
                if (numId != "0")
                {
                    string fmt = numToAbstract.TryGetValue(numId, out var abs) && abstractFormats.TryGetValue(abs, out var lv) && lv.TryGetValue(ilvl, out var f) ? f : "bullet";
                    var key = (numId, ilvl);
                    counters[key] = counters.TryGetValue(key, out var c) ? c + 1 : 1;
                    // Deeper levels restart when a shallower item appears.
                    foreach (var k in counters.Keys.Where(k => k.Item1 == numId && k.Item2 > ilvl).ToList()) counters.Remove(k);
                    block.Type = BlockType.ListItem;
                    block.Level = ilvl;
                    block.Ordered = fmt != "bullet" && fmt != "none";
                    block.Number = counters[key];
                }
            }
            if (block.Inlines.Count > 0 || block.Type != BlockType.Paragraph) doc.Blocks.Add(block);
        }

        List<Inline> Runs(XElement p)
        {
            var list = new List<Inline>();
            foreach (var node in p.Elements())
            {
                if (node.Name == W + "r") AddRun(node, null);
                else if (node.Name == W + "hyperlink")
                {
                    string? id = (string?)node.Attribute(R + "id");
                    string? url = id != null && links.TryGetValue(id, out var t) ? t : null;
                    foreach (var r in node.Elements(W + "r")) AddRun(r, url);
                }
                else if (node.Name == W + "ins" || node.Name == W + "smartTag" || node.Name == W + "sdt")
                    foreach (var r in node.Descendants(W + "r")) AddRun(r, null);
            }
            return list;

            void AddRun(XElement r, string? url)
            {
                var rpr = r.Element(W + "rPr");
                bool b = IsOn(rpr?.Element(W + "b")), i = IsOn(rpr?.Element(W + "i"));
                string font = (string?)rpr?.Element(W + "rFonts")?.Attribute(W + "ascii") ?? "";
                bool mono = font.Contains("Consolas") || font.Contains("Courier") || font.Contains("Mono");
                foreach (var c in r.Elements())
                {
                    if (c.Name == W + "t") list.Add(new Inline(c.Value, b, i, mono, url));
                    else if (c.Name == W + "tab") list.Add(new Inline("\t", b, i, mono, url));
                    else if (c.Name == W + "br" && (string?)c.Attribute(W + "type") != "page") list.Add(new Inline("\n", b, i, mono, url));
                }
            }
        }

        static bool IsOn(XElement? e) => e != null && (string?)e.Attribute(W + "val") is null or "1" or "true" or "on";
    }

    // ------------------------------------------------------------------ EPUB

    public static DocModel Epub(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        string ReadEntry(string name)
        {
            var e = zip.GetEntry(name) ?? zip.Entries.FirstOrDefault(x => string.Equals(x.FullName, name, StringComparison.OrdinalIgnoreCase));
            if (e == null) return "";
            using var r = new StreamReader(e.Open());
            return r.ReadToEnd();
        }
        var container = XDocument.Parse(ReadEntry("META-INF/container.xml"));
        string opfPath = container.Descendants().FirstOrDefault(e => e.Name.LocalName == "rootfile")?.Attribute("full-path")?.Value ?? "";
        var opf = XDocument.Parse(ReadEntry(opfPath));
        string baseDir = opfPath.Contains('/') ? opfPath[..(opfPath.LastIndexOf('/') + 1)] : "";
        var manifest = opf.Descendants().Where(e => e.Name.LocalName == "item")
            .ToDictionary(e => e.Attribute("id")?.Value ?? "", e => e.Attribute("href")?.Value ?? "");
        var doc = new DocModel { Title = opf.Descendants().FirstOrDefault(e => e.Name.LocalName == "title")?.Value ?? "" };
        foreach (var itemref in opf.Descendants().Where(e => e.Name.LocalName == "itemref"))
        {
            var id = itemref.Attribute("idref")?.Value ?? "";
            if (!manifest.TryGetValue(id, out var href)) continue;
            var chapter = Html(ReadEntry(baseDir + Uri.UnescapeDataString(href)));
            if (doc.Blocks.Count > 0 && chapter.Blocks.Count > 0) doc.Blocks.Add(new Block { Type = BlockType.PageBreak });
            doc.Blocks.AddRange(chapter.Blocks);
        }
        return doc;
    }

    // ------------------------------------------------------------------ RTF

    public static DocModel Rtf(string rtf)
    {
        var doc = new DocModel();
        var para = new Block { Type = BlockType.Paragraph };
        var sb = new StringBuilder();
        bool bold = false, italic = false;
        var stack = new Stack<(bool b, bool i, bool skip)>();
        bool skip = false;
        int ucSkip = 1, pendingSkip = 0;
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var enc = Encoding.GetEncoding(1252);
        var bytes = new List<byte>();

        void FlushText()
        {
            if (bytes.Count > 0) { sb.Append(enc.GetString(bytes.ToArray())); bytes.Clear(); }
            if (sb.Length > 0) { para.Inlines.Add(new Inline(sb.ToString(), bold, italic)); sb.Clear(); }
        }
        void EndPara()
        {
            FlushText();
            if (para.Inlines.Count > 0) doc.Blocks.Add(para);
            para = new Block { Type = BlockType.Paragraph };
        }

        for (int i = 0; i < rtf.Length; i++)
        {
            char ch = rtf[i];
            if (ch == '{') { FlushText(); stack.Push((bold, italic, skip)); continue; }
            if (ch == '}') { FlushText(); if (stack.Count > 0) (bold, italic, skip) = stack.Pop(); continue; }
            if (ch == '\\')
            {
                if (i + 1 >= rtf.Length) break;
                char next = rtf[i + 1];
                if (next == '\'' && i + 3 < rtf.Length)
                {
                    if (!skip && pendingSkip-- <= 0) bytes.Add(System.Convert.ToByte(rtf.Substring(i + 2, 2), 16));
                    i += 3;
                    continue;
                }
                if (next is '\\' or '{' or '}') { if (!skip) { FlushBytes(); sb.Append(next); } i++; continue; }
                if (next == '*') { skip = true; i++; continue; }
                if (next == '~') { if (!skip) sb.Append('\u00A0'); i++; continue; }
                if (!char.IsLetter(next)) { i++; continue; }
                int j = i + 1;
                while (j < rtf.Length && char.IsLetter(rtf[j])) j++;
                string word = rtf[(i + 1)..j];
                int k = j;
                if (k < rtf.Length && (rtf[k] == '-' || char.IsDigit(rtf[k]))) { k++; while (k < rtf.Length && char.IsDigit(rtf[k])) k++; }
                string param = rtf[j..k];
                if (k < rtf.Length && rtf[k] == ' ') k++;
                i = k - 1;
                int.TryParse(param, out int num);
                switch (word)
                {
                    case "fonttbl" or "colortbl" or "stylesheet" or "info" or "pict" or "object" or "header" or "footer" or "listtable" or "listoverridetable" or "rsidtbl" or "generator" or "themedata" or "datastore" or "latentstyles":
                        skip = true; break;
                    case "ansicpg": try { enc = Encoding.GetEncoding(num); } catch { } break;
                    case "par" or "sect": if (!skip) EndPara(); break;
                    case "line": if (!skip) { FlushText(); sb.Append('\n'); } break;
                    case "tab": if (!skip) sb.Append('\t'); break;
                    case "b": FlushText(); bold = param != "0"; break;
                    case "i": FlushText(); italic = param != "0"; break;
                    case "plain": FlushText(); bold = italic = false; break;
                    case "uc": ucSkip = num; break;
                    case "u": if (!skip) { FlushBytes(); sb.Append((char)(num < 0 ? num + 65536 : num)); pendingSkip = ucSkip; } break;
                    case "emdash": if (!skip) sb.Append('—'); break;
                    case "endash": if (!skip) sb.Append('–'); break;
                    case "bullet": if (!skip) sb.Append('•'); break;
                    case "lquote": if (!skip) sb.Append('‘'); break;
                    case "rquote": if (!skip) sb.Append('’'); break;
                    case "ldblquote": if (!skip) sb.Append('“'); break;
                    case "rdblquote": if (!skip) sb.Append('”'); break;
                }
                continue;
            }
            if (ch is '\r' or '\n') continue;
            if (skip) continue;
            if (pendingSkip > 0) { pendingSkip--; continue; }
            FlushBytes();
            sb.Append(ch);
        }
        EndPara();
        return doc;

        void FlushBytes()
        {
            if (bytes.Count > 0) { sb.Append(enc.GetString(bytes.ToArray())); bytes.Clear(); }
        }
    }

    // ------------------------------------------------------------------ ODT

    public static DocModel Odt(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        var entry = zip.GetEntry("content.xml") ?? throw new OpException("Not an OpenDocument text file.");
        XDocument content;
        using (var s = entry.Open()) content = XDocument.Load(s);
        XNamespace text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
        XNamespace table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
        XNamespace office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
        var doc = new DocModel();
        var body = content.Descendants(office + "text").FirstOrDefault();
        if (body == null) return doc;
        Walk(body, 0);
        return doc;

        void Walk(XElement parent, int listLevel)
        {
            foreach (var el in parent.Elements())
            {
                if (el.Name == text + "h")
                    doc.Blocks.Add(new Block { Type = BlockType.Heading, Level = (int?)el.Attribute(text + "outline-level") ?? 1, Inlines = { new Inline(Flat(el)) } });
                else if (el.Name == text + "p")
                    doc.Blocks.Add(Block.Para(Flat(el)));
                else if (el.Name == text + "list")
                {
                    int n = 1;
                    foreach (var item in el.Elements(text + "list-item"))
                    {
                        foreach (var child in item.Elements())
                        {
                            if (child.Name == text + "p" || child.Name == text + "h")
                                doc.Blocks.Add(new Block { Type = BlockType.ListItem, Level = listLevel, Number = n, Inlines = { new Inline(Flat(child)) } });
                            else if (child.Name == text + "list")
                                Walk(new XElement("wrap", child), listLevel + 1);
                        }
                        n++;
                    }
                }
                else if (el.Name == table + "table")
                {
                    var rows = el.Descendants(table + "table-row").Select(r => r.Elements(table + "table-cell").Select(c => string.Join("\n", c.Elements(text + "p").Select(Flat))).ToList()).ToList();
                    doc.Blocks.Add(new Block { Type = BlockType.Table, Rows = rows });
                }
                else if (el.Name == text + "section") Walk(el, listLevel);
            }
        }

        string Flat(XElement e)
        {
            var sb = new StringBuilder();
            foreach (var node in e.Nodes())
            {
                if (node is XText t) sb.Append(t.Value);
                else if (node is XElement x)
                {
                    if (x.Name == text + "s") sb.Append(' ', (int?)x.Attribute(text + "c") ?? 1);
                    else if (x.Name == text + "tab") sb.Append('\t');
                    else if (x.Name == text + "line-break") sb.Append('\n');
                    else if (x.Name.LocalName is "note" or "annotation") continue;
                    else sb.Append(Flat(x));
                }
            }
            return sb.ToString();
        }
    }
}
