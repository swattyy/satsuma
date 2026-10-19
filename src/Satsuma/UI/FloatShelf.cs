using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Satsuma.Core;
using Satsuma.Native;
using Brush = System.Windows.Media.Brush;
using Color = System.Windows.Media.Color;

namespace Satsuma.UI;

/// <summary>
/// A small always-on-top shelf for parking files: drop files on it (or use the Float action), then drag them out
/// into any app. Dragging out uses the real shell drag, so Explorer, browsers and mail clients all accept it.
/// </summary>
public sealed class FloatShelf : Window
{
    static FloatShelf? _instance;

    public sealed class Entry
    {
        public required string Path { get; init; }
        public string Name => System.IO.Path.GetFileName(Path.TrimEnd('\\'));
        public string Detail { get; init; } = "";
        public ImageSource? Thumb { get; init; }
    }

    readonly ObservableCollection<Entry> _items = new();
    readonly ListBox _list;
    readonly TextBlock _count;
    Point _dragStart;
    Entry? _pressed;

    public static void Add(IReadOnlyList<string> paths, Win32.POINT anchor)
    {
        if (_instance == null)
        {
            _instance = new FloatShelf();
            Ui.PlaceNear(_instance, anchor, 300, 120);
            _instance.Show();
        }
        foreach (var p in paths)
            if (_instance._items.All(i => !string.Equals(i.Path, p, StringComparison.OrdinalIgnoreCase)))
                _instance._items.Add(MakeEntry(p));
        _instance.UpdateCount();
        Ui.ForceForeground(_instance);
    }

    public static void ShowEmpty()
    {
        Win32.GetCursorPos(out var pt);
        Add(Array.Empty<string>(), pt);
    }

    static Entry MakeEntry(string path)
    {
        string detail = Directory.Exists(path) ? "Folder" : File.Exists(path) ? FileKinds.HumanSize(new FileInfo(path).Length) : "";
        return new Entry { Path = path, Detail = detail, Thumb = ShellThumbnail.Get(path, 64) };
    }

    FloatShelf()
    {
        Title = "Satsuma Shelf";
        Width = 300;
        SizeToContent = SizeToContent.Height;
        MaxHeight = 460;
        Topmost = true;
        ShowInTaskbar = false;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        AllowDrop = true;

        bool dark = Overlay.ThemeInfo.IsDark;
        Brush card = new SolidColorBrush(dark ? Color.FromArgb(242, 34, 33, 38) : Color.FromArgb(246, 251, 249, 246));
        Brush ink = new SolidColorBrush(dark ? Color.FromRgb(242, 238, 234) : Color.FromRgb(38, 32, 28));
        Brush muted = new SolidColorBrush(dark ? Color.FromRgb(170, 162, 155) : Color.FromRgb(125, 116, 108));
        Brush hover = new SolidColorBrush(dark ? Color.FromArgb(28, 255, 255, 255) : Color.FromArgb(18, 0, 0, 0));

        var root = new Border
        {
            Background = card,
            CornerRadius = new CornerRadius(14),
            BorderBrush = new SolidColorBrush(dark ? Color.FromArgb(40, 255, 255, 255) : Color.FromArgb(30, 0, 0, 0)),
            BorderThickness = new Thickness(1),
            Margin = new Thickness(14),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, ShadowDepth = 4, Opacity = dark ? 0.5 : 0.18, Direction = 270 },
        };
        var stack = new DockPanel();
        root.Child = stack;

