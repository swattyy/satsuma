using Satsuma.Core;
using Satsuma.Overlay;
using SkiaSharp;
using static Satsuma.Native.Win32;

namespace Satsuma.Wheel;

/// <summary>
/// The little glass bubble that appears where you dropped: progress ring while working, then a drawn-on
/// checkmark ("Saved photo.png", click to show in folder) or an error. Lives on the overlay thread.
/// </summary>
public sealed class Hud : IFrameClient
{
    enum Phase { Working, Done, Failed, Closing }

    static readonly List<Hud> Active = new();

    readonly LayeredWindow _win;
    readonly float S;
    readonly bool _dark;
    SKImage? _backdrop;
    RECT _backdropRect;
    POINT _center;
    int _x, _y, _w, _h;
    float _bubbleW, _bubbleH;

    Phase _phase = Phase.Working;
    string _title, _subtitle = "", _glyph;
    double _fraction = -1;
    readonly Spring _appear = new(0, 0.42f, 0.66f);
    readonly Spring _fade = new(0, 0.12f, 1f);
    readonly Spring _progress = new(0, 0.35f, 1f);
    readonly Spring _done = new(0, 0.5f, 0.85f);
    readonly Spring _widthAnim = new(0, 0.3f, 0.86f);
    double _dismissAt = double.MaxValue;
    bool _hovered, _animating;
    double _spin;
    IReadOnlyList<string> _outputs = Array.Empty<string>();

    public Hud(POINT center, string title, string glyph, SKImage? backdrop, RECT backdropRect)
    {
        _center = center;
        _title = title;
        _glyph = glyph;
        S = DpiScaleAt(center) * (float)Math.Clamp(Settings.Current.WheelScale, 0.6, 1.6);
        _dark = ThemeInfo.IsDark;
        _backdrop = backdrop;
        _backdropRect = backdropRect;
        _win = new LayeredWindow(clickThrough: true);
        _win.MessageHandler = OnMessage;
        _bubbleH = 56 * S;
        _bubbleW = MeasureWidth();
        _widthAnim.Snap(_bubbleW);
        Layout();
        if (_backdrop == null) CaptureBackdrop();
        _appear.To(1);
        _fade.To(1);
        Active.Add(this);
        StartAnimating();
    }

    /// <summary>Offscreen instance for visual tests: no window, no timers.</summary>
    Hud(string title, string subtitle, string glyph, float scale, bool dark, Backdrop.Snapshot? backdrop)
    {
        _win = null!;
        _title = title;
        _subtitle = subtitle;
        _glyph = glyph;
        S = scale;
        _dark = dark;
        _bubbleH = 56 * S;
        _bubbleW = MeasureWidth();
        _widthAnim.Snap(_bubbleW);
        float margin = 36 * S;
        _w = (int)MathF.Ceiling(440 * S + margin * 2);
        _h = (int)MathF.Ceiling(_bubbleH + margin * 2);
        _backdrop = backdrop?.Image;
        _backdropRect = new RECT(0, 0, _w, _h);
        _appear.Snap(1);
        _fade.Snap(1);
    }

