using Satsuma.UI;
using Satsuma.Wheel;

namespace Satsuma.Ops;

public static partial class Catalog
{
    static WheelItem Action(string id, string label, string glyph, string caption, Func<OpContext, Task<OpResult>> run, bool interactive = true) => new()
    {
        Id = "action:" + id,
        Label = label,
        Glyph = glyph,
        Caption = caption,
        DropText = caption,
        WorkingTitle = caption + "…",
        Interactive = interactive,
        Run = run,
    };

    static IReadOnlyList<WheelItem> ActionItems(IReadOnlyList<string> files, bool virtualOnly)
    {
        var list = new List<WheelItem>
        {
            Action("share", "Share", Glyphs.Share, "Share with Windows", async ctx => { await FileActions.ShareAsync(ctx.Files); return OpResult.QuietDone(); }),
            Action("float", "Float", Glyphs.Pin, "Keep on a floating shelf", async ctx => { await FileActions.FloatAsync(ctx.Files, ctx.Anchor); return OpResult.QuietDone(); }),
            Action("copy", "Copy", Glyphs.Copy, "Copy to clipboard", async ctx =>
            {
                await FileActions.CopyFilesAsync(ctx.Files);
                return OpResult.Done(ctx.Files.Count == 1 ? "Copied " + Path.GetFileName(ctx.File.TrimEnd('\\')) : $"Copied {ctx.Files.Count} items", "Paste anywhere");
            }, interactive: false),
        };
        if (!virtualOnly)
        {
            list.Add(Action("move", "Move", Glyphs.Move, "Move to a folder", async ctx =>
            {
                var moved = await FileActions.MoveAsync(ctx.Files);
                if (moved == null) return OpResult.Cancel();
                var r = OpResult.Files(moved);
                r.Title = moved.Count == 1 ? "Moved " + Path.GetFileName(moved[0].TrimEnd('\\')) : $"Moved {moved.Count} items";
                return r;
            }));
            list.Add(Action("path", "Copy Path", Glyphs.Link, "Copy full path", async ctx =>
            {
                await FileActions.SetClipboardTextAsync(string.Join(Environment.NewLine, ctx.Files));
                return OpResult.Done(ctx.Files.Count == 1 ? "Path copied" : $"{ctx.Files.Count} paths copied", ctx.Files.Count == 1 ? ctx.File : "One per line");
            }, interactive: false));
            list.Add(Action("terminal", "Terminal", Glyphs.Terminal, "Open a terminal here", ctx => { FileActions.OpenTerminal(ctx.File); return Task.FromResult(OpResult.QuietDone()); }));
            if (files.Count == 1 && File.Exists(files[0]))
                list.Add(Action("openwith", "Open with", Glyphs.OpenWith, "Choose an app", async ctx => { await FileActions.OpenWithAsync(ctx.File); return OpResult.QuietDone(); }));
        }
        return list;
    }
}
