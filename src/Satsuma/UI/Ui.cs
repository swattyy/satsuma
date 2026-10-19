using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Satsuma.UI;

/// <summary>Helpers for running work on the WPF UI thread and bringing our windows to the front.</summary>
public static class Ui
{
    public static Dispatcher Dispatcher => Application.Current.Dispatcher;

    public static Task<T> Run<T>(Func<T> func) => Dispatcher.InvokeAsync(func).Task;
    public static Task Run(Action action) => Dispatcher.InvokeAsync(action).Task;
    public static Task<T> RunAsync<T>(Func<Task<T>> func) => Dispatcher.InvokeAsync(func).Task.Unwrap();

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);

    /// <summary>
    /// Our windows open in response to a drop on a non-activating overlay, so Windows' focus-stealing rules would
    /// leave them behind Explorer. Briefly attaching to the foreground thread's input lets us take focus legitimately.
    /// </summary>
    public static void ForceForeground(Window window)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        if (SetForegroundWindow(hwnd)) { window.Activate(); return; }
        uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        uint me = GetCurrentThreadId();
        if (fg != me && fg != 0)
        {
            AttachThreadInput(fg, me, true);
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            AttachThreadInput(fg, me, false);
        }
        window.Activate();
    }

    /// <summary>Converts a physical-pixel screen point into WPF device-independent units for <paramref name="visual"/>'s monitor.</summary>
    public static Point ToDips(Native.Win32.POINT p)
    {
        float scale = Native.Win32.DpiScaleAt(p);
        return new Point(p.X / scale, p.Y / scale);
    }

    /// <summary>Places a window centered near a physical-pixel point, clamped to that monitor's work area.</summary>
    public static void PlaceNear(Window w, Native.Win32.POINT anchor, double width, double height)
    {
        var work = Native.Win32.WorkAreaAt(anchor);
        float s = Native.Win32.DpiScaleAt(anchor);
        double left = anchor.X / s - width / 2, top = anchor.Y / s - height / 2;
        left = Math.Clamp(left, work.Left / s + 8, Math.Max(work.Left / s + 8, work.Right / s - width - 8));
        top = Math.Clamp(top, work.Top / s + 8, Math.Max(work.Top / s + 8, work.Bottom / s - height - 8));
        w.WindowStartupLocation = WindowStartupLocation.Manual;
        w.Left = left;
        w.Top = top;
    }
}