    /// <summary>Renders the bubble in a given state (0 = working, 1 = done, 2 = failed) for visual tests.</summary>
    public static SKImage RenderPreview(int phase, string title, string subtitle, float progress, bool dark, float scale, Backdrop.Snapshot? backdrop)
    {
        var hud = new Hud(title, subtitle, Glyphs.Convert, scale, dark, backdrop);
        hud._phase = phase switch { 1 => Phase.Done, 2 => Phase.Failed, _ => Phase.Working };
        hud._fraction = progress;
        hud._progress.Snap(phase == 0 ? progress : 1);
        hud._done.Snap(phase == 0 ? 0 : 1);
        hud._spin = 40;
        var info = new SKImageInfo(hud._w, hud._h, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var surface = SKSurface.Create(info);
        hud.Draw(surface.Canvas);
        return surface.Snapshot();
    }

    public static (int width, int height) PreviewSize(float scale) =>
        ((int)MathF.Ceiling(440 * scale + 72 * scale), (int)MathF.Ceiling(56 * scale + 72 * scale));

    // ---------------------------------------------------------------- public API (overlay thread)

    public void Report(double fraction, string? status)
    {
        if (_phase != Phase.Working) return;
        _fraction = fraction;
        if (fraction >= 0) _progress.To((float)Math.Clamp(fraction, 0, 1));
        if (status != null && status != _subtitle) { _subtitle = status; Resize(); }
        StartAnimating();
    }

    public void Complete(string title, string subtitle, IReadOnlyList<string> outputs)
    {
        if (_phase == Phase.Closing) return;
        _phase = Phase.Done;
        _title = title;
        _subtitle = subtitle;
        _outputs = outputs;
        _progress.To(1);
        _done.To(1, 0.08f);
        Resize();
        if (outputs.Count > 0)
        {
            _win.SetClickThrough(false);
            _win.HandCursor = true;
        }
        _dismissAt = OverlayThread.Instance.Now + 2.6;
        SoundFx.Play(SoundFx.Done);
        StartAnimating();
    }

    public void Fail(string title, string message)
    {
        if (_phase == Phase.Closing) return;
        _phase = Phase.Failed;
        _title = title;
        _subtitle = message;
        _done.To(1);
        Resize();
        _win.SetClickThrough(false);
        _dismissAt = OverlayThread.Instance.Now + 6;
        SoundFx.Play(SoundFx.Error);
        StartAnimating();
    }

    public void Dismiss()
    {
        if (_phase == Phase.Closing) return;
        _phase = Phase.Closing;
        _appear.Configure(0.25f, 1f).To(0.92f);
        _fade.Configure(0.12f, 1f).To(0);
        _win.SetClickThrough(true);
        StartAnimating();
    }

    // ---------------------------------------------------------------- layout

    float MeasureWidth()
    {
        using var t = new SKFont(WheelRenderer.Type.Semibold, 13.5f * S);
        using var s = new SKFont(WheelRenderer.Type.Regular, 11.5f * S);
        float text = MathF.Max(t.MeasureText(_title), s.MeasureText(_subtitle));
        return Math.Clamp(text + 82 * S, 230 * S, 440 * S);
    }

    void Resize()
    {
        _bubbleW = MeasureWidth();
        _widthAnim.To(_bubbleW);
    }

    void Layout()
    {
        float margin = 36 * S;
        _w = (int)MathF.Ceiling(440 * S + margin * 2);
        _h = (int)MathF.Ceiling(_bubbleH + margin * 2);
        int cx = _center.X, cy = _center.Y;
        // Stack below other bubbles that are already in that spot.
        foreach (var other in Active)
        {
            if (other == this || other._phase == Phase.Closing) continue;
            if (Math.Abs(other._center.X - cx) < 300 * S && Math.Abs(other._center.Y - cy) < _bubbleH + 8 * S)
                cy = other._center.Y + (int)(_bubbleH + 10 * S);
        }
        var mon = MonitorAt(new POINT(cx, cy));
        cy = Math.Clamp(cy, mon.Top + (int)(_bubbleH), mon.Bottom - (int)(_bubbleH));
        cx = Math.Clamp(cx, mon.Left + (int)(230 * S), mon.Right - (int)(230 * S));
        _center = new POINT(cx, cy);
        _x = cx - _w / 2;
        _y = cy - _h / 2;
    }

    void CaptureBackdrop()
    {
        var snap = Backdrop.Capture(new RECT(_x, _y, _x + _w, _y + _h));
        if (snap == null) return;
        _backdrop = snap.Image;
        _backdropRect = snap.ScreenRect;
    }

    // ---------------------------------------------------------------- input

    IntPtr? OnMessage(uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case WM_MOUSEMOVE:
                if (!_hovered)
                {
                    _hovered = true;
                    var tme = new TRACKMOUSEEVENT { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<TRACKMOUSEEVENT>(), dwFlags = TME_LEAVE, hwndTrack = _win.Hwnd };
                    TrackMouseEvent(ref tme);
                }
                return IntPtr.Zero;
            case WM_MOUSELEAVE:
                _hovered = false;
                _dismissAt = Math.Max(_dismissAt, OverlayThread.Instance.Now + 1.2);
                StartAnimating();
                return IntPtr.Zero;
            case WM_LBUTTONUP:
                if (_phase == Phase.Done && _outputs.Count > 0) Shell.RevealInExplorer(_outputs);
                Dismiss();
                return IntPtr.Zero;
            case WM_RBUTTONUP:
                Dismiss();
                return IntPtr.Zero;
        }
        return null;
    }

    // ---------------------------------------------------------------- frames

    void StartAnimating()
    {
        if (_animating) return;
        _animating = true;
        OverlayThread.Instance.Animate(this);
    }

