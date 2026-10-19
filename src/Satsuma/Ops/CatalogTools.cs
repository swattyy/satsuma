using Satsuma.Core;
using Satsuma.Ops.Convert;
using Satsuma.Ops.Tools;
using Satsuma.UI;
using Satsuma.Wheel;

namespace Satsuma.Ops;

public static partial class Catalog
{
    static WheelItem Tool(string id, string label, string glyph, string caption, Func<OpContext, Task<OpResult>> run, bool interactive = false, string? working = null) => new()
    {
        Id = "tool:" + id,
        Label = label,
        Glyph = glyph,
        Caption = caption,
        DropText = label,
        WorkingTitle = working ?? label + "…",
        Interactive = interactive,
        Run = run,
    };

    static IReadOnlyList<WheelItem> ToolItems(IReadOnlyList<string> files)
    {
        var groups = files.Select(GroupOf).Distinct().ToList();
        bool many = files.Count > 1;
        var list = new List<WheelItem>();
        var group = groups.Count == 1 ? groups[0] : Group.None;
        if (groups.Count == 2 && groups.Contains(Group.Gif) && groups.Contains(Group.Image)) group = Group.Image;

        switch (group)
        {
            case Group.Image:
            case Group.Gif:
                list.Add(Tool("compress", "Compress", Glyphs.Compress, "Reduce file size", async ctx =>
                {
                    var o = await ToolDialogs.ImageCompressAsync(ctx.Files);
                    if (o == null) return OpResult.Cancel();
                    ctx.BeginWork("Compressing…");
                    return await ForEach(ctx, (f, i) => ImageTools.CompressAsync(f, o));
                }, interactive: true));
                list.Add(Tool("resize", "Resize", Glyphs.Resize, "Change dimensions", async ctx =>
                {
                    var o = await ToolDialogs.ImageResizeAsync(ctx.Files);
                    if (o == null) return OpResult.Cancel();
                    ctx.BeginWork("Resizing…");
                    return await ForEach(ctx, (f, i) => ImageTools.ResizeAsync(f, o.Scale, o.Width, o.Height));
                }, interactive: true));
                if (!many)
                    list.Add(Tool("crop", "Crop", Glyphs.Crop, "Trim the edges", async ctx =>
                    {
                        var rect = await ToolDialogs.ImageCropAsync(ctx.File);
                        if (rect == null) return OpResult.Cancel();
                        ctx.BeginWork("Cropping…");
                        return OpResult.Files(new[] { await ImageTools.CropAsync(ctx.File, rect.Value) });
                    }, interactive: true));
                list.Add(Tool("rotate", "Rotate", Glyphs.Rotate, "Turn 90° clockwise", ctx => ForEach(ctx, (f, i) => ImageTools.RotateAsync(f, 90)), working: "Rotating…"));
                list.Add(Tool("metadata", "Metadata", Glyphs.Tag, "Remove location & camera info", ctx => ForEach(ctx, (f, i) => ImageTools.StripMetadataAsync(f)), working: "Removing metadata…"));
                list.Add(Tool("ocr", "Text", Glyphs.Text, "Copy the text in the image", async ctx =>
                {
                    var texts = new List<string>();
                    for (int i = 0; i < ctx.Files.Count; i++) { texts.Add(await ImageTools.RecognizeTextAsync(ctx.Files[i])); ctx.ReportItem(i, 1); }
                    var all = string.Join(Environment.NewLine + Environment.NewLine, texts).Trim();
                    if (all.Length == 0) throw new OpException("No text found.");
                    await FileActions.SetClipboardTextAsync(all);
                    var words = DocTools.Count(all).words;
                    return OpResult.Done("Text copied", $"{words} words on the clipboard");
                }, working: "Reading text…"));
                list.Add(Tool("redact", "Redact", Glyphs.Redact, "Blur faces or text", async ctx =>
                {
                    var o = await ToolDialogs.RedactAsync(ctx.Files);
                    if (o == null) return OpResult.Cancel();
                    ctx.BeginWork("Redacting…");
                    return await ForEach(ctx, async (f, i) => (await ImageTools.RedactAsync(f, o.Faces, o.Text, o.Style)).output);
                }, interactive: true));
                list.Add(Tool("background", "Backdrop", Glyphs.Background, "Place on a background", async ctx =>
                {
                    var o = await ToolDialogs.BackgroundAsync(ctx.Files);
                    if (o == null) return OpResult.Cancel();
                    ctx.BeginWork("Adding background…");
                    return await ForEach(ctx, (f, i) => ImageTools.BackgroundAsync(f, o));
                }, interactive: true));
                if (many)
                {
                    list.Add(Tool("makepdf", "Make PDF", Glyphs.Document, "One page per image", async ctx =>
                        OpResult.Files(new[] { await ImageTools.MakePdfAsync(ctx.Files, p => ctx.Report(p)) }), working: "Making PDF…"));
                    list.Add(Tool("collage", "Collage", Glyphs.Grid, "Combine into one image", async ctx =>
                    {
                        var o = await ToolDialogs.CollageAsync(ctx.Files);
                        if (o == null) return OpResult.Cancel();
                        ctx.BeginWork("Making collage…");
                        return OpResult.Files(new[] { await ImageTools.CollageAsync(ctx.Files, o, p => ctx.Report(p)) });
                    }, interactive: true));
                }
                break;

            case Group.Video:
                list.Add(Tool("compress", "Compress", Glyphs.Compress, "Reduce file size", async ctx =>
                {
                    var o = await ToolDialogs.VideoCompressAsync(ctx.Files);
                    if (o == null) return OpResult.Cancel();
                    ctx.BeginWork("Compressing video…");
                    return await ForEach(ctx, (f, i) => MediaTools.CompressVideoAsync(f, o, p => ctx.ReportItem(i, p), ctx.Cancel));
                }, interactive: true));
                if (!many)
                    list.Add(Tool("trim", "Trim", Glyphs.Cut, "Cut the start or end", async ctx =>
                    {
                        var r = await ToolDialogs.TrimAsync(ctx.File);
                        if (r == null) return OpResult.Cancel();
                        ctx.BeginWork("Trimming…");
                        return OpResult.Files(new[] { await MediaTools.TrimAsync(ctx.File, r.Value.start, r.Value.end, p => ctx.Report(p), ctx.Cancel) });
                    }, interactive: true));
                list.Add(Tool("mute", "Mute", Glyphs.Mute, "Remove the audio", ctx => ForEach(ctx, (f, i) => MediaTools.MuteAsync(f, p => ctx.ReportItem(i, p), ctx.Cancel)), working: "Removing audio…"));
                list.Add(Tool("720p", "720p", Glyphs.Resize, "Scale down to 720p", ctx => ForEach(ctx, (f, i) => MediaTools.ResizeVideoAsync(f, 720, p => ctx.ReportItem(i, p), ctx.Cancel)), working: "Resizing to 720p…"));
                list.Add(Tool("rotate", "Rotate", Glyphs.Rotate, "Turn 90° clockwise", ctx => ForEach(ctx, (f, i) => MediaTools.RotateVideoAsync(f, true, p => ctx.ReportItem(i, p), ctx.Cancel)), working: "Rotating…"));
                list.Add(Tool("snapshot", "Frame", Glyphs.Camera, "Save a still frame", ctx => ForEach(ctx, (f, i) => MediaTools.SnapshotAsync(f, null, ctx.Cancel)), working: "Grabbing a frame…"));
                list.Add(Tool("normalize", "Loudness", Glyphs.Volume, "Even out the volume", ctx => ForEach(ctx, (f, i) => MediaTools.NormalizeAsync(f, p => ctx.ReportItem(i, p), ctx.Cancel)), working: "Normalizing…"));
                if (many) list.Add(Tool("merge", "Merge", Glyphs.Merge, "Join clips in order", async ctx =>
                    OpResult.Files(new[] { await MediaTools.MergeAsync(ctx.Files, p => ctx.Report(p), ctx.Cancel) }), working: "Merging clips…"));
                break;

            case Group.Audio:
                list.Add(Tool("compress", "Compress", Glyphs.Compress, "Reduce file size", async ctx =>
                {
                    var kbps = await ToolDialogs.AudioCompressAsync(ctx.Files);
                    if (kbps == null) return OpResult.Cancel();
                    ctx.BeginWork("Compressing audio…");
                    return await ForEach(ctx, (f, i) => MediaTools.CompressAudioAsync(f, kbps.Value, p => ctx.ReportItem(i, p), ctx.Cancel));
                }, interactive: true));
                if (!many)
                    list.Add(Tool("trim", "Trim", Glyphs.Cut, "Cut the start or end", async ctx =>
                    {
                        var r = await ToolDialogs.TrimAsync(ctx.File);
                        if (r == null) return OpResult.Cancel();
                        ctx.BeginWork("Trimming…");
                        return OpResult.Files(new[] { await MediaTools.TrimAsync(ctx.File, r.Value.start, r.Value.end, p => ctx.Report(p), ctx.Cancel) });
                    }, interactive: true));
                list.Add(Tool("normalize", "Loudness", Glyphs.Volume, "Even out the volume", ctx => ForEach(ctx, (f, i) => MediaTools.NormalizeAsync(f, p => ctx.ReportItem(i, p), ctx.Cancel)), working: "Normalizing…"));
                list.Add(Tool("mono", "Mono", Glyphs.Speaker, "Mix down to one channel", ctx => ForEach(ctx, (f, i) => MediaTools.MonoAsync(f, p => ctx.ReportItem(i, p), ctx.Cancel)), working: "Mixing to mono…"));
                list.Add(Tool("fade", "Fade", Glyphs.Audio, "Fade in and out", ctx => ForEach(ctx, (f, i) => MediaTools.FadeAsync(f, 2, p => ctx.ReportItem(i, p), ctx.Cancel)), working: "Adding fades…"));
                if (many) list.Add(Tool("merge", "Merge", Glyphs.Merge, "Join tracks in order", async ctx =>
                    OpResult.Files(new[] { await MediaTools.MergeAsync(ctx.Files, p => ctx.Report(p), ctx.Cancel) }), working: "Merging tracks…"));
                break;

            case Group.Pdf:
                if (many) list.Add(Tool("merge", "Merge", Glyphs.Merge, "Combine into one PDF", ctx => Task.Run(() => OpResult.Files(new[] { PdfTools.Merge(ctx.Files) })), working: "Merging PDFs…"));
                list.Add(Tool("split", "Split", Glyphs.Split, "One PDF per page", ctx => ForEach(ctx, (f, i) => Task.Run(() => PdfTools.Split(f, p => ctx.ReportItem(i, p)))), working: "Splitting…"));
                if (!many)
                    list.Add(Tool("extract", "Pages", Glyphs.Pages, "Keep only some pages", async ctx =>
                    {
                        var pages = await ToolDialogs.PagesAsync(ctx.File);
                        if (pages == null) return OpResult.Cancel();
                        ctx.BeginWork("Extracting pages…");
                        return OpResult.Files(new[] { await Task.Run(() => PdfTools.ExtractPages(ctx.File, pages)) });
                    }, interactive: true));
                list.Add(Tool("images", "Images", Glyphs.Photo, "Save embedded images", ctx => ForEachMany(ctx, (f, i) => Task.Run(() => PdfTools.ExtractImages(f, p => ctx.ReportItem(i, p)))), working: "Extracting images…"));
                list.Add(Tool("compress", "Compress", Glyphs.Compress, "Flatten pages to shrink", ctx => ForEach(ctx, (f, i) => PdfTools.FlattenCompressAsync(f, 150, 72, p => ctx.ReportItem(i, p), ctx.Cancel)), working: "Compressing PDF…"));
                AddTextTools(list);
                break;

            case Group.Doc:
            case Group.Sheet:
            case Group.Subtitle:
                AddTextTools(list);
                break;

            case Group.Archive:
                list.Add(Tool("extract", "Extract", Glyphs.FolderOpen, "Unpack here", ctx => ForEach(ctx, (f, i) => ArchiveConverter.ExtractAsync(f, ctx.Cancel)), working: "Extracting…"));
                break;

            case Group.Folder:
                list.Add(Tool("zip", "Zip", Glyphs.Package, "Compress into ZIP", async ctx => OpResult.Files(new[] { await ArchiveConverter.CreateAsync(ctx.Files, "zip", p => ctx.Report(p), ctx.Cancel) }), working: "Zipping…"));
                list.Add(Tool("info", "Size", Glyphs.Info, "Count files and size", ctx => Task.Run(() =>
                {
                    long bytes = 0; int count = 0;
                    foreach (var dir in ctx.Files)
                        foreach (var f in Directory.EnumerateFiles(dir, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true }))
                        {
                            try { bytes += new FileInfo(f).Length; count++; } catch { }
                        }
                    return OpResult.Done(FileKinds.HumanSize(bytes), $"{count:N0} files");
                }), working: "Measuring…"));
                break;
        }

