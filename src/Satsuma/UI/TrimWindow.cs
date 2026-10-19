using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Satsuma.Core;
using Satsuma.Ops.Convert;
using Rectangle = System.Windows.Shapes.Rectangle;

namespace Satsuma.UI;

/// <summary>Trim audio/video: waveform with the kept range highlighted, start/end frames for video.</summary>
public sealed class TrimWindow : ToolWindow
{
    readonly string _file;
    readonly MediaInfo _info;
    readonly Slider _start, _end;
    readonly Rectangle _leftShade = new() { Fill = new SolidColorBrush(Color.FromArgb(150, 20, 20, 24)), IsHitTestVisible = false };
    readonly Rectangle _rightShade = new() { Fill = new SolidColorBrush(Color.FromArgb(150, 20, 20, 24)), IsHitTestVisible = false };
    readonly Canvas _waveCanvas = new() { Height = 96 };
    readonly Image _startFrame = new() { Stretch = Stretch.Uniform }, _endFrame = new() { Stretch = Stretch.Uniform };
    readonly TextBlock _summary = new() { FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 10, 0, 0) };
    readonly string _tmp = AppPaths.NewTempDir("trim");
    readonly DispatcherTimer _frameTimer = new() { Interval = TimeSpan.FromMilliseconds(180) };
    int _frameVersion;

    public double Start => _start.Value;
    public double End => _end.Value;

    static string T(double s) => TimeSpan.FromSeconds(s).ToString(s >= 3600 ? @"h\:mm\:ss\.f" : @"m\:ss\.f");

    public TrimWindow(string file, MediaInfo info) : base("Trim", $"{Path.GetFileName(file)} · {T(info.Duration)}", "Trim", 620)
    {
        _file = file;
        _info = info;
        bool video = info.Video != null;
        if (video)
        {
            var frames = new Grid { Height = 150, Margin = new Thickness(0, 0, 0, 10) };
            frames.ColumnDefinitions.Add(new ColumnDefinition());
            frames.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
            frames.ColumnDefinitions.Add(new ColumnDefinition());
            var a = FrameBox(_startFrame, "Start");
            var b = FrameBox(_endFrame, "End");
            Grid.SetColumn(b, 2);
            frames.Children.Add(a);
            frames.Children.Add(b);
            Body.Children.Add(frames);
        }
        var wave = new Border
        {
            Height = 96, CornerRadius = new CornerRadius(8), ClipToBounds = true,
            Background = new SolidColorBrush(Color.FromArgb(22, 128, 128, 128)), Child = _waveCanvas,
        };
        Body.Children.Add(wave);
        _start = SliderRow(Body, "Start", 0, info.Duration, 0, T, 0.1);
        _end = SliderRow(Body, "End", 0, info.Duration, info.Duration, T, 0.1);
        _start.ValueChanged += (_, _) => { if (_start.Value > _end.Value - 0.1) _start.Value = Math.Max(0, _end.Value - 0.1); Changed(); };
        _end.ValueChanged += (_, _) => { if (_end.Value < _start.Value + 0.1) _end.Value = Math.Min(info.Duration, _start.Value + 0.1); Changed(); };
        Body.Children.Add(_summary);
        Body.Children.Add(Hint("Cuts are frame-accurate; the result is re-encoded at high quality."));
        wave.SizeChanged += (_, _) => Layout();
        _frameTimer.Tick += (_, _) => { _frameTimer.Stop(); _ = LoadFramesAsync(); };
        Closed += (_, _) => { try { Directory.Delete(_tmp, true); } catch { } };
        Changed();
        _ = LoadWaveformAsync();
        if (video) _ = LoadFramesAsync();
    }

    static Border FrameBox(Image image, string label)
    {
        var g = new Grid();
        g.Children.Add(image);
        g.Children.Add(new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)), CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 1, 6, 1),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(6),
            Child = new TextBlock { Text = label, Foreground = Brushes.White, FontSize = 11 },
        });
        return new Border { CornerRadius = new CornerRadius(8), ClipToBounds = true, Background = new SolidColorBrush(Color.FromArgb(30, 0, 0, 0)), Child = g };
    }

    void Changed()
    {
        _summary.Text = $"Keep {T(_start.Value)} → {T(_end.Value)}  ({_end.Value - _start.Value:0.0} s)";
        Layout();
        _frameTimer.Stop();
        _frameTimer.Start();
    }

    void Layout()
    {
        double w = _waveCanvas.ActualWidth, h = _waveCanvas.ActualHeight;
        if (w <= 0) return;
        double a = _start.Value / _info.Duration * w, b = _end.Value / _info.Duration * w;
        if (!_waveCanvas.Children.Contains(_leftShade)) { _waveCanvas.Children.Add(_leftShade); _waveCanvas.Children.Add(_rightShade); }
        Canvas.SetLeft(_leftShade, 0); _leftShade.Width = Math.Max(0, a); _leftShade.Height = h;
        Canvas.SetLeft(_rightShade, b); _rightShade.Width = Math.Max(0, w - b); _rightShade.Height = h;
    }

    async Task LoadWaveformAsync()
    {
        if (_info.Audio == null) return;
        string png = Path.Combine(_tmp, "wave.png");
        try
        {
            await Ffmpeg.RunAsync($"-i {Ffmpeg.Q(_file)} -filter_complex \"aformat=channel_layouts=mono,showwavespic=s=1200x200:colors=0xFF7A1A\" -frames:v 1 {Ffmpeg.Q(png)}", 0, null, CancellationToken.None);
            var img = new Image { Source = Load(png), Stretch = Stretch.Fill, Height = 96 };
            img.Width = Math.Max(1, _waveCanvas.ActualWidth);
            _waveCanvas.SizeChanged += (_, _) => img.Width = _waveCanvas.ActualWidth;
            _waveCanvas.Children.Insert(0, img);
            Layout();
        }
        catch (Exception ex) { Log.Info("Waveform failed: " + ex.Message); }
    }

    async Task LoadFramesAsync()
    {
        if (_info.Video == null) return;
        int version = ++_frameVersion;
        double s = _start.Value, e = Math.Max(0, _end.Value - 0.05);
        string a = Path.Combine(_tmp, $"s{version}.jpg"), b = Path.Combine(_tmp, $"e{version}.jpg");
        try
        {
            await Task.WhenAll(
                Ffmpeg.RunAsync($"-ss {s.ToString(System.Globalization.CultureInfo.InvariantCulture)} -i {Ffmpeg.Q(_file)} -frames:v 1 -vf scale=480:-2 {Ffmpeg.Q(a)}", 0, null, CancellationToken.None),
                Ffmpeg.RunAsync($"-ss {e.ToString(System.Globalization.CultureInfo.InvariantCulture)} -i {Ffmpeg.Q(_file)} -frames:v 1 -vf scale=480:-2 {Ffmpeg.Q(b)}", 0, null, CancellationToken.None));
            if (version != _frameVersion) return;
            if (File.Exists(a)) _startFrame.Source = Load(a);
            if (File.Exists(b)) _endFrame.Source = Load(b);
        }
        catch (Exception ex) { Log.Info("Frame preview failed: " + ex.Message); }
    }

    static BitmapImage Load(string path)
    {
        var bi = new BitmapImage();
        bi.BeginInit();
        bi.CacheOption = BitmapCacheOption.OnLoad; // don't keep the temp file locked
        bi.UriSource = new Uri(path);
        bi.EndInit();
        bi.Freeze();
        return bi;
    }
}