    public bool Tick(double now, float dt)
    {
        bool moving = _appear.Step(dt) | _fade.Step(dt) | _progress.Step(dt) | _done.Step(dt) | _widthAnim.Step(dt);
        if (_phase == Phase.Working) { _spin += dt * 300; moving = true; }

        if ((_phase == Phase.Done || _phase == Phase.Failed) && !_hovered && now >= _dismissAt) Dismiss();
        if (_phase == Phase.Closing && _fade.Value < 0.01f && _fade.Target <= 0)
        {
            Active.Remove(this);
            _win.Dispose();
            _backdrop?.Dispose();
            _animating = false;
            return false;
        }

        Render();
        bool waiting = _phase is Phase.Done or Phase.Failed;
        if (!moving && !waiting) { _animating = false; return false; }
        if (!moving && waiting)
        {
            // Nothing to animate until the dismiss time: sleep instead of rendering frames.
            _animating = false;
            double wait = Math.Max(0.05, _dismissAt - now);
            OverlayThread.Instance.After(wait, StartAnimating);
            return false;
        }
        return true;
    }

    void Render()
    {
        var c = _win.BeginDraw(_w, _h);
        Draw(c);
        _win.Present(_x, _y);
    }

    void Draw(SKCanvas c)
    {
        float fade = Ease.Clamp01(_fade.Value);
        if (fade <= 0.003f) return;
        float scale = 0.72f + 0.28f * _appear.Value;
        float cx = _w / 2f, cy = _h / 2f;
        float bw = _widthAnim.Value, bh = _bubbleH;
        var rect = new SKRect(cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2);

        int layer = c.SaveLayer(new SKPaint { Color = SKColors.White.WithAlpha((byte)(255 * fade)) });
        c.Translate(cx, cy);
        c.Scale(scale);
        c.Translate(-cx, -cy);

        using var paint = new SKPaint { IsAntialias = true };
        using var bubble = new SKPath();
        bubble.AddRoundRect(rect, bh / 2, bh / 2);

        // Shadow
        paint.Color = new SKColor(0, 0, 0, (byte)(_dark ? 90 : 46));
        paint.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 12 * S);
        c.Save(); c.Translate(0, 6 * S); c.DrawPath(bubble, paint); c.Restore();
        paint.MaskFilter = null;

        // Glass
        c.Save();
        c.ClipPath(bubble, SKClipOperation.Intersect, true);
        if (_backdrop != null)
        {
            float sx = _backdrop.Width / (float)_backdropRect.Width, sy = _backdrop.Height / (float)_backdropRect.Height;
            var src = new SKRect((_x - _backdropRect.Left) * sx, (_y - _backdropRect.Top) * sy,
                                 (_x + _w - _backdropRect.Left) * sx, (_y + _h - _backdropRect.Top) * sy);
            c.DrawImage(_backdrop, src, new SKRect(0, 0, _w, _h), new SKSamplingOptions(SKFilterMode.Linear), null);
        }
        paint.Color = _dark ? new SKColor(30, 29, 34, 205) : new SKColor(252, 250, 247, 200);
        c.DrawPaint(paint);
        c.Restore();
        paint.Style = SKPaintStyle.Stroke;
        paint.StrokeWidth = 1 * S;
        paint.Color = _dark ? SKColors.White.WithAlpha(34) : SKColors.White.WithAlpha(235);
        c.DrawRoundRect(rect, bh / 2, bh / 2, paint);
        paint.Color = _dark ? new SKColor(0, 0, 0, 80) : new SKColor(0, 0, 0, 18);
        var outer = rect; outer.Inflate(0.6f * S, 0.6f * S);
        c.DrawRoundRect(outer, bh / 2 + 0.6f * S, bh / 2 + 0.6f * S, paint);
        paint.Style = SKPaintStyle.Fill;

        // Status disc
        float dr = 17 * S;
        var disc = new SKPoint(rect.Left + 10 * S + dr, cy);
        DrawDisc(c, disc, dr, paint);

