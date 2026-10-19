using Satsuma.Core;
using Satsuma.Native;
using Satsuma.Ops;
using Satsuma.Overlay;
using static Satsuma.Native.Win32;
using IComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace Satsuma.Wheel;

/// <summary>
/// Owns the wheel window, its animation state and the drop target. Everything here runs on the overlay thread.
/// Lifecycle: Open (on trigger key) → DragEnter fills segments → DragOver hovers → Drop runs the item → Close.
/// </summary>
public sealed class WheelController : IFrameClient
{
    public static WheelController? Instance { get; private set; }

    readonly LayeredWindow _win;
    readonly WheelRenderer _renderer = new();
    readonly WheelState _st = new();
    WheelDropTarget? _dropTarget;

    IReadOnlyList<string> _files = Array.Empty<string>();
    bool _virtualOnly;
    bool _visible, _closing, _committed, _animating;
    int _x, _y;
    POINT _lastPt;
    POINT _openPt;
    double _openedAt;

    public bool IsOpen => _visible && !_closing;
    public WheelKind Kind => _st.Kind;

    public static void Create()
    {
        Instance = new WheelController();
    }

    WheelController()
    {
        _win = new LayeredWindow(clickThrough: false);
        _dropTarget = new WheelDropTarget(this, _win.Hwnd);
        int hr = RegisterDragDrop(_win.Hwnd, _dropTarget);
        if (hr != 0) Log.Error($"RegisterDragDrop failed: 0x{hr:X8}");
    }

    // ------------------------------------------------------------------ open / close

    public void Open(WheelKind kind, POINT cursor)
    {
        if (_visible && !_closing)
        {
            if (kind == _st.Kind) Close();
            else SwitchTo(kind);
            return;
        }
        FinishClose(); // in case a close animation was still running

        float scale = DpiScaleAt(cursor) * (float)Math.Clamp(Settings.Current.WheelScale, 0.6, 1.6);
        var L = new WheelLayout(scale, Settings.Current.ShowKeyHints);
        var mon = MonitorAt(cursor);
        float margin = 6 * scale;
        float cx = Math.Clamp(cursor.X, mon.Left + L.RPlate + margin, mon.Right - L.RPlate - margin);
        float bottomNeed = L.ShowHints ? L.RPlate + 50 * scale : L.RPlate;
        float cy = Math.Clamp(cursor.Y, mon.Top + L.RPlate + margin, mon.Bottom - bottomNeed - margin);
        _x = (int)MathF.Round(cx - L.Cx);
        _y = (int)MathF.Round(cy - L.Cy);
        _openPt = new POINT((int)cx, (int)cy);
        _lastPt = cursor;

        _st.Backdrop?.Dispose();
        _st.Backdrop = Backdrop.Capture(new RECT(_x, _y, _x + L.Width, _y + L.Height));
        _st.Layout = L;
        _st.Dark = ThemeInfo.IsDark;
        _st.Kind = kind;
        _st.Segments.Clear();
        _st.Leaving.Clear();
        _st.Hover = -1;
        _st.Loading = true;
        _st.Open.Configure(0.36f, 0.72f).Snap(0); _st.Open.To(1);
        _st.Fade.Configure(0.13f, 1f).Snap(0); _st.Fade.To(1);
        _st.HubPop.Snap(0); _st.HubPop.To(1, 0.03f);
        _st.Dim.Snap(0);
        _st.ChipX.Snap(0);
        _st.HubFrom = ("", "", false);
        _st.HubTo = ("", "", false);
        _st.HubFade.Snap(1);

        _visible = true;
        _closing = false;
        _committed = false;
        _openedAt = OverlayThread.Instance.Now;
        Native.InputMonitor.WheelOpen = true;

        // Files are known if the drag already entered the wheel earlier in this same drag.
        if (_files.Count > 0) ApplyContent(initial: true);

        Render();
        _win.BringToFront(FindDragImageWindow());
        StartAnimating();
        SoundFx.Play(SoundFx.Open);
        Log.Info($"Wheel open: {kind} at {cursor.X},{cursor.Y} scale {scale:0.00}");
    }

    public void SwitchTo(WheelKind kind)
    {
        if (!_visible || _closing || kind == _st.Kind) return;
        _st.Kind = kind;
        foreach (var s in _st.Segments)
        {
            s.Appear.Configure(0.16f, 1f).To(0);
            s.Hover.To(0);
            _st.Leaving.Add(s);
        }
        _st.Segments.Clear();
        _st.Hover = -1;
        ApplyContent(initial: false);
        UpdateHover(_lastPt);
        StartAnimating();
        SoundFx.Play(SoundFx.Switch);
    }

    public void Close(bool commit = false)
    {
        if (!_visible || _closing) return;
        _closing = true;
        Native.InputMonitor.WheelOpen = false;
        if (commit)
        {
            _st.Open.Configure(0.3f, 0.9f).To(1.07f);
            _st.Fade.Configure(0.12f, 1f).To(0, 0.07f);
        }
        else
        {
            _st.Open.Configure(0.22f, 1f).To(0.9f);
            _st.Fade.Configure(0.1f, 1f).To(0);
        }
        StartAnimating();
    }

