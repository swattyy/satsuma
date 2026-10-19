using System.Diagnostics;
using Satsuma.Core;
using Satsuma.Overlay;
using Satsuma.Wheel;
using static Satsuma.Native.Win32;

namespace Satsuma.Native;

/// <summary>
/// Global low-level keyboard and mouse hooks on their own high-priority thread. Tracks whether a mouse button is
/// held and has moved past the drag threshold; when a trigger key goes down during a real OLE drag it opens the
/// wheel and swallows that key (and its release) so the app being dragged from never sees it.
/// Hook callbacks must return within a few ms or Windows silently unhooks them, so all real work is posted away.
/// </summary>
public sealed class InputMonitor
{
    public static InputMonitor Instance { get; } = new();

    Thread? _thread;
    uint _threadId;
    IntPtr _kbHook, _mouseHook;
    readonly LowLevelProc _kbProc, _mouseProc;

    bool _buttonDown, _dragMoved;
    uint _upMessage;
    POINT _downPt;
    int _cxDrag = 4, _cyDrag = 4;
    readonly HashSet<uint> _down = new();
    readonly HashSet<uint> _swallowed = new();

    /// <summary>Mirrors whether the wheel is open (written on the overlay thread).</summary>
    public static volatile bool WheelOpen;

    InputMonitor()
    {
        _kbProc = KeyboardProc;
        _mouseProc = MouseProc;
    }