        // Text
        var primary = _dark ? new SKColor(246, 242, 238) : new SKColor(36, 30, 26);
        var secondary = _dark ? new SKColor(176, 168, 160) : new SKColor(120, 112, 105);
        using var tf = new SKFont(WheelRenderer.Type.Semibold, 13.5f * S) { Subpixel = true, Edging = SKFontEdging.Antialias };
        using var sf = new SKFont(WheelRenderer.Type.Regular, 11.5f * S) { Subpixel = true, Edging = SKFontEdging.Antialias };
        float tx = disc.X + dr + 12 * S;
        float maxW = rect.Right - 18 * S - tx;
        c.Save();
        c.ClipRect(new SKRect(tx, rect.Top, rect.Right - 14 * S, rect.Bottom));
        paint.Color = primary;
        bool hasSub = !string.IsNullOrEmpty(_subtitle);
        c.DrawText(Ellipsize(_title, tf, maxW), tx, cy + (hasSub ? -3 * S : 5 * S), SKTextAlign.Left, tf, paint);
        if (hasSub)
        {
            paint.Color = secondary;
            c.DrawText(Ellipsize(_subtitle, sf, maxW), tx, cy + 14 * S, SKTextAlign.Left, sf, paint);
        }
        c.Restore();
        c.RestoreToCount(layer);
    }

    void DrawDisc(SKCanvas c, SKPoint p, float r, SKPaint paint)
    {
        float done = Ease.Clamp01(_done.Value);
        bool failed = _phase == Phase.Failed;
        var accent = failed ? new SKColor(232, 72, 60) : WheelRenderer.Accent;

        // Track + progress arc
        paint.Style = SKPaintStyle.Stroke;
        paint.StrokeWidth = 3 * S;
        paint.StrokeCap = SKStrokeCap.Round;
        paint.Color = _dark ? SKColors.White.WithAlpha(30) : new SKColor(0, 0, 0, 22);
        var arcRect = new SKRect(p.X - r + 1.5f * S, p.Y - r + 1.5f * S, p.X + r - 1.5f * S, p.Y + r - 1.5f * S);
        c.DrawOval(arcRect, paint);
        paint.Color = SKColors.White; // the paint's alpha would otherwise dim the gradient
        paint.Shader = SKShader.CreateSweepGradient(p, new[] { WheelRenderer.AccentLight, WheelRenderer.AccentDeep, WheelRenderer.AccentLight });
        if (_phase == Phase.Working && _fraction < 0)
        {
            c.DrawArc(arcRect, (float)(_spin % 360), 100, false, paint);
        }
        else
        {
            float sweep = 360 * Ease.Clamp01(_progress.Value);
            if (sweep > 0.5f) c.DrawArc(arcRect, -90, sweep, false, paint);
        }
        paint.Shader = null;
        paint.StrokeCap = SKStrokeCap.Butt;
        paint.Style = SKPaintStyle.Fill;

        // Working: small glyph inside. Done/failed: filled disc with a drawn-on mark.
        if (done < 0.02f)
        {
            using var gf = new SKFont(WheelRenderer.Type.Icons, 13 * S);
            paint.Color = _dark ? new SKColor(230, 224, 218) : new SKColor(70, 62, 56);
            c.DrawText(_glyph, p.X, p.Y + 6.5f * S, SKTextAlign.Center, gf, paint);
            return;
        }
        float rr = r * (0.55f + 0.45f * done);
        paint.Shader = SKShader.CreateLinearGradient(new SKPoint(p.X - r, p.Y - r), new SKPoint(p.X + r, p.Y + r),
            failed ? new[] { new SKColor(245, 110, 96), new SKColor(214, 52, 44) } : new[] { WheelRenderer.AccentLight, WheelRenderer.AccentDeep },
            SKShaderTileMode.Clamp);
        paint.Color = SKColors.White.WithAlpha((byte)(255 * Math.Min(1, done * 1.5f)));
        c.DrawCircle(p, rr, paint);
        paint.Shader = null;

        paint.Style = SKPaintStyle.Stroke;
        paint.StrokeWidth = 2.6f * S;
        paint.StrokeCap = SKStrokeCap.Round;
        paint.StrokeJoin = SKStrokeJoin.Round;
        paint.Color = SKColors.White;
        using var mark = new SKPath();
        if (failed)
        {
            mark.MoveTo(p.X, p.Y - 7 * S); mark.LineTo(p.X, p.Y + 2 * S);
            c.DrawPath(mark, paint);
            paint.Style = SKPaintStyle.Fill;
            c.DrawCircle(p.X, p.Y + 7 * S, 1.6f * S, paint);
        }
        else
        {
            mark.MoveTo(p.X - 7 * S, p.Y + 0.5f * S);
            mark.LineTo(p.X - 2 * S, p.Y + 5.5f * S);
            mark.LineTo(p.X + 7.5f * S, p.Y - 5 * S);
            using var measure = new SKPathMeasure(mark, false);
            using var partial = new SKPath();
            float t = Ease.OutCubic(Ease.Clamp01((done - 0.25f) / 0.75f));
            measure.GetSegment(0, measure.Length * t, partial, true);
            c.DrawPath(partial, paint);
        }
        paint.Style = SKPaintStyle.Fill;
        paint.StrokeCap = SKStrokeCap.Butt;
    }

    static string Ellipsize(string text, SKFont font, float max)
    {
        if (font.MeasureText(text) <= max) return text;
        // Keep the extension visible: "very-long-name….png"
        string ext = Path.GetExtension(text);
        if (ext.Length > 6) ext = "";
        string head = text[..^ext.Length];
        while (head.Length > 1 && font.MeasureText(head + "…" + ext) > max) head = head[..^1];
        return head + "…" + ext;
    }
}
