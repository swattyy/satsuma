using Satsuma.Core;
using Satsuma.Ops.Convert;
using SkiaSharp;
using Windows.Graphics.Imaging;
using Windows.Media.FaceAnalysis;
using Windows.Media.Ocr;

namespace Satsuma.Ops.Tools;

public enum RedactStyle { Blur, Pixelate, Box }

/// <summary>Image tools: compress, resize, crop, rotate, metadata, OCR, redaction, backgrounds, PDF/collage.</summary>
public static class ImageTools
{
    /// <summary>Output format for edits: keep the source format when we can write it, otherwise PNG/JPG.</summary>
    public static string EditFormat(string input, bool hasAlpha)
    {
        string ext = FileKinds.Ext(input);
        return ext switch
        {
            "jpg" or "jpeg" or "jfif" or "jpe" => "jpg",
            "png" or "webp" or "heic" or "tiff" or "bmp" or "avif" => ext,
            "heif" or "hif" => "heic",
            "tif" => "tiff",
            _ => hasAlpha ? "png" : "jpg",
        };
    }

    static async Task<string> SaveEdit(DecodedImage img, string input, string suffix, string? format = null, int? quality = null, bool keepMeta = true)
    {
        string fmt = format ?? EditFormat(input, img.HasAlpha);
        string output = OutputPaths.For(input, fmt, suffix);
        var copy = keepMeta ? img : new DecodedImage { Bitmap = img.Bitmap, HasAlpha = img.HasAlpha };
        try { await ImageConverter.SaveAsync(copy, output, fmt, quality ?? Settings.Current.ImageQuality, FileKinds.Ext(input), CancellationToken.None); }
        catch { OutputPaths.Discard(output); throw; }
        return output;
    }

