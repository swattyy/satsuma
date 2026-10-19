using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Xml.Linq;
using Satsuma.Core;
using SkiaSharp;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Satsuma.Ops.Convert;

public sealed class DecodedImage : IDisposable
{
    public required SKBitmap Bitmap { get; init; }
    public BitmapPropertySet? Metadata { get; init; }
    public bool HasAlpha { get; init; }
    public void Dispose() => Bitmap.Dispose();
}

/// <summary>
/// Image conversion. Decoding goes through Windows Imaging (WIC via WinRT), so anything Windows can open works:
/// HEIC, AVIF, WebP, camera RAW, TIFF… Encoding uses Skia (PNG/WebP), WIC (JPEG/HEIC/TIFF/BMP/GIF, keeping
/// camera metadata), FFmpeg (AVIF) and small hand-written writers (ICO, PDF).
/// </summary>
public static class ImageConverter
{
    public static readonly string[] Targets = { "jpg", "png", "webp", "heic", "avif", "pdf", "tiff", "bmp", "ico" };

    static readonly string[] MetadataKeys =
    {
        "System.Photo.DateTaken", "System.Photo.CameraManufacturer", "System.Photo.CameraModel", "System.Photo.FNumber",
        "System.Photo.ExposureTime", "System.Photo.ISOSpeed", "System.Photo.FocalLength", "System.Photo.LensModel",
        "System.GPS.Latitude", "System.GPS.LatitudeRef", "System.GPS.Longitude", "System.GPS.LongitudeRef",
        "System.GPS.Altitude", "System.Author", "System.Copyright", "System.Title", "System.Comment",
    };

    // ------------------------------------------------------------------ decode

