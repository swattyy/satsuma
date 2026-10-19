using Satsuma.Core;
using Satsuma.Ops.Convert.Docs;
using UglyToad.PdfPig.DocumentLayoutAnalysis.PageSegmenter;
using UglyToad.PdfPig.DocumentLayoutAnalysis.ReadingOrderDetector;
using UglyToad.PdfPig.DocumentLayoutAnalysis.WordExtractor;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Storage;
using PdfDocument = Windows.Data.Pdf.PdfDocument;

namespace Satsuma.Ops.Convert;

/// <summary>PDF → images (Windows' own PDF renderer), text/Markdown/HTML/EPUB (PdfPig), DOCX (Word) and PPTX (PowerPoint).</summary>
public static class PdfConverter
{
    public static IEnumerable<string> Targets()
    {
        yield return "docx";
        yield return "png";
        yield return "jpg";
        yield return "txt";
        yield return "md";
        yield return "html";
        yield return "epub";
        if (Office.HasPowerPoint) yield return "pptx";
    }

    public static async Task<List<string>> ConvertAsync(string input, string target, Action<double> progress, CancellationToken ct)
    {
        switch (target)
        {
            case "png":
            case "jpg":
                return await RenderPagesAsync(input, target, Settings.Current.PdfRenderDpi, progress, ct);
            case "docx" when Office.HasWord:
            {
                var output = OutputPaths.For(input, "docx");
                try { await Office.WordAsync(input, output, Office.WdFormat.Docx); }
                catch { OutputPaths.Discard(output); throw; }
                return new() { output };
            }
            case "pptx":
                return new() { await ToPowerPointAsync(input, progress, ct) };
            default:
            {
                var doc = ReadText(input, progress, ct);
                var output = OutputPaths.For(input, target);
                try { DocWriters.Write(doc, output, target); }
                catch { OutputPaths.Discard(output); throw; }
                return new() { output };
            }
        }
    }