        var header = new DockPanel { Margin = new Thickness(14, 10, 8, 6), Background = Brushes.Transparent };
        header.MouseLeftButtonDown += (_, e) => { if (e.ClickCount == 1) DragMove(); };
        var close = new Button { Content = "", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 11, Padding = new Thickness(8, 4, 8, 4), ToolTip = "Close shelf", Background = Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = muted };
        close.Click += (_, _) => Close();
        var clear = new Button { Content = "Clear", FontSize = 12, Padding = new Thickness(8, 3, 8, 3), Background = Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = muted, Margin = new Thickness(0, 0, 2, 0) };
        clear.Click += (_, _) => { _items.Clear(); UpdateCount(); };
        DockPanel.SetDock(close, Dock.Right);
        DockPanel.SetDock(clear, Dock.Right);
        header.Children.Add(close);
        header.Children.Add(clear);
        var titleStack = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        titleStack.Children.Add(new TextBlock { Text = "", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 13, Foreground = new SolidColorBrush(Color.FromRgb(255, 122, 26)), Margin = new Thickness(0, 1, 8, 0) });
        titleStack.Children.Add(new TextBlock { Text = "Shelf", FontWeight = FontWeights.SemiBold, FontSize = 13, Foreground = ink });
        _count = new TextBlock { FontSize = 12, Foreground = muted, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        titleStack.Children.Add(_count);
        header.Children.Add(titleStack);
        DockPanel.SetDock(header, Dock.Top);
        stack.Children.Add(header);

        var hint = new TextBlock
        {
            Text = "Drop files here, then drag them out anywhere.",
            Foreground = muted, FontSize = 12, Margin = new Thickness(14, 2, 14, 14), TextWrapping = TextWrapping.Wrap,
        };
        DockPanel.SetDock(hint, Dock.Bottom);
        stack.Children.Add(hint);

        _list = new ListBox
        {
            ItemsSource = _items,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(6, 0, 6, 0),
            MaxHeight = 360,
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(_list, ScrollBarVisibility.Disabled);
        _list.ItemTemplate = BuildTemplate(ink, muted);
        _list.ItemContainerStyle = BuildItemStyle(hover);
        _list.PreviewMouseLeftButtonDown += (_, e) =>
        {
            _dragStart = e.GetPosition(this);
            _pressed = (e.OriginalSource as FrameworkElement)?.DataContext as Entry;
            if (e.ClickCount == 2 && _pressed != null) Shell.Open(_pressed.Path);
        };
        _list.PreviewMouseMove += OnListMouseMove;
        _list.MouseRightButtonUp += (_, e) =>
        {
            if ((e.OriginalSource as FrameworkElement)?.DataContext is Entry entry) { _items.Remove(entry); UpdateCount(); }
        };
        stack.Children.Add(_list);
        Content = root;
        _items.CollectionChanged += (_, _) => hint.Visibility = _items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
                foreach (var f in files) if (_items.All(i => i.Path != f)) _items.Add(MakeEntry(f));
            UpdateCount();
        };
        DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Link : DragDropEffects.None; e.Handled = true; };
        Closed += (_, _) => _instance = null;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    void UpdateCount() => _count.Text = _items.Count == 0 ? "" : _items.Count == 1 ? "1 item" : $"{_items.Count} items";

