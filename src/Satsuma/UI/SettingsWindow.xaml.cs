using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Satsuma.Core;
using Satsuma.Ops.Convert;

namespace Satsuma.UI;

public partial class SettingsWindow : Window
{
    static SettingsWindow? _instance;
    bool _loading;

    public static void ShowSingle()
    {
        if (_instance == null)
        {
            _instance = new SettingsWindow();
            _instance.Closed += (_, _) => _instance = null;
            _instance.Show();
        }
        Ui.ForceForeground(_instance);
    }

    static readonly (TriggerKey key, string name)[] Keys =
    {
        (TriggerKey.Shift, "Shift"), (TriggerKey.Ctrl, "Ctrl"), (TriggerKey.Alt, "Alt"), (TriggerKey.Space, "Space"),
        (TriggerKey.Tab, "Tab"), (TriggerKey.CapsLock, "Caps Lock"), (TriggerKey.None, "Off"),
    };

    public SettingsWindow()
    {
        InitializeComponent();
        Logo.Source = ToImage(AppIcon.Render(96, tray: false));
        foreach (var combo in new[] { ConvertKey, ToolsKey, ActionsKey })
            foreach (var (_, name) in Keys) combo.Items.Add(name);
        foreach (var t in new[] { "System", "Light", "Dark" }) ThemeCombo.Items.Add(t);
        foreach (var d in new[] { "150 DPI", "300 DPI", "600 DPI" }) DpiCombo.Items.Add(d);
        Load();
        Wire();
    }

    static BitmapSource ToImage(SkiaSharp.SKBitmap bmp)
    {
        using var img = SkiaSharp.SKImage.FromBitmap(bmp);
        using var png = img.Encode(SkiaSharp.SKEncodedImageFormat.Png, 100);
        var bi = new BitmapImage();
        bi.BeginInit();
        bi.StreamSource = new MemoryStream(png.ToArray());
        bi.CacheOption = BitmapCacheOption.OnLoad;
        bi.EndInit();
        bi.Freeze();
        bmp.Dispose();
        return bi;
    }

    void Load()
    {
        _loading = true;
        var s = Settings.Current;
        EnabledSwitch.IsChecked = s.Enabled;
        ConvertKey.SelectedIndex = Array.FindIndex(Keys, k => k.key == s.ConvertKey);
        ToolsKey.SelectedIndex = Array.FindIndex(Keys, k => k.key == s.ToolsKey);
        ActionsKey.SelectedIndex = Array.FindIndex(Keys, k => k.key == s.ActionsKey);
        OutNext.IsChecked = s.Output == OutputLocation.NextToOriginal;
        OutDownloads.IsChecked = s.Output == OutputLocation.Downloads;
        OutCustom.IsChecked = s.Output == OutputLocation.CustomFolder;
        CustomFolderText.Text = string.IsNullOrEmpty(s.CustomOutputFolder) ? "A folder of my choice" : s.CustomOutputFolder;
        RevealSwitch.IsChecked = s.RevealAfterConvert;
        QualitySlider.Value = s.ImageQuality;
        QualityText.Text = s.ImageQuality.ToString();
        MetadataSwitch.IsChecked = s.KeepMetadata;
        GpuSwitch.IsChecked = s.HardwareVideoEncoding;
        DpiCombo.SelectedIndex = s.PdfRenderDpi <= 150 ? 0 : s.PdfRenderDpi >= 600 ? 2 : 1;
        StartupSwitch.IsChecked = s.LaunchAtStartup;
        HintsSwitch.IsChecked = s.ShowKeyHints;
        SoundSwitch.IsChecked = s.Sounds;
        ThemeCombo.SelectedIndex = (int)s.Theme;
        ScaleSlider.Value = s.WheelScale;
        ScaleText.Text = $"{s.WheelScale:P0}";
        RefreshEngines();
        VersionText.Text = $"Version {typeof(App).Assembly.GetName().Version?.ToString(3)} · Everything runs on this PC. Nothing is uploaded.";
        _loading = false;
    }

    void RefreshEngines()
    {
        Ffmpeg.Reset();
        var path = Ffmpeg.FfmpegPath;
        FfmpegStatus.Text = path != null ? "Found: " + path : "Not found. Install it to convert audio and video.";
        InstallFfmpeg.Visibility = path == null ? Visibility.Visible : Visibility.Collapsed;
        var parts = new List<string>();
        if (Office.HasWord) parts.Add("Word ✓");
        if (Office.HasExcel) parts.Add("Excel ✓");
        if (Office.HasPowerPoint) parts.Add("PowerPoint ✓");
        OfficeStatus.Text = parts.Count > 0
            ? string.Join("   ", parts) + ". Used for Word and PDF files, spreadsheets to PDF, and slides."
            : "Not installed. Built-in converters handle DOCX, Markdown, HTML, EPUB, CSV and XLSX; slides need PowerPoint.";
    }

    void Save()
    {
        if (_loading) return;
        Settings.Save();
    }

