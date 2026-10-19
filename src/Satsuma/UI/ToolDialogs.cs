using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Satsuma.Core;
using Satsuma.Ops.Convert;
using Satsuma.Ops.Tools;
using SkiaSharp;

namespace Satsuma.UI;

public sealed record ResizeChoice(double? Scale, int? Width, int? Height);
public sealed record RedactChoice(bool Faces, bool Text, RedactStyle Style);

/// <summary>Option dialogs for interactive tools. Each returns null when the user cancels.</summary>
public static class ToolDialogs
{
    /// <summary>Headless test runs: answer every dialog with its defaults instead of opening a window.</summary>
    public static bool UseDefaults;

    static Task<T?> Default<T>(T? value) => Task.FromResult(value);
    static string Describe(IReadOnlyList<string> files) =>
        files.Count == 1
            ? $"{Path.GetFileName(files[0])} · {FileKinds.HumanSize(new FileInfo(files[0]).Length)}"
            : $"{files.Count} files · {FileKinds.HumanSize(FileKinds.TotalSize(files))}";

    /// <summary>Runs <paramref name="work"/> after input settles for a moment (for live previews).</summary>
    sealed class Debouncer(TimeSpan delay)
    {
        DispatcherTimer? _timer;
        public void Run(Action work)
        {
            _timer?.Stop();
            _timer = new DispatcherTimer { Interval = delay };
            _timer.Tick += (_, _) => { _timer.Stop(); work(); };
            _timer.Start();
        }
    }

    static Border PreviewFrame(Image image, double height = 220) => new()
    {
        Height = height, CornerRadius = new CornerRadius(8), ClipToBounds = true, Margin = new Thickness(0, 0, 0, 10),
        Background = new SolidColorBrush(Color.FromArgb(18, 128, 128, 128)), Child = image,
    };

    // ------------------------------------------------------------------ image compress

