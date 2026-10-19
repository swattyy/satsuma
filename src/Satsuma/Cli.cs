using System.Text.Json;
using Satsuma.Core;
using Satsuma.Ops;
using Satsuma.Overlay;
using Satsuma.UI;
using Satsuma.Wheel;
using SkiaSharp;

namespace Satsuma;

/// <summary>
/// Command-line modes used for testing and tooling (the app is otherwise a tray app):
///   --convert &lt;target&gt; &lt;files…&gt; [--result out.json]   run a Convert segment headlessly
///   --tool &lt;id&gt; &lt;files…&gt; [--result out.json]          run a Tools segment (non-interactive ones)
///   --list &lt;files…&gt; [--result out.json]                list what each wheel would show
///   --render-test &lt;dir&gt;                                 render wheel frames and bubbles to PNG
///   --render-ui &lt;dir&gt; &lt;image&gt; &lt;video&gt; &lt;audio&gt; &lt;pdf&gt;   render every window/dialog offscreen to PNG
///   --selftest &lt;files…&gt;                                 offscreen checks of the drop path and hit-testing
///   --make-icon &lt;path.ico&gt;                              write the app icon
///   --demo-wheel [convert|tools|actions] [ms]            open the live wheel at the cursor (no drag needed)
/// </summary>
public static class Cli
{
    static readonly string[] Verbs = { "--convert", "--tool", "--list", "--render-test", "--make-icon", "--demo-wheel", "--selftest", "--render-ui", "--make-installer-art" };

    public static bool Handles(string[] args) => args.Length > 0 && Verbs.Contains(args[0]);

