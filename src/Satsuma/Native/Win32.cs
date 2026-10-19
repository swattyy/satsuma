using System.Runtime.InteropServices;
using System.Text;

namespace Satsuma.Native;

/// <summary>Plain Win32 declarations used across the app.</summary>
public static class Win32
{
    // ---------- structs ----------
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }

    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE { public int cx, cy; public SIZE(int w, int h) { cx = w; cy = h; } }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public POINT pt; public uint lPrivate;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEX
    {
        public int cbSize; public uint style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string? lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize; public uint flags; public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret; public RECT rcCaret;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DWM_TIMING_INFO
    {
        public int cbSize; public UNSIGNED_RATIO rateRefresh; public ulong qpcRefreshPeriod; public UNSIGNED_RATIO rateCompose;
        public ulong qpcVBlank, cRefresh; public uint cDXRefresh; public ulong qpcCompose, cFrame; public uint cDXPresent;
        public ulong cRefreshFrame, cFrameSubmitted; public uint cDXPresentSubmitted; public ulong cFrameConfirmed; public uint cDXPresentConfirmed;
        public ulong cRefreshConfirmed; public uint cDXRefreshConfirmed; public ulong cFramesLate; public uint cFramesOutstanding;
        public ulong cFrameDisplayed, qpcFrameDisplayed, cRefreshFrameDisplayed, cFrameComplete, qpcFrameComplete, cFramePending, qpcFramePending;
        public ulong cFramesDisplayed, cFramesComplete, cFramesPending, cFramesAvailable, cFramesDropped, cFramesMissed;
        public ulong cRefreshNextDisplayed, cRefreshNextPresented, cRefreshesDisplayed, cRefreshesPresented, cRefreshStarted;
        public ulong cPixelsReceived, cPixelsDrawn, cBuffersEmpty;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct UNSIGNED_RATIO { public uint uiNumerator, uiDenominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TRACKMOUSEEVENT { public int cbSize; public uint dwFlags; public IntPtr hwndTrack; public uint dwHoverTime; }

    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }

    public delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    public delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    // ---------- constants ----------
    public const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    public const uint WM_NULL = 0, WM_DESTROY = 0x0002, WM_CLOSE = 0x0010, WM_QUIT = 0x0012, WM_SETCURSOR = 0x0020, WM_MOUSEACTIVATE = 0x0021,
        WM_NCHITTEST = 0x0084, WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105,
        WM_TIMER = 0x0113, WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202, WM_RBUTTONDOWN = 0x0204,
        WM_RBUTTONUP = 0x0205, WM_MBUTTONDOWN = 0x0207, WM_MBUTTONUP = 0x0208, WM_MOUSELEAVE = 0x02A3, WM_DPICHANGED = 0x02E0,
        WM_SETTINGCHANGE = 0x001A, WM_APP = 0x8000, WM_USER = 0x0400, WM_CONTEXTMENU = 0x007B, WM_COMMAND = 0x0111;
    public const int MA_NOACTIVATE = 3;
    public const int HTTRANSPARENT = -1, HTCLIENT = 1;

    public const uint WS_POPUP = 0x80000000, WS_VISIBLE = 0x10000000;
    public const uint WS_EX_LAYERED = 0x00080000, WS_EX_TRANSPARENT = 0x00000020, WS_EX_TOPMOST = 0x00000008,
        WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000;
    public const int GWL_EXSTYLE = -20;
    public const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4, SW_SHOWNA = 8;
    public const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010,
        SWP_SHOWWINDOW = 0x0040, SWP_HIDEWINDOW = 0x0080, SWP_NOOWNERZORDER = 0x0200;
    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public static readonly IntPtr HWND_MESSAGE = new(-3);

    public const byte AC_SRC_OVER = 0, AC_SRC_ALPHA = 1;
    public const int ULW_ALPHA = 2;
    public const int DIB_RGB_COLORS = 0, BI_RGB = 0;
    public const int SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000;

    public const uint PM_REMOVE = 0x0001;
    public const uint QS_ALLINPUT = 0x04FF, MWMO_INPUTAVAILABLE = 0x0004;
    public const uint INFINITE = 0xFFFFFFFF, WAIT_TIMEOUT = 0x102;

    public const int SM_CXDRAG = 68, SM_CYDRAG = 69, SM_SWAPBUTTON = 23;
    public const int MONITOR_DEFAULTTONEAREST = 2;
    public const int MDT_EFFECTIVE_DPI = 0;

    public const uint LLKHF_INJECTED = 0x10, LLKHF_UP = 0x80;
    public const uint TME_LEAVE = 0x2;

    public const int VK_LBUTTON = 0x01, VK_RBUTTON = 0x02, VK_TAB = 0x09, VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12,
        VK_CAPITAL = 0x14, VK_ESCAPE = 0x1B, VK_SPACE = 0x20, VK_LWIN = 0x5B, VK_RWIN = 0x5C,
        VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5;

    public const uint GUI_INMOVESIZE = 0x2, GUI_INMENUMODE = 0x4;

    // ---------- user32 ----------
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] public static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern void PostQuitMessage(int exitCode);
    [DllImport("user32.dll")] public static extern uint MsgWaitForMultipleObjectsEx(uint nCount, IntPtr[]? handles, uint ms, uint wakeMask, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern ushort RegisterClassEx(ref WNDCLASSEX wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowEx(uint exStyle, string className, string windowName, uint style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc,
        int crKey, ref BLENDFUNCTION pblend, int flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? cls, string? title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT pt);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, int flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("user32.dll")] public static extern bool TrackMouseEvent(ref TRACKMOUSEEVENT tme);
    [DllImport("user32.dll")] public static extern IntPtr LoadCursor(IntPtr instance, IntPtr name);
    [DllImport("user32.dll")] public static extern IntPtr SetCursor(IntPtr cursor);
    [DllImport("user32.dll")] public static extern IntPtr CreateIconIndirect(ref ICONINFO info);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    public static readonly IntPtr IDC_ARROW = new(32512), IDC_HAND = new(32649);

    // ---------- gdi32 ----------
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, int usage, out IntPtr bits, IntPtr section, int offset);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateBitmap(int w, int h, uint planes, uint bpp, IntPtr bits);

    // ---------- kernel32 ----------
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string? name);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateWaitableTimerExW(IntPtr attrs, string? name, uint flags, uint access);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetWaitableTimer(IntPtr timer, ref long dueTime, int period, IntPtr completion, IntPtr arg, bool resume);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint ms);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalFree(IntPtr h);
    [DllImport("kernel32.dll")] public static extern UIntPtr GlobalSize(IntPtr h);
    public const uint GMEM_MOVEABLE = 0x0002, GMEM_ZEROINIT = 0x0040;
    public const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x2, TIMER_ALL_ACCESS = 0x1F0003;

    // ---------- dwm / shcore / winmm ----------
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
    [DllImport("dwmapi.dll")] public static extern int DwmGetCompositionTimingInfo(IntPtr hwnd, ref DWM_TIMING_INFO info);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll", SetLastError = true)] public static extern bool PlaySound(IntPtr data, IntPtr module, uint flags);
    public const uint SND_ASYNC = 0x0001, SND_NODEFAULT = 0x0002, SND_MEMORY = 0x0004, SND_PURGE = 0x0040;

    // ---------- shell32 ----------
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern uint DragQueryFile(IntPtr hDrop, uint index, StringBuilder? file, int max);
    [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr ILCreateFromPath(string path);
    [DllImport("shell32.dll")] public static extern void ILFree(IntPtr pidl);
    [DllImport("shell32.dll")] public static extern int SHOpenFolderAndSelectItems(IntPtr pidlFolder, uint cidl, IntPtr[]? apidl, uint flags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct OPENASINFO { public string pcszFile; public string? pcszClass; public int oaifInFlags; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SHOpenWithDialog(IntPtr hwnd, ref OPENASINFO info);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NOTIFYICONDATA
    {
        public int cbSize; public IntPtr hWnd; public uint uID, uFlags, uCallbackMessage; public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon;
    }
    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    public const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern bool Shell_NotifyIcon(uint msg, ref NOTIFYICONDATA data);

    // ---------- ole32 ----------
    [DllImport("ole32.dll")] public static extern int OleInitialize(IntPtr reserved);
    [DllImport("ole32.dll")] public static extern void OleUninitialize();
    [DllImport("ole32.dll")] public static extern int RegisterDragDrop(IntPtr hwnd, IDropTarget target);
    [DllImport("ole32.dll")] public static extern int RevokeDragDrop(IntPtr hwnd);
    [DllImport("ole32.dll")] public static extern void ReleaseStgMedium(ref System.Runtime.InteropServices.ComTypes.STGMEDIUM medium);

    // ---------- helpers ----------
    public static string ClassName(IntPtr hwnd)
    {
        var sb = new StringBuilder(256);
        return GetClassName(hwnd, sb, sb.Capacity) > 0 ? sb.ToString() : "";
    }

    public static IntPtr MakeLParam(int lo, int hi) => (IntPtr)((hi << 16) | (lo & 0xFFFF));

    public static float DpiScaleAt(POINT pt)
    {
        var mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        return GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, out var dx, out _) == 0 ? dx / 96f : 1f;
    }

    public static RECT WorkAreaAt(POINT pt)
    {
        var mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        return GetMonitorInfo(mon, ref mi) ? mi.rcWork : new RECT(0, 0, 1920, 1080);
    }

    public static RECT MonitorAt(POINT pt)
    {
        var mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        return GetMonitorInfo(mon, ref mi) ? mi.rcMonitor : new RECT(0, 0, 1920, 1080);
    }
}
