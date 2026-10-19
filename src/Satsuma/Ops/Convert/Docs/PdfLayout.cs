using System.Text.RegularExpressions;
using SkiaSharp;

namespace Satsuma.Ops.Convert.Docs;

/// <summary>
/// A small typesetter that renders a <see cref="DocModel"/> to PDF with Skia: wrapped paragraphs, headings,
/// lists, code blocks, quotes, tables and clickable links, with per-character font fallback for any script.
/// </summary>
public static class PdfLayout
{
    const float PageW = 595.28f, PageH = 841.89f, Margin = 62f;
    const float BodySize = 10.5f, LineFactor = 1.45f;
    static readonly float[] HeadingSizes = { 22, 17, 14, 12, 11, 10.5f };
    static readonly SKColor Ink = new(0x24, 0x20, 0x1C), Muted = new(0x6B, 0x62, 0x5B), LinkColor = new(0xD9, 0x5B, 0x0B),
        Rule = new(0xDD, 0xD6, 0xCF), CodeBg = new(0xF5, 0xF2, 0xEE), Accent = new(0xFF, 0x7A, 0x1A);

    sealed class Faces
    {
        public readonly SKTypeface Regular, Bold, Italic, BoldItalic, Mono;
        public Faces()
        {
            Regular = Load("Segoe UI", SKFontStyle.Normal);
            Bold = Load("Segoe UI", SKFontStyle.Bold);
            Italic = Load("Segoe UI", SKFontStyle.Italic);
            BoldItalic = Load("Segoe UI", SKFontStyle.BoldItalic);
            Mono = SKTypeface.FromFamilyName("Cascadia Mono") is { FamilyName: "Cascadia Mono" } c ? c : Load("Consolas", SKFontStyle.Normal);
        }
        static SKTypeface Load(string family, SKFontStyle style) => SKTypeface.FromFamilyName(family, style) ?? SKTypeface.Default;
        public SKTypeface For(bool bold, bool italic, bool code) =>
            code ? Mono : bold && italic ? BoldItalic : bold ? Bold : italic ? Italic : Regular;
    }

    record struct Run(string Text, SKTypeface Face, float Size, SKColor Color, string? Link);
    record struct Piece(string Text, SKTypeface Face, float Size, SKColor Color, string? Link, float Width);

    public static void Write(DocModel doc, string path)
    {
        using var stream = new SKFileWStream(path);
        var meta = new SKDocumentPdfMetadata { Title = doc.GuessTitle(), Creator = "Satsuma", Producer = "Satsuma" };
        using var pdf = SKDocument.CreatePdf(stream, meta);
        var w = new Writer(pdf, new Faces());
        w.Render(doc);
        w.Finish();
        pdf.Close();
    }

    sealed class Writer
    {
        readonly SKDocument _pdf;
        readonly Faces _f;
        SKCanvas? _c;
        float _y;
        int _page;
        readonly float _left = Margin, _right = PageW - Margin, _bottom = PageH - Margin;
        readonly SKPaint _paint = new() { IsAntialias = true };

        public Writer(SKDocument pdf, Faces f) { _pdf = pdf; _f = f; NewPage(); }

        void NewPage()
        {
            if (_c != null) { Footer(); _pdf.EndPage(); }
            _c = _pdf.BeginPage(PageW, PageH);
            _page++;
            _y = Margin;
        }

        void Footer()
        {
            using var font = new SKFont(_f.Regular, 8.5f);
            _paint.Color = Muted;
            _c!.DrawText(_page.ToString(), PageW / 2, PageH - Margin / 2, SKTextAlign.Center, font, _paint);
        }

        public void Finish() { Footer(); _pdf.EndPage(); _c = null; }

        void Ensure(float h) { if (_y + h > _bottom && _y > Margin + 1) NewPage(); }

