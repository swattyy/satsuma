using Satsuma.Ops;

namespace Satsuma.Wheel;

public enum WheelKind { Convert, Tools, Actions }

public sealed class WheelItem
{
    /// <summary>Stable id, e.g. "convert:png" or "tool:compress".</summary>
    public required string Id { get; init; }

    /// <summary>Short label drawn on the segment ("PNG", "Compress").</summary>
    public required string Label { get; init; }

    /// <summary>Optional icon (Segoe Fluent Icons code point), drawn above the label.</summary>
    public string? Glyph { get; init; }

    /// <summary>Caption shown in the hub while hovering ("Convert to", "Reduce file size").</summary>
    public string Caption { get; init; } = "Convert to";

    /// <summary>Text under the drag icon while hovering, e.g. "Convert to %1". %1 is replaced by <see cref="Label"/>.</summary>
    public string DropText { get; init; } = "Convert to %1";

    /// <summary>Title of the progress bubble ("Converting to PNG…"). Defaults to "{Caption} {Label}…".</summary>
    public string? WorkingTitle { get; init; }

    /// <summary>The item opens a dialog first and calls <see cref="OpContext.BeginWork"/> itself once confirmed.</summary>
    public bool Interactive { get; init; }

    public required Func<OpContext, Task<OpResult>> Run { get; init; }
}

public sealed class WheelContent
{
    public WheelKind Kind { get; init; }
    public IReadOnlyList<WheelItem> Items { get; init; } = Array.Empty<WheelItem>();

    /// <summary>Hub text when nothing is hovered.</summary>
    public string HubCaption { get; init; } = "";
    public string HubTitle { get; init; } = "";

    /// <summary>Shown in the hub when there are no items.</summary>
    public string EmptyMessage { get; init; } = "No options";
}