    void Wire()
    {
        EnabledSwitch.Click += (_, _) => { Settings.Current.Enabled = EnabledSwitch.IsChecked == true; Save(); };
        ConvertKey.SelectionChanged += (_, _) => { if (ConvertKey.SelectedIndex >= 0) { Settings.Current.ConvertKey = Keys[ConvertKey.SelectedIndex].key; Dedupe(ConvertKey); Save(); } };
        ToolsKey.SelectionChanged += (_, _) => { if (ToolsKey.SelectedIndex >= 0) { Settings.Current.ToolsKey = Keys[ToolsKey.SelectedIndex].key; Dedupe(ToolsKey); Save(); } };
        ActionsKey.SelectionChanged += (_, _) => { if (ActionsKey.SelectedIndex >= 0) { Settings.Current.ActionsKey = Keys[ActionsKey.SelectedIndex].key; Dedupe(ActionsKey); Save(); } };
        OutNext.Checked += (_, _) => { Settings.Current.Output = OutputLocation.NextToOriginal; Save(); };
        OutDownloads.Checked += (_, _) => { Settings.Current.Output = OutputLocation.Downloads; Save(); };
        OutCustom.Checked += (_, _) =>
        {
            if (string.IsNullOrEmpty(Settings.Current.CustomOutputFolder) && !_loading) PickFolder();
            else { Settings.Current.Output = OutputLocation.CustomFolder; Save(); }
        };
        BrowseFolder.Click += (_, _) => PickFolder();
        RevealSwitch.Click += (_, _) => { Settings.Current.RevealAfterConvert = RevealSwitch.IsChecked == true; Save(); };
        QualitySlider.ValueChanged += (_, _) =>
        {
            Settings.Current.ImageQuality = (int)QualitySlider.Value;
            QualityText.Text = Settings.Current.ImageQuality.ToString();
            Save();
        };
        MetadataSwitch.Click += (_, _) => { Settings.Current.KeepMetadata = MetadataSwitch.IsChecked == true; Save(); };
        GpuSwitch.Click += (_, _) => { Settings.Current.HardwareVideoEncoding = GpuSwitch.IsChecked == true; Save(); };
        DpiCombo.SelectionChanged += (_, _) => { Settings.Current.PdfRenderDpi = DpiCombo.SelectedIndex switch { 0 => 150, 2 => 600, _ => 300 }; Save(); };
        StartupSwitch.Click += (_, _) => { Settings.Current.LaunchAtStartup = StartupSwitch.IsChecked == true; Save(); };
        HintsSwitch.Click += (_, _) => { Settings.Current.ShowKeyHints = HintsSwitch.IsChecked == true; Save(); };
        SoundSwitch.Click += (_, _) => { Settings.Current.Sounds = SoundSwitch.IsChecked == true; Save(); };
        ThemeCombo.SelectionChanged += (_, _) => { Settings.Current.Theme = (ThemePreference)Math.Max(0, ThemeCombo.SelectedIndex); Save(); };
        ScaleSlider.ValueChanged += (_, _) =>
        {
            Settings.Current.WheelScale = Math.Round(ScaleSlider.Value, 2);
            ScaleText.Text = $"{Settings.Current.WheelScale:P0}";
            Save();
        };
        InstallFfmpeg.Click += async (_, _) => await InstallFfmpegAsync();
        TourButton.Click += (_, _) => WelcomeWindow.ShowSingle();
        LogButton.Click += (_, _) => Shell.RevealInExplorer(new[] { AppPaths.LogFile });
    }

    /// <summary>Two wheels can't share a key: whichever other wheel used it is switched off.</summary>
    void Dedupe(ComboBox changed)
    {
        var s = Settings.Current;
        var key = Keys[changed.SelectedIndex].key;
        if (key == TriggerKey.None) return;
        _loading = true;
        if (changed != ConvertKey && s.ConvertKey == key) { s.ConvertKey = TriggerKey.None; ConvertKey.SelectedIndex = Keys.Length - 1; }
        if (changed != ToolsKey && s.ToolsKey == key) { s.ToolsKey = TriggerKey.None; ToolsKey.SelectedIndex = Keys.Length - 1; }
        if (changed != ActionsKey && s.ActionsKey == key) { s.ActionsKey = TriggerKey.None; ActionsKey.SelectedIndex = Keys.Length - 1; }
        _loading = false;
    }

    void PickFolder()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Save converted files to…" };
        if (dialog.ShowDialog(this) == true)
        {
            Settings.Current.CustomOutputFolder = dialog.FolderName;
            Settings.Current.Output = OutputLocation.CustomFolder;
            CustomFolderText.Text = dialog.FolderName;
            OutCustom.IsChecked = true;
            Save();
        }
        else if (string.IsNullOrEmpty(Settings.Current.CustomOutputFolder)) OutNext.IsChecked = true;
    }

    async Task InstallFfmpegAsync()
    {
        InstallFfmpeg.IsEnabled = false;
        FfmpegStatus.Text = "Installing with winget… (this downloads about 100 MB from gyan.dev)";
        try
        {
            var psi = new ProcessStartInfo("winget", "install --id Gyan.FFmpeg.Essentials -e --accept-source-agreements --accept-package-agreements --disable-interactivity")
            { UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi)!;
            await p.WaitForExitAsync();
        }
        catch (Exception ex) { FfmpegStatus.Text = "winget failed: " + ex.Message; }
        InstallFfmpeg.IsEnabled = true;
        RefreshEngines();
    }
}
