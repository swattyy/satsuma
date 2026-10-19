using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Satsuma.Ops.Convert;
using Windows.Data.Pdf;
using Windows.Storage.Streams;

namespace Satsuma.UI;

/// <summary>Pick PDF pages by clicking thumbnails or typing ranges like "1-3, 7".</summary>
public sealed class PagesWindow : ToolWindow
{
    readonly WrapPanel _grid = new();
    readonly TextBox _range = new() { Margin = new Thickness(0, 4, 0, 0) };
    readonly List<ToggleButton> _pages = new();
    bool _syncing;
    int _count;

    public List<int> SelectedPages => Parse(_range.Text, _count);

    public PagesWindow(string file) : base("Extract pages", Path.GetFileName(file), "Extract", 640)
    {
        var scroll = new ScrollViewer { Height = 330, Content = _grid, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 0, 0, 10) };
        Body.Children.Add(scroll);
        Body.Children.Add(new TextBlock { Text = "Pages to keep" });
        Body.Children.Add(_range);
        var quick = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        foreach (var (label, pick) in new (string, Func<int, bool>)[] { ("All", _ => true), ("None", _ => false), ("Odd", p => p % 2 == 1), ("Even", p => p % 2 == 0) })
        {
            var b = new Button { Content = label, Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(0, 0, 6, 0) };
            b.Click += (_, _) => { for (int i = 0; i < _pages.Count; i++) _pages[i].IsChecked = pick(i + 1); SyncText(); };
            quick.Children.Add(b);
        }
        Body.Children.Add(quick);
        _range.TextChanged += (_, _) => SyncChecks();
        _ = LoadAsync(file);
    }

    async Task LoadAsync(string file)
    {
        try
        {
            var pdf = await PdfConverter.LoadAsync(file);
            _count = (int)pdf.PageCount;
            Subtitle = $"{Path.GetFileName(file)} · {_count} pages";
            for (int i = 0; i < _count; i++)
            {
                var image = new Image { Width = 104, Height = 134, Stretch = Stretch.Uniform };
                var panel = new StackPanel();
                panel.Children.Add(image);
                panel.Children.Add(new TextBlock { Text = (i + 1).ToString(), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0), FontSize = 11 });
                var toggle = new ToggleButton { Content = panel, Margin = new Thickness(4), Padding = new Thickness(6), IsChecked = true, Cursor = System.Windows.Input.Cursors.Hand };
                toggle.Click += (_, _) => SyncText();
                _pages.Add(toggle);
                _grid.Children.Add(toggle);
                if (i < 120) image.Source = await Thumb(pdf, (uint)i);
            }
            SyncText();
        }
        catch (Exception ex) { Subtitle = "Couldn't read this PDF: " + ex.Message; Primary.IsEnabled = false; }
    }

    static async Task<ImageSource?> Thumb(PdfDocument pdf, uint index)
    {
        using var page = pdf.GetPage(index);
        using var stream = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = 208 });
        var bi = new BitmapImage();
        bi.BeginInit();
        bi.CacheOption = BitmapCacheOption.OnLoad;
        bi.StreamSource = stream.AsStream();
        bi.EndInit();
        bi.Freeze();
        return bi;
    }

    void SyncText()
    {
        if (_syncing) return;
        _syncing = true;
        var chosen = _pages.Select((t, i) => (t, i)).Where(x => x.t.IsChecked == true).Select(x => x.i + 1).ToList();
        _range.Text = Format(chosen);
        Primary.IsEnabled = chosen.Count > 0;
        _syncing = false;
    }

    void SyncChecks()
    {
        if (_syncing) return;
        _syncing = true;
        var set = Parse(_range.Text, _count).ToHashSet();
        for (int i = 0; i < _pages.Count; i++) _pages[i].IsChecked = set.Contains(i + 1);
        Primary.IsEnabled = set.Count > 0;
        _syncing = false;
    }

    static string Format(List<int> pages)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < pages.Count;)
        {
            int j = i;
            while (j + 1 < pages.Count && pages[j + 1] == pages[j] + 1) j++;
            if (sb.Length > 0) sb.Append(", ");
            sb.Append(j > i ? $"{pages[i]}-{pages[j]}" : pages[i].ToString());
            i = j + 1;
        }
        return sb.ToString();
    }

    public static List<int> Parse(string text, int max)
    {
        var result = new SortedSet<int>();
        foreach (var part in text.Split(',', ';', ' ').Select(p => p.Trim()).Where(p => p.Length > 0))
        {
            var bits = part.Split('-', '–');
            if (bits.Length == 2 && int.TryParse(bits[0], out var a) && int.TryParse(bits[1], out var b))
                for (int p = Math.Min(a, b); p <= Math.Max(a, b); p++) { if (p >= 1 && (max == 0 || p <= max)) result.Add(p); }
            else if (int.TryParse(part, out var single) && single >= 1 && (max == 0 || single <= max)) result.Add(single);
        }
        return result.ToList();
    }
}
