using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Satsuma.Core;
using static Satsuma.Native.Win32;

namespace Satsuma.Overlay;

/// <summary>Something that draws animated frames. Return false from <see cref="Tick"/> once settled.</summary>
public interface IFrameClient
{
    bool Tick(double now, float dt);
}

/// <summary>
/// The STA thread that owns every overlay window (the wheel and progress bubbles) and the OLE drop target.
/// It pumps messages, runs posted work, and while anything animates renders one frame per display refresh
/// (paced by DwmFlush, so a 240 Hz monitor gets 240 fps). When idle it sleeps with zero CPU.
/// </summary>
public sealed class OverlayThread
{
    public static OverlayThread Instance { get; } = new();

    const uint WM_WAKE = WM_APP + 0x101;
    readonly ConcurrentQueue<Action> _queue = new();
    readonly List<IFrameClient> _clients = new();
    readonly List<(double due, Action action)> _timers = new();
    readonly ManualResetEventSlim _ready = new();
    readonly Stopwatch _clock = Stopwatch.StartNew();
    Thread? _thread;
    uint _threadId;
    IntPtr _waitTimer;
    double _refreshPeriod = 1.0 / 60.0;
    double _lastRefreshQuery = -10;

    public double Now => _clock.Elapsed.TotalSeconds;
    public bool IsOverlayThread => Environment.CurrentManagedThreadId == _thread?.ManagedThreadId;
    public double RefreshRate => 1.0 / _refreshPeriod;

    public void Start(Action? init = null)
    {
        if (_thread != null) return;
        _thread = new Thread(() => Run(init)) { IsBackground = true, Name = "Satsuma overlay", Priority = ThreadPriority.AboveNormal };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        _ready.Wait();
    }

    public void Post(Action action)
    {
        _queue.Enqueue(action);
        if (_threadId != 0) PostThreadMessage(_threadId, WM_WAKE, IntPtr.Zero, IntPtr.Zero);
    }

    /// <summary>Runs <paramref name="action"/> on the overlay thread and waits for it.</summary>
    public T Invoke<T>(Func<T> action)
    {
        if (IsOverlayThread) return action();
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(() => { try { tcs.SetResult(action()); } catch (Exception ex) { tcs.SetException(ex); } });
        return tcs.Task.GetAwaiter().GetResult();
    }

    /// <summary>Schedules a callback on the overlay thread. Call from the overlay thread.</summary>
    public void After(double seconds, Action action) => _timers.Add((Now + seconds, action));

    /// <summary>Starts frame callbacks for a client until it reports it has settled. Call from the overlay thread.</summary>
    public void Animate(IFrameClient client)
    {
        if (!_clients.Contains(client)) _clients.Add(client);
    }

    void Run(Action? init)
    {
        OleInitialize(IntPtr.Zero);
        timeBeginPeriod(1);
        PeekMessage(out _, IntPtr.Zero, 0, 0, 0); // force-create the message queue
        _threadId = GetCurrentThreadId();
        _waitTimer = CreateWaitableTimerExW(IntPtr.Zero, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
        try { init?.Invoke(); } catch (Exception ex) { Log.Error("Overlay init failed", ex); }
        _ready.Set();

        double last = Now;
        while (true)
        {
            while (PeekMessage(out var msg, IntPtr.Zero, 0, 0, PM_REMOVE))
            {
                if (msg.message == WM_QUIT) return;
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
            while (_queue.TryDequeue(out var work))
            {
                try { work(); } catch (Exception ex) { Log.Error("Overlay work item failed", ex); }
            }
            RunDueTimers();

            if (_clients.Count > 0)
            {
                double now = Now;
                float dt = (float)Math.Clamp(now - last, 0, 1.0 / 20.0);
                last = now;
                for (int i = _clients.Count - 1; i >= 0; i--)
                {
                    bool more;
                    try { more = _clients[i].Tick(now, dt); }
                    catch (Exception ex) { Log.Error("Frame client failed", ex); more = false; }
                    if (!more) _clients.RemoveAt(i);
                }
                WaitForNextFrame();
            }
            else
            {
                uint timeout = INFINITE;
                if (_timers.Count > 0)
                {
                    double next = _timers.Min(t => t.due) - Now;
                    timeout = (uint)Math.Clamp(next * 1000.0, 0, 60_000);
                }
                MsgWaitForMultipleObjectsEx(0, null, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
                last = Now;
            }
        }
    }

    void RunDueTimers()
    {
        if (_timers.Count == 0) return;
        double now = Now;
        for (int i = 0; i < _timers.Count; i++)
        {
            if (_timers[i].due > now) continue;
            var action = _timers[i].action;
            _timers.RemoveAt(i--);
            try { action(); } catch (Exception ex) { Log.Error("Overlay timer failed", ex); }
        }
    }

    void WaitForNextFrame()
    {
        if (Now - _lastRefreshQuery > 2.0) QueryRefreshRate();
        double start = Now;
        int hr = DwmFlush();
        double waited = Now - start;
        // DwmFlush can return immediately when the compositor is idle; fall back to a timed wait.
        if (hr != 0 || waited < 0.0008)
        {
            double remaining = _refreshPeriod - waited;
            if (remaining > 0.0005) SleepPrecise(remaining);
        }
    }

    void SleepPrecise(double seconds)
    {
        if (_waitTimer == IntPtr.Zero) { Thread.Sleep(Math.Max(1, (int)(seconds * 1000))); return; }
        long due = -(long)(seconds * 10_000_000); // relative, 100ns units
        if (SetWaitableTimer(_waitTimer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false))
            WaitForSingleObject(_waitTimer, 100);
    }

    void QueryRefreshRate()
    {
        _lastRefreshQuery = Now;
        var info = new DWM_TIMING_INFO { cbSize = Marshal.SizeOf<DWM_TIMING_INFO>() };
        if (DwmGetCompositionTimingInfo(IntPtr.Zero, ref info) == 0 && info.rateRefresh.uiNumerator > 0 && info.rateRefresh.uiDenominator > 0)
        {
            double hz = (double)info.rateRefresh.uiNumerator / info.rateRefresh.uiDenominator;
            if (hz >= 24 && hz <= 1000) _refreshPeriod = 1.0 / hz;
        }
    }
}
