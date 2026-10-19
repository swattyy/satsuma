using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SkiaSharp;

namespace Satsuma.UI;

/// <summary>
/// Shared chrome for tool option dialogs: title + subtitle, a body, and Cancel / primary buttons.
/// Opens near the pointer, in front, and resolves <see cref="ShowAndWaitAsync"/> with true when confirmed.
/// </summary>
public class ToolWindow : Window
{
    public readonly StackPanel Body = new();
    public readonly Button Primary;
    readonly TaskCompletionSource<bool> _tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly TextBlock _subtitle;

    public ToolWindow(string title, string subtitle, string primaryText, double width = 460)
    {
        Title = title + " - Satsuma";
        Width = width;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        ShowInTaskbar = true;
        Icon = AppIconImage;

        var root = new DockPanel { Margin = new Thickness(24, 20, 24, 20) };
        var header = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
        header.Children.Add(new TextBlock { Text = title, FontSize = 20, FontWeight = FontWeights.SemiBold });
        _subtitle = new TextBlock { Text = subtitle, Opacity = 0.7, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) };
        header.Children.Add(_subtitle);
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);

        var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        var cancel = new Button { Content = "Cancel", Padding = new Thickness(16, 6, 16, 6), Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
        cancel.Click += (_, _) => Close();
        Primary = new Button { Content = primaryText, IsDefault = true, Style = (Style)Application.Current.FindResource("SatsumaAccentButton") };
        Primary.Click += (_, _) => Accept();
        footer.Children.Add(cancel);
        footer.Children.Add(Primary);
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(Body);
        Content = root;
        Closed += (_, _) => _tcs.TrySetResult(false);
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    public string Subtitle { set => _subtitle.Text = value; }

    /// <summary>Test mode: dialogs render their content to PNG files here instead of opening on screen.</summary>
    public static string? RenderOnlyDir;

    public async Task<bool> ShowAndWaitAsync()
    {
        if (RenderOnlyDir != null)
        {
            await Task.Delay(2500); // let async previews/estimates arrive
            RenderContent(this, Path.Combine(RenderOnlyDir, "dialog-" + Title.Split(' ')[0].ToLowerInvariant() + ".png"), Width);
            Close();
            return false;
        }
        return await ShowOnScreenAsync();
    }

    /// <summary>Renders a window's content offscreen without showing it. Used for visual tests.</summary>
    public static void RenderContent(Window w, string path, double width)
    {
        var content = (FrameworkElement)w.Content;
        w.Content = null;
        bool dark = Overlay.ThemeInfo.IsDark;
        var host = new Border
        {
            Width = width, Child = content,
            Background = new SolidColorBrush(dark ? Color.FromRgb(0x20, 0x20, 0x20) : Color.FromRgb(0xF3, 0xF3, 0xF3)),
        };
        host.SetResourceReference(TextElement.ForegroundProperty, "TextFillColorPrimaryBrush");
        host.Measure(new Size(width, double.PositiveInfinity));
        host.Arrange(new Rect(host.DesiredSize));
        host.UpdateLayout();
        const double scale = 1.5;
        var rtb = new RenderTargetBitmap((int)Math.Ceiling(host.ActualWidth * scale), (int)Math.Ceiling(host.ActualHeight * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        rtb.Render(host);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        using var fs = File.Create(path);
        enc.Save(fs);
        host.Child = null;
    }

    Task<bool> ShowOnScreenAsync()
    {
        Native.Win32.GetCursorPos(out var pt);
        Loaded += (_, _) => Ui.PlaceNear(this, pt, ActualWidth, ActualHeight);
        Ui.PlaceNear(this, pt, Width, 420);
        Show();
        Ui.ForceForeground(this);
        return _tcs.Task;
    }

    protected void Accept()
    {
        _tcs.TrySetResult(true);
        Close();
    }

    // ------------------------------------------------------------------ building blocks

    static ImageSource? _appIcon;
    static ImageSource? AppIconImage => _appIcon ??= ToSource(AppIcon.Render(64, tray: false), dispose: true);

    public static TextBlock Section(string text) => new()
    {
        Text = text, FontWeight = FontWeights.SemiBold, FontSize = 13, Margin = new Thickness(0, 12, 0, 6),
    };

    public static TextBlock Hint(string text) => new()
    {
        Text = text, Opacity = 0.7, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
    };

    public static FrameworkElement Row(string label, UIElement control, double controlWidth = 190)
    {
        var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(controlWidth) });
        var t = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
        g.Children.Add(t);
        Grid.SetColumn(control, 1);
        g.Children.Add(control);
        return g;
    }

    /// <summary>A slider with a live value label; returns the slider.</summary>
    public static Slider SliderRow(Panel host, string label, double min, double max, double value, Func<double, string> format, double tick = 1)
    {
        var top = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
        var val = new TextBlock { FontWeight = FontWeights.SemiBold, MinWidth = 60, TextAlignment = TextAlignment.Right };
        DockPanel.SetDock(val, Dock.Right);
        top.Children.Add(val);
        top.Children.Add(new TextBlock { Text = label });
        var slider = new Slider { Minimum = min, Maximum = max, Value = value, TickFrequency = tick, IsSnapToTickEnabled = true, Margin = new Thickness(0, 4, 0, 2) };
        val.Text = format(value);
        slider.ValueChanged += (_, e) => val.Text = format(e.NewValue);
        host.Children.Add(top);
        host.Children.Add(slider);
        return slider;
    }

    public static CheckBox Switch(string text, bool on) => new()
    {
        Content = text, IsChecked = on, Style = (Style)Application.Current.FindResource("Switch"), Margin = new Thickness(0, 8, 0, 0),
    };

    public static ComboBox Combo(IEnumerable<string> items, int selected)
    {
        var c = new ComboBox();
        foreach (var i in items) c.Items.Add(i);
        c.SelectedIndex = selected;
        return c;
    }

    public static ImageSource ToSource(SKBitmap bmp, bool dispose = false)
    {
        var src = bmp.ColorType == SKColorType.Bgra8888 ? bmp : bmp.Copy(SKColorType.Bgra8888);
        var wb = new WriteableBitmap(src.Width, src.Height, 96, 96, PixelFormats.Pbgra32, null);
        wb.WritePixels(new Int32Rect(0, 0, src.Width, src.Height), src.GetPixels(), src.RowBytes * src.Height, src.RowBytes);
        wb.Freeze();
        if (!ReferenceEquals(src, bmp)) src.Dispose();
        if (dispose) bmp.Dispose();
        return wb;
    }
}