        public void Render(DocModel doc)
        {
            BlockType? prev = null;
            foreach (var b in doc.Blocks)
            {
                switch (b.Type)
                {
                    case BlockType.Heading:
                    {
                        float size = HeadingSizes[Math.Clamp(b.Level, 1, 6) - 1];
                        _y += prev == null ? 0 : size * (b.Level <= 2 ? 1.0f : 0.8f);
                        var runs = b.Inlines.Select(i => new Run(i.Text, _f.For(true, i.Italic, i.Code), size, Ink, i.Link)).ToList();
                        Ensure(size * 3);
                        Paragraph(runs, _left, _right, size * 1.25f);
                        if (b.Level == 1)
                        {
                            _paint.Color = Accent; _paint.StrokeWidth = 1.5f; _paint.Style = SKPaintStyle.Stroke;
                            _c!.DrawLine(_left, _y + 2, _left + 36, _y + 2, _paint);
                            _paint.Style = SKPaintStyle.Fill;
                            _y += 8;
                        }
                        _y += size * 0.35f;
                        break;
                    }
                    case BlockType.Paragraph:
                        Paragraph(Runs(b.Inlines, BodySize, Ink), _left, _right, BodySize * LineFactor);
                        _y += BodySize * 0.75f;
                        break;
                    case BlockType.Quote:
                    {
                        float top = _y;
                        Paragraph(b.Inlines.Select(i => new Run(i.Text, _f.For(i.Bold, true, i.Code), BodySize, Muted, i.Link)).ToList(), _left + 16, _right, BodySize * LineFactor);
                        _paint.Color = Accent;
                        _c!.DrawRect(new SKRect(_left + 2, Math.Max(top, Margin), _left + 4.5f, _y), _paint);
                        _y += BodySize * 0.75f;
                        break;
                    }
                    case BlockType.ListItem:
                    {
                        float indent = 18 * (b.Level + 1);
                        Ensure(BodySize * LineFactor);
                        using var mf = new SKFont(_f.Regular, BodySize);
                        _paint.Color = Ink;
                        string marker = b.Ordered ? $"{b.Number}." : (b.Level % 2 == 0 ? "•" : "◦");
                        _c!.DrawText(marker, _left + indent - 5, _y + BodySize * 1.05f, SKTextAlign.Right, mf, _paint);
                        Paragraph(Runs(b.Inlines, BodySize, Ink), _left + indent, _right, BodySize * LineFactor);
                        _y += BodySize * 0.3f;
                        if (prev == BlockType.ListItem) { }
                        break;
                    }
                    case BlockType.Code:
                        Code(b.CodeText ?? "");
                        break;
                    case BlockType.Rule:
                        Ensure(20);
                        _y += 8;
                        _paint.Color = Rule; _paint.Style = SKPaintStyle.Stroke; _paint.StrokeWidth = 0.75f;
                        _c!.DrawLine(_left, _y, _right, _y, _paint);
                        _paint.Style = SKPaintStyle.Fill;
                        _y += 12;
                        break;
                    case BlockType.PageBreak:
                        if (_y > Margin + 1) NewPage();
                        break;
                    case BlockType.Table when b.Rows is { Count: > 0 }:
                        Table(b.Rows);
                        _y += BodySize;
                        break;
                }
                if (prev == BlockType.ListItem && b.Type != BlockType.ListItem) _y += BodySize * 0.4f;
                prev = b.Type;
            }
        }

        List<Run> Runs(List<Inline> inlines, float size, SKColor color) =>
            inlines.Select(i => new Run(i.Text, _f.For(i.Bold, i.Italic, i.Code), i.Code ? size * 0.92f : size, i.Link != null ? LinkColor : color, i.Link)).ToList();

        // ---- paragraph layout ----

        void Paragraph(List<Run> runs, float left, float right, float lineHeight)
        {
            foreach (var line in Wrap(runs, right - left))
            {
                Ensure(lineHeight);
                float maxSize = line.Count > 0 ? line.Max(p => p.Size) : BodySize;
                float baseline = _y + lineHeight * 0.5f + maxSize * 0.36f;
                float x = left;
                foreach (var p in line)
                {
                    using var font = new SKFont(p.Face, p.Size) { Subpixel = true };
                    _paint.Color = p.Color;
                    _c!.DrawText(p.Text, x, baseline, SKTextAlign.Left, font, _paint);
                    if (p.Link != null && Uri.TryCreate(p.Link, UriKind.Absolute, out _))
                    {
                        _c.DrawUrlAnnotation(new SKRect(x, baseline - p.Size, x + p.Width, baseline + p.Size * 0.3f), p.Link);
                        _paint.StrokeWidth = 0.5f; _paint.Style = SKPaintStyle.Stroke;
                        _c.DrawLine(x, baseline + 1.5f, x + p.Width, baseline + 1.5f, _paint);
                        _paint.Style = SKPaintStyle.Fill;
                    }
                    x += p.Width;
                }
                _y += lineHeight;
            }
        }

