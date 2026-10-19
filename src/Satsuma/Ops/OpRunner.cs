using Satsuma.Core;
using Satsuma.Native;
using Satsuma.Overlay;
using Satsuma.Wheel;
using SkiaSharp;

namespace Satsuma.Ops;

/// <summary>Runs a wheel item off the UI threads and mirrors its progress into a <see cref="Hud"/> bubble.</summary>
public static class OpRunner
{
    /// <summary>Call on the overlay thread (right after a drop).</summary>
    public static void Start(WheelItem item, IReadOnlyList<string> files, Win32.POINT anchor,
        SKImage? backdrop, Win32.POINT origin, Win32.RECT? backdropRect)
    {
        // Copy the wheel's frosted backdrop now; the wheel disposes its own when it finishes closing.
        SKImage? backdropCopy = null;
        if (backdrop != null)
        {
            using var pixmap = backdrop.PeekPixels();
            backdropCopy = pixmap != null ? SKImage.FromPixelCopy(pixmap) : null;
        }
        var rect = backdropRect ?? default;

        Hud? hud = null;
        var ctx = new OpContext { Files = files, Anchor = anchor, Cancel = CancellationToken.None };
        ctx.OnBeginWork = title => OverlayThread.Instance.Post(() =>
        {
            if (hud == null)
            {
                hud = new Hud(anchor, title, GlyphFor(item), backdropCopy, rect);
                backdropCopy = null;
            }
        });
        ctx.OnProgress = p => OverlayThread.Instance.Post(() => hud?.Report(p.Fraction, p.Status));

        if (!item.Interactive) ctx.BeginWork(item.WorkingTitle ?? $"{item.Caption} {item.Label}…");

        Task.Run(async () =>
        {
            OpResult result;
            try
            {
                result = await item.Run(ctx).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { result = OpResult.Cancel(); }
            catch (OpException ex)
            {
                Log.Warn($"{item.Id} failed: {ex.Message}");
                Finish(() => EnsureHud().Fail("Couldn't finish", ex.Message));
                return;
            }
            catch (Exception ex)
            {
                Log.Error($"{item.Id} crashed", ex);
                Finish(() => EnsureHud().Fail("Something went wrong", FirstLine(ex.Message)));
                return;
            }

            if (result.Canceled || result.Quiet)
            {
                Finish(() => hud?.Dismiss());
                return;
            }
            string title, subtitle;
            if (result.Title != null) { title = result.Title; subtitle = result.Message ?? (result.Outputs.Count > 0 ? "Click to show in folder" : ""); }
            else if (result.Outputs.Count == 1) { title = "Saved " + Path.GetFileName(result.Outputs[0].TrimEnd('\\')); subtitle = "Click to show in folder"; }
            else if (result.Outputs.Count > 1) { title = $"Saved {result.Outputs.Count} files"; subtitle = "Click to show in folder"; }
            else { title = "Done"; subtitle = ""; }
            Finish(() => EnsureHud().Complete(title, subtitle, result.Outputs));
            if (Settings.Current.RevealAfterConvert && result.Outputs.Count > 0) Shell.RevealInExplorer(result.Outputs);
        });

        Hud EnsureHud() => hud ??= new Hud(anchor, item.Label, GlyphFor(item), backdropCopy, rect);
        void Finish(Action a) => OverlayThread.Instance.Post(a);
    }

    static string FirstLine(string s)
    {
        var i = s.IndexOfAny(new[] { '\r', '\n' });
        return i > 0 ? s[..i] : s;
    }

    static string GlyphFor(WheelItem item) => item.Glyph ?? Glyphs.Convert;
}