    void FinishClose()
    {
        if (!_visible) return;
        _win.Hide();
        _visible = false;
        _closing = false;
        _st.Backdrop?.Dispose();
        _st.Backdrop = null;
        _st.Segments.Clear();
        _st.Leaving.Clear();
    }

    /// <summary>Forget the dragged files once the drag is over.</summary>
    public void ResetDrag()
    {
        _files = Array.Empty<string>();
        _virtualOnly = false;
    }

    public void OnMouseUp()
    {
        if (!IsOpen) { ResetDrag(); return; }
        // The OLE Drop (if any) arrives right after the button is released; give it a moment.
        OverlayThread.Instance.After(0.35, () =>
        {
            if (IsOpen && !_committed) Close();
            ResetDrag();
        });
    }

    public void OnEscape()
    {
        if (IsOpen) Close();
        ResetDrag();
    }

    // ------------------------------------------------------------------ content

    void ApplyContent(bool initial)
    {
        var content = Catalog.Build(_st.Kind, _files, _virtualOnly);
        _st.Content = content;
        _st.Loading = false;
        float baseDelay = initial ? Math.Max(0f, 0.04f - (float)(OverlayThread.Instance.Now - _openedAt)) : 0.06f;
        for (int i = 0; i < content.Items.Count; i++)
        {
            var seg = new SegmentState { Item = content.Items[i] };
            seg.Appear.Snap(0);
            seg.Appear.To(1, baseDelay + i * 0.016f);
            _st.Segments.Add(seg);
        }
        SetHub(DefaultHub());
    }

    (string, string, bool) DefaultHub()
    {
        var c = _st.Content;
        if (_files.Count == 0) return ("", _st.Loading ? "" : "", false);
        if (c != null && c.Items.Count == 0) return (c.HubCaption, c.EmptyMessage, false);
        return (c?.HubCaption ?? "", c?.HubTitle ?? "", false);
    }

    void SetHub((string, string, bool) text)
    {
        if (_st.HubTo == text) return;
        _st.HubFrom = _st.HubFade.Value > 0.5f ? _st.HubTo : _st.HubFrom;
        _st.HubTo = text;
        _st.HubFade.Snap(0);
        _st.HubFade.To(1);
    }

    // ------------------------------------------------------------------ drag events (from WheelDropTarget)

    internal int OnDragEnter(IComDataObject data, POINT pt, int allowed)
    {
        var files = OleData.GetFilePaths(data);
        bool virtualOnly = false;
        if (files.Count == 0)
        {
            files = OleData.GetVirtualFileNames(data);
            virtualOnly = files.Count > 0;
        }
        bool changed = !files.SequenceEqual(_files) || virtualOnly != _virtualOnly;
        if (changed) Log.Info($"DragEnter: {files.Count} item(s){(virtualOnly ? " (virtual)" : "")}, first: {(files.Count > 0 ? Path.GetFileName(files[0]) : "-")}");
        _files = files;
        _virtualOnly = virtualOnly;
        if (_visible && (changed || _st.Loading))
        {
            foreach (var s in _st.Segments) { s.Appear.Configure(0.16f, 1f).To(0); _st.Leaving.Add(s); }
            _st.Segments.Clear();
            ApplyContent(initial: true);
        }
        _st.Dim.To(0);
        StartAnimating();
        return OnDragOver(pt, allowed);
    }

    internal int OnDragOver(POINT pt, int allowed)
    {
        _lastPt = pt;
        if (!IsOpen) return DropEffects.None;
        int idx = UpdateHover(pt);
        if (idx < 0) return DropEffects.None;
        // Never report Move: the source would delete the original after a "move".
        if ((allowed & DropEffects.Copy) != 0) return DropEffects.Copy;
        if ((allowed & DropEffects.Link) != 0) return DropEffects.Link;
        return DropEffects.None;
    }

    internal void OnDragLeave()
    {
        if (!IsOpen) return;
        SetHoverIndex(-1);
        _st.Dim.To(1);
        StartAnimating();
    }

    internal int OnDrop(IComDataObject data, POINT pt, int allowed)
    {
        if (!IsOpen) return DropEffects.None;
        int idx = UpdateHover(pt);
        if (idx < 0 || idx >= _st.Segments.Count)
        {
            Close();
            ResetDrag();
            return DropEffects.None;
        }

        var seg = _st.Segments[idx];
        IReadOnlyList<string> files = _files;
        if (_virtualOnly)
        {
            // Browser/mail drags: the bytes must be read before Drop returns.
            var dir = AppPaths.NewTempDir("in");
            files = OleData.MaterializeVirtualFiles(data, dir);
        }

        _committed = true;
        seg.Press.Snap(0);
        seg.Press.To(1);
        var anchor = new POINT(_x + (int)_st.Layout.Cx, _y + (int)_st.Layout.Cy);
        var backdrop = _st.Backdrop;
        var origin = new POINT(_x, _y);
        Close(commit: true);
        SoundFx.Play(SoundFx.Commit);
        Log.Info($"Drop → {seg.Item.Id} on {files.Count} file(s)");

        if (files.Count > 0)
            OpRunner.Start(seg.Item, files, anchor, backdrop?.Image, origin, backdrop?.ScreenRect);
        ResetDrag();
        int effect = (allowed & DropEffects.Copy) != 0 ? DropEffects.Copy : (allowed & DropEffects.Link) != 0 ? DropEffects.Link : DropEffects.None;
        return effect;
    }

