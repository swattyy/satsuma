using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Satsuma.Core;

namespace Satsuma.Ops.Convert;

/// <summary>
/// Microsoft Office automation (late-bound COM) for high-fidelity Word/Excel/PowerPoint conversions.
/// All calls run on one dedicated STA thread; each job has a watchdog that kills the Office process we started
/// if it stops responding (e.g. a hidden dialog).
/// </summary>
public static class Office
{
    static readonly Lazy<bool> _word = new(() => ProgIdExists("Word.Application"));
    static readonly Lazy<bool> _excel = new(() => ProgIdExists("Excel.Application"));
    static readonly Lazy<bool> _powerPoint = new(() => ProgIdExists("PowerPoint.Application"));
    public static bool HasWord => _word.Value;
    public static bool HasExcel => _excel.Value;
    public static bool HasPowerPoint => _powerPoint.Value;

    static bool ProgIdExists(string progId)
    {
        try { return Type.GetTypeFromProgID(progId) != null; } catch { return false; }
    }

    // ------------------------------------------------------------------ STA worker

    static readonly BlockingCollection<Action> Queue = new();
    static Thread? _worker;
    static readonly object Gate = new();

    static Task Run(Action work)
    {
        lock (Gate)
        {
            if (_worker == null)
            {
                _worker = new Thread(() => { foreach (var a in Queue.GetConsumingEnumerable()) a(); })
                { IsBackground = true, Name = "Satsuma Office" };
                _worker.SetApartmentState(ApartmentState.STA);
                _worker.Start();
            }
        }
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Queue.Add(() =>
        {
            try { work(); tcs.SetResult(); }
            catch (Exception ex) { tcs.SetException(ex); }
            finally { ReleaseLeftovers(); }
        });
        return tcs.Task;
    }

