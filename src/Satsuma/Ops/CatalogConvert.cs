using Satsuma.Core;
using Satsuma.Ops.Convert;
using Satsuma.Wheel;

namespace Satsuma.Ops;

public static partial class Catalog
{
    enum Group { None, Image, Gif, Video, Audio, Pdf, Doc, Slides, Sheet, Subtitle, Archive, Folder }

    static Group GroupOf(string path) => FileKinds.KindOf(path) switch
    {
        FileKind.Image or FileKind.RawImage or FileKind.Svg => Group.Image,
        FileKind.Gif => Group.Gif,
        FileKind.Video => Group.Video,
        FileKind.Audio => Group.Audio,
        FileKind.Pdf => Group.Pdf,
        FileKind.WordDoc or FileKind.Text or FileKind.Markdown or FileKind.Html or FileKind.Epub => Group.Doc,
        FileKind.Slides => Group.Slides,
        FileKind.Sheet => Group.Sheet,
        FileKind.Subtitle => Group.Subtitle,
        FileKind.Archive => Group.Archive,
        FileKind.Folder => Group.Folder,
        _ => Group.None,
    };

    static IReadOnlyList<WheelItem> ConvertItems(IReadOnlyList<string> files)
    {
        var groups = files.Select(GroupOf).Distinct().ToList();
        // GIFs mixed with stills behave as images.
        if (groups.Count == 2 && groups.Contains(Group.Gif) && groups.Contains(Group.Image)) groups = new() { Group.Image };
        var exts = files.Select(FileKinds.Ext).Distinct().ToList();
        string? only = exts.Count == 1 ? exts[0] : null;
        string? Self(string t) => only != null && (only == t || only == "jpeg" && t == "jpg" || only == "tif" && t == "tiff" || only == "heif" && t == "heic") ? t : null;

        if (groups.Count != 1)
            return ArchiveConverter.ArchiveTargets().Select(t => ArchiveAll(t)).ToList();

        switch (groups[0])
        {
            case Group.Image:
                return ImageConverter.Targets.Where(t => Self(t) == null)
                    .Select(t => Item(t, (f, ctx, i) => ImageConverter.ConvertAsync(f, t, ctx.Cancel))).ToList();
            case Group.Gif:
                return new[] { "mp4", "webm", "webp", "png", "jpg", "pdf" }
                    .Select(t => Item(t, (f, ctx, i) => ImageConverter.ConvertAsync(f, t, ctx.Cancel))).ToList();
            case Group.Video:
                return MediaConverter.VideoTargets.Where(t => Self(t) == null && !(t == "mp4" && only == "m4v"))
                    .Select(t => Item(t, (f, ctx, i) => MediaConverter.ConvertAsync(f, t, p => ctx.ReportItem(i, p), ctx.Cancel),
                        caption: t == "mp3" ? "Extract audio as" : "Convert to")).ToList();
            case Group.Audio:
                return MediaConverter.AudioTargets.Where(t => Self(t) == null)
                    .Select(t => Item(t, (f, ctx, i) => MediaConverter.ConvertAsync(f, t, p => ctx.ReportItem(i, p), ctx.Cancel))).ToList();
            case Group.Pdf:
                return PdfConverter.Targets()
                    .Select(t => ItemMulti(t, (f, ctx, i) => PdfConverter.ConvertAsync(f, t, p => ctx.ReportItem(i, p), ctx.Cancel))).ToList();
            case Group.Doc:
            {
                // Offer what every selected document can become.
                IEnumerable<string>? common = null;
                foreach (var e in exts)
                {
                    var t = DocConverter.TargetsFor(e).ToList();
                    common = common == null ? t : common.Intersect(t).ToList();
                }
                return (common ?? Enumerable.Empty<string>())
                    .Select(t => Item(t, (f, ctx, i) => DocConverter.ConvertAsync(f, t, ctx.Cancel))).ToList();
            }
            case Group.Slides:
            {
                if (!Office.HasPowerPoint) return Array.Empty<WheelItem>();
                var list = new List<WheelItem>
                {
                    Item("pdf", (f, ctx, i) => SlidesTo(f, "pdf")),
                    ItemMulti("png", (f, ctx, i) => SlideImages(f, "PNG")),
                    ItemMulti("jpg", (f, ctx, i) => SlideImages(f, "JPG")),
                };
                if (only != "pptx") list.Insert(1, Item("pptx", (f, ctx, i) => SlidesTo(f, "pptx")));
                return list;
            }
            case Group.Sheet:
            {
                IEnumerable<string>? common = null;
                foreach (var e in exts)
                {
                    var t = SheetConverter.TargetsFor(e).ToList();
                    common = common == null ? t : common.Intersect(t).ToList();
                }
                return (common ?? Enumerable.Empty<string>())
                    .Select(t => Item(t, (f, ctx, i) => SheetConverter.ConvertAsync(f, t, ctx.Cancel))).ToList();
            }
            case Group.Subtitle:
                return SubtitleConverter.TargetsFor(only ?? "")
                    .Select(t => Item(t, (f, ctx, i) => SubtitleConverter.ConvertAsync(f, t, ctx.Cancel))).ToList();
            case Group.Archive:
            {
                var list = new List<WheelItem>
                {
                    new()
                    {
                        Id = "convert:extract", Label = "Extract", Caption = "Unpack", Glyph = Glyphs.FolderOpen,
                        DropText = "Extract here", WorkingTitle = "Extracting…",
                        Run = ctx => ForEach(ctx, (f, i) => ArchiveConverter.ExtractAsync(f, ctx.Cancel)),
                    },
                };
                list.AddRange(ArchiveConverter.ArchiveTargets(only).Select(t => Item(t,
                    (f, ctx, i) => ArchiveConverter.RepackAsync(f, t, p => ctx.ReportItem(i, p), ctx.Cancel), label: ArchiveConverter.Label(t))));
                return list;
            }
            case Group.Folder:
                return ArchiveConverter.ArchiveTargets().Select(t => ArchiveAll(t)).ToList();
            default:
                return ArchiveConverter.ArchiveTargets().Select(t => ArchiveAll(t)).ToList();
        }
    }