    public static Task<ImageTools.CompressOptions?> ImageCompressAsync(IReadOnlyList<string> files) => UseDefaults
        ? Default<ImageTools.CompressOptions>(new(72, 2560, null, true, null))
        : Ui.RunAsync(async () =>
    {
        var w = new ToolWindow("Compress", Describe(files), files.Count == 1 ? "Compress" : $"Compress {files.Count}");
        var mode = new Segmented(new[] { "Quality", "Target size" });
        w.Body.Children.Add(mode);

        var qualityPanel = new StackPanel();
        var quality = ToolWindow.SliderRow(qualityPanel, "Quality", 10, 95, 72, v => $"{v:0}%");
        w.Body.Children.Add(qualityPanel);

        var targetPanel = new StackPanel { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0) };
        var targetBox = new TextBox { Text = "500", Width = 90, HorizontalContentAlignment = HorizontalAlignment.Right };
        var unit = ToolWindow.Combo(new[] { "KB", "MB" }, 0);
        var targetRow = new StackPanel { Orientation = Orientation.Horizontal };
        targetRow.Children.Add(targetBox);
        unit.Margin = new Thickness(8, 0, 0, 0);
        targetRow.Children.Add(unit);
        targetPanel.Children.Add(ToolWindow.Row("Aim for at most", targetRow, 170));
        w.Body.Children.Add(targetPanel);
        mode.Changed += i => { qualityPanel.Visibility = i == 0 ? Visibility.Visible : Visibility.Collapsed; targetPanel.Visibility = i == 1 ? Visibility.Visible : Visibility.Collapsed; };

        int[] dims = { 0, 3840, 2560, 1920, 1280, 800 };
        var maxDim = ToolWindow.Combo(new[] { "Keep size", "3840 px", "2560 px", "1920 px", "1280 px", "800 px" }, 2);
        w.Body.Children.Add(ToolWindow.Section("Options"));
        w.Body.Children.Add(ToolWindow.Row("Longest side at most", maxDim));
        string?[] formats = { null, "jpg", "webp", "avif", "heic" };
        var format = ToolWindow.Combo(new[] { "Keep format", "JPG", "WebP", "AVIF", "HEIC" }, 0);
        w.Body.Children.Add(ToolWindow.Row("Save as", format));
        var strip = ToolWindow.Switch("Remove metadata (location, camera)", true);
        w.Body.Children.Add(strip);
        var estimate = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 14, 0, 0) };
        w.Body.Children.Add(estimate);

        // Live estimate from the first image.
        SKBitmap? sample = null;
        long sampleBytes = new FileInfo(files[0]).Length;
        var debounce = new Debouncer(TimeSpan.FromMilliseconds(220));
        async void Update()
        {
            if (sample == null) return;
            if (mode.SelectedIndex == 1) { estimate.Text = "Quality is chosen automatically to fit the size."; return; }
            int q = (int)quality.Value, d = dims[Math.Max(0, maxDim.SelectedIndex)];
            string fmt = formats[Math.Max(0, format.SelectedIndex)] ?? ImageTools.EditFormat(files[0], false);
            estimate.Text = "Estimating…";
            long size = await Task.Run(() =>
            {
                using var scaled = d > 0 && Math.Max(sample.Width, sample.Height) > d
                    ? ImageTools.Resample(sample, (int)(sample.Width * d / (double)Math.Max(sample.Width, sample.Height)), (int)(sample.Height * d / (double)Math.Max(sample.Width, sample.Height)))
                    : null;
                using var img = SKImage.FromBitmap(scaled ?? sample);
                using var data = img.Encode(fmt == "webp" ? SKEncodedImageFormat.Webp : SKEncodedImageFormat.Jpeg, q);
                return (long)(data.Size * (fmt is "avif" ? 0.55 : fmt is "heic" ? 0.65 : 1.0));
            });
            double pct = 100.0 * (1 - size / (double)sampleBytes);
            estimate.Text = files.Count == 1
                ? $"≈ {FileKinds.HumanSize(size)}  ({(pct >= 0 ? "−" : "+")}{Math.Abs(pct):0}%)"
                : $"First image ≈ {FileKinds.HumanSize(size)}  ({(pct >= 0 ? "−" : "+")}{Math.Abs(pct):0}%)";
        }
        quality.ValueChanged += (_, _) => debounce.Run(Update);
        maxDim.SelectionChanged += (_, _) => debounce.Run(Update);
        format.SelectionChanged += (_, _) => debounce.Run(Update);
        mode.Changed += _ => Update();
        estimate.Text = "Estimating…";
        _ = Task.Run(async () =>
        {
            try
            {
                using var d = await ImageConverter.DecodeAsync(files[0]);
                var copy = d.Bitmap.Copy();
                await w.Dispatcher.InvokeAsync(() => { sample = copy; Update(); });
            }
            catch { await w.Dispatcher.InvokeAsync(() => estimate.Text = ""); }
        });

        if (!await w.ShowAndWaitAsync()) { sample?.Dispose(); return null; }
        sample?.Dispose();
        long? target = null;
        if (mode.SelectedIndex == 1 && double.TryParse(targetBox.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var t) && t > 0)
            target = (long)(t * (unit.SelectedIndex == 1 ? 1_000_000 : 1_000));
        int dim = dims[Math.Max(0, maxDim.SelectedIndex)];
        return new ImageTools.CompressOptions((int)quality.Value, dim > 0 ? dim : null, formats[Math.Max(0, format.SelectedIndex)], strip.IsChecked == true, target);
    });

    // ------------------------------------------------------------------ image resize

    public static Task<ResizeChoice?> ImageResizeAsync(IReadOnlyList<string> files) => UseDefaults
        ? Default<ResizeChoice>(new(0.5, null, null))
        : Ui.RunAsync(async () =>
    {
        var w = new ToolWindow("Resize", Describe(files), "Resize");
        (int width, int height) original = (0, 0);
        var mode = new Segmented(new[] { "Percent", "Width", "Height", "Exact" });
        w.Body.Children.Add(mode);
        var percentPanel = new StackPanel();
        var percent = ToolWindow.SliderRow(percentPanel, "Scale", 5, 200, 50, v => $"{v:0}%", 5);
        w.Body.Children.Add(percentPanel);
        var sizePanel = new StackPanel { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0) };
        var widthBox = new TextBox { Text = "1920", Width = 80 };
        var heightBox = new TextBox { Text = "1080", Width = 80 };
        var sizeRow = new StackPanel { Orientation = Orientation.Horizontal };
        sizeRow.Children.Add(widthBox);
        sizeRow.Children.Add(new TextBlock { Text = " × ", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 6, 0) });
        sizeRow.Children.Add(heightBox);
        sizePanel.Children.Add(ToolWindow.Row("Pixels", sizeRow, 200));
        w.Body.Children.Add(sizePanel);
        var result = new TextBlock { FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 0) };
        w.Body.Children.Add(result);
        var presets = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var (label, pw) in new[] { ("4K", 3840), ("1080p", 1920), ("720p", 1280), ("Web", 1024), ("Thumb", 320) })
        {
            var b = new Button { Content = label, Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(0, 0, 6, 6) };
            b.Click += (_, _) => { mode.Select(1, true); widthBox.Text = pw.ToString(); };
            presets.Children.Add(b);
        }
        w.Body.Children.Add(presets);

        void Update()
        {
            percentPanel.Visibility = mode.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
            sizePanel.Visibility = mode.SelectedIndex == 0 ? Visibility.Collapsed : Visibility.Visible;
            widthBox.IsEnabled = mode.SelectedIndex is 1 or 3;
            heightBox.IsEnabled = mode.SelectedIndex is 2 or 3;
            if (original.width == 0) { result.Text = ""; return; }
            int.TryParse(widthBox.Text, out var wv); int.TryParse(heightBox.Text, out var hv);
            (int nw, int nh) = mode.SelectedIndex switch
            {
                0 => ((int)(original.width * percent.Value / 100), (int)(original.height * percent.Value / 100)),
                1 => (wv, (int)(original.height * (wv / (double)original.width))),
                2 => ((int)(original.width * (hv / (double)original.height)), hv),
                _ => (wv, hv),
            };
            result.Text = $"{original.width} × {original.height}  →  {nw} × {nh}";
        }
        mode.Changed += _ => Update();
        percent.ValueChanged += (_, _) => Update();
        widthBox.TextChanged += (_, _) => Update();
        heightBox.TextChanged += (_, _) => Update();
        Update();
        _ = Task.Run(async () =>
        {
            try
            {
                using var d = await ImageConverter.DecodeAsync(files[0]);
                var dims = (d.Bitmap.Width, d.Bitmap.Height);
                await w.Dispatcher.InvokeAsync(() => { original = dims; widthBox.Text = dims.Width.ToString(); heightBox.Text = dims.Height.ToString(); Update(); });
            }
            catch { }
        });

        if (!await w.ShowAndWaitAsync()) return null;
        int.TryParse(widthBox.Text, out var fw); int.TryParse(heightBox.Text, out var fh);
        return mode.SelectedIndex switch
        {
            0 => new ResizeChoice(percent.Value / 100.0, null, null),
            1 when fw > 0 => new ResizeChoice(null, fw, null),
            2 when fh > 0 => new ResizeChoice(null, null, fh),
            3 when fw > 0 && fh > 0 => new ResizeChoice(null, fw, fh),
            _ => null,
        };
    });

    // ------------------------------------------------------------------ crop

    public static Task<SKRectI?> ImageCropAsync(string file) => UseDefaults
        ? Task.FromResult<SKRectI?>(null)
        : Ui.RunAsync<SKRectI?>(async () =>
    {
        using var decoded = await ImageConverter.DecodeAsync(file);
        var w = new CropWindow(file, decoded.Bitmap);
        if (!await w.ShowAndWaitAsync()) return null;
        return w.Selection;
    });

    // ------------------------------------------------------------------ redact

    public static Task<RedactChoice?> RedactAsync(IReadOnlyList<string> files) => UseDefaults
        ? Default<RedactChoice>(new(true, false, RedactStyle.Blur))
        : Ui.RunAsync(async () =>
    {
        var w = new ToolWindow("Redact", Describe(files) + " · detection runs on this PC", "Redact", 520);
        var image = new Image { Stretch = Stretch.Uniform };
        w.Body.Children.Add(PreviewFrame(image, 260));
        var status = ToolWindow.Hint("Looking for faces and text…");
        w.Body.Children.Add(status);
        var faces = ToolWindow.Switch("Blur faces", true);
        var text = ToolWindow.Switch("Blur text", false);
        w.Body.Children.Add(faces);
        w.Body.Children.Add(text);
        w.Body.Children.Add(ToolWindow.Section("Style"));
        var style = new Segmented(new[] { "Blur", "Pixelate", "Black box" });
        w.Body.Children.Add(style);

        SKBitmap? preview = null;
        List<SKRect> faceRects = new(), textRects = new();
        float k = 1;
        void Render()
        {
            if (preview == null) return;
            using var copy = preview.Copy();
            var regions = new List<(SKRect, bool)>();
            SKRect Scale(SKRect r) => new(r.Left * k, r.Top * k, r.Right * k, r.Bottom * k);
            if (faces.IsChecked == true) regions.AddRange(faceRects.Select(r => (Scale(r), true)));
            if (text.IsChecked == true) regions.AddRange(textRects.Select(r => (Scale(r), false)));
            ImageTools.ApplyRedactions(copy, regions, (RedactStyle)style.SelectedIndex);
            image.Source = ToolWindow.ToSource(copy);
            int count = regions.Count;
            status.Text = count == 0 ? "Nothing selected to redact." : $"{count} area{(count == 1 ? "" : "s")} will be covered" + (files.Count > 1 ? " in the first image (others are detected when you click Redact)." : ".");
            w.Primary.IsEnabled = faces.IsChecked == true || text.IsChecked == true;
        }
        faces.Click += (_, _) => Render();
        text.Click += (_, _) => Render();
        style.Changed += _ => Render();
        _ = Task.Run(async () =>
        {
            try
            {
                using var d = await ImageConverter.DecodeAsync(files[0]);
                var fr = await ImageTools.DetectFacesAsync(d.Bitmap);
                List<SKRect> tr;
                try { tr = await ImageTools.DetectTextAsync(d.Bitmap); } catch { tr = new(); }
                float scale = Math.Min(1, 1000f / Math.Max(d.Bitmap.Width, d.Bitmap.Height));
                var small = ImageTools.Resample(d.Bitmap, (int)(d.Bitmap.Width * scale), (int)(d.Bitmap.Height * scale));
                await w.Dispatcher.InvokeAsync(() =>
                {
                    preview = small; faceRects = fr; textRects = tr; k = scale;
                    if (fr.Count == 0 && tr.Count > 0) { faces.IsChecked = false; text.IsChecked = true; }
                    Render();
                    if (fr.Count == 0 && tr.Count == 0)
                    {
                        status.Text = files.Count == 1 ? "No faces or text found in this image." : "No faces or text in the first image; the others are checked when you click Redact.";
                        w.Primary.IsEnabled = files.Count > 1;
                    }
                    else status.Text = $"Found {fr.Count} face{(fr.Count == 1 ? "" : "s")} and {tr.Count} line{(tr.Count == 1 ? "" : "s")} of text. " + status.Text;
                });
            }
            catch (Exception ex) { await w.Dispatcher.InvokeAsync(() => status.Text = "Detection failed: " + ex.Message); }
        });
        if (!await w.ShowAndWaitAsync()) { preview?.Dispose(); return null; }
        preview?.Dispose();
        return new RedactChoice(faces.IsChecked == true, text.IsChecked == true, (RedactStyle)style.SelectedIndex);
    });

    // ------------------------------------------------------------------ background

    static readonly (string name, SKColor[] colors)[] Backdrops =
    {
        ("Tangerine", new[] { new SKColor(0xFF, 0xC4, 0x7A), new SKColor(0xFF, 0x5A, 0x14) }),
        ("Sunset", new[] { new SKColor(0xFF, 0x9A, 0x8B), new SKColor(0xA1, 0x55, 0xE8) }),
        ("Ocean", new[] { new SKColor(0x4F, 0xC3, 0xF7), new SKColor(0x2B, 0x4E, 0xE0) }),
        ("Mint", new[] { new SKColor(0xA8, 0xF0, 0xC6), new SKColor(0x1F, 0xA2, 0x7E) }),
        ("Graphite", new[] { new SKColor(0x4A, 0x4A, 0x55), new SKColor(0x15, 0x15, 0x1A) }),
        ("Paper", new[] { new SKColor(0xFA, 0xF7, 0xF2) }),
        ("White", new[] { SKColors.White }),
        ("Black", new[] { SKColors.Black }),
    };

    static WrapPanel Swatches(Action<int> picked, int selected)
    {
        var panel = new WrapPanel { Margin = new Thickness(0, 2, 0, 4) };
        var borders = new List<Border>();
        for (int i = 0; i < Backdrops.Length; i++)
        {
            int index = i;
            var (name, colors) = Backdrops[i];
            Brush fill = colors.Length > 1
                ? new LinearGradientBrush(Color.FromRgb(colors[0].Red, colors[0].Green, colors[0].Blue), Color.FromRgb(colors[1].Red, colors[1].Green, colors[1].Blue), 45)
                : new SolidColorBrush(Color.FromRgb(colors[0].Red, colors[0].Green, colors[0].Blue));
            var b = new Border { Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Background = fill, Margin = new Thickness(0, 0, 8, 8), ToolTip = name, Cursor = System.Windows.Input.Cursors.Hand, BorderThickness = new Thickness(2.5) };
            b.MouseLeftButtonUp += (_, _) => { foreach (var o in borders) o.BorderBrush = Brushes.Transparent; b.BorderBrush = (Brush)Application.Current.FindResource("Tangerine"); picked(index); };
            b.BorderBrush = i == selected ? (Brush)Application.Current.FindResource("Tangerine") : new SolidColorBrush(Color.FromArgb(40, 128, 128, 128));
            borders.Add(b);
            panel.Children.Add(b);
        }
        return panel;
    }

    public static Task<ImageTools.BackgroundOptions?> BackgroundAsync(IReadOnlyList<string> files) => UseDefaults
        ? Default<ImageTools.BackgroundOptions>(new(Backdrops[0].colors, 0.08f, 0.03f, null, true))
        : Ui.RunAsync(async () =>
    {
        var w = new ToolWindow("Backdrop", "Put the image on a background. Handy for screenshots.", "Save", 520);
        var image = new Image { Stretch = Stretch.Uniform };
        w.Body.Children.Add(PreviewFrame(image, 240));
        int swatch = 0;
        Action? render = null;
        w.Body.Children.Add(Swatches(i => { swatch = i; render?.Invoke(); }, 0));
        var padding = ToolWindow.SliderRow(w.Body, "Spacing", 0, 30, 8, v => $"{v:0}%");
        var radius = ToolWindow.SliderRow(w.Body, "Corner radius", 0, 15, 3, v => $"{v:0}%");
        var shadow = ToolWindow.Switch("Drop shadow", true);
        w.Body.Children.Add(shadow);
        w.Body.Children.Add(ToolWindow.Section("Shape"));
        float?[] aspects = { null, 1f, 4f / 3f, 16f / 9f, 9f / 16f };
        var aspect = new Segmented(new[] { "Auto", "1:1", "4:3", "16:9", "9:16" });
        w.Body.Children.Add(aspect);

        SKBitmap? small = null;
        ImageTools.BackgroundOptions Options() => new(Backdrops[swatch].colors, (float)padding.Value / 100f, (float)radius.Value / 100f, aspects[aspect.SelectedIndex], shadow.IsChecked == true);
        void Render()
        {
            if (small == null) return;
            using var composed = ImageTools.ComposeBackground(small, Options());
            image.Source = ToolWindow.ToSource(composed);
        }
        render = Render;
        padding.ValueChanged += (_, _) => Render();
        radius.ValueChanged += (_, _) => Render();
        shadow.Click += (_, _) => Render();
        aspect.Changed += _ => Render();
        _ = Task.Run(async () =>
        {
            using var d = await ImageConverter.DecodeAsync(files[0]);
            float s = Math.Min(1, 640f / Math.Max(d.Bitmap.Width, d.Bitmap.Height));
            var bmp = ImageTools.Resample(d.Bitmap, (int)(d.Bitmap.Width * s), (int)(d.Bitmap.Height * s));
            await w.Dispatcher.InvokeAsync(() => { small = bmp; Render(); });
        });
        if (!await w.ShowAndWaitAsync()) { small?.Dispose(); return null; }
        small?.Dispose();
        return Options();
    });

    // ------------------------------------------------------------------ collage

    public static Task<ImageTools.CollageOptions?> CollageAsync(IReadOnlyList<string> files) => UseDefaults
        ? Default<ImageTools.CollageOptions>(new(ImageTools.CollageLayout.Grid, 16, 0.03f, SKColors.White, 2400))
        : Ui.RunAsync(async () =>
    {
        var w = new ToolWindow("Collage", $"{files.Count} images", "Make collage", 540);
        var image = new Image { Stretch = Stretch.Uniform };
        w.Body.Children.Add(PreviewFrame(image, 260));
        var layout = new Segmented(new[] { "Grid", "Row", "Column", "Featured" });
        w.Body.Children.Add(layout);
        var spacing = ToolWindow.SliderRow(w.Body, "Spacing", 0, 60, 16, v => $"{v:0} px");
        var radius = ToolWindow.SliderRow(w.Body, "Corner radius", 0, 15, 3, v => $"{v:0}%");
        w.Body.Children.Add(ToolWindow.Section("Background"));
        int swatch = 6;
        Action? render = null;
        w.Body.Children.Add(Swatches(i => { swatch = i; render?.Invoke(); }, 6));
        int[] widths = { 1600, 2400, 3600 };
        var width = ToolWindow.Combo(new[] { "1600 px wide", "2400 px wide", "3600 px wide" }, 1);
        w.Body.Children.Add(ToolWindow.Row("Size", width));

        var thumbs = new List<SKBitmap>();
        ImageTools.CollageOptions Options(int outWidth) => new((ImageTools.CollageLayout)layout.SelectedIndex, (float)spacing.Value * outWidth / 2400f,
            (float)radius.Value / 100f, Backdrops[swatch].colors[0], outWidth);
        void Render()
        {
            if (thumbs.Count == 0) return;
            using var c = ImageTools.ComposeCollage(thumbs, Options(800));
            image.Source = ToolWindow.ToSource(c);
        }
        render = Render;
        layout.Changed += _ => Render();
        spacing.ValueChanged += (_, _) => Render();
        radius.ValueChanged += (_, _) => Render();
        _ = Task.Run(async () =>
        {
            var list = new List<SKBitmap>();
            foreach (var f in files.Take(24))
            {
                try
                {
                    using var d = await ImageConverter.DecodeAsync(f);
                    float s = Math.Min(1, 500f / Math.Max(d.Bitmap.Width, d.Bitmap.Height));
                    list.Add(ImageTools.Resample(d.Bitmap, (int)(d.Bitmap.Width * s), (int)(d.Bitmap.Height * s)));
                }
                catch { }
            }
            await w.Dispatcher.InvokeAsync(() => { thumbs.AddRange(list); Render(); });
        });
        bool ok = await w.ShowAndWaitAsync();
        foreach (var t in thumbs) t.Dispose();
        return ok ? Options(widths[Math.Max(0, width.SelectedIndex)]) : null;
    });

    // ------------------------------------------------------------------ video / audio

    public static Task<MediaTools.VideoCompressOptions?> VideoCompressAsync(IReadOnlyList<string> files) => UseDefaults
        ? Default<MediaTools.VideoCompressOptions>(new(28, 1080, 128, null))
        : Ui.RunAsync(async () =>
    {
        var info = await Task.Run(() => Ffmpeg.Probe(files[0]));
        string res = info.Video is { } v ? $" · {v.Width}×{v.Height}" : "";
        var w = new ToolWindow("Compress video", Describe(files) + res + (info.Duration > 0 ? $" · {TimeSpan.FromSeconds(info.Duration):m\\:ss}" : ""), "Compress");
        var preset = new Segmented(new[] { "Balanced", "Smaller", "Smallest", "Target size" });
        w.Body.Children.Add(preset);
        var hint = ToolWindow.Hint("");
        w.Body.Children.Add(hint);
        int[] heights = { 0, 2160, 1440, 1080, 720, 480 };
        var resolution = ToolWindow.Combo(new[] { "Keep resolution", "4K (2160p)", "1440p", "1080p", "720p", "480p" }, 3);
        w.Body.Children.Add(ToolWindow.Section("Options"));
        w.Body.Children.Add(ToolWindow.Row("Resolution at most", resolution));
        int[] audios = { 64, 96, 128, 160, 192 };
        var audio = ToolWindow.Combo(new[] { "64 kbps", "96 kbps", "128 kbps", "160 kbps", "192 kbps" }, 2);
        w.Body.Children.Add(ToolWindow.Row("Audio", audio));
        var targetPanel = new StackPanel { Visibility = Visibility.Collapsed };
        var targetBox = new TextBox { Text = "25", Width = 80 };
        var targetRow = new StackPanel { Orientation = Orientation.Horizontal };
        targetRow.Children.Add(targetBox);
        targetRow.Children.Add(new TextBlock { Text = " MB", VerticalAlignment = VerticalAlignment.Center });
        targetPanel.Children.Add(ToolWindow.Row("Aim for at most", targetRow));
        w.Body.Children.Add(targetPanel);
        int[] crfs = { 23, 28, 32 };
        void Update(int i)
        {
            targetPanel.Visibility = i == 3 ? Visibility.Visible : Visibility.Collapsed;
            hint.Text = i switch
            {
                0 => "Visually close to the original, usually 40–70% smaller.",
                1 => "Noticeably smaller files; fine for sharing in chats.",
                2 => "As small as possible; softer image.",
                _ => "Two passes to land right under the size (e.g. 25 MB for mail, 10 MB for Discord).",
            };
            if (i == 2 && resolution.SelectedIndex < 4) resolution.SelectedIndex = 4;
        }
        preset.Changed += Update;
        Update(0);
        if (!await w.ShowAndWaitAsync()) return null;
        int p = preset.SelectedIndex;
        long? target = p == 3 && double.TryParse(targetBox.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var mb) && mb > 0 ? (long)(mb * 1_000_000) : null;
        int h = heights[Math.Max(0, resolution.SelectedIndex)];
        return new MediaTools.VideoCompressOptions(crfs[Math.Min(p, 2)], h > 0 ? h : null, audios[Math.Max(0, audio.SelectedIndex)], target);
    });

    public static Task<int?> AudioCompressAsync(IReadOnlyList<string> files) => UseDefaults
        ? Task.FromResult<int?>(128)
        : Ui.RunAsync<int?>(async () =>
    {
        var info = await Task.Run(() => Ffmpeg.Probe(files[0]));
        var w = new ToolWindow("Compress audio", Describe(files), "Compress");
        int[] rates = { 64, 96, 128, 160, 192 };
        var rate = new Segmented(new[] { "64", "96", "128", "160", "192" }, 2);
        w.Body.Children.Add(ToolWindow.Row("Bitrate (kbps)", rate, 260));
        var est = new TextBlock { FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 0) };
        w.Body.Children.Add(est);
        w.Body.Children.Add(ToolWindow.Hint("128 kbps sounds great for speech and most music. 64–96 kbps is fine for podcasts and voice notes."));
        void Update(int i) => est.Text = info.Duration > 0 ? $"≈ {FileKinds.HumanSize((long)(info.Duration * rates[i] * 1000 / 8))} per file" : "";
        rate.Changed += Update;
        Update(2);
        if (!await w.ShowAndWaitAsync()) return null;
        return rates[rate.SelectedIndex];
    });

    public static Task<(double start, double end)?> TrimAsync(string file) => UseDefaults
        ? Task.FromResult<(double start, double end)?>(null)
        : Ui.RunAsync<(double, double)?>(async () =>
    {
        var info = await Task.Run(() => Ffmpeg.Probe(file));
        if (info.Duration <= 0) throw new Ops.OpException("Couldn't read the duration of this file.");
        var w = new TrimWindow(file, info);
        if (!await w.ShowAndWaitAsync()) return null;
        return (w.Start, w.End);
    });

    public static Task<List<int>?> PagesAsync(string file) => UseDefaults
        ? Default<List<int>>(new() { 1 })
        : Ui.RunAsync(async () =>
    {
        var w = new PagesWindow(file);
        if (!await w.ShowAndWaitAsync()) return null;
        var pages = w.SelectedPages;
        return pages.Count == 0 ? null : pages;
    });
}
