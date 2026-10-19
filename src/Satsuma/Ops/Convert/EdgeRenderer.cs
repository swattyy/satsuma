using System.Diagnostics;
using Satsuma.Core;

namespace Satsuma.Ops.Convert;

/// <summary>
/// Uses the Microsoft Edge engine that ships with Windows, headless, to print HTML to PDF (small files with
/// subset fonts and full Unicode) and to rasterize SVG.
/// </summary>
public static class EdgeRenderer
{
    public static string? EdgePath { get; } = new[]
    {
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"Microsoft\Edge\Application\msedge.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Microsoft\Edge\Application\msedge.exe"),
    }.FirstOrDefault(File.Exists);

    public static bool Available => EdgePath != null;

    static async Task RunAsync(string args, string profileDir, CancellationToken ct)
    {
        if (EdgePath == null) throw new OpException("Microsoft Edge is needed for this conversion.");
        var psi = new ProcessStartInfo(EdgePath,
            $"--headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check --disable-extensions " +
            $"--allow-file-access-from-files --user-data-dir=\"{profileDir}\" {args}")
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        using var p = Process.Start(psi)!;
        _ = p.StandardError.ReadToEndAsync(ct);
        _ = p.StandardOutput.ReadToEndAsync(ct);
        try { await p.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(60), ct); }
        catch (TimeoutException) { try { p.Kill(true); } catch { } throw new OpException("Edge took too long to render."); }
    }

    /// <summary>Prints an HTML file (or URL) to PDF.</summary>
    public static async Task PrintToPdfAsync(string htmlPath, string output, CancellationToken ct)
    {
        var dir = AppPaths.NewTempDir("edge");
        try
        {
            string tmpOut = Path.Combine(dir, "out.pdf");
            await RunAsync($"--no-pdf-header-footer --print-to-pdf=\"{tmpOut}\" \"{new Uri(htmlPath).AbsoluteUri}\"", Path.Combine(dir, "profile"), ct);
            if (!File.Exists(tmpOut) || new FileInfo(tmpOut).Length == 0) throw new OpException("Edge couldn't print this page to PDF.");
            File.Move(tmpOut, output, overwrite: true);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    /// <summary>Writes <paramref name="html"/> to a temp file (relative links resolve against <paramref name="baseDir"/>) and prints it.</summary>
    public static async Task HtmlToPdfAsync(string html, string? baseDir, string output, CancellationToken ct)
    {
        var dir = AppPaths.NewTempDir("html");
        try
        {
            if (baseDir != null)
                html = html.Replace("<head>", $"<head>\n<base href=\"{new Uri(baseDir.TrimEnd('\\') + "\\").AbsoluteUri}\">", StringComparison.OrdinalIgnoreCase);
            // Print styling: no page-wide max width, avoid splitting rows and code blocks across pages.
            html = html.Replace("</head>", "<style>@media print { body { max-width: none; margin: 0; font-size: 11pt; } pre, tr, img, blockquote { break-inside: avoid; } h1, h2, h3 { break-after: avoid; } } @page { margin: 18mm 17mm; }</style>\n</head>", StringComparison.OrdinalIgnoreCase);
            var file = Path.Combine(dir, "doc.html");
            await File.WriteAllTextAsync(file, html, new System.Text.UTF8Encoding(false), ct);
            await PrintToPdfAsync(file, output, ct);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    /// <summary>Takes a transparent screenshot of a page at the given size.</summary>
    public static async Task<string> ScreenshotAsync(string htmlPath, int width, int height, string pngOut, CancellationToken ct)
    {
        var dir = AppPaths.NewTempDir("shot");
        try
        {
            await RunAsync($"--default-background-color=00000000 --window-size={width},{height} --screenshot=\"{pngOut}\" \"{new Uri(htmlPath).AbsoluteUri}\"", Path.Combine(dir, "profile"), ct);
            if (!File.Exists(pngOut)) throw new OpException("Edge couldn't render this file.");
            return pngOut;
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }
}