    public static SKBitmap Resample(SKBitmap src, int w, int h)
    {
        var dst = new SKBitmap(new SKImageInfo(Math.Max(1, w), Math.Max(1, h), SKColorType.Bgra8888, SKAlphaType.Premul));
        using var c = new SKCanvas(dst);
        using var img = SKImage.FromBitmap(src);
        var sampling = w < src.Width / 2 ? new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear) : new SKSamplingOptions(SKCubicResampler.Mitchell);
        c.DrawImage(img, new SKRect(0, 0, w, h), sampling, null);
        return dst;
    }

    // ------------------------------------------------------------------ compress / resize

    public sealed record CompressOptions(int Quality, int? MaxDimension, string? Format, bool StripMetadata, long? TargetBytes);

    public static async Task<string> CompressAsync(string input, CompressOptions o)
    {
        using var img = await ImageConverter.DecodeAsync(input);
        var bmp = img.Bitmap;
        SKBitmap? scaled = null;
        if (o.MaxDimension is int max && Math.Max(bmp.Width, bmp.Height) > max)
        {
            double k = max / (double)Math.Max(bmp.Width, bmp.Height);
            scaled = Resample(bmp, (int)Math.Round(bmp.Width * k), (int)Math.Round(bmp.Height * k));
        }
        using var _ = scaled;
        var work = new DecodedImage { Bitmap = scaled ?? bmp, HasAlpha = img.HasAlpha, Metadata = o.StripMetadata ? null : img.Metadata };
        string fmt = o.Format ?? EditFormat(input, img.HasAlpha);
        if (fmt is "png" or "bmp" or "tiff" && !img.HasAlpha) fmt = "jpg"; // lossless formats can't get smaller by "quality"
        string output = OutputPaths.For(input, fmt, " (compressed)");
        try
        {
            if (o.TargetBytes is long target && fmt is "jpg" or "webp" or "heic" or "avif")
            {
                // Binary-search the quality that lands just under the requested size.
                int lo = 5, hi = 95, best = lo;
                for (int step = 0; step < 7 && lo <= hi; step++)
                {
                    int q = (lo + hi) / 2;
                    await ImageConverter.SaveAsync(work, output, fmt, q, FileKinds.Ext(input), CancellationToken.None);
                    if (new FileInfo(output).Length <= target) { best = q; lo = q + 1; } else hi = q - 1;
                }
                await ImageConverter.SaveAsync(work, output, fmt, best, FileKinds.Ext(input), CancellationToken.None);
            }
            else await ImageConverter.SaveAsync(work, output, fmt, o.Quality, FileKinds.Ext(input), CancellationToken.None);
        }
        catch { OutputPaths.Discard(output); throw; }
        return output;
    }

    public static async Task<string> ResizeAsync(string input, double? scale, int? width, int? height)
    {
        using var img = await ImageConverter.DecodeAsync(input);
        var b = img.Bitmap;
        int w, h;
        if (scale is double s) { w = (int)Math.Round(b.Width * s); h = (int)Math.Round(b.Height * s); }
        else if (width is int fw && height is int fh) { w = fw; h = fh; }
        else if (width is int ow) { w = ow; h = (int)Math.Round(b.Height * ow / (double)b.Width); }
        else if (height is int oh) { h = oh; w = (int)Math.Round(b.Width * oh / (double)b.Height); }
        else throw new OpException("No size given.");
        using var resized = Resample(b, w, h);
        return await SaveEdit(new DecodedImage { Bitmap = resized, HasAlpha = img.HasAlpha, Metadata = img.Metadata }, input, $" ({w}×{h})");
    }

    // ------------------------------------------------------------------ crop / rotate / flip

    public static async Task<string> CropAsync(string input, SKRectI rect)
    {
        using var img = await ImageConverter.DecodeAsync(input);
        rect.Intersect(new SKRectI(0, 0, img.Bitmap.Width, img.Bitmap.Height));
        if (rect.Width < 1 || rect.Height < 1) throw new OpException("Nothing left to keep after cropping.");
        using var cropped = new SKBitmap(new SKImageInfo(rect.Width, rect.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        img.Bitmap.ExtractSubset(cropped, rect);
        using var copy = cropped.Copy();
        return await SaveEdit(new DecodedImage { Bitmap = copy, HasAlpha = img.HasAlpha, Metadata = img.Metadata }, input, " (cropped)");
    }

    public static async Task<string> RotateAsync(string input, int degrees)
    {
        using var img = await ImageConverter.DecodeAsync(input);
        var b = img.Bitmap;
        bool swap = Math.Abs(degrees) % 180 == 90;
        using var rotated = new SKBitmap(new SKImageInfo(swap ? b.Height : b.Width, swap ? b.Width : b.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var c = new SKCanvas(rotated))
        {
            c.Translate(rotated.Width / 2f, rotated.Height / 2f);
            c.RotateDegrees(degrees);
            c.Translate(-b.Width / 2f, -b.Height / 2f);
            c.DrawBitmap(b, 0, 0);
        }
        return await SaveEdit(new DecodedImage { Bitmap = rotated, HasAlpha = img.HasAlpha, Metadata = img.Metadata }, input, " (rotated)");
    }

    public static async Task<string> StripMetadataAsync(string input)
    {
        using var img = await ImageConverter.DecodeAsync(input);
        // Re-encoding without copying properties drops EXIF, GPS, XMP and maker notes.
        return await SaveEdit(img, input, " (no metadata)", quality: 95, keepMeta: false);
    }

    // ------------------------------------------------------------------ OCR

    public static async Task<string> RecognizeTextAsync(string input)
    {
        using var img = await ImageConverter.DecodeAsync(input);
        var result = await OcrAsync(img.Bitmap);
        return string.Join(Environment.NewLine, result.Lines.Select(l => l.Text));
    }

    public static async Task<OcrResult> OcrAsync(SKBitmap bmp)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? throw new OpException("No Windows OCR language is installed (Settings → Time & language → Language).");
        double k = 1;
        int max = (int)OcrEngine.MaxImageDimension;
        SKBitmap? scaled = null;
        if (Math.Max(bmp.Width, bmp.Height) > max)
        {
            k = max / (double)Math.Max(bmp.Width, bmp.Height);
            scaled = Resample(bmp, (int)(bmp.Width * k), (int)(bmp.Height * k));
        }
        using var _ = scaled;
        using var sb = ImageConverter.ToSoftwareBitmap(scaled ?? bmp, opaque: false);
        var result = await engine.RecognizeAsync(sb);
        OcrScale = 1 / k;
        return result;
    }

    /// <summary>Scale from the last OCR's coordinates back to the original image.</summary>
    [ThreadStatic] public static double OcrScale;

    // ------------------------------------------------------------------ redact

    public static async Task<List<SKRect>> DetectFacesAsync(SKBitmap bmp)
    {
        if (!FaceDetector.IsSupported) return new();
        double k = Math.Min(1, 1600.0 / Math.Max(bmp.Width, bmp.Height));
        using var small = k < 1 ? Resample(bmp, (int)(bmp.Width * k), (int)(bmp.Height * k)) : null;
        using var sb = ImageConverter.ToSoftwareBitmap(small ?? bmp, opaque: true);
        using var gray = SoftwareBitmap.Convert(sb, BitmapPixelFormat.Gray8);
        var detector = await FaceDetector.CreateAsync();
        var faces = await detector.DetectFacesAsync(gray);
        return faces.Select(f =>
        {
            var r = new SKRect(f.FaceBox.X, f.FaceBox.Y, f.FaceBox.X + f.FaceBox.Width, f.FaceBox.Y + f.FaceBox.Height);
            float s = (float)(1 / k);
            // The detector's box is tight around the features; grow it to cover hair and chin.
            var grown = new SKRect(r.Left * s, r.Top * s, r.Right * s, r.Bottom * s);
            grown.Inflate(grown.Width * 0.18f, grown.Height * 0.25f);
            return grown;
        }).ToList();
    }

    public static async Task<List<SKRect>> DetectTextAsync(SKBitmap bmp)
    {
        var result = await OcrAsync(bmp);
        float s = (float)OcrScale;
        var rects = new List<SKRect>();
        foreach (var line in result.Lines)
        {
            if (line.Words.Count == 0) continue;
            float l = (float)line.Words.Min(w => w.BoundingRect.Left), t = (float)line.Words.Min(w => w.BoundingRect.Top);
            float r = (float)line.Words.Max(w => w.BoundingRect.Right), b = (float)line.Words.Max(w => w.BoundingRect.Bottom);
            var rect = new SKRect(l * s, t * s, r * s, b * s);
            rect.Inflate(rect.Height * 0.15f, rect.Height * 0.2f);
            rects.Add(rect);
        }
        return rects;
    }

    public static void ApplyRedactions(SKBitmap bmp, IEnumerable<(SKRect rect, bool oval)> regions, RedactStyle style)
    {
        using var canvas = new SKCanvas(bmp);
        using var snapshot = SKImage.FromBitmap(bmp.Copy());
        foreach (var (rect, oval) in regions)
        {
            using var clip = new SKPath();
            if (oval) clip.AddOval(rect); else clip.AddRoundRect(rect, rect.Height * 0.2f, rect.Height * 0.2f);
            canvas.Save();
            canvas.ClipPath(clip, SKClipOperation.Intersect, true);
            switch (style)
            {
                case RedactStyle.Box:
                    canvas.Clear(SKColors.Black);
                    break;
                case RedactStyle.Pixelate:
                {
                    float block = Math.Max(6, Math.Min(rect.Width, rect.Height) / 9);
                    int sw = Math.Max(1, (int)(rect.Width / block)), sh = Math.Max(1, (int)(rect.Height / block));
                    using var tiny = new SKBitmap(sw, sh);
                    using (var tc = new SKCanvas(tiny))
                        tc.DrawImage(snapshot, rect, new SKRect(0, 0, sw, sh), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), null);
                    using var tinyImg = SKImage.FromBitmap(tiny);
                    canvas.DrawImage(tinyImg, new SKRect(0, 0, sw, sh), rect, new SKSamplingOptions(SKFilterMode.Nearest), null);
                    break;
                }
                default:
                {
                    float sigma = Math.Max(8, Math.Min(rect.Width, rect.Height) / 5);
                    using var paint = new SKPaint { ImageFilter = SKImageFilter.CreateBlur(sigma, sigma, SKShaderTileMode.Clamp) };
                    canvas.DrawImage(snapshot, 0, 0, paint);
                    break;
                }
            }
            canvas.Restore();
        }
    }

    public static async Task<(string output, int count)> RedactAsync(string input, bool faces, bool text, RedactStyle style)
    {
        using var img = await ImageConverter.DecodeAsync(input);
        var regions = new List<(SKRect, bool)>();
        if (faces) regions.AddRange((await DetectFacesAsync(img.Bitmap)).Select(r => (r, true)));
        if (text) regions.AddRange((await DetectTextAsync(img.Bitmap)).Select(r => (r, false)));
        if (regions.Count == 0) throw new OpException(faces && text ? "No faces or text found." : faces ? "No faces found." : "No text found.");
        ApplyRedactions(img.Bitmap, regions, style);
        var output = await SaveEdit(new DecodedImage { Bitmap = img.Bitmap, HasAlpha = img.HasAlpha }, input, " (redacted)", keepMeta: false);
        return (output, regions.Count);
    }

    // ------------------------------------------------------------------ background

    public sealed record BackgroundOptions(SKColor[] Colors, float PaddingFraction, float Radius, float? Aspect, bool Shadow);

    public static SKBitmap ComposeBackground(SKBitmap src, BackgroundOptions o)
    {
        float pad = Math.Max(src.Width, src.Height) * o.PaddingFraction;
        float w = src.Width + pad * 2, h = src.Height + pad * 2;
        if (o.Aspect is float a && a > 0)
        {
            if (w / h < a) w = h * a; else h = w / a;
        }
        var result = new SKBitmap(new SKImageInfo((int)Math.Round(w), (int)Math.Round(h), SKColorType.Bgra8888, SKAlphaType.Premul));
        using var c = new SKCanvas(result);
        using var bg = new SKPaint { IsAntialias = true };
        bg.Shader = o.Colors.Length > 1
            ? SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(w, h), o.Colors, SKShaderTileMode.Clamp)
            : SKShader.CreateColor(o.Colors[0]);
        c.DrawRect(0, 0, w, h, bg);
        var rect = SKRect.Create((w - src.Width) / 2, (h - src.Height) / 2, src.Width, src.Height);
        float radius = o.Radius * Math.Min(src.Width, src.Height);
        if (o.Shadow)
        {
            using var sh = new SKPaint { IsAntialias = true, Color = new SKColor(0, 0, 0, 90), MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, Math.Max(6, pad * 0.25f)) };
            var shadowRect = rect; shadowRect.Offset(0, pad * 0.12f);
            c.DrawRoundRect(shadowRect, radius, radius, sh);
        }
        using var clip = new SKPath();
        clip.AddRoundRect(rect, radius, radius);
        c.Save();
        c.ClipPath(clip, SKClipOperation.Intersect, true);
        c.DrawBitmap(src, rect.Left, rect.Top);
        c.Restore();
        return result;
    }

    public static async Task<string> BackgroundAsync(string input, BackgroundOptions o)
    {
        using var img = await ImageConverter.DecodeAsync(input);
        using var composed = ComposeBackground(img.Bitmap, o);
        return await SaveEdit(new DecodedImage { Bitmap = composed, HasAlpha = false }, input, " (background)", format: "png");
    }

    // ------------------------------------------------------------------ multiple images

    public static async Task<string> MakePdfAsync(IReadOnlyList<string> files, Action<double> progress)
    {
        var decoded = new List<(DecodedImage, string)>();
        try
        {
            for (int i = 0; i < files.Count; i++)
            {
                decoded.Add((await ImageConverter.DecodeAsync(files[i]), FileKinds.Ext(files[i])));
                progress((i + 1.0) / files.Count * 0.8);
            }
            var output = OutputPaths.Unique(OutputPaths.DirectoryFor(files[0]), files.Count == 1 ? FileKinds.BaseName(files[0]) : "Combined", "pdf");
            ImageConverter.PdfFromImages(decoded, output);
            return output;
        }
        finally { foreach (var (d, _) in decoded) d.Dispose(); }
    }

    public enum CollageLayout { Grid, Row, Column, Featured }

    public sealed record CollageOptions(CollageLayout Layout, float Spacing, float Radius, SKColor Background, int Width);

    public static SKBitmap ComposeCollage(IReadOnlyList<SKBitmap> images, CollageOptions o)
    {
        int n = images.Count;
        float gap = o.Spacing;
        var cells = new List<SKRect>();
        float W = o.Width, H;
        switch (o.Layout)
        {
            case CollageLayout.Row:
            {
                // Same height, widths by aspect.
                float sumAspect = images.Sum(b => b.Width / (float)b.Height);
                float h = (W - gap * (n + 1)) / sumAspect;
                H = h + gap * 2;
                float x = gap;
                foreach (var b in images) { float w = h * b.Width / b.Height; cells.Add(SKRect.Create(x, gap, w, h)); x += w + gap; }
                break;
            }
            case CollageLayout.Column:
            {
                float w = W - gap * 2;
                float y = gap;
                foreach (var b in images) { float h = w * b.Height / b.Width; cells.Add(SKRect.Create(gap, y, w, h)); y += h + gap; }
                H = y;
                break;
            }
            case CollageLayout.Featured when n >= 2:
            {
                float bigW = (W - gap * 3) * 0.62f, smallW = W - gap * 3 - bigW;
                int rest = n - 1;
                float smallH = smallW * 0.75f;
                H = Math.Max(rest * smallH + gap * (rest + 1), bigW * 0.75f + gap * 2);
                cells.Add(SKRect.Create(gap, gap, bigW, H - gap * 2));
                float sh = (H - gap * (rest + 1)) / rest;
                for (int i = 0; i < rest; i++) cells.Add(SKRect.Create(gap * 2 + bigW, gap + i * (sh + gap), smallW, sh));
                break;
            }
            default:
            {
                int cols = (int)Math.Ceiling(Math.Sqrt(n));
                int rows = (int)Math.Ceiling(n / (double)cols);
                float cw = (W - gap * (cols + 1)) / cols, ch = cw * 0.75f;
                H = rows * ch + gap * (rows + 1);
                for (int i = 0; i < n; i++) cells.Add(SKRect.Create(gap + (i % cols) * (cw + gap), gap + (i / cols) * (ch + gap), cw, ch));
                break;
            }
        }
        var result = new SKBitmap(new SKImageInfo((int)Math.Round(W), (int)Math.Round(H), SKColorType.Bgra8888, SKAlphaType.Premul));
        using var c = new SKCanvas(result);
        c.Clear(o.Background);
        for (int i = 0; i < n && i < cells.Count; i++)
        {
            var cell = cells[i];
            var b = images[i];
            // Cover-fit: fill the cell, crop the overflow.
            float k = Math.Max(cell.Width / b.Width, cell.Height / b.Height);
            float sw = cell.Width / k, sh = cell.Height / k;
            var src = SKRect.Create((b.Width - sw) / 2, (b.Height - sh) / 2, sw, sh);
            using var clip = new SKPath();
            float r = o.Radius * Math.Min(cell.Width, cell.Height);
            clip.AddRoundRect(cell, r, r);
            c.Save();
            c.ClipPath(clip, SKClipOperation.Intersect, true);
            using var img = SKImage.FromBitmap(b);
            c.DrawImage(img, src, cell, new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), null);
            c.Restore();
        }
        return result;
    }

    public static async Task<string> CollageAsync(IReadOnlyList<string> files, CollageOptions o, Action<double> progress)
    {
        var bitmaps = new List<SKBitmap>();
        try
        {
            for (int i = 0; i < files.Count; i++)
            {
                using var d = await ImageConverter.DecodeAsync(files[i]);
                // Keep memory sane: no source needs to be bigger than the canvas.
                var b = d.Bitmap;
                double k = Math.Min(1, o.Width / (double)b.Width);
                bitmaps.Add(k < 1 ? Resample(b, (int)(b.Width * k), (int)(b.Height * k)) : b.Copy());
                progress((i + 1.0) / files.Count * 0.7);
            }
            using var collage = ComposeCollage(bitmaps, o);
            var output = OutputPaths.Unique(OutputPaths.DirectoryFor(files[0]), "Collage", "png");
            await ImageConverter.SaveAsync(new DecodedImage { Bitmap = collage }, output, "png", 100, "png", CancellationToken.None);
            return output;
        }
        finally { foreach (var b in bitmaps) b.Dispose(); }
    }
}
