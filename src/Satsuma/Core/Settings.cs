using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace Satsuma.Core;

public enum TriggerKey { None, Shift, Ctrl, Alt, Space, Tab, CapsLock }
public enum OutputLocation { NextToOriginal, Downloads, CustomFolder }
public enum ThemePreference { System, Light, Dark }

public sealed class AppSettings
{
    public bool Enabled { get; set; } = true;
    public TriggerKey ConvertKey { get; set; } = TriggerKey.Shift;
    public TriggerKey ToolsKey { get; set; } = TriggerKey.Ctrl;
    public TriggerKey ActionsKey { get; set; } = TriggerKey.Alt;

    public OutputLocation Output { get; set; } = OutputLocation.NextToOriginal;
    public string? CustomOutputFolder { get; set; }

    public int ImageQuality { get; set; } = 90;
    public bool KeepMetadata { get; set; } = true;
    public bool HardwareVideoEncoding { get; set; } = true;
    public int PdfRenderDpi { get; set; } = 300;

    public bool ShowKeyHints { get; set; } = true;
    public bool Sounds { get; set; } = true;
    public bool RevealAfterConvert { get; set; }
    public ThemePreference Theme { get; set; } = ThemePreference.System;
    public double WheelScale { get; set; } = 1.0;

    public string? FfmpegPath { get; set; }
    public bool FirstRunDone { get; set; }

    [JsonIgnore]
    public bool LaunchAtStartup
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("Satsuma") is string s && s.Contains(AppPaths.ExePath, StringComparison.OrdinalIgnoreCase);
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("Satsuma", $"\"{AppPaths.ExePath}\" --background");
            else key.DeleteValue("Satsuma", false);
        }
    }

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
}

public static class Settings
{
    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static AppSettings Current { get; private set; } = new();
    public static event Action? Changed;

    public static void Load()
    {
        try
        {
            if (File.Exists(AppPaths.SettingsFile))
                Current = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(AppPaths.SettingsFile), Json) ?? new AppSettings();
        }
        catch (Exception ex)
        {
            Log.Warn("Settings load failed, using defaults: " + ex.Message);
            Current = new AppSettings();
        }
    }

    public static void Save()
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            File.WriteAllText(AppPaths.SettingsFile, JsonSerializer.Serialize(Current, Json));
        }
        catch (Exception ex) { Log.Warn("Settings save failed: " + ex.Message); }
        Changed?.Invoke();
    }
}
