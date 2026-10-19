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
    static readonly string[] Verbs = { "--convert", "--tool", "--list", "--render-test", "--make-icon", "--demo-wheel", "--selftest", "--render-ui" };

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
                case "--render-test":
                    RenderTest(rest[0]);
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

    /// <summary>Renders the wheel over a synthetic wallpaper at several animation states.</summary>
    static void RenderTest(string dir)
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
