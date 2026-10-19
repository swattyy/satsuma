using System.Runtime.InteropServices;
using Microsoft.Win32;
using Satsuma.Core;
using SkiaSharp;
using static Satsuma.Native.Win32;

namespace Satsuma.Overlay;

/// <summary>
/// Frosted-glass backdrop: grabs the screen under where an overlay is about to appear, then downsamples,
/// blurs and boosts saturation once. Drawn scaled back up it reads like live acrylic, at no per-frame cost.
/// </summary>
public static class Backdrop
{
    public sealed class Snapshot : IDisposable
    {
        public SKImage Image { get; init; } = null!;
        public RECT ScreenRect { get; init; }
        public float AverageLuma { get; init; }
        public void Dispose() => Image.Dispose();
    }

    public static Snapshot? Capture(RECT r, float downscale = 0.25f, float blurSigma = 7f, float saturation = 1.45f)
    {
        int w = r.Width, h = r.Height;
        if (w <= 0 || h <= 0) return null;
        IntPtr screen = IntPtr.Zero, mem = IntPtr.Zero, dib = IntPtr.Zero, old = IntPtr.Zero;
        try
        {
            screen = GetDC(IntPtr.Zero);
            mem = CreateCompatibleDC(screen);
            var bmi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32, biCompression = BI_RGB };
            dib = CreateDIBSection(mem, ref bmi, DIB_RGB_COLORS, out var bits, IntPtr.Zero, 0);
            old = SelectObject(mem, dib);
            if (!BitBlt(mem, 0, 0, w, h, screen, r.Left, r.Top, SRCCOPY)) return null;

            using var full = SKImage.FromPixelCopy(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Opaque), bits, w * 4);
            return FromImage(full, r, downscale, blurSigma, saturation);
        }
        catch (Exception ex)
        {
            Log.Warn("Backdrop capture failed: " + ex.Message);
            return null;
        }
        finally
        {
            if (old != IntPtr.Zero) SelectObject(mem, old);
            if (dib != IntPtr.Zero) DeleteObject(dib);
            if (mem != IntPtr.Zero) DeleteDC(mem);
            if (screen != IntPtr.Zero) ReleaseDC(IntPtr.Zero, screen);
        }
    }

    /// <summary>Blurs an already-captured image of the screen area <paramref name="r"/>.</summary>
    public static Snapshot FromImage(SKImage full, RECT r, float downscale = 0.25f, float blurSigma = 7f, float saturation = 1.45f)
    {
        int sw = Math.Max(4, (int)(full.Width * downscale)), sh = Math.Max(4, (int)(full.Height * downscale));
        using var surface = SKSurface.Create(new SKImageInfo(sw, sh, SKColorType.Bgra8888, SKAlphaType.Premul));
        using var paint = new SKPaint
        {
            ImageFilter = SKImageFilter.CreateBlur(blurSigma, blurSigma, SKShaderTileMode.Clamp),
            ColorFilter = SKColorFilter.CreateColorMatrix(SaturationMatrix(saturation)),
        };
        surface.Canvas.DrawImage(full, new SKRect(0, 0, sw, sh), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), paint);
        var image = surface.Snapshot();
        return new Snapshot { Image = image, ScreenRect = r, AverageLuma = Luma(image) };
    }

    static float Luma(SKImage img)
    {
        using var bmp = SKBitmap.FromImage(img);
        double sum = 0; int n = 0;
        for (int y = 0; y < bmp.Height; y += 4)
            for (int x = 0; x < bmp.Width; x += 4)
            {
                var c = bmp.GetPixel(x, y);
                sum += (0.2126 * c.Red + 0.7152 * c.Green + 0.0722 * c.Blue) / 255.0;
                n++;
            }
        return n == 0 ? 0.5f : (float)(sum / n);
    }

    static float[] SaturationMatrix(float s)
    {
        const float lr = 0.2126f, lg = 0.7152f, lb = 0.0722f;
        float sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
        return new[]
        {
            sr + s, sg, sb, 0, 0,
            sr, sg + s, sb, 0, 0,
            sr, sg, sb + s, 0, 0,
            0, 0, 0, 1, 0,
        };
    }
}

public static class ThemeInfo
{
    public static bool IsDark
    {
        get
        {
            switch (Settings.Current.Theme)
            {
                case ThemePreference.Light: return false;
                case ThemePreference.Dark: return true;
            }
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
            }
            catch { return false; }
        }
    }

    public static bool TaskbarIsDark
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return !(key?.GetValue("SystemUsesLightTheme") is int v && v == 1);
            }
            catch { return true; }
        }
    }
}