        static readonly Regex Tokens = new(@"\n|[^\S\n]+|[^\s]+", RegexOptions.Compiled);

        List<List<Piece>> Wrap(List<Run> runs, float width)
        {
            var lines = new List<List<Piece>>();
            var line = new List<Piece>();
            float x = 0;
            foreach (var run in runs)
            {
                foreach (Match m in Tokens.Matches(run.Text))
                {
                    string tok = m.Value;
                    if (tok == "\n") { lines.Add(line); line = new List<Piece>(); x = 0; continue; }
                    bool space = char.IsWhiteSpace(tok[0]);
                    if (space && x == 0) continue;
                    var pieces = Shape(tok, run);
                    float w = pieces.Sum(p => p.Width);
                    if (!space && x + w > width && x > 0)
                    {
                        TrimTrailingSpace(line);
                        lines.Add(line); line = new List<Piece>(); x = 0;
                    }
                    if (!space && w > width)
                    {
                        // Break very long words by characters.
                        foreach (var ch in SplitChars(tok, run, width - x, width))
                        {
                            if (x + ch.Width > width && x > 0) { lines.Add(line); line = new List<Piece>(); x = 0; }
                            line.Add(ch); x += ch.Width;
                        }
                        continue;
                    }
                    line.AddRange(pieces);
                    x += w;
                }
            }
            TrimTrailingSpace(line);
            if (line.Count > 0 || lines.Count == 0) lines.Add(line);
            return lines;
        }

        static void TrimTrailingSpace(List<Piece> line)
        {
            while (line.Count > 0 && line[^1].Text.Trim().Length == 0) line.RemoveAt(line.Count - 1);
        }

        IEnumerable<Piece> SplitChars(string word, Run run, float firstWidth, float width)
        {
            foreach (var p in Shape(word, run))
            {
                // Split each shaped piece into characters.
                using var font = new SKFont(p.Face, p.Size);
                foreach (var ch in EnumerateTextElements(p.Text))
                    yield return p with { Text = ch, Width = font.MeasureText(ch) };
            }
        }

        static IEnumerable<string> EnumerateTextElements(string s)
        {
            var e = System.Globalization.StringInfo.GetTextElementEnumerator(s);
            while (e.MoveNext()) yield return e.GetTextElement();
        }

        /// <summary>Splits text into pieces whose characters the chosen typeface can actually draw.</summary>
        List<Piece> Shape(string text, Run run)
        {
            var result = new List<Piece>();
            using var font = new SKFont(run.Face, run.Size);
            bool ascii = text.All(c => c < 128);
            if (ascii)
            {
                result.Add(new Piece(text, run.Face, run.Size, run.Color, run.Link, font.MeasureText(text)));
                return result;
            }
            var glyphs = font.GetGlyphs(text);
            if (glyphs.All(g => g != 0) && glyphs.Length > 0)
            {
                result.Add(new Piece(text, run.Face, run.Size, run.Color, run.Link, font.MeasureText(text)));
                return result;
            }
            var sb = new System.Text.StringBuilder();
            SKTypeface? curFace = null;
            foreach (var el in EnumerateTextElements(text))
            {
                int cp = char.ConvertToUtf32(el, 0);
                SKTypeface face = run.Face;
                using (var probe = new SKFont(run.Face, run.Size))
                {
                    if (probe.GetGlyphs(el).Any(g => g == 0))
                        face = SKFontManager.Default.MatchCharacter(run.Face.FamilyName, run.Face.FontStyle, null, cp) ?? run.Face;
                }
                if (curFace != null && face.FamilyName != curFace.FamilyName && sb.Length > 0)
                {
                    using var ff = new SKFont(curFace, run.Size);
                    result.Add(new Piece(sb.ToString(), curFace, run.Size, run.Color, run.Link, ff.MeasureText(sb.ToString())));
                    sb.Clear();
                }
                curFace = face;
                sb.Append(el);
            }
            if (sb.Length > 0 && curFace != null)
            {
                using var ff = new SKFont(curFace, run.Size);
                result.Add(new Piece(sb.ToString(), curFace, run.Size, run.Color, run.Link, ff.MeasureText(sb.ToString())));
            }
            return result;
        }