        if (many && group != Group.Folder && list.All(i => i.Id != "tool:zip"))
            list.Add(Tool("zip", "Zip", Glyphs.Package, "Compress all into one ZIP", async ctx =>
                OpResult.Files(new[] { await ArchiveConverter.CreateAsync(ctx.Files, "zip", p => ctx.Report(p), ctx.Cancel) }), working: "Zipping…"));
        return list;
    }

    static void AddTextTools(List<WheelItem> list)
    {
        list.Add(Tool("copytext", "Copy text", Glyphs.Copy, "Copy all text", async ctx =>
        {
            var text = string.Join(Environment.NewLine + Environment.NewLine, await Task.Run(() => ctx.Files.Select(DocTools.ExtractText).ToList()));
            if (text.Trim().Length == 0) throw new OpException("No text found.");
            await FileActions.SetClipboardTextAsync(text);
            return OpResult.Done("Text copied", $"{DocTools.Count(text).words:N0} words on the clipboard");
        }, working: "Reading text…"));
        list.Add(Tool("count", "Count", Glyphs.Text, "Words and reading time", async ctx =>
        {
            var text = string.Join("\n", await Task.Run(() => ctx.Files.Select(DocTools.ExtractText).ToList()));
            var (words, chars, _, reading) = DocTools.Count(text);
            return OpResult.Done($"{words:N0} words", $"{chars:N0} characters · {reading}");
        }, working: "Counting…"));
    }
}