    public void Start()
    {
        if (_thread != null) return;
        var ready = new ManualResetEventSlim();
        _thread = new Thread(() =>
        {
            _threadId = GetCurrentThreadId();
            _cxDrag = Math.Max(4, GetSystemMetrics(SM_CXDRAG));
            _cyDrag = Math.Max(4, GetSystemMetrics(SM_CYDRAG));
            IntPtr module = GetModuleHandle(null);
            _kbHook = SetWindowsHookEx(WH_KEYBOARD_LL, _kbProc, module, 0);
            _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, module, 0);
            if (_kbHook == IntPtr.Zero || _mouseHook == IntPtr.Zero)
                Log.Error($"Installing hooks failed (kb={_kbHook}, mouse={_mouseHook}, err={System.Runtime.InteropServices.Marshal.GetLastWin32Error()})");
            ready.Set();
            while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
            UnhookWindowsHookEx(_kbHook);
            UnhookWindowsHookEx(_mouseHook);
        })
        { IsBackground = true, Name = "Satsuma input hooks", Priority = ThreadPriority.Highest };
        _thread.Start();
        ready.Wait();
    }

    public void Stop()
    {
        if (_threadId != 0) PostThreadMessage(_threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
    }

    static WheelKind? KindFor(uint vk)
    {
        var s = Settings.Current;
        if (Matches(s.ConvertKey, vk)) return WheelKind.Convert;
        if (Matches(s.ToolsKey, vk)) return WheelKind.Tools;
        if (Matches(s.ActionsKey, vk)) return WheelKind.Actions;
        return null;
    }

    static bool Matches(TriggerKey key, uint vk) => key switch
    {
        TriggerKey.Shift => vk is VK_LSHIFT or VK_RSHIFT or VK_SHIFT,
        TriggerKey.Ctrl => vk is VK_LCONTROL or VK_RCONTROL or VK_CONTROL,
        TriggerKey.Alt => vk is VK_LMENU or VK_RMENU or VK_MENU,
        TriggerKey.Space => vk == VK_SPACE,
        TriggerKey.Tab => vk == VK_TAB,
        TriggerKey.CapsLock => vk == VK_CAPITAL,
        _ => false,
    };

    unsafe IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var k = *(KBDLLHOOKSTRUCT*)lParam;
            uint msg = (uint)wParam;
            uint vk = k.vkCode;
            if (msg is WM_KEYDOWN or WM_SYSKEYDOWN)
            {
                bool repeat = !_down.Add(vk);
                if (repeat)
                {
                    if (_swallowed.Contains(vk)) return 1;
                }
                else if (Settings.Current.Enabled && _buttonDown && _dragMoved && KindFor(vk) is WheelKind kind)
                {
                    // Games and other full-screen apps: never interfere (holding the mouse + Shift is common there).
                    if (!WheelOpen && FullscreenAppActive()) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
                    if (WheelOpen || DragDetector.IsDragInProgress(_downPt, out var why))
                    {
                        GetCursorPos(out var pt);
                        OverlayThread.Instance.Post(() => WheelController.Instance?.Open(kind, pt));
                        _swallowed.Add(vk);
                        return 1;
                    }
                    LogLater($"Trigger ignored: no drag detected ({why})");
                }
                else if (vk == VK_ESCAPE && WheelOpen)
                {
                    OverlayThread.Instance.Post(() => WheelController.Instance?.OnEscape());
                }
            }
            else if (msg is WM_KEYUP or WM_SYSKEYUP)
            {
                _down.Remove(vk);
                if (_swallowed.Remove(vk)) return 1;
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    static long _lastLogTicks;

    /// <summary>Hook callbacks must stay fast: write diagnostics on the thread pool, at most every few seconds.</summary>
    static void LogLater(string message)
    {
        long now = Environment.TickCount64;
        if (now - Interlocked.Read(ref _lastLogTicks) < 5000) return;
        Interlocked.Exchange(ref _lastLogTicks, now);
        ThreadPool.QueueUserWorkItem(_ => Log.Info(message));
    }

    static bool FullscreenAppActive()
    {
        // QUNS_BUSY (2) = a full-screen app; QUNS_RUNNING_D3D_FULL_SCREEN (3) = exclusive full-screen game; 4 = presentation mode.
        return SHQueryUserNotificationState(out int state) == 0 && state is 2 or 3 or 4;
    }

    unsafe IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var m = *(MSLLHOOKSTRUCT*)lParam;
            switch ((uint)wParam)
            {
                case WM_LBUTTONDOWN or WM_RBUTTONDOWN:
                    if (!_buttonDown)
                    {
                        _buttonDown = true;
                        _dragMoved = false;
                        _downPt = m.pt;
                        _upMessage = (uint)wParam == WM_LBUTTONDOWN ? WM_LBUTTONUP : WM_RBUTTONUP;
                    }
                    break;
                case WM_MOUSEMOVE:
                    if (_buttonDown && !_dragMoved && (Math.Abs(m.pt.X - _downPt.X) > _cxDrag || Math.Abs(m.pt.Y - _downPt.Y) > _cyDrag))
                        _dragMoved = true;
                    break;
                case WM_LBUTTONUP or WM_RBUTTONUP:
                    if (_buttonDown && (uint)wParam == _upMessage)
                    {
                        _buttonDown = false;
                        _dragMoved = false;
                        OverlayThread.Instance.Post(() => WheelController.Instance?.OnMouseUp());
                    }
                    break;
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }
}

/// <summary>Decides whether a system drag-and-drop is in progress (vs. selecting text, moving a window, gaming…).</summary>
public static class DragDetector
{
    public static bool IsDragInProgress(POINT downPt, out string why)
    {
        // 1. The shell's drag image (Explorer, desktop, browsers…) is its own layered window.
        IntPtr h = IntPtr.Zero;
        while ((h = FindWindowEx(IntPtr.Zero, h, "SysDragImage", null)) != IntPtr.Zero)
        {
            if (IsWindowVisible(h)) { why = "SysDragImage"; return true; }
        }

        // 2. OLE's DoDragDrop loop captures the mouse with its own tracking window. Check the foreground
        //    thread and the thread that owns the window where the drag started.
        var threads = new HashSet<uint>();
        var fg = GetForegroundWindow();
        if (fg != IntPtr.Zero) threads.Add(GetWindowThreadProcessId(fg, out _));
        var start = WindowFromPoint(downPt);
        if (start != IntPtr.Zero) threads.Add(GetWindowThreadProcessId(start, out _));
        foreach (var tid in threads)
        {
            var gti = new GUITHREADINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<GUITHREADINFO>() };
            if (!GetGUIThreadInfo(tid, ref gti) || gti.hwndCapture == IntPtr.Zero) continue;
            if ((gti.flags & (GUI_INMOVESIZE | GUI_INMENUMODE)) != 0) { why = "move/menu loop"; return false; }
            string cls = ClassName(gti.hwndCapture);
            if (IsOleTracker(cls)) { why = "capture:" + cls; return true; }
        }
        why = "no drag window";
        return false;
    }

    public static bool IsOleTracker(string cls) =>
        cls.Equals("CLIPBRDWNDCLASS", StringComparison.OrdinalIgnoreCase)
        || cls.Contains("DragDrop", StringComparison.OrdinalIgnoreCase)
        || cls.Contains("OleDrag", StringComparison.OrdinalIgnoreCase)
        || cls.StartsWith("OleMainThreadWndClass", StringComparison.OrdinalIgnoreCase);
}