    int UpdateHover(POINT pt)
    {
        var L = _st.Layout;
        int idx = L.HitTest(pt.X - _x, pt.Y - _y, _st.Segments.Count);
        SetHoverIndex(idx >= 0 ? idx : -1);
        return idx;
    }

    void SetHoverIndex(int idx)
    {
        if (idx == _st.Hover) return;
        if (_st.Hover >= 0 && _st.Hover < _st.Segments.Count) _st.Segments[_st.Hover].Hover.To(0);
        _st.Hover = idx;
        if (idx >= 0 && idx < _st.Segments.Count)
        {
            var item = _st.Segments[idx].Item;
            _st.Segments[idx].Hover.To(1);
            SetHub((item.Caption, item.Label, true));
            SoundFx.Play(SoundFx.Tick);
        }
        else SetHub(DefaultHub());
        StartAnimating();
    }

    internal (int type, string message, string insert) CurrentDropDescription()
    {
        if (!IsOpen) return (OleData.DropImageInvalid, "", "");
        if (_st.Hover >= 0 && _st.Hover < _st.Segments.Count)
        {
            var item = _st.Segments[_st.Hover].Item;
            return (OleData.DropImageCopy, item.DropText, item.Label);
        }
        return (OleData.DropImageNone, _st.Segments.Count > 0 ? "Pick an option" : "Nothing to do here", "");
    }

    // ------------------------------------------------------------------ frames

    void StartAnimating()
    {
        if (_animating) return;
        _animating = true;
        OverlayThread.Instance.Animate(this);
    }

    public bool Tick(double now, float dt)
    {
        if (!_visible) { _animating = false; return false; }
        bool moving = false;
        foreach (var s in _st.AllSprings()) moving |= s.Step(dt);
        _st.Leaving.RemoveAll(s => s.Appear.Target <= 0 && s.Appear.Value < 0.01f);

        if (_closing && _st.Fade.Target <= 0 && _st.Fade.Value < 0.01f && !_st.Fade.IsMoving)
        {
            FinishClose();
            _animating = false;
            return false;
        }
        Render();
        if (!moving && !_closing) { _animating = false; return false; }
        return true;
    }

    void Render()
    {
        var L = _st.Layout;
        var canvas = _win.BeginDraw(L.Width, L.Height);
        _renderer.Draw(canvas, _st);
        _win.Present(_x, _y);
    }

    static IntPtr FindDragImageWindow()
    {
        IntPtr h = IntPtr.Zero;
        while ((h = FindWindowEx(IntPtr.Zero, h, "SysDragImage", null)) != IntPtr.Zero)
            if (IsWindowVisible(h)) return h;
        return IntPtr.Zero;
    }

    // ------------------------------------------------------------------ testing hooks

    /// <summary>Renders a wheel frame offscreen for visual tests.</summary>
    public static SkiaSharp.SKImage RenderPreview(WheelKind kind, IReadOnlyList<string> files, int hover, float t, bool dark, float scale = 2f, Backdrop.Snapshot? backdrop = null)
    {
        var st = new WheelState { Layout = new WheelLayout(scale, true), Dark = dark, Kind = kind, Backdrop = backdrop };
        var content = Catalog.Build(kind, files, false);
        st.Content = content;
        st.Loading = false;
        foreach (var item in content.Items) st.Segments.Add(new SegmentState { Item = item });
        st.Open.Snap(t); st.Fade.Snap(MathF.Min(1, t * 1.6f)); st.HubPop.Snap(t);
        for (int i = 0; i < st.Segments.Count; i++) st.Segments[i].Appear.Snap(Math.Clamp(t * 1.3f - i * 0.03f, 0, 1));
        if (hover >= 0 && hover < st.Segments.Count)
        {
            st.Segments[hover].Hover.Snap(1);
            st.Hover = hover;
            st.HubTo = (st.Segments[hover].Item.Caption, st.Segments[hover].Item.Label, true);
        }
        else st.HubTo = (content.HubCaption, content.Items.Count == 0 ? content.EmptyMessage : content.HubTitle, false);
        var info = new SkiaSharp.SKImageInfo(st.Layout.Width, st.Layout.Height, SkiaSharp.SKColorType.Bgra8888, SkiaSharp.SKAlphaType.Premul);
        using var surface = SkiaSharp.SKSurface.Create(info);
        new WheelRenderer().Draw(surface.Canvas, st);
        return surface.Snapshot();
    }
}