    /// <summary>
    /// Late-bound calls like <c>word.Documents.Open(…)</c> create hidden intermediate COM wrappers that keep Office
    /// alive after Quit. Once the job's locals are out of scope, collecting them lets the process exit right away.
    /// </summary>
    static void ReleaseLeftovers()
    {
        for (int i = 0; i < 2; i++)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
        }
    }

    static (dynamic app, int pid) Launch(string progId, string processName)
    {
        var before = Process.GetProcessesByName(processName).Select(p => p.Id).ToHashSet();
        var type = Type.GetTypeFromProgID(progId) ?? throw new OpException($"{progId} isn't installed.");
        dynamic app = Activator.CreateInstance(type)!;
        int pid = Process.GetProcessesByName(processName).Select(p => p.Id).FirstOrDefault(id => !before.Contains(id));
        return (app, pid);
    }

    static Timer Watchdog(int pid, string what, TimeSpan timeout) => new(_ =>
    {
        if (pid == 0) return;
        Log.Warn($"{what} timed out; killing Office process {pid}");
        try { Process.GetProcessById(pid).Kill(); } catch { }
    }, null, timeout, Timeout.InfiniteTimeSpan);

    static void Release(object? com)
    {
        try { if (com != null && Marshal.IsComObject(com)) Marshal.FinalReleaseComObject(com); } catch { }
    }

    // ------------------------------------------------------------------ Word

    public static class WdFormat
    {
        public const int Docx = 16, Pdf = 17, Rtf = 6, FilteredHtml = 10, Text = 7, Odt = 23, Doc = 0, Xps = 18;
    }

    public static Task WordAsync(string input, string output, int format) => Run(() =>
    {
        if (FileKinds.Ext(input) == "pdf") SuppressPdfReflowPrompt();
        var (word, pid) = Launch("Word.Application", "WINWORD");
        using var dog = Watchdog(pid, "Word", TimeSpan.FromMinutes(3));
        dynamic? doc = null;
        try
        {
            word.Visible = false;
            word.DisplayAlerts = 0;            // wdAlertsNone
            word.AutomationSecurity = 3;       // msoAutomationSecurityForceDisable: never run macros
            doc = word.Documents.Open(FileName: input, ConfirmConversions: false, ReadOnly: true, AddToRecentFiles: false,
                Visible: false, NoEncodingDialog: true);
            if (format == WdFormat.Pdf)
                doc.ExportAsFixedFormat(OutputFileName: output, ExportFormat: 17, OpenAfterExport: false, OptimizeFor: 0,
                    IncludeDocProps: true, CreateBookmarks: 1, DocStructureTags: true);
            else if (format == WdFormat.Text)
                doc.SaveAs2(FileName: output, FileFormat: format, AddToRecentFiles: false, Encoding: 65001);
            else
                doc.SaveAs2(FileName: output, FileFormat: format, AddToRecentFiles: false);
        }
        catch (COMException ex) { throw new OpException("Word: " + ex.Message); }
        finally
        {
            try { doc?.Close(SaveChanges: 0); } catch { }
            try { word.Quit(SaveChanges: 0); } catch { }
            Release(doc);
            Release(word);
        }
    });

    /// <summary>Word asks "convert this PDF to an editable document?" on open; hidden instances would hang on it.</summary>
    static void SuppressPdfReflowPrompt()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Office\16.0\Word\Options");
            if (key.GetValue("DisableConvertPdfWarning") == null) key.SetValue("DisableConvertPdfWarning", 1, RegistryValueKind.DWord);
        }
        catch { }
    }

    // ------------------------------------------------------------------ Excel

    public static class XlFormat
    {
        public const int Xlsx = 51, Xls = 56, Ods = 60, CsvUtf8 = 62, Html = 44;
    }

    public static Task ExcelAsync(string input, string output, int? format) => Run(() =>
    {
        var (xl, pid) = Launch("Excel.Application", "EXCEL");
        using var dog = Watchdog(pid, "Excel", TimeSpan.FromMinutes(3));
        dynamic? wb = null;
        try
        {
            xl.Visible = false;
            xl.DisplayAlerts = false;
            xl.ScreenUpdating = false;
            xl.AutomationSecurity = 3;
            wb = xl.Workbooks.Open(Filename: input, UpdateLinks: 0, ReadOnly: true, IgnoreReadOnlyRecommended: true, AddToMru: false);
            if (format == null) wb.ExportAsFixedFormat(Type: 0, Filename: output, Quality: 0, IncludeDocProperties: true, IgnorePrintAreas: false, OpenAfterPublish: false);
            else wb.SaveAs(Filename: output, FileFormat: format.Value);
        }
        catch (COMException ex) { throw new OpException("Excel: " + ex.Message); }
        finally
        {
            try { wb?.Close(SaveChanges: false); } catch { }
            try { xl.Quit(); } catch { }
            Release(wb);
            Release(xl);
        }
    });

    // ------------------------------------------------------------------ PowerPoint

    /// <summary>PowerPoint is single-instance; only quit it if we were the ones who started it.</summary>
    static void WithPowerPoint(Action<dynamic> work)
    {
        bool wasRunning = Process.GetProcessesByName("POWERPNT").Length > 0;
        var (pp, pid) = Launch("PowerPoint.Application", "POWERPNT");
        using var dog = wasRunning ? null : Watchdog(pid, "PowerPoint", TimeSpan.FromMinutes(4));
        try { work(pp); }
        catch (COMException ex) { throw new OpException("PowerPoint: " + ex.Message); }
        finally
        {
            try { if (!wasRunning && (int)pp.Presentations.Count == 0) pp.Quit(); } catch { }
            Release(pp);
        }
    }

    public static class PpFormat
    {
        public const int Pdf = 32, Pptx = 24, Odp = 35;
    }

    public static Task PowerPointAsync(string input, string output, int format) => Run(() => WithPowerPoint(pp =>
    {
        dynamic pres = pp.Presentations.Open(FileName: input, ReadOnly: -1, Untitled: 0, WithWindow: 0);
        try { pres.SaveAs(FileName: output, FileFormat: format); }
        finally { try { pres.Close(); } catch { } Release(pres); }
    }));

    /// <summary>Exports each slide as an image; returns the files in order.</summary>
    public static async Task<List<string>> PowerPointSlidesAsync(string input, string folder, string filter, int width)
    {
        var files = new List<string>();
        await Run(() => WithPowerPoint(pp =>
        {
            dynamic pres = pp.Presentations.Open(FileName: input, ReadOnly: -1, Untitled: 0, WithWindow: 0);
            try
            {
                float sw = (float)pres.PageSetup.SlideWidth, sh = (float)pres.PageSetup.SlideHeight;
                int height = (int)Math.Round(width * sh / sw);
                int count = pres.Slides.Count;
                string ext = filter == "PNG" ? "png" : "jpg";
                for (int i = 1; i <= count; i++)
                {
                    string file = Path.Combine(folder, $"Slide {i:00}.{ext}");
                    pres.Slides[i].Export(file, filter, width, height);
                    files.Add(file);
                }
            }
            finally { try { pres.Close(); } catch { } Release(pres); }
        }));
        return files;
    }

    /// <summary>Builds a deck with one full-bleed picture per slide (PDF → PPTX).</summary>
    public static Task PowerPointFromImagesAsync(IReadOnlyList<string> images, float slideW, float slideH, string output) => Run(() => WithPowerPoint(pp =>
    {
        dynamic pres = pp.Presentations.Add(WithWindow: 0);
        try
        {
            pres.PageSetup.SlideWidth = Math.Clamp(slideW, 72, 4032);
            pres.PageSetup.SlideHeight = Math.Clamp(slideH, 72, 4032);
            float w = (float)pres.PageSetup.SlideWidth, h = (float)pres.PageSetup.SlideHeight;
            for (int i = 0; i < images.Count; i++)
            {
                dynamic slide = pres.Slides.Add(i + 1, 12); // ppLayoutBlank
                slide.Shapes.AddPicture(FileName: images[i], LinkToFile: 0, SaveWithDocument: -1, Left: 0, Top: 0, Width: w, Height: h);
                Release(slide);
            }
            pres.SaveAs(FileName: output, FileFormat: PpFormat.Pptx);
        }
        finally { try { pres.Close(); } catch { } Release(pres); }
    }));
}
