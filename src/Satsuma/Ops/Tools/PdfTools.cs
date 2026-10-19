using Satsuma.Core;
using Satsuma.Ops.Convert;
using SkiaSharp;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Writer;

namespace Satsuma.Ops.Tools;

/// <summary>Split, merge, extract images and "flatten-compress" PDFs.</summary>
public static class PdfTools
{
    public static string Merge(IReadOnlyList<string> files)
    {
        var bytes = PdfMerger.Merge(files.ToArray());
        var output = OutputPaths.Unique(OutputPaths.DirectoryFor(files[0]), "Merged", "pdf");
        File.WriteAllBytes(output, bytes);
        return output;
    }

    public static string Split(string input, Action<double> progress)
    {
        using var doc = PdfDocument.Open(input);
        int n = doc.NumberOfPages;
        if (n < 2) throw new OpException("This PDF only has one page.");
        var folder = OutputPaths.FolderFor(input, " pages");
        for (int p = 1; p <= n; p++)
        {
            var builder = new PdfDocumentBuilder();
            builder.AddPage(doc, p);
            File.WriteAllBytes(Path.Combine(folder, $"{FileKinds.BaseName(input)} - {p:000}.pdf"), builder.Build());
            progress(p / (double)n);
        }
        return folder;
    }

    public static string ExtractPages(string input, IReadOnlyList<int> pages)
    {
        using var doc = PdfDocument.Open(input);
        var builder = new PdfDocumentBuilder();
        foreach (var p in pages.Where(p => p >= 1 && p <= doc.NumberOfPages)) builder.AddPage(doc, p);
        var output = OutputPaths.For(input, "pdf", " (selected pages)");
        File.WriteAllBytes(output, builder.Build());
        return output;
    }

    public static List<string> ExtractImages(string input, Action<double> progress)
    {
        using var doc = PdfDocument.Open(input);
        string? folder = null;
        var outputs = new List<string>();
        int index = 0;
        for (int p = 1; p <= doc.NumberOfPages; p++)
        {
            foreach (var image in doc.GetPage(p).GetImages())
            {
                byte[]? data = null;
                string ext = "png";
                var raw = image.RawMemory;
                if (IsJpeg(raw.Span)) { data = raw.ToArray(); ext = "jpg"; }  // DCT streams are complete JPEG files
                else if (image.TryGetPng(out var png)) data = png;
                if (data == null || data.Length < 512) continue;
                folder ??= OutputPaths.FolderFor(input, " images");
                var path = Path.Combine(folder, $"Image {++index:000}.{ext}");
                File.WriteAllBytes(path, data);
                outputs.Add(path);
            }
            progress(p / (double)doc.NumberOfPages);
        }
        if (folder == null) throw new OpException("No embedded images found.");
        return new List<string> { folder };
    }

    static bool IsJpeg(ReadOnlySpan<byte> b) => b.Length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

    /// <summary>Re-renders every page as a JPEG. Shrinks scans and image-heavy PDFs; text stops being selectable.</summary>
    public static async Task<string> FlattenCompressAsync(string input, int dpi, int quality, Action<double> progress, CancellationToken ct)
    {
        var tmp = AppPaths.NewTempDir("flatten");
        var output = OutputPaths.For(input, "pdf", " (compressed)");
        try
        {
            var pages = await PdfConverter.RenderPagesAsync(input, "jpg", dpi, p => progress(p * 0.8), ct, folderOverride: tmp);
            var files = Directory.GetFiles(tmp, "*.jpg").OrderBy(f => f).ToList();
            var pdf = await PdfConverter.LoadAsync(input);
            using var stream = new SKFileWStream(output);
            using var doc = SKDocument.CreatePdf(stream, new SKDocumentPdfMetadata { Creator = "Satsuma", Producer = "Satsuma" });
            for (int i = 0; i < files.Count; i++)
            {
                using var page = pdf.GetPage((uint)i);
                float w = (float)page.Size.Width * 0.75f, h = (float)page.Size.Height * 0.75f; // DIPs → points
                using var original = SKImage.FromEncodedData(files[i]);
                using var bitmap = SKBitmap.FromImage(original);
                using var tmpImg = SKImage.FromBitmap(bitmap);
                using var jpeg = tmpImg.Encode(SKEncodedImageFormat.Jpeg, quality);
                using var img = SKImage.FromEncodedData(jpeg);
                var canvas = doc.BeginPage(w, h);
                canvas.DrawImage(img, new SKRect(0, 0, w, h), new SKSamplingOptions(SKFilterMode.Linear), null);
                doc.EndPage();
            }
            doc.Close();
        }
        catch { OutputPaths.Discard(output); throw; }
        finally { try { Directory.Delete(tmp, true); } catch { } }

        long before = new FileInfo(input).Length, after = new FileInfo(output).Length;
        if (after >= before * 0.95)
        {
            OutputPaths.Discard(output);
            throw new OpException("This PDF is already compact; flattening wouldn't make it smaller.");
        }
        return output;
    }

    public static string AllText(string input)
    {
        using var doc = PdfDocument.Open(input);
        return string.Join(Environment.NewLine + Environment.NewLine,
            doc.GetPages().Select(p => UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor.GetText(p)));
    }
}
