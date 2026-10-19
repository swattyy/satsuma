using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Satsuma.Core;
using Satsuma.Native;
using Satsuma.Wheel;
using SkiaSharp;

namespace Satsuma.UI;

public partial class WelcomeWindow : Window
{
    static WelcomeWindow? _instance;
    readonly string _sample;
    Point _down;
    bool _pressed;

    public static void ShowSingle()
    {
        if (_instance == null)
        {
            _instance = new WelcomeWindow();
            _instance.Closed += (_, _) => _instance = null;
            _instance.Show();
        }
        Ui.ForceForeground(_instance);
    }

    public WelcomeWindow()
    {
        InitializeComponent();
        using (var icon = AppIcon.Render(96, tray: false)) Logo.Source = ToImage(icon);
        AddKey(Settings.Current.ConvertKey, "Convert");
        AddKey(Settings.Current.ToolsKey, "Tools");
        AddKey(Settings.Current.ActionsKey, "Actions");
        StartupSwitch.IsChecked = Settings.Current.FirstRunDone ? Settings.Current.LaunchAtStartup : true;

        _sample = EnsureSample();
        SampleThumb.Source = new BitmapImage(new Uri(_sample));
        PracticeText.Text = $"Drag this picture a little, tap {WheelRenderer.KeyName(Settings.Current.ConvertKey).Replace("⇧ ", "")}, then drop it on WEBP.";

        Practice.PreviewMouseLeftButtonDown += (_, e) => { _down = e.GetPosition(this); _pressed = true; };
        Practice.PreviewMouseLeftButtonUp += (_, _) => _pressed = false;
        Practice.PreviewMouseMove += OnPracticeMove;
        Done.Click += (_, _) =>
        {
            Settings.Current.FirstRunDone = true;
            try { Settings.Current.LaunchAtStartup = StartupSwitch.IsChecked == true; } catch { }
            Settings.Save();
            Close();
        };
    }

    void AddKey(TriggerKey key, string label)
    {
        if (key == TriggerKey.None) return;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 5) };
        var cap = new Border { Style = (Style)FindResource("KeyCap"), Child = new TextBlock { Text = WheelRenderer.KeyName(key), FontSize = 11.5, FontWeight = FontWeights.SemiBold } };
        row.Children.Add(cap);
        row.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, FontSize = 12.5 });
        KeyList.Children.Add(row);
    }

    void OnPracticeMove(object sender, MouseEventArgs e)
    {
        if (!_pressed || e.LeftButton != MouseButtonState.Pressed) return;
        var p = e.GetPosition(this);
        if (Math.Abs(p.X - _down.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(p.Y - _down.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _pressed = false;
        if (!File.Exists(_sample)) EnsureSample();
        // A real shell drag (with the system drag image), exactly like dragging from Explorer.
        ShellDrag.DoDragDrop(new WindowInteropHelper(this).Handle, new[] { _sample }, DropEffects.Copy | DropEffects.Link);
        PracticeText.Text = "Nice. Converted files show up next to the original. Click the bubble to open the folder.";
    }

    static string EnsureSample()
    {
        var dir = Path.Combine(AppPaths.LocalDir, "Try");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "sample.png");
        if (File.Exists(path)) return path;
        using var bmp = new SKBitmap(1200, 800);
        using (var c = new SKCanvas(bmp))
        {
            using var paint = new SKPaint { IsAntialias = true };
            paint.Shader = SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(1200, 800),
                new[] { new SKColor(0xFF, 0xC9, 0x7A), new SKColor(0xFF, 0x7A, 0x1A), new SKColor(0xD9, 0x3F, 0x1E) }, SKShaderTileMode.Clamp);
            c.DrawRect(0, 0, 1200, 800, paint);
            paint.Shader = null;
            paint.Color = new SKColor(255, 255, 255, 60);
            for (int i = 0; i < 7; i++) c.DrawCircle(160 + i * 160, 620 - (i % 3) * 120, 70 + (i % 2) * 40, paint);
            paint.Color = new SKColor(255, 255, 255, 235);
            using var font = new SKFont(WheelRenderer.Type.Bold, 120);
            c.DrawText("Satsuma", 600, 400, SKTextAlign.Center, font, paint);
            using var small = new SKFont(WheelRenderer.Type.Semibold, 40);
            paint.Color = new SKColor(255, 255, 255, 200);
            c.DrawText("a sample picture to convert", 600, 470, SKTextAlign.Center, small, paint);
        }
        using var img = SKImage.FromBitmap(bmp);
        using var data = img.Encode(SKEncodedImageFormat.Png, 100);
        File.WriteAllBytes(path, data.ToArray());
        return path;
    }

    static BitmapSource ToImage(SKBitmap bmp)
    {
        using var img = SKImage.FromBitmap(bmp);
        using var png = img.Encode(SKEncodedImageFormat.Png, 100);
        var bi = new BitmapImage();
        bi.BeginInit();
        bi.StreamSource = new MemoryStream(png.ToArray());
        bi.CacheOption = BitmapCacheOption.OnLoad;
        bi.EndInit();
        bi.Freeze();
        return bi;
    }
}
