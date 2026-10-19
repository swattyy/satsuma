using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Satsuma.Core;
using Satsuma.Native;
using Satsuma.Overlay;
using SkiaSharp;
using static Satsuma.Native.Win32;

namespace Satsuma.UI;

/// <summary>Notification-area icon (drawn at runtime) with a Fluent context menu.</summary>
public sealed class TrayIcon : IDisposable
{
    const uint CallbackMessage = WM_APP + 0x31;
    readonly HwndSource _source;
    readonly uint _taskbarCreated;
    IntPtr _icon;
    bool _added;

    public TrayIcon()
    {
        _source = new HwndSource(new HwndSourceParameters("Satsuma tray") { Width = 0, Height = 0, WindowStyle = 0 });
        _source.AddHook(WndProc);
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        Settings.Changed += Refresh;
        Add();
    }

    void Add()
    {
        if (_icon != IntPtr.Zero) DestroyIcon(_icon);
        _icon = AppIcon.CreateTrayIcon(Settings.Current.Enabled);
        var data = Data();
        data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
        _added = Shell_NotifyIcon(_added ? NIM_MODIFY : NIM_ADD, ref data);
        data.uVersion = 4;
        Shell_NotifyIcon(NIM_SETVERSION, ref data);
    }

    NOTIFYICONDATA Data() => new()
    {
        cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
        hWnd = _source.Handle,
        uID = 1,
        uCallbackMessage = CallbackMessage,
        hIcon = _icon,
        szTip = Settings.Current.Enabled ? "Satsuma: drag a file, tap Shift" : "Satsuma (paused)",
        szInfo = "",
        szInfoTitle = "",
    };

    public void Refresh() => Application.Current.Dispatcher.BeginInvoke(Add);

    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == _taskbarCreated) { _added = false; Add(); }
        else if (msg == CallbackMessage)
        {
            int ev = lParam.ToInt32() & 0xFFFF;
            if (ev is 0x0202 /*WM_LBUTTONUP*/ or 0x0205 /*WM_RBUTTONUP*/ or 0x007B /*WM_CONTEXTMENU*/) ShowMenu();
            else if (ev == 0x0203 /*WM_LBUTTONDBLCLK*/) SettingsWindow.ShowSingle();
            handled = true;
        }
        return IntPtr.Zero;
    }

    void ShowMenu()
    {
        SetForegroundWindow(_source.Handle); // otherwise the menu won't close when clicking elsewhere
        var menu = new ContextMenu();
        var toggle = new MenuItem { Header = Settings.Current.Enabled ? "Pause Satsuma" : "Resume Satsuma" };
        toggle.Click += (_, _) => { Settings.Current.Enabled = !Settings.Current.Enabled; Settings.Save(); };
        menu.Items.Add(toggle);
        menu.Items.Add(new Separator());
        var shelf = new MenuItem { Header = "Open shelf" };
        shelf.Click += (_, _) => FloatShelf.ShowEmpty();
        menu.Items.Add(shelf);
        var welcome = new MenuItem { Header = "How it works" };
        welcome.Click += (_, _) => WelcomeWindow.ShowSingle();
        menu.Items.Add(welcome);
        var settings = new MenuItem { Header = "Settings…" };
        settings.Click += (_, _) => SettingsWindow.ShowSingle();
        menu.Items.Add(settings);
        menu.Items.Add(new Separator());
        var quit = new MenuItem { Header = "Quit Satsuma" };
        quit.Click += (_, _) => Application.Current.Shutdown();
        menu.Items.Add(quit);
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        menu.IsOpen = true;
    }

    public void Dispose()
    {
        Settings.Changed -= Refresh;
        var data = Data();
        Shell_NotifyIcon(NIM_DELETE, ref data);
        if (_icon != IntPtr.Zero) DestroyIcon(_icon);
        _source.Dispose();
    }
}

