using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SkiaSharp;
using Rectangle = System.Windows.Shapes.Rectangle;
using ShapePath = System.Windows.Shapes.Path;

namespace Satsuma.UI;

/// <summary>Interactive crop: drag the box or its handles, pick an aspect ratio, or type exact pixels.</summary>
public sealed class CropWindow : ToolWindow
{
    readonly int _imgW, _imgH;
    readonly double _k;               // display px per image px
    readonly Canvas _canvas = new();
    readonly ShapePath _shade = new() { Fill = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)), IsHitTestVisible = false };
    readonly Rectangle _frame = new() { Stroke = Brushes.White, StrokeThickness = 1.5, IsHitTestVisible = false };
    readonly List<Rectangle> _thirds = new();
    readonly List<Rectangle> _handles = new();
    readonly TextBox _wBox = new() { Width = 70 }, _hBox = new() { Width = 70 };
    Rect _sel;
    double? _aspect;
    enum Drag { None, Move, Create, N, S, E, W, NE, NW, SE, SW }
    Drag _drag;
    Point _start;
    Rect _startSel;
    bool _syncing;

    public SKRectI Selection => new(
        (int)Math.Round(_sel.Left / _k), (int)Math.Round(_sel.Top / _k),
        (int)Math.Round(_sel.Right / _k), (int)Math.Round(_sel.Bottom / _k));

    public CropWindow(string file, SKBitmap bmp) : base("Crop", $"{System.IO.Path.GetFileName(file)} · {bmp.Width} × {bmp.Height}", "Crop", 760)
    {
        _imgW = bmp.Width;
        _imgH = bmp.Height;
        double maxW = 700, maxH = 460;
        _k = Math.Min(maxW / _imgW, maxH / _imgH);
        double dw = _imgW * _k, dh = _imgH * _k;
        float s = (float)Math.Min(1, (dw * 1.5) / _imgW);
        using var preview = Ops.Tools.ImageTools.Resample(bmp, (int)(_imgW * s), (int)(_imgH * s));
        var image = new Image { Source = ToSource(preview), Width = dw, Height = dh, Stretch = Stretch.Fill };
        _canvas.Width = dw;
        _canvas.Height = dh;
        _canvas.Background = Brushes.Transparent;
        _canvas.Cursor = Cursors.Cross;
        _canvas.Children.Add(image);
        _canvas.Children.Add(_shade);
        for (int i = 0; i < 4; i++)
        {
            var t = new Rectangle { Fill = new SolidColorBrush(Color.FromArgb(90, 255, 255, 255)), IsHitTestVisible = false };
            _thirds.Add(t);
            _canvas.Children.Add(t);
        }
        _canvas.Children.Add(_frame);
        for (int i = 0; i < 8; i++)
        {
            var h = new Rectangle { Width = 10, Height = 10, Fill = Brushes.White, Stroke = new SolidColorBrush(Color.FromRgb(255, 122, 26)), StrokeThickness = 1.5, IsHitTestVisible = false, RadiusX = 2, RadiusY = 2 };
            _handles.Add(h);
            _canvas.Children.Add(h);
        }
        var holder = new Border { Child = _canvas, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 12), CornerRadius = new CornerRadius(6), ClipToBounds = false };
        Body.Children.Add(holder);

        var aspect = new Segmented(new[] { "Free", "Original", "1:1", "4:3", "3:2", "16:9", "9:16", "4:5" });
        Body.Children.Add(aspect);
        double?[] ratios = { null, _imgW / (double)_imgH, 1, 4.0 / 3, 3.0 / 2, 16.0 / 9, 9.0 / 16, 4.0 / 5 };
        aspect.Changed += i => { _aspect = ratios[i]; ApplyAspect(); };

        var sizeRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        sizeRow.Children.Add(new TextBlock { Text = "Size", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        sizeRow.Children.Add(_wBox);
        sizeRow.Children.Add(new TextBlock { Text = " × ", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 6, 0) });
        sizeRow.Children.Add(_hBox);
        sizeRow.Children.Add(new TextBlock { Text = "px", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0), Opacity = 0.7 });
        var reset = new Button { Content = "Reset", Margin = new Thickness(16, 0, 0, 0), Padding = new Thickness(12, 3, 12, 3) };
        reset.Click += (_, _) => { _sel = Inset(new Rect(0, 0, dw, dh), 0.08); ApplyAspect(); };
        sizeRow.Children.Add(reset);
        Body.Children.Add(sizeRow);
        _wBox.LostFocus += (_, _) => TypedSize();
        _hBox.LostFocus += (_, _) => TypedSize();
        _wBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) TypedSize(); };
        _hBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) TypedSize(); };

        _canvas.MouseLeftButtonDown += OnDown;
        _canvas.MouseMove += OnMove;
        _canvas.MouseLeftButtonUp += (_, _) => { _drag = Drag.None; _canvas.ReleaseMouseCapture(); };

        _sel = Inset(new Rect(0, 0, dw, dh), 0.08);
        Redraw();
    }

    static Rect Inset(Rect r, double f) => new(r.X + r.Width * f, r.Y + r.Height * f, r.Width * (1 - 2 * f), r.Height * (1 - 2 * f));

    Rect Bounds => new(0, 0, _canvas.Width, _canvas.Height);

    void ApplyAspect()
    {
        if (_aspect is double a)
        {
            var c = new Point(_sel.X + _sel.Width / 2, _sel.Y + _sel.Height / 2);
            double w = _sel.Width, h = w / a;
            if (h > Bounds.Height) { h = Bounds.Height * 0.9; w = h * a; }
            if (w > Bounds.Width) { w = Bounds.Width * 0.9; h = w / a; }
            _sel = new Rect(c.X - w / 2, c.Y - h / 2, w, h);
            _sel = Clamp(_sel);
        }
        Redraw();
    }

    Rect Clamp(Rect r)
    {
        double x = Math.Clamp(r.X, 0, Math.Max(0, Bounds.Width - r.Width));
        double y = Math.Clamp(r.Y, 0, Math.Max(0, Bounds.Height - r.Height));
        return new Rect(x, y, Math.Min(r.Width, Bounds.Width), Math.Min(r.Height, Bounds.Height));
    }

    void TypedSize()
    {
        if (_syncing) return;
        if (!int.TryParse(_wBox.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var w) || !int.TryParse(_hBox.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var h)) return;
        w = Math.Clamp(w, 1, _imgW); h = Math.Clamp(h, 1, _imgH);
        var c = new Point(_sel.X + _sel.Width / 2, _sel.Y + _sel.Height / 2);
        _sel = Clamp(new Rect(c.X - w * _k / 2, c.Y - h * _k / 2, w * _k, h * _k));
        Redraw();
    }

    Drag HitTest(Point p)
    {
        const double r = 9;
        bool nearL = Math.Abs(p.X - _sel.Left) < r, nearR = Math.Abs(p.X - _sel.Right) < r;
        bool nearT = Math.Abs(p.Y - _sel.Top) < r, nearB = Math.Abs(p.Y - _sel.Bottom) < r;
        bool inX = p.X > _sel.Left - r && p.X < _sel.Right + r, inY = p.Y > _sel.Top - r && p.Y < _sel.Bottom + r;
        if (nearT && nearL) return Drag.NW;
        if (nearT && nearR) return Drag.NE;
        if (nearB && nearL) return Drag.SW;
        if (nearB && nearR) return Drag.SE;
        if (nearT && inX) return Drag.N;
        if (nearB && inX) return Drag.S;
        if (nearL && inY) return Drag.W;
        if (nearR && inY) return Drag.E;
        if (_sel.Contains(p)) return Drag.Move;
        return Drag.Create;
    }

    void OnDown(object sender, MouseButtonEventArgs e)
    {
        _start = e.GetPosition(_canvas);
        _startSel = _sel;
        _drag = HitTest(_start);
        _canvas.CaptureMouse();
    }

    void OnMove(object sender, MouseEventArgs e)
    {
        var p = e.GetPosition(_canvas);
        if (_drag == Drag.None)
        {
            _canvas.Cursor = HitTest(p) switch
            {
                Drag.Move => Cursors.SizeAll,
                Drag.N or Drag.S => Cursors.SizeNS,
                Drag.E or Drag.W => Cursors.SizeWE,
                Drag.NE or Drag.SW => Cursors.SizeNESW,
                Drag.NW or Drag.SE => Cursors.SizeNWSE,
                _ => Cursors.Cross,
            };
            return;
        }
        double dx = p.X - _start.X, dy = p.Y - _start.Y;
        p = new Point(Math.Clamp(p.X, 0, Bounds.Width), Math.Clamp(p.Y, 0, Bounds.Height));
        Rect r = _startSel;
        switch (_drag)
        {
            case Drag.Move:
                _sel = Clamp(new Rect(r.X + dx, r.Y + dy, r.Width, r.Height));
                Redraw();
                return;
            case Drag.Create:
                r = new Rect(_start, p);
                break;
            default:
                double l = r.Left, t = r.Top, rr = r.Right, b = r.Bottom;
                if (_drag is Drag.W or Drag.NW or Drag.SW) l = Math.Min(p.X, rr - 8);
                if (_drag is Drag.E or Drag.NE or Drag.SE) rr = Math.Max(p.X, l + 8);
                if (_drag is Drag.N or Drag.NW or Drag.NE) t = Math.Min(p.Y, b - 8);
                if (_drag is Drag.S or Drag.SW or Drag.SE) b = Math.Max(p.Y, t + 8);
                r = new Rect(new Point(l, t), new Point(rr, b));
                break;
        }
        if (_aspect is double a && r.Width > 0 && r.Height > 0)
        {
            // Keep the ratio, anchoring the corner opposite the one being dragged.
            bool widthLeads = _drag is Drag.E or Drag.W || r.Width / r.Height > a && _drag is not (Drag.N or Drag.S);
            double w = widthLeads ? r.Width : r.Height * a, h = widthLeads ? r.Width / a : r.Height;
            double x = _drag is Drag.W or Drag.NW or Drag.SW || (_drag == Drag.Create && p.X < _start.X) ? r.Right - w : r.Left;
            double y = _drag is Drag.N or Drag.NW or Drag.NE || (_drag == Drag.Create && p.Y < _start.Y) ? r.Bottom - h : r.Top;
            r = new Rect(x, y, w, h);
        }
        r.Intersect(Bounds);
        if (r.IsEmpty || r.Width < 4 || r.Height < 4) return;
        _sel = r;
        Redraw();
    }

    void Redraw()
    {
        var outer = new RectangleGeometry(Bounds);
        var inner = new RectangleGeometry(_sel);
        _shade.Data = new CombinedGeometry(GeometryCombineMode.Exclude, outer, inner);
        Canvas.SetLeft(_frame, _sel.X); Canvas.SetTop(_frame, _sel.Y);
        _frame.Width = _sel.Width; _frame.Height = _sel.Height;
        for (int i = 0; i < 2; i++)
        {
            var v = _thirds[i];
            Canvas.SetLeft(v, _sel.X + _sel.Width * (i + 1) / 3); Canvas.SetTop(v, _sel.Y);
            v.Width = 1; v.Height = _sel.Height;
            var h = _thirds[i + 2];
            Canvas.SetLeft(h, _sel.X); Canvas.SetTop(h, _sel.Y + _sel.Height * (i + 1) / 3);
            h.Width = _sel.Width; h.Height = 1;
        }
        var pts = new[]
        {
            new Point(_sel.Left, _sel.Top), new Point(_sel.Left + _sel.Width / 2, _sel.Top), new Point(_sel.Right, _sel.Top),
            new Point(_sel.Right, _sel.Top + _sel.Height / 2), new Point(_sel.Right, _sel.Bottom), new Point(_sel.Left + _sel.Width / 2, _sel.Bottom),
            new Point(_sel.Left, _sel.Bottom), new Point(_sel.Left, _sel.Top + _sel.Height / 2),
        };
        for (int i = 0; i < 8; i++) { Canvas.SetLeft(_handles[i], pts[i].X - 5); Canvas.SetTop(_handles[i], pts[i].Y - 5); }
        _syncing = true;
        var s = Selection;
        _wBox.Text = s.Width.ToString(CultureInfo.CurrentCulture);
        _hBox.Text = s.Height.ToString(CultureInfo.CurrentCulture);
        _syncing = false;
    }
}