    public static async Task<PdfDocument> LoadAsync(string path)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
            return await PdfDocument.LoadFromFileAsync(file);
        }
        catch (Exception ex) when (ex.HResult == unchecked((int)0x8007052B) || ex.Message.Contains("password", StringComparison.OrdinalIgnoreCase))
        {
            throw new OpException("This PDF is password-protected.");
        }
    }

    /// <summary>Renders every page. One page → a single file; several → a folder of pages.</summary>
    public static async Task<List<string>> RenderPagesAsync(string input, string format, int dpi, Action<double>? progress, CancellationToken ct, string? folderOverride = null)
    {
        var pdf = await LoadAsync(input);
        uint count = pdf.PageCount;
        if (count == 0) throw new OpException("This PDF has no pages.");
        var outputs = new List<string>();
        string? folder = folderOverride ?? (count > 1 ? OutputPaths.FolderFor(input, " pages") : null);
        for (uint i = 0; i < count; i++)
        {
            ct.ThrowIfCancellationRequested();
            using var page = pdf.GetPage(i);
            string path = folder == null
                ? OutputPaths.For(input, format)
                : Path.Combine(folder, $"{FileKinds.BaseName(input)} - {i + 1:000}.{format}");
            await RenderPageAsync(page, path, format, dpi);
            outputs.Add(path);
            progress?.Invoke((i + 1.0) / count);
        }
        return folder != null ? new List<string> { folder } : outputs;
    }

    static async Task RenderPageAsync(PdfPage page, string path, string format, int dpi)
    {
        // Page.Size is in DIPs (1/96 in). Cap at ~60 MP so huge posters don't exhaust memory.
        double scale = dpi / 96.0;
        double w = page.Size.Width * scale, h = page.Size.Height * scale;
        double cap = Math.Sqrt(60_000_000 / Math.Max(1, w * h));
        if (cap < 1) { w *= cap; h *= cap; }
        var options = new PdfPageRenderOptions
        {
            DestinationWidth = (uint)Math.Max(1, Math.Round(w)),
            DestinationHeight = (uint)Math.Max(1, Math.Round(h)),
            BitmapEncoderId = format == "jpg" ? BitmapEncoder.JpegEncoderId : BitmapEncoder.PngEncoderId,
            BackgroundColor = Windows.UI.Color.FromArgb(255, 255, 255, 255),
        };
        await using var fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite);
        using var ras = fs.AsRandomAccessStream();
        await page.RenderToStreamAsync(ras, options);
    }

    /// <summary>Extracts text in reading order, guessing headings from font size.</summary>
    public static DocModel ReadText(string input, Action<double>? progress = null, CancellationToken ct = default)
    {
        var doc = new DocModel { Title = FileKinds.BaseName(input) };
        using var pdf = UglyToad.PdfPig.PdfDocument.Open(input);
        var blocksPerPage = new List<List<(string text, double size)>>();
        var sizes = new List<double>();
        int n = pdf.NumberOfPages;
        for (int p = 1; p <= n; p++)
        {
            ct.ThrowIfCancellationRequested();
            var page = pdf.GetPage(p);
            var words = page.GetWords(NearestNeighbourWordExtractor.Instance).ToList();
            var list = new List<(string, double)>();
            if (words.Count > 0)
            {
                var blocks = DocstrumBoundingBoxes.Instance.GetBlocks(words);
                var ordered = UnsupervisedReadingOrderDetector.Instance.Get(blocks);
                foreach (var block in ordered)
                {
                    var letters = block.TextLines.SelectMany(l => l.Words).SelectMany(w => w.Letters).ToList();
                    double size = letters.Count > 0 ? letters.Average(l => l.PointSize) : 0;
                    string text = string.Join("\n", block.TextLines.Select(l => l.Text)).Trim();
                    if (text.Length == 0) continue;
                    list.Add((text, size));
                    sizes.AddRange(letters.Select(l => l.PointSize));
                }
            }
            blocksPerPage.Add(list);
            progress?.Invoke(p / (double)n * 0.9);
        }
        if (sizes.Count == 0) throw new OpException("This PDF has no selectable text (it may be a scan).");
        sizes.Sort();
        double median = sizes[sizes.Count / 2];
        for (int p = 0; p < blocksPerPage.Count; p++)
        {
            if (p > 0) doc.Blocks.Add(new Block { Type = BlockType.PageBreak });
            foreach (var (text, size) in blocksPerPage[p])
            {
                string joined = JoinLines(text);
                bool shortLine = joined.Length < 120 && !joined.EndsWith('.');
                if (size > median * 1.6 && shortLine) doc.Blocks.Add(Block.Heading(1, joined));
                else if (size > median * 1.25 && shortLine) doc.Blocks.Add(Block.Heading(2, joined));
                else if (size > median * 1.1 && shortLine && joined.Length < 80) doc.Blocks.Add(Block.Heading(3, joined));
                else doc.Blocks.Add(Block.Para(joined));
            }
        }
        return doc.Normalize();
    }

    /// <summary>Re-flows hard-wrapped PDF lines into paragraphs, fixing hyphenation at line ends.</summary>
    static string JoinLines(string text)
    {
        var lines = text.Split('\n');
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i].TrimEnd();
            if (i < lines.Length - 1 && line.EndsWith('-') && line.Length > 1 && char.IsLetter(line[^2])) sb.Append(line[..^1]);
            else { sb.Append(line); if (i < lines.Length - 1) sb.Append(' '); }
        }
        return sb.ToString();
    }

    static async Task<string> ToPowerPointAsync(string input, Action<double> progress, CancellationToken ct)
    {
        var tmp = AppPaths.NewTempDir("pptx");
        try
        {
            var pdf = await LoadAsync(input);
            var images = new List<string>();
            float slideW = 960, slideH = 540;
            for (uint i = 0; i < pdf.PageCount; i++)
            {
                using var page = pdf.GetPage(i);
                if (i == 0) { slideW = (float)(page.Size.Width * 0.75); slideH = (float)(page.Size.Height * 0.75); } // DIP → pt
                var path = Path.Combine(tmp, $"p{i:0000}.png");
                await RenderPageAsync(page, path, "png", 200);
                images.Add(path);
                progress((i + 1.0) / pdf.PageCount * 0.6);
            }
            var output = OutputPaths.For(input, "pptx");
            try { await Office.PowerPointFromImagesAsync(images, slideW, slideH, output); }
            catch { OutputPaths.Discard(output); throw; }
            return output;
        }
        finally { try { Directory.Delete(tmp, true); } catch { } }
    }
}
