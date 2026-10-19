using System.Windows;
using Satsuma.Core;
using Satsuma.Native;
using Satsuma.Overlay;
using Satsuma.UI;
using Satsuma.Wheel;

namespace Satsuma;

public static class Program
{
    /// <summary>Set by the command-line test modes (lets outputs land next to temp inputs).</summary>
    public static bool IsTestMode;
}

public partial class App : Application
{
    const string SignalName = @"Local\Satsuma.ShowSettings";
    Mutex? _mutex;
    TrayIcon? _tray;
    EventWaitHandle? _signal;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        AppDomain.CurrentDomain.UnhandledException += (_, ex) => Log.Error("Unhandled", ex.ExceptionObject as Exception);
        DispatcherUnhandledException += (_, ex) => { Log.Error("UI exception", ex.Exception); ex.Handled = true; };
        TaskScheduler.UnobservedTaskException += (_, ex) => { Log.Error("Task exception", ex.Exception); ex.SetObserved(); };
        Settings.Load();

        if (Cli.Handles(e.Args))
        {
            int code = await Cli.RunAsync(e.Args);
            Shutdown(code);
            return;
        }

        _mutex = new Mutex(true, @"Local\Satsuma.Instance", out bool created);
        if (!created)
        {
            // Already running: ask that instance to show its settings, then leave.
            try { EventWaitHandle.OpenExisting(SignalName).Set(); } catch { }
            Shutdown();
            return;
        }
        _signal = new EventWaitHandle(false, EventResetMode.AutoReset, SignalName);
        new Thread(() => { while (_signal.WaitOne()) Dispatcher.BeginInvoke(SettingsWindow.ShowSingle); }) { IsBackground = true, Name = "Satsuma signal" }.Start();

        OverlayThread.Instance.Start(WheelController.Create);
        InputMonitor.Instance.Start();
        _tray = new TrayIcon();

        if (!Settings.Current.FirstRunDone && !e.Args.Contains("--background")) WelcomeWindow.ShowSingle();
        Log.Info($"Satsuma {typeof(App).Assembly.GetName().Version} started");
    }

    protected override void OnExit(ExitEventArgs e)
    {
        InputMonitor.Instance.Stop();
        _tray?.Dispose();
        _mutex?.Dispose();
        base.OnExit(e);
    }
}