    static async Task<string> SlidesTo(string input, string target)
    {
        var output = OutputPaths.For(input, target);
        try { await Office.PowerPointAsync(input, output, target == "pdf" ? Office.PpFormat.Pdf : Office.PpFormat.Pptx); }
        catch { OutputPaths.Discard(output); throw; }
        return output;
    }

    static async Task<List<string>> SlideImages(string input, string filter)
    {
        var folder = OutputPaths.FolderFor(input, " slides");
        try { await Office.PowerPointSlidesAsync(input, folder, filter, 1920); }
        catch { OutputPaths.Discard(folder); throw; }
        return new List<string> { folder };
    }

    /// <summary>A convert segment that runs <paramref name="convert"/> on each file in turn.</summary>
    static WheelItem Item(string target, Func<string, OpContext, int, Task<string>> convert, string caption = "Convert to", string? label = null)
    {
        string lbl = label ?? target.ToUpperInvariant();
        return new WheelItem
        {
            Id = "convert:" + target,
            Label = lbl,
            Caption = caption,
            DropText = caption == "Convert to" ? "Convert to %1" : caption + " %1",
            WorkingTitle = (caption == "Convert to" ? "Converting to " : caption + " ") + lbl + "…",
            Run = ctx => ForEach(ctx, (f, i) => convert(f, ctx, i)),
        };
    }

    static WheelItem ItemMulti(string target, Func<string, OpContext, int, Task<List<string>>> convert) => new()
    {
        Id = "convert:" + target,
        Label = target.ToUpperInvariant(),
        WorkingTitle = $"Converting to {target.ToUpperInvariant()}…",
        Run = ctx => ForEachMany(ctx, (f, i) => convert(f, ctx, i)),
    };

    static WheelItem ArchiveAll(string format) => new()
    {
        Id = "archive:" + format,
        Label = ArchiveConverter.Label(format),
        Caption = "Compress into",
        DropText = "Compress into %1",
        WorkingTitle = $"Compressing into {ArchiveConverter.Label(format)}…",
        Run = async ctx => OpResult.Files(new[] { await ArchiveConverter.CreateAsync(ctx.Files, format, p => ctx.Report(p), ctx.Cancel) }),
    };

    /// <summary>Runs a per-file job over the selection, collecting outputs and tolerating individual failures.</summary>
    public static Task<OpResult> ForEach(OpContext ctx, Func<string, int, Task<string>> job) =>
        ForEachMany(ctx, async (f, i) => new List<string> { await job(f, i) });

    public static async Task<OpResult> ForEachMany(OpContext ctx, Func<string, int, Task<List<string>>> job)
    {
        var result = new OpResult();
        var errors = new List<string>();
        for (int i = 0; i < ctx.Files.Count; i++)
        {
            ctx.Cancel.ThrowIfCancellationRequested();
            ctx.ReportItem(i, 0);
            try { result.Outputs.AddRange(await job(ctx.Files[i], i)); }
            catch (OpException ex) when (ctx.Files.Count > 1) { errors.Add($"{Path.GetFileName(ctx.Files[i])}: {ex.Message}"); }
            catch (Exception ex) when (ctx.Files.Count > 1 && ex is not OperationCanceledException)
            {
                Log.Error("Item failed", ex);
                errors.Add($"{Path.GetFileName(ctx.Files[i])}: {ex.Message}");
            }
            ctx.ReportItem(i, 1);
        }
        if (errors.Count > 0)
        {
            if (result.Outputs.Count == 0) throw new OpException(errors[0]);
            result.Title = $"Saved {result.Outputs.Count} of {ctx.Files.Count}";
            result.Message = $"{errors.Count} failed: {errors[0]}";
        }
        return result;
    }
}
