using Satsuma.Core;
using Satsuma.Wheel;

namespace Satsuma.Ops;

/// <summary>Decides which segments a wheel shows for a set of dragged files.</summary>
public static partial class Catalog
{
    public static WheelContent Build(WheelKind kind, IReadOnlyList<string> files, bool virtualOnly)
    {
        var (caption, title) = HubText(files);
        IReadOnlyList<WheelItem> items = files.Count == 0 ? Array.Empty<WheelItem>() : kind switch
        {
            WheelKind.Convert => ConvertItems(files),
            WheelKind.Tools => ToolItems(files),
            _ => ActionItems(files, virtualOnly),
        };
        string empty = kind switch
        {
            WheelKind.Convert => "No conversions",
            WheelKind.Tools => "No tools",
            _ => "No actions",
        };
        return new WheelContent { Kind = kind, Items = items, HubCaption = caption, HubTitle = title, EmptyMessage = empty };
    }

    static (string caption, string title) HubText(IReadOnlyList<string> files)
    {
        if (files.Count == 0) return ("", "");
        if (files.Count == 1)
        {
            var f = files[0];
            if (Directory.Exists(f)) return ("Folder", Path.GetFileName(f.TrimEnd('\\')));
            var size = File.Exists(f) ? FileKinds.HumanSize(new FileInfo(f).Length) : "";
            var ext = FileKinds.Ext(f).ToUpperInvariant();
            return (ext.Length > 0 ? ext : "File", size.Length > 0 ? size : Path.GetFileName(f));
        }
        var exts = files.Select(f => Directory.Exists(f) ? "FOLDER" : FileKinds.Ext(f).ToUpperInvariant()).Distinct().ToList();
        string cap = exts.Count == 1 ? $"{files.Count} {exts[0]}s" : $"{files.Count} items";
        long total = FileKinds.TotalSize(files);
        return (cap, total > 0 ? FileKinds.HumanSize(total) : $"{files.Count} items");
    }
}