    public static async Task<DecodedImage> DecodeAsync(string path, CancellationToken ct = default)
    {
        var ext = FileKinds.Ext(path);
        if (ext == "svg") return new DecodedImage { Bitmap = await RenderSvgAsync(path, ct), HasAlpha = true };
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var ras = fs.AsRandomAccessStream();
            var decoder = await BitmapDecoder.CreateAsync(ras);
            BitmapPropertySet? meta = null;
            try { meta = await decoder.BitmapProperties.GetPropertiesAsync(MetadataKeys); } catch { }
            using var sb = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                new BitmapTransform(), ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
            var bmp = FromSoftwareBitmap(sb);
            return new DecodedImage { Bitmap = bmp, Metadata = meta, HasAlpha = HasTransparency(bmp) };
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Log.Warn($"WIC decode failed for {path}: {ex.Message}; trying Skia");
            using var codec = SKCodec.Create(path);
            if (codec == null) throw new OpException($"Windows can't read {Path.GetFileName(path)}. For HEIC/AVIF install the HEIF/AV1 extensions from the Microsoft Store.");
            var bmp = SKBitmap.Decode(codec);
            bmp = ApplyOrigin(bmp, codec.EncodedOrigin);
            return new DecodedImage { Bitmap = bmp, HasAlpha = HasTransparency(bmp) };
        }
    }

    public static SKBitmap FromSoftwareBitmap(SoftwareBitmap sb)
    {
        int w = sb.PixelWidth, h = sb.PixelHeight;
        var bytes = new byte[w * h * 4];
        sb.CopyToBuffer(bytes.AsBuffer());
        var bmp = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
        if (bmp.RowBytes == w * 4) Marshal.Copy(bytes, 0, bmp.GetPixels(), bytes.Length);
        else for (int y = 0; y < h; y++) Marshal.Copy(bytes, y * w * 4, bmp.GetPixels() + y * bmp.RowBytes, w * 4);
        return bmp;
    }

    public static SoftwareBitmap ToSoftwareBitmap(SKBitmap bmp, bool opaque)
    {
        var src = bmp.ColorType == SKColorType.Bgra8888 && bmp.AlphaType == SKAlphaType.Premul ? bmp : Convert(bmp);
        var bytes = new byte[src.Width * src.Height * 4];
        for (int y = 0; y < src.Height; y++) Marshal.Copy(src.GetPixels() + y * src.RowBytes, bytes, y * src.Width * 4, src.Width * 4);
        if (!ReferenceEquals(src, bmp)) src.Dispose();
        return SoftwareBitmap.CreateCopyFromBuffer(bytes.AsBuffer(), BitmapPixelFormat.Bgra8, bmp.Width, bmp.Height,
            opaque ? BitmapAlphaMode.Ignore : BitmapAlphaMode.Premultiplied);

        static SKBitmap Convert(SKBitmap b)
        {
            var c = new SKBitmap(new SKImageInfo(b.Width, b.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
            using var canvas = new SKCanvas(c);
            canvas.DrawBitmap(b, 0, 0);
            return c;
        }
    }

    static SKBitmap ApplyOrigin(SKBitmap bmp, SKEncodedOrigin origin)
    {
        if (origin == SKEncodedOrigin.TopLeft) return bmp;
        bool swap = origin is SKEncodedOrigin.LeftTop or SKEncodedOrigin.RightTop or SKEncodedOrigin.RightBottom or SKEncodedOrigin.LeftBottom;
        var result = new SKBitmap(swap ? bmp.Height : bmp.Width, swap ? bmp.Width : bmp.Height, bmp.ColorType, bmp.AlphaType);
        using var c = new SKCanvas(result);
        switch (origin)
        {
            case SKEncodedOrigin.TopRight: c.Scale(-1, 1, bmp.Width / 2f, 0); break;
            case SKEncodedOrigin.BottomRight: c.RotateDegrees(180, bmp.Width / 2f, bmp.Height / 2f); break;
            case SKEncodedOrigin.BottomLeft: c.Scale(1, -1, 0, bmp.Height / 2f); break;
            case SKEncodedOrigin.LeftTop: c.Translate(result.Width, 0); c.RotateDegrees(90); c.Scale(1, -1, 0, bmp.Height / 2f); break;
            case SKEncodedOrigin.RightTop: c.Translate(result.Width, 0); c.RotateDegrees(90); break;
            case SKEncodedOrigin.RightBottom: c.Translate(0, result.Height); c.RotateDegrees(-90); c.Scale(1, -1, 0, bmp.Height / 2f); break;
            case SKEncodedOrigin.LeftBottom: c.Translate(0, result.Height); c.RotateDegrees(-90); break;
        }
        c.DrawBitmap(bmp, 0, 0);
        bmp.Dispose();
        return result;
    }

    public static bool HasTransparency(SKBitmap bmp)
    {
        if (bmp.AlphaType == SKAlphaType.Opaque) return false;
        var span = bmp.GetPixelSpan();
        int stride = bmp.RowBytes;
        int step = Math.Max(1, (bmp.Width * bmp.Height) / 400_000); // sample big images
        for (int y = 0; y < bmp.Height; y += step)
        {
            int row = y * stride;
            for (int x = 0; x < bmp.Width; x += step)
                if (span[row + x * 4 + 3] != 255) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ convert

    public static async Task<string> ConvertAsync(string input, string target, CancellationToken ct)
    {
        string inExt = FileKinds.Ext(input);
        if (inExt == "gif" && target is "mp4" or "webm" or "webp")
            return await AnimatedGifAsync(input, target, ct);

        using var img = await DecodeAsync(input, ct);
        string output = OutputPaths.For(input, target);
        try
        {
            await SaveAsync(img, output, target, Settings.Current.ImageQuality, inExt, ct);
            return output;
        }
        catch { OutputPaths.Discard(output); throw; }
    }

    public static async Task SaveAsync(DecodedImage img, string output, string target, int quality, string sourceExt, CancellationToken ct)
    {
        var bmp = img.Bitmap;
        bool keepMeta = Settings.Current.KeepMetadata;
        switch (target)
        {
            case "png":
                await WriteSkiaAsync(bmp, output, SKEncodedImageFormat.Png, 100);
                break;
            case "webp":
                await WriteSkiaAsync(bmp, output, SKEncodedImageFormat.Webp, quality);
                break;
            case "jpg":
            case "jpeg":
                using (var flat = Flatten(bmp))
                    await WriteWicAsync(flat, output, BitmapEncoder.JpegEncoderId, quality, opaque: true, keepMeta ? img.Metadata : null);
                break;
            case "heic":
                using (var flat = Flatten(bmp))
                {
                    try { await WriteWicAsync(flat, output, BitmapEncoder.HeifEncoderId, quality, opaque: true, keepMeta ? img.Metadata : null); }
                    catch (Exception ex) when (ex is not OpException)
                    {
                        throw new OpException("HEIC encoding needs “HEIF Image Extensions” and “HEVC Video Extensions” from the Microsoft Store.");
                    }
                }
                break;
            case "tiff":
                await WriteWicAsync(bmp, output, BitmapEncoder.TiffEncoderId, null, opaque: !img.HasAlpha, keepMeta ? img.Metadata : null);
                break;
            case "bmp":
                using (var flat = Flatten(bmp))
                    await WriteWicAsync(flat, output, BitmapEncoder.BmpEncoderId, null, opaque: true, null);
                break;
            case "gif":
                await WriteWicAsync(bmp, output, BitmapEncoder.GifEncoderId, null, opaque: !img.HasAlpha, null);
                break;
            case "ico":
                await File.WriteAllBytesAsync(output, BuildIco(bmp), ct);
                break;
            case "avif":
                await WriteAvifAsync(bmp, img.HasAlpha, output, quality, ct);
                break;
            case "pdf":
                PdfFromImages(new[] { (img, sourceExt) }, output);
                break;
            default:
                throw new OpException($"Can't write {target.ToUpperInvariant()} images.");
        }
    }

    public static SKBitmap Flatten(SKBitmap bmp, SKColor? background = null)
    {
        var result = new SKBitmap(new SKImageInfo(bmp.Width, bmp.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        using var c = new SKCanvas(result);
        c.Clear(background ?? SKColors.White);
        c.DrawBitmap(bmp, 0, 0);
        return result;
    }

    static async Task WriteSkiaAsync(SKBitmap bmp, string output, SKEncodedImageFormat format, int quality)
    {
        using var image = SKImage.FromBitmap(bmp);
        using var data = image.Encode(format, quality) ?? throw new OpException($"Skia couldn't encode {format}.");
        await using var fs = File.Create(output);
        data.SaveTo(fs);
    }

    public static async Task WriteWicAsync(SKBitmap bmp, string output, Guid encoderId, int? quality, bool opaque, BitmapPropertySet? metadata)
    {
        using var sb = ToSoftwareBitmap(bmp, opaque);
        await using var fs = new FileStream(output, FileMode.Create, FileAccess.ReadWrite);
        using var ras = fs.AsRandomAccessStream();
        var options = new BitmapPropertySet();
        if (quality.HasValue && (encoderId == BitmapEncoder.JpegEncoderId || encoderId == BitmapEncoder.HeifEncoderId))
            options.Add("ImageQuality", new BitmapTypedValue(Math.Clamp(quality.Value, 1, 100) / 100f, Windows.Foundation.PropertyType.Single));
        if (encoderId == BitmapEncoder.TiffEncoderId)
            options.Add("TiffCompressionMethod", new BitmapTypedValue((byte)6, Windows.Foundation.PropertyType.UInt8)); // ZIP
        var encoder = await BitmapEncoder.CreateAsync(encoderId, ras, options);
        encoder.SetSoftwareBitmap(sb);
        if (metadata != null && metadata.Count > 0)
        {
            try { await encoder.BitmapProperties.SetPropertiesAsync(metadata); }
            catch (Exception ex) { Log.Info("Metadata not copied: " + ex.Message); }
        }
        await encoder.FlushAsync();
    }

    static async Task WriteAvifAsync(SKBitmap bmp, bool alpha, string output, int quality, CancellationToken ct)
    {
        var tmpDir = AppPaths.NewTempDir("avif");
        var tmp = Path.Combine(tmpDir, "frame.png");
        try
        {
            await WriteSkiaAsync(bmp, tmp, SKEncodedImageFormat.Png, 100);
            int crf = Math.Clamp((int)Math.Round(63 - quality * 0.45), 10, 50); // q90 → crf 22
            // Even dimensions keep 4:2:0 encoders happy.
            string scale = "scale=trunc(iw/2)*2:trunc(ih/2)*2";
            string args = alpha
                ? $"-i {Ffmpeg.Q(tmp)} -filter_complex \"[0:v]{scale},format=yuva444p,split[c][a];[a]alphaextract[al]\" -map \"[c]\" -map \"[al]\" -c:v libaom-av1 -still-picture 1 -crf {crf} -cpu-used 6 -row-mt 1 {Ffmpeg.Q(output)}"
                : $"-i {Ffmpeg.Q(tmp)} -vf {scale},format=yuv420p -c:v libaom-av1 -still-picture 1 -crf {crf} -cpu-used 6 -row-mt 1 {Ffmpeg.Q(output)}";
            await Ffmpeg.RunAsync(args, 0, null, ct);
        }
        finally { try { Directory.Delete(tmpDir, true); } catch { } }
    }

    static async Task<string> AnimatedGifAsync(string input, string target, CancellationToken ct)
    {
        var info = Ffmpeg.Probe(input);
        string output = OutputPaths.For(input, target);
        string args = target switch
        {
            "mp4" => $"-i {Ffmpeg.Q(input)} -movflags +faststart -pix_fmt yuv420p -vf \"scale=trunc(iw/2)*2:trunc(ih/2)*2\" -c:v libx264 -crf 20 -preset medium {Ffmpeg.Q(output)}",
            "webm" => $"-i {Ffmpeg.Q(input)} -c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1 -pix_fmt yuva420p {Ffmpeg.Q(output)}",
            _ => $"-i {Ffmpeg.Q(input)} -c:v libwebp_anim -lossless 0 -q:v {Settings.Current.ImageQuality} -loop 0 {Ffmpeg.Q(output)}",
        };
        try { await Ffmpeg.RunAsync(args, info.Duration, null, ct); }
        catch { OutputPaths.Discard(output); throw; }
        return output;
    }

    // ------------------------------------------------------------------ ICO

    public static byte[] BuildIco(SKBitmap source)
    {
        int[] sizes = { 16, 20, 24, 32, 40, 48, 64, 128, 256 };
        int side = Math.Max(source.Width, source.Height);
        using var square = new SKBitmap(new SKImageInfo(side, side, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var c = new SKCanvas(square))
        {
            c.Clear(SKColors.Transparent);
            c.DrawBitmap(source, (side - source.Width) / 2f, (side - source.Height) / 2f);
        }
        var frames = new List<byte[]>();
        foreach (var s in sizes)
        {
            using var scaled = new SKBitmap(new SKImageInfo(s, s, SKColorType.Bgra8888, SKAlphaType.Premul));
            using (var c = new SKCanvas(scaled))
            {
                c.Clear(SKColors.Transparent);
                using var img = SKImage.FromBitmap(square);
                c.DrawImage(img, new SKRect(0, 0, s, s), new SKSamplingOptions(SKCubicResampler.Mitchell), null);
            }
            using var image = SKImage.FromBitmap(scaled);
            using var png = image.Encode(SKEncodedImageFormat.Png, 100);
            frames.Add(png.ToArray());
        }
        return WriteIco(sizes, frames);
    }

    public static byte[] WriteIco(IReadOnlyList<int> sizes, IReadOnlyList<byte[]> pngFrames)
    {
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write((short)0); w.Write((short)1); w.Write((short)pngFrames.Count);
        int offset = 6 + 16 * pngFrames.Count;
        for (int i = 0; i < pngFrames.Count; i++)
        {
            int s = sizes[i];
            w.Write((byte)(s >= 256 ? 0 : s)); w.Write((byte)(s >= 256 ? 0 : s));
            w.Write((byte)0); w.Write((byte)0);
            w.Write((short)1); w.Write((short)32);
            w.Write(pngFrames[i].Length); w.Write(offset);
            offset += pngFrames[i].Length;
        }
        foreach (var f in pngFrames) w.Write(f);
        return ms.ToArray();
    }

    // ------------------------------------------------------------------ PDF from images

    static readonly HashSet<string> LossyExts = new(StringComparer.OrdinalIgnoreCase) { "jpg", "jpeg", "jfif", "jpe", "heic", "heif", "hif", "avif", "webp" };

    /// <summary>One page per image. Photos are embedded as JPEG, graphics losslessly.</summary>
    public static void PdfFromImages(IEnumerable<(DecodedImage img, string sourceExt)> images, string output)
    {
        using var stream = new SKFileWStream(output);
        var meta = new SKDocumentPdfMetadata { Creator = "Satsuma", Producer = "Satsuma", RasterDpi = 300, EncodingQuality = 92 };
        using var doc = SKDocument.CreatePdf(stream, meta);
        foreach (var (img, ext) in images)
        {
            var bmp = img.Bitmap;
            float longSide = 842f; // A4 long side in points
            float k = longSide / Math.Max(bmp.Width, bmp.Height);
            float pw = bmp.Width * k, ph = bmp.Height * k;
            var canvas = doc.BeginPage(pw, ph);
            SKImage page;
            if (LossyExts.Contains(ext) || (!img.HasAlpha && bmp.Width * bmp.Height > 4_000_000))
            {
                using var flat = Flatten(bmp);
                using var tmp = SKImage.FromBitmap(flat);
                var jpeg = tmp.Encode(SKEncodedImageFormat.Jpeg, 92);
                page = SKImage.FromEncodedData(jpeg); // Skia's PDF backend embeds JPEG data as-is
            }
            else page = SKImage.FromBitmap(bmp);
            canvas.DrawImage(page, new SKRect(0, 0, pw, ph), new SKSamplingOptions(SKFilterMode.Linear), null);
            page.Dispose();
            doc.EndPage();
        }
        doc.Close();
    }

    // ------------------------------------------------------------------ SVG

    /// <summary>Rasterizes SVG with the Edge engine that ships with Windows (headless screenshot).</summary>
    static async Task<SKBitmap> RenderSvgAsync(string path, CancellationToken ct)
    {
        float w = 1024, h = 1024;
        try
        {
            var root = XDocument.Load(path).Root!;
            float Parse(string? v) => float.TryParse(new string((v ?? "").TakeWhile(ch => char.IsDigit(ch) || ch == '.').ToArray()),
                System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var f) ? f : 0;
            float aw = Parse((string?)root.Attribute("width")), ah = Parse((string?)root.Attribute("height"));
            var vb = ((string?)root.Attribute("viewBox"))?.Split(new[] { ' ', ',' }, StringSplitOptions.RemoveEmptyEntries);
            if (aw > 0 && ah > 0) { w = aw; h = ah; }
            else if (vb is { Length: 4 }) { w = Parse(vb[2]); h = Parse(vb[3]); }
        }
        catch { }
        // Render large enough to be useful: at least 1024 px on the long side.
        float k = Math.Max(1, 1024 / Math.Max(w, h));
        int pw = (int)Math.Ceiling(w * k), ph = (int)Math.Ceiling(h * k);

        if (!EdgeRenderer.Available) throw new OpException("SVG needs Microsoft Edge to render.");
        var dir = AppPaths.NewTempDir("svg");
        try
        {
            var html = Path.Combine(dir, "page.html");
            var svgUri = new Uri(path).AbsoluteUri;
            await File.WriteAllTextAsync(html,
                $"<!doctype html><html><head><style>html,body{{margin:0;padding:0;background:transparent;overflow:hidden}}img{{display:block;width:{pw}px;height:{ph}px}}</style></head><body><img src=\"{svgUri}\"></body></html>", ct);
            var shot = await EdgeRenderer.ScreenshotAsync(html, pw, ph, Path.Combine(dir, "shot.png"), ct);
            return SKBitmap.Decode(shot) ?? throw new OpException("Edge couldn't render this SVG.");
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }
}