    void OnListMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _pressed == null) return;
        var pos = e.GetPosition(this);
        if (Math.Abs(pos.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(pos.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        var selected = _list.SelectedItems.Cast<Entry>().ToList();
        var paths = (selected.Contains(_pressed) && selected.Count > 1 ? selected : new List<Entry> { _pressed }).Select(i => i.Path).ToList();
        _pressed = null;
        var hwnd = new WindowInteropHelper(this).Handle;
        int effect = ShellDrag.DoDragDrop(hwnd, paths);
        // Items that were moved away no longer exist; drop them from the shelf.
        foreach (var entry in _items.Where(i => !File.Exists(i.Path) && !Directory.Exists(i.Path)).ToList()) _items.Remove(entry);
        UpdateCount();
    }

    static DataTemplate BuildTemplate(Brush ink, Brush muted)
    {
        var grid = new FrameworkElementFactory(typeof(DockPanel));
        grid.SetValue(MarginProperty, new Thickness(4, 3, 4, 3));
        var img = new FrameworkElementFactory(typeof(Image));
        img.SetBinding(Image.SourceProperty, new System.Windows.Data.Binding(nameof(Entry.Thumb)));
        img.SetValue(WidthProperty, 32.0);
        img.SetValue(HeightProperty, 32.0);
        img.SetValue(MarginProperty, new Thickness(0, 0, 10, 0));
        img.SetValue(DockPanel.DockProperty, Dock.Left);
        grid.AppendChild(img);
        var texts = new FrameworkElementFactory(typeof(StackPanel));
        texts.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        var name = new FrameworkElementFactory(typeof(TextBlock));
        name.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(nameof(Entry.Name)));
        name.SetValue(TextBlock.ForegroundProperty, ink);
        name.SetValue(TextBlock.FontSizeProperty, 12.5);
        name.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        texts.AppendChild(name);
        var detail = new FrameworkElementFactory(typeof(TextBlock));
        detail.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(nameof(Entry.Detail)));
        detail.SetValue(TextBlock.ForegroundProperty, muted);
        detail.SetValue(TextBlock.FontSizeProperty, 11.0);
        texts.AppendChild(detail);
        grid.AppendChild(texts);
        return new DataTemplate { VisualTree = grid };
    }

    static Style BuildItemStyle(Brush hover)
    {
        var style = new Style(typeof(ListBoxItem));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(4)));
        style.Setters.Add(new Setter(Control.CursorProperty, Cursors.Hand));
        style.Setters.Add(new Setter(ToolTipProperty, new System.Windows.Data.Binding(nameof(Entry.Path))));
        var template = new ControlTemplate(typeof(ListBoxItem));
        var border = new FrameworkElementFactory(typeof(Border), "Bd");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(8));
        border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        border.SetValue(Border.PaddingProperty, new Thickness(4));
        border.AppendChild(new FrameworkElementFactory(typeof(ContentPresenter)));
        template.VisualTree = border;
        var trigger = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        trigger.Setters.Add(new Setter(Border.BackgroundProperty, hover, "Bd"));
        template.Triggers.Add(trigger);
        var sel = new Trigger { Property = ListBoxItem.IsSelectedProperty, Value = true };
        sel.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(46, 255, 122, 26)), "Bd"));
        template.Triggers.Add(sel);
        style.Setters.Add(new Setter(Control.TemplateProperty, template));
        return style;
    }
}

/// <summary>Explorer-quality thumbnails (images, video frames, PDF pages, app icons) with alpha preserved.</summary>
public static class ShellThumbnail
{
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory { [PreserveSig] int GetImage(Win32.SIZE size, int flags, out IntPtr phbm); }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public short bmPlanes, bmBitsPixel; public IntPtr bmBits; }
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, out BITMAP bmp);

    public static BitmapSource? Get(string path, int size)
    {
        try
        {
            SHCreateItemFromParsingName(path.TrimEnd('\\'), IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out var factory);
            if (factory.GetImage(new Win32.SIZE(size, size), 0x1 /*BIGGERSIZEOK*/, out var hbmp) != 0 || hbmp == IntPtr.Zero) return null;
            try
            {
                GetObject(hbmp, Marshal.SizeOf<BITMAP>(), out var bm);
                if (bm.bmBitsPixel == 32 && bm.bmBits != IntPtr.Zero)
                {
                    // DIB sections are bottom-up; copy rows flipped, keeping the premultiplied alpha.
                    int stride = bm.bmWidthBytes;
                    var pixels = new byte[stride * bm.bmHeight];
                    for (int y = 0; y < bm.bmHeight; y++)
                        Marshal.Copy(bm.bmBits + y * stride, pixels, (bm.bmHeight - 1 - y) * stride, stride);
                    var src = BitmapSource.Create(bm.bmWidth, bm.bmHeight, 96, 96, PixelFormats.Pbgra32, null, pixels, stride);
                    src.Freeze();
                    return src;
                }
                var fallback = Imaging.CreateBitmapSourceFromHBitmap(hbmp, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                fallback.Freeze();
                return fallback;
            }
            finally { Win32.DeleteObject(hbmp); }
        }
        catch { return null; }
    }
}