        // ---- code block ----

        void Code(string code)
        {
            float size = 9f, lh = size * 1.45f, pad = 8;
            var run = new Run("", _f.Mono, size, Ink, null);
            var lines = new List<List<Piece>>();
            foreach (var raw in code.Replace("\r", "").Split('\n'))
                lines.AddRange(Wrap(new List<Run> { run with { Text = raw.Replace("\t", "    ").Length == 0 ? " " : raw.Replace("\t", "    ") } }, _right - _left - pad * 2));
            int i = 0;
            _y += 2;
            while (i < lines.Count)
            {
                Ensure(lh + pad * 2);
                int fit = Math.Max(1, (int)((_bottom - _y - pad * 2) / lh));
                int count = Math.Min(fit, lines.Count - i);
                var rect = new SKRect(_left, _y, _right, _y + count * lh + pad * 2);
                _paint.Color = CodeBg;
                _c!.DrawRoundRect(rect, 5, 5, _paint);
                float y = _y + pad;
                for (int k = 0; k < count; k++, i++)
                {
                    float x = _left + pad;
                    foreach (var p in lines[i])
                    {
                        using var font = new SKFont(p.Face, p.Size);
                        _paint.Color = Ink;
                        _c.DrawText(p.Text, x, y + lh * 0.72f, SKTextAlign.Left, font, _paint);
                        x += p.Width;
                    }
                    y += lh;
                }
                _y = rect.Bottom + 8;
                if (i < lines.Count) NewPage();
            }
        }

        // ---- table ----

        void Table(List<List<string>> rows)
        {
            int cols = rows.Max(r => r.Count);
            float avail = _right - _left, pad = 5, size = 9.5f, lh = size * 1.4f;
            using var measure = new SKFont(_f.Regular, size);
            var natural = new float[cols];
            foreach (var r in rows)
                for (int c = 0; c < r.Count; c++)
                    natural[c] = Math.Max(natural[c], Math.Min(260, r[c].Split('\n').Max(l => measure.MeasureText(l))) + pad * 2);
            float total = Math.Max(1, natural.Sum());
            // Fill the text width: grow narrow tables, shrink wide ones (keeping a minimum column width).
            var widths = natural.Select(n => total <= avail ? n * avail / total : Math.Max(40, n * avail / total)).ToArray();
            float sum = widths.Sum();
            if (sum > avail) for (int c = 0; c < cols; c++) widths[c] *= avail / sum;

            for (int r = 0; r < rows.Count; r++)
            {
                bool header = r == 0;
                var cellLines = new List<List<List<Piece>>>();
                for (int c = 0; c < cols; c++)
                {
                    string text = c < rows[r].Count ? rows[r][c] : "";
                    var run = new Run(text, header ? _f.Bold : _f.Regular, size, Ink, null);
                    cellLines.Add(Wrap(new List<Run> { run }, widths[c] - pad * 2));
                }
                float h = cellLines.Max(l => l.Count) * lh + pad * 2;
                Ensure(h);
                float x = _left;
                for (int c = 0; c < cols; c++)
                {
                    var rect = new SKRect(x, _y, x + widths[c], _y + h);
                    if (header) { _paint.Color = CodeBg; _c!.DrawRect(rect, _paint); }
                    _paint.Color = Rule; _paint.Style = SKPaintStyle.Stroke; _paint.StrokeWidth = 0.6f;
                    _c!.DrawRect(rect, _paint);
                    _paint.Style = SKPaintStyle.Fill;
                    float y = _y + pad;
                    foreach (var line in cellLines[c])
                    {
                        float lx = x + pad;
                        foreach (var p in line)
                        {
                            using var font = new SKFont(p.Face, p.Size);
                            _paint.Color = Ink;
                            _c.DrawText(p.Text, lx, y + lh * 0.72f, SKTextAlign.Left, font, _paint);
                            lx += p.Width;
                        }
                        y += lh;
                    }
                    x += widths[c];
                }
                _y += h;
            }
        }
    }
}
