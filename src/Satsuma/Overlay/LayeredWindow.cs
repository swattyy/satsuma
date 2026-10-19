using System.Runtime.InteropServices;
using Satsuma.Native;
using SkiaSharp;
using static Satsuma.Native.Win32;

namespace Satsuma.Overlay;

/// <summary>
/// A borderless, topmost, never-activating window whose pixels come from a Skia surface via UpdateLayeredWindow.
/// Per-pixel alpha also drives hit testing: fully transparent pixels let clicks and drags through.
/// Must be created and used on the overlay thread.
/// </summary>
public sealed class LayeredWindow : IDisposable
{
    const string ClassName = "Satsuma.Overlay";
    static readonly WndProc Proc = StaticWndProc;
    static bool _registered;
    static readonly Dictionary<IntPtr, LayeredWindow> Windows = new();

    public IntPtr Hwnd { get; }
    public int X { get; private set; }
    public int Y { get; private set; }
    public int Width { get; private set; }
    public int Height { get; private set; }
    public bool Visible { get; private set; }
    public bool HandCursor { get; set; }

    /// <summary>Optional message hook. Return a value to handle the message, or null for default handling.</summary>
    public Func<uint, IntPtr, IntPtr, IntPtr?>? MessageHandler { get; set; }

    IntPtr _memDc, _dib, _oldBitmap, _bits;
    SKSurface? _surface;
    int _surfaceW, _surfaceH;
    bool _clickThrough;

    public LayeredWindow(bool clickThrough)
    {
        EnsureClass();
        _clickThrough = clickThrough;
        uint ex = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | (clickThrough ? WS_EX_TRANSPARENT : 0);
        Hwnd = CreateWindowEx(ex, ClassName, "Satsuma", WS_POPUP, 0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
        if (Hwnd == IntPtr.Zero) throw new InvalidOperationException("CreateWindowEx failed: " + Marshal.GetLastWin32Error());
        Windows[Hwnd] = this;
    }

    static void EnsureClass()
    {
        if (_registered) return;
        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(Proc),
            hInstance = GetModuleHandle(null),
            hCursor = LoadCursor(IntPtr.Zero, IDC_ARROW),
            lpszClassName = ClassName,
        };
        RegisterClassEx(ref wc);
        _registered = true;
    }

    static IntPtr StaticWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
        if (Windows.TryGetValue(hwnd, out var w))
        {
            if (msg == WM_SETCURSOR)
            {
                SetCursor(LoadCursor(IntPtr.Zero, w.HandCursor ? IDC_HAND : IDC_ARROW));
                return 1;
            }
            var handled = w.MessageHandler?.Invoke(msg, wParam, lParam);
            if (handled.HasValue) return handled.Value;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    public void SetClickThrough(bool clickThrough)
    {
        if (_clickThrough == clickThrough) return;
        _clickThrough = clickThrough;
        long ex = GetWindowLongPtr(Hwnd, GWL_EXSTYLE).ToInt64();
        ex = clickThrough ? ex | WS_EX_TRANSPARENT : ex & ~(long)WS_EX_TRANSPARENT;
        SetWindowLongPtr(Hwnd, GWL_EXSTYLE, new IntPtr(ex));
    }

    void EnsureSurface(int w, int h)
    {
        if (_surface != null && w == _surfaceW && h == _surfaceH) return;
        FreeSurface();
        var bmi = new BITMAPINFOHEADER
        {
            biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32, biCompression = BI_RGB,
        };
        IntPtr screen = GetDC(IntPtr.Zero);
        _memDc = CreateCompatibleDC(screen);
        ReleaseDC(IntPtr.Zero, screen);
        _dib = CreateDIBSection(_memDc, ref bmi, DIB_RGB_COLORS, out _bits, IntPtr.Zero, 0);
        _oldBitmap = SelectObject(_memDc, _dib);
        _surface = SKSurface.Create(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul), _bits, w * 4);
        _surfaceW = w;
        _surfaceH = h;
    }

    void FreeSurface()
    {
        _surface?.Dispose();
        _surface = null;
        if (_memDc != IntPtr.Zero)
        {
            SelectObject(_memDc, _oldBitmap);
            DeleteObject(_dib);
            DeleteDC(_memDc);
            _memDc = _dib = IntPtr.Zero;
        }
    }

    /// <summary>Returns a cleared canvas of the given pixel size.</summary>
    public SKCanvas BeginDraw(int width, int height)
    {
        EnsureSurface(Math.Max(1, width), Math.Max(1, height));
        var canvas = _surface!.Canvas;
        canvas.ResetMatrix();
        canvas.Clear(SKColors.Transparent);
        return canvas;
    }

    /// <summary>Pushes the drawn pixels to the screen at (x, y) and shows the window if needed.</summary>
    public void Present(int x, int y, byte opacity = 255)
    {
        if (_surface == null) return;
        _surface.Flush();
        var dst = new POINT(x, y);
        var size = new SIZE(_surfaceW, _surfaceH);
        var src = new POINT(0, 0);
        var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = opacity, AlphaFormat = AC_SRC_ALPHA };
        UpdateLayeredWindow(Hwnd, IntPtr.Zero, ref dst, ref size, _memDc, ref src, 0, ref blend, ULW_ALPHA);
        X = x; Y = y; Width = _surfaceW; Height = _surfaceH;
        if (!Visible)
        {
            SetWindowPos(Hwnd, HWND_TOPMOST, x, y, _surfaceW, _surfaceH, SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
            Visible = true;
        }
    }

    /// <summary>Re-asserts topmost order; places this window just below <paramref name="above"/> when given.</summary>
    public void BringToFront(IntPtr above = default)
    {
        SetWindowPos(Hwnd, above != IntPtr.Zero ? above : HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }

    public void Hide()
    {
        if (!Visible) return;
        ShowWindow(Hwnd, SW_HIDE);
        Visible = false;
    }

    /// <summary>Copies the current back buffer (for tests and icon rendering).</summary>
    public SKImage? Snapshot() => _surface?.Snapshot();

    public void Dispose()
    {
        Windows.Remove(Hwnd);
        DestroyWindow(Hwnd);
        FreeSurface();
    }
}