/// <summary>A row of mutually exclusive pill buttons.</summary>
public sealed class Segmented : Border
{
    readonly List<ToggleButton> _buttons = new();
    int _selected;
    public event Action<int>? Changed;

    public Segmented(IEnumerable<string> options, int selected = 0)
    {
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        SetResourceReference(BorderBrushProperty, "ControlStrokeColorDefaultBrush");
        Padding = new Thickness(3);
        HorizontalAlignment = HorizontalAlignment.Left;
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        int i = 0;
        foreach (var o in options)
        {
            int index = i++;
            var b = new ToggleButton
            {
                Content = o, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(1, 0, 1, 0), BorderThickness = new Thickness(0),
                Background = Brushes.Transparent, Cursor = Cursors.Hand, FocusVisualStyle = null,
            };
            b.Click += (_, _) => Select(index, true);
            _buttons.Add(b);
            panel.Children.Add(b);
        }
        Child = panel;
        Select(selected, false);
    }

    public int SelectedIndex => _selected;

    public void Select(int index, bool notify)
    {
        _selected = index;
        for (int i = 0; i < _buttons.Count; i++)
        {
            bool on = i == index;
            _buttons[i].IsChecked = on;
            _buttons[i].Background = on ? (Brush)Application.Current.FindResource("TangerineGradient") : Brushes.Transparent;
            if (on) _buttons[i].Foreground = Brushes.White;
            else _buttons[i].ClearValue(Control.ForegroundProperty);
            _buttons[i].FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
        }
        if (notify) Changed?.Invoke(index);
    }
}