/// <summary>The app icon: a wheel with one orange segment, drawn with the same geometry as the overlay.</summary>
public static class AppIcon
{
    public static SKBitmap Render(int size, bool tray, bool enabled = true, bool darkTaskbar = true)
    {
        var bmp = new SKBitmap(new SKImageInfo(size, size, SKColorType.Bgra8888, SKAlphaType.Premul));
        using var c = new SKCanvas(bmp);
        c.Clear(SKColors.Transparent);
        float s = size / 64f;
        using var paint = new SKPaint { IsAntialias = true };
        if (!tray)
        {
            // Rounded tile with a warm gradient.
            var tile = new SKRect(2 * s, 2 * s, 62 * s, 62 * s);
            paint.Shader = SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(size, size),
                new[] { new SKColor(0x2B, 0x26, 0x23), new SKColor(0x17, 0x14, 0x12) }, SKShaderTileMode.Clamp);
            c.DrawRoundRect(tile, 14 * s, 14 * s, paint);
            paint.Shader = null;
        }
        float cx = size / 2f, cy = size / 2f;
        float R = (tray ? 30f : 23f) * s, r = (tray ? 13f : 10f) * s;
        int n = 6;
        var ring = darkTaskbar || !tray ? new SKColor(255, 255, 255, (byte)(enabled ? 215 : 120)) : new SKColor(20, 20, 20, (byte)(enabled ? 200 : 110));
        for (int i = 0; i < n; i++)
        {
            float span = 360f / n;
            using var seg = Wheel.WheelGeometry.Segment(-span / 2, span / 2, r, R, Math.Max(1.2f, 2.2f * s), 4f * s, 2f * s);
            c.Save();
            c.Translate(cx, cy);
            c.RotateDegrees(-90 + i * span);
            if (i == 1 && enabled)
                paint.Shader = SKShader.CreateLinearGradient(new SKPoint(R, -R * 0.4f), new SKPoint(r, R * 0.4f),
                    new[] { Wheel.WheelRenderer.AccentLight, Wheel.WheelRenderer.AccentDeep }, SKShaderTileMode.Clamp);
            else { paint.Shader = null; paint.Color = ring; }
            c.DrawPath(seg, paint);
            paint.Shader = null;
            c.Restore();
        }
        return bmp;
    }

    public static IntPtr CreateTrayIcon(bool enabled)
    {
        int size = Math.Max(16, (int)Math.Round(16 * DpiScaleAt(new POINT(0, 0))));
        using var bmp = Render(size, tray: true, enabled, ThemeInfo.TaskbarIsDark);
        return ToHIcon(bmp);
    }

    static IntPtr ToHIcon(SKBitmap bmp)
    {
        var bmi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = bmp.Width, biHeight = -bmp.Height, biPlanes = 1, biBitCount = 32, biCompression = BI_RGB };
        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr color = CreateDIBSection(screen, ref bmi, DIB_RGB_COLORS, out var bits, IntPtr.Zero, 0);
        ReleaseDC(IntPtr.Zero, screen);
        var pixels = bmp.GetPixelSpan();
        Marshal.Copy(pixels.ToArray(), 0, bits, pixels.Length);
        IntPtr mask = CreateBitmap(bmp.Width, bmp.Height, 1, 1, IntPtr.Zero);
        var info = new ICONINFO { fIcon = true, hbmColor = color, hbmMask = mask };
        IntPtr icon = CreateIconIndirect(ref info);
        DeleteObject(color);
        DeleteObject(mask);
        return icon;
    }

    /// <summary>Writes a multi-size .ico (used to produce Assets\Satsuma.ico).</summary>
    public static void WriteIco(string path)
    {
        int[] sizes = { 16, 20, 24, 32, 40, 48, 64, 128, 256 };
        var frames = sizes.Select(size =>
        {
            using var b = Render(size, tray: false);
            using var img = SKImage.FromBitmap(b);
            using var png = img.Encode(SKEncodedImageFormat.Png, 100);
            return png.ToArray();
        }).ToList();
        File.WriteAllBytes(path, Ops.Convert.ImageConverter.WriteIco(sizes, frames));
    }
}