    public static async Task<int> RunAsync(string[] args)
    {
        Program.IsTestMode = true;
        // Headless runs must never open a window: interactive tools take their default options.
        if (args[0] is "--convert" or "--tool") ToolDialogs.UseDefaults = true;
        string? resultPath = null;
        var rest = new List<string>();
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--result" && i + 1 < args.Length) resultPath = args[++i];
            else rest.Add(args[i]);
        }
        var result = new Dictionary<string, object?>();
        int code = 0;
        try
        {
            switch (args[0])
            {
                case "--make-icon":
                    AppIcon.WriteIco(rest[0]);
                    result["ok"] = true;
                    break;
                case "--make-installer-art":
                    await InstallerArt(rest[0]);
                    result["ok"] = true;
                    break;
                case "--render-test":
                    result["transition"] = RenderTest(rest[0]);
                    result["ok"] = true;
                    break;
                case "--list":
                {
                    var files = rest.Select(Path.GetFullPath).ToList();
                    foreach (var kind in Enum.GetValues<WheelKind>())
                    {
                        var c = Catalog.Build(kind, files, false);
                        result[kind.ToString()] = c.Items.Select(i => i.Label).ToList();
                        result[kind + "Hub"] = $"{c.HubCaption} | {c.HubTitle}";
                    }
                    result["ok"] = true;
                    break;
                }
                case "--convert":
                case "--tool":
                {
                    string target = rest[0];
                    var files = rest.Skip(1).Select(Path.GetFullPath).ToList();
                    var kind = args[0] == "--convert" ? WheelKind.Convert : WheelKind.Tools;
                    var items = Catalog.Build(kind, files, false).Items;
                    var item = items.FirstOrDefault(i => i.Id.EndsWith(":" + target, StringComparison.OrdinalIgnoreCase))
                        ?? throw new OpException($"No '{target}' on the {kind} wheel for these files. Options: {string.Join(", ", items.Select(i => i.Id))}");
                    var progress = new List<double>();
                    var ctx = new OpContext { Files = files, Anchor = default, Cancel = CancellationToken.None };
                    ctx.OnProgress = p => { lock (progress) progress.Add(p.Fraction); };
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    var r = await item.Run(ctx);
                    result["ok"] = !r.Canceled;
                    result["outputs"] = r.Outputs;
                    result["title"] = r.Title;
                    result["message"] = r.Message;
                    result["seconds"] = Math.Round(sw.Elapsed.TotalSeconds, 2);
                    result["progressEvents"] = progress.Count;
                    break;
                }
                case "--render-ui":
                {
                    // Renders every window/dialog offscreen to PNG (nothing appears on screen).
                    // Args: <dir> <image> <video> <audio> <pdf>
                    string dir = rest[0];
                    Directory.CreateDirectory(dir);
                    ToolWindow.RenderOnlyDir = dir;
                    ToolWindow.RenderContent(new SettingsWindow(), Path.Combine(dir, "settings.png"), 600);
                    ToolWindow.RenderContent(new WelcomeWindow(), Path.Combine(dir, "welcome.png"), 680);
                    string img = Path.GetFullPath(rest[1]), vid = Path.GetFullPath(rest[2]), aud = Path.GetFullPath(rest[3]), pdf = Path.GetFullPath(rest[4]);
                    await ToolDialogs.ImageCompressAsync(new[] { img });
                    await ToolDialogs.ImageResizeAsync(new[] { img });
                    await ToolDialogs.ImageCropAsync(img);
                    await ToolDialogs.RedactAsync(new[] { img });
                    await ToolDialogs.BackgroundAsync(new[] { img });
                    await ToolDialogs.CollageAsync(new[] { img, img, img });
                    await ToolDialogs.VideoCompressAsync(new[] { vid });
                    await ToolDialogs.TrimAsync(vid);
                    await ToolDialogs.AudioCompressAsync(new[] { aud });
                    await ToolDialogs.PagesAsync(pdf);
                    result["ok"] = true;
                    result["files"] = Directory.GetFiles(dir, "*.png").Select(Path.GetFileName).ToList();
                    break;
                }
                case "--selftest":
                {
                    // Offscreen checks of the drop path: no windows, no input.
                    var files = rest.Select(Path.GetFullPath).ToList();
                    var checks = new List<string>();
                    bool ok = true;
                    void Check(bool cond, string what) { checks.Add((cond ? "PASS " : "FAIL ") + what); ok &= cond; }

                    var data = Native.ShellDrag.CreateDataObject(files);
                    Check(data != null, "shell data object created");
                    var read = data != null ? Native.OleData.GetFilePaths(data) : new List<string>();
                    Check(read.SequenceEqual(files, StringComparer.OrdinalIgnoreCase), $"CF_HDROP round-trip ({read.Count} paths)");
                    try { Native.OleData.SetDropDescription(data, Native.OleData.DropImageCopy, "Convert to %1", "PNG"); Check(true, "drop description set"); }
                    catch (Exception ex) { Check(false, "drop description: " + ex.Message); }

                    var content = Catalog.Build(WheelKind.Convert, read, false);
                    Check(content.Items.Count > 0, $"convert wheel has {content.Items.Count} items");
                    foreach (var scale in new[] { 1f, 1.25f, 1.5f, 2f })
                    {
                        var L = new WheelLayout(scale, true);
                        int n = content.Items.Count;
                        bool all = true;
                        for (int i = 0; i < n; i++)
                        {
                            double a = WheelLayout.MidAngle(i, n) * Math.PI / 180, r = (L.R + L.RIn) / 2;
                            all &= L.HitTest((float)(L.Cx + Math.Cos(a) * r), (float)(L.Cy + Math.Sin(a) * r), n) == i;
                            // Near both edges of the segment as well.
                            double span = 360.0 / n;
                            foreach (var off in new[] { -span * 0.45, span * 0.45 })
                            {
                                double b = (WheelLayout.MidAngle(i, n) + off) * Math.PI / 180;
                                all &= L.HitTest((float)(L.Cx + Math.Cos(b) * L.R * 0.95), (float)(L.Cy + Math.Sin(b) * L.R * 0.95), n) == i;
                            }
                        }
                        Check(all, $"hit-testing every segment at {scale:0.##}x");
                        Check(L.HitTest(L.Cx, L.Cy, n) == -1, $"hub is a no-drop zone at {scale:0.##}x");
                        Check(L.HitTest(L.Cx + L.R + 20 * scale, L.Cy, n) >= 0, $"magnetic zone just outside the ring at {scale:0.##}x");
                        Check(L.HitTest(L.Cx + L.HitRadius + 5, L.Cy, n) == -2, $"outside the halo at {scale:0.##}x");
                    }
                    foreach (var kind in Enum.GetValues<WheelKind>())
                        Check(Catalog.Build(kind, read, false).Items.All(i => !string.IsNullOrEmpty(i.Label)), $"{kind} wheel labels");
                    result["checks"] = checks;
                    result["ok"] = ok;
                    code = ok ? 0 : 1;
                    break;
                }
                case "--demo-wheel":
                {
                    OverlayThread.Instance.Start(WheelController.Create);
                    Native.Win32.GetCursorPos(out var pt);
                    var kind = rest.Count > 0 && Enum.TryParse<WheelKind>(rest[0], true, out var k) ? k : WheelKind.Convert;
                    OverlayThread.Instance.Post(() => WheelController.Instance!.Open(kind, pt));
                    await Task.Delay(rest.Count > 1 && int.TryParse(rest[1], out var ms) ? ms : 4000);
                    result["ok"] = true;
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            code = 1;
            result["ok"] = false;
            result["error"] = ex is OpException ? ex.Message : ex.ToString();
        }
        var json = JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true });
        if (resultPath != null) await File.WriteAllTextAsync(resultPath, json);
        Log.Info("CLI " + string.Join(' ', args) + " → " + json);
        return code;
    }

    /// <summary>Renders the wheel over a synthetic wallpaper at several animation states, and measures hover transitions.</summary>
    static Dictionary<string, object> RenderTest(string dir)
    {
        Directory.CreateDirectory(dir);
        var samples = Path.Combine(dir, "samples");
        Directory.CreateDirectory(samples);
        string Make(string name, int bytes) { var p = Path.Combine(samples, name); if (!File.Exists(p)) File.WriteAllBytes(p, new byte[bytes]); return p; }
        var jpg = Make("holiday.jpg", 2_400_000);
        var wav = Make("mixtape.wav", 31_000_000);
        var pdf = Make("field-notes.pdf", 820_000);
        var mov = Make("weekend.mov", 148_000_000);
        var folder = Path.Combine(samples, "Project");
        Directory.CreateDirectory(folder);
        var longFolder = Path.Combine(samples, "Vacation photos from summer 2024 (backup copy)");
        Directory.CreateDirectory(longFolder);
        var unknown = Make("firmware.bin", 4_000);

        float scale = 2f;
        var layout = new WheelLayout(scale, true);
        var cases = new (string name, WheelKind kind, string[] files, int hover, float t, bool dark)[]
        {
            ("convert-jpg-idle", WheelKind.Convert, new[] { jpg }, -1, 1f, false),
            ("convert-jpg-hover", WheelKind.Convert, new[] { jpg }, 1, 1f, false),
            ("convert-jpg-opening", WheelKind.Convert, new[] { jpg }, -1, 0.45f, false),
            ("convert-wav-hover-dark", WheelKind.Convert, new[] { wav }, 2, 1f, true),
            ("convert-pdf-hover", WheelKind.Convert, new[] { pdf }, 0, 1f, false),
            ("convert-mov-dark", WheelKind.Convert, new[] { mov }, 6, 1f, true),
            ("tools-jpg-hover", WheelKind.Tools, new[] { jpg }, 3, 1f, false),
            ("tools-jpg-dark", WheelKind.Tools, new[] { jpg }, 0, 1f, true),
            ("actions-hover", WheelKind.Actions, new[] { jpg }, 1, 1f, false),
            ("folder-convert", WheelKind.Convert, new[] { folder }, -1, 1f, false),
            // Text-fit stress cases for the center circle.
            ("fit-actions-share", WheelKind.Actions, new[] { jpg }, 0, 1f, true),
            ("fit-actions-openwith", WheelKind.Actions, new[] { jpg }, 6, 1f, false),
            ("fit-tools-metadata", WheelKind.Tools, new[] { jpg }, 4, 1f, false),
            ("fit-tools-redact", WheelKind.Tools, new[] { jpg }, 6, 1f, true),
            ("fit-tools-background", WheelKind.Tools, new[] { jpg }, 7, 1f, false),
            ("fit-tools-trim", WheelKind.Tools, new[] { mov }, 1, 1f, false),
            ("fit-tools-pdf-pages", WheelKind.Tools, new[] { pdf }, 1, 1f, true),
            ("fit-tools-multi-zip", WheelKind.Tools, new[] { jpg, pdf, mov }, 0, 1f, false),
            ("fit-convert-mp3", WheelKind.Convert, new[] { mov }, 6, 1f, false),
            ("fit-long-folder", WheelKind.Convert, new[] { longFolder }, -1, 1f, false),
            ("fit-empty-tools", WheelKind.Tools, new[] { unknown }, -1, 1f, true),
        };
        foreach (var (name, kind, files, hover, t, dark) in cases)
        {
            using var wallpaper = Wallpaper(layout.Width, layout.Height, dark);
            using var snap = Backdrop.FromImage(wallpaper, new Native.Win32.RECT(0, 0, layout.Width, layout.Height));
            using var wheel = WheelController.RenderPreview(kind, files, hover, t, dark, scale, snap);
            using var surface = SKSurface.Create(new SKImageInfo(layout.Width, layout.Height));
            surface.Canvas.DrawImage(wallpaper, 0, 0);
            surface.Canvas.DrawImage(wheel, 0, 0);
            using var img = surface.Snapshot();
            using var png = img.Encode(SKEncodedImageFormat.Png, 100);
            File.WriteAllBytes(Path.Combine(dir, name + ".png"), png.ToArray());
        }
        // Progress / result bubbles
        var (hw, hh) = Hud.PreviewSize(scale);
        var hudCases = new (string name, int phase, string title, string sub, float p, bool dark)[]
        {
            ("hud-working", 0, "Converting to WEBP…", "holiday.jpg · 42%", 0.42f, false),
            ("hud-done", 1, "Saved holiday.webp", "Click to show in folder", 1f, false),
            ("hud-done-dark", 1, "Saved 12 files", "Click to show in folder", 1f, true),
            ("hud-failed-dark", 2, "Couldn't finish", "FFmpeg isn't installed. Open Satsuma settings → Engines.", 1f, true),
        };
        foreach (var (name, phase, title, sub, p, dark) in hudCases)
        {
            using var wallpaper = Wallpaper(hw, hh, dark);
            using var snap = Backdrop.FromImage(wallpaper, new Native.Win32.RECT(0, 0, hw, hh));
            using var bubble = Hud.RenderPreview(phase, title, sub, p, dark, scale, snap);
            using var surface = SKSurface.Create(new SKImageInfo(hw, hh));
            surface.Canvas.DrawImage(wallpaper, 0, 0);
            surface.Canvas.DrawImage(bubble, 0, 0);
            using var img = surface.Snapshot();
            using var png = img.Encode(SKEncodedImageFormat.Png, 100);
            File.WriteAllBytes(Path.Combine(dir, name + ".png"), png.ToArray());
        }

        // Icons
        foreach (var (size, tray) in new[] { (256, false), (64, false), (32, true), (16, true) })
        {
            using var b = AppIcon.Render(size, tray);
            using var img = SKImage.FromBitmap(b);
            using var png = img.Encode(SKEncodedImageFormat.Png, 100);
            File.WriteAllBytes(Path.Combine(dir, $"icon-{size}{(tray ? "-tray" : "")}.png"), png.ToArray());
        }

        // Hover transition PDF -> TIFF on a JPG's convert wheel, old timing vs new, in dark mode where a dip shows most.
        var metrics = new Dictionary<string, object>();
        using (var wallpaper = Wallpaper(layout.Width, layout.Height, true))
        using (var snap = Backdrop.FromImage(wallpaper, new Native.Win32.RECT(0, 0, layout.Width, layout.Height)))
        {
            foreach (var legacy in new[] { true, false })
            {
                string name = legacy ? "old" : "new";
                var (peak, bright) = WheelController.SimulateHoverTransition(WheelKind.Convert, new[] { jpg }, 4, 5, true, legacy, scale, snap,
                    Path.Combine(dir, $"transition-{name}.png"));
                metrics[name] = new Dictionary<string, object>
                {
                    ["weakestHighlight"] = Math.Round(peak.Min(), 3),
                    ["brightnessMin"] = Math.Round(bright.Min(), 1),
                    ["brightnessMax"] = Math.Round(bright.Max(), 1),
                    ["brightnessStart"] = Math.Round(bright[0], 1),
                    ["brightnessEnd"] = Math.Round(bright[^1], 1),
                    ["brightnessCurve"] = string.Join(" ", bright.Where((_, i) => i % 3 == 0).Select(b => b.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture))),
                    ["highlightCurve"] = string.Join(" ", peak.Where((_, i) => i % 3 == 0).Select(b => b.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture))),
                };
            }
        }
        return metrics;
    }

    /// <summary>Wizard images for the Inno Setup installer (BMP, several DPI sizes).</summary>
    static async Task InstallerArt(string dir)
    {
        Directory.CreateDirectory(dir);
        // Side image on the welcome/finish pages: 164x314 at 100%.
        foreach (var scale in new[] { 1.0f, 1.5f, 2.0f, 2.5f })
        {
            int w = (int)Math.Round(164 * scale), h = (int)Math.Round(314 * scale);
            using var bmp = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
            using (var c = new SKCanvas(bmp))
            {
                using var p = new SKPaint { IsAntialias = true };
                p.Shader = SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(w * 0.4f, h),
                    new[] { new SKColor(0xFF, 0xA8, 0x4C), new SKColor(0xFF, 0x5A, 0x14) }, SKShaderTileMode.Clamp);
                c.DrawRect(0, 0, w, h, p);
                p.Shader = null;
                p.Color = SKColors.White.WithAlpha(22);
                c.DrawCircle(w * 0.15f, h * 0.88f, 70 * scale, p);
                c.DrawCircle(w * 0.95f, h * 0.12f, 52 * scale, p);
                int icon = (int)(84 * scale);
                using var mark = AppIcon.Render(icon, tray: false);
                float ix = (w - icon) / 2f, iy = h * 0.30f - icon / 2f;
                p.Color = new SKColor(0, 0, 0, 70);
                p.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 6 * scale);
                c.DrawRoundRect(new SKRect(ix + 4 * scale, iy + 8 * scale, ix + icon - 4 * scale, iy + icon + 2 * scale), 18 * scale, 18 * scale, p);
                p.MaskFilter = null;
                c.DrawBitmap(mark, ix, iy);
                using var title = new SKFont(WheelRenderer.Type.Bold, 24 * scale) { Subpixel = true, Edging = SKFontEdging.Antialias };
                using var sub = new SKFont(WheelRenderer.Type.Semibold, 12 * scale) { Subpixel = true, Edging = SKFontEdging.Antialias };
                p.Color = SKColors.White;
                c.DrawText("Satsuma", w / 2f, iy + icon + 38 * scale, SKTextAlign.Center, title, p);
                p.Color = SKColors.White.WithAlpha(220);
                c.DrawText("Drag. Tap. Drop.", w / 2f, iy + icon + 60 * scale, SKTextAlign.Center, sub, p);
            }
            await Ops.Convert.ImageConverter.WriteWicAsync(bmp, Path.Combine(dir, $"wizard-{(int)(scale * 100)}.bmp"),
                Windows.Graphics.Imaging.BitmapEncoder.BmpEncoderId, null, opaque: true, null);
        }
        // Small header image: 55x55 at 100%, on white.
        foreach (var scale in new[] { 1.0f, 1.5f, 2.0f, 2.5f })
        {
            int s = (int)Math.Round(55 * scale);
            using var bmp = new SKBitmap(new SKImageInfo(s, s, SKColorType.Bgra8888, SKAlphaType.Premul));
            using (var c = new SKCanvas(bmp))
            {
                c.Clear(SKColors.White);
                using var mark = AppIcon.Render(s, tray: false);
                c.DrawBitmap(mark, 0, 0);
            }
            await Ops.Convert.ImageConverter.WriteWicAsync(bmp, Path.Combine(dir, $"small-{(int)(scale * 100)}.bmp"),
                Windows.Graphics.Imaging.BitmapEncoder.BmpEncoderId, null, opaque: true, null);
        }
    }

    static SKImage Wallpaper(int w, int h, bool dark)
    {
        using var surface = SKSurface.Create(new SKImageInfo(w, h));
        var c = surface.Canvas;
        using var p = new SKPaint { IsAntialias = true };
        p.Shader = SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(w, h),
            dark ? new[] { new SKColor(0x1B, 0x22, 0x3A), new SKColor(0x3A, 0x1D, 0x4A), new SKColor(0x0E, 0x12, 0x20) }
                 : new[] { new SKColor(0xFF, 0xB8, 0x6B), new SKColor(0xF2, 0x5C, 0x54), new SKColor(0x7B, 0x5C, 0xF0) },
            SKShaderTileMode.Clamp);
        c.DrawRect(0, 0, w, h, p);
        p.Shader = null;
        // A few "desktop icons" so the frosted glass has something to blur.
        var rnd = new Random(4);
        for (int i = 0; i < 14; i++)
        {
            p.Color = new SKColor((byte)rnd.Next(150, 255), (byte)rnd.Next(150, 255), (byte)rnd.Next(150, 255), 230);
            float x = rnd.Next(0, w), y = rnd.Next(0, h);
            c.DrawRoundRect(SKRect.Create(x, y, 70, 86), 10, 10, p);
        }
        return surface.Snapshot();
    }
}
