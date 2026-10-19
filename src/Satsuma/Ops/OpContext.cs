using Satsuma.Native;

namespace Satsuma.Ops;

public readonly record struct OpProgress(double Fraction, string? Status = null);

public sealed class OpResult
{
    public List<string> Outputs { get; } = new();
    public string? Title { get; set; }
    public string? Message { get; set; }
    public bool Canceled { get; set; }
    /// <summary>Don't show a success bubble (e.g. the action opened its own window).</summary>
    public bool Quiet { get; set; }

    public static OpResult Cancel() => new() { Canceled = true };
    public static OpResult QuietDone() => new() { Quiet = true };
    public static OpResult Done(string title, string? message = null) => new() { Title = title, Message = message };
    public static OpResult Files(IEnumerable<string> outputs)
    {
        var r = new OpResult();
        r.Outputs.AddRange(outputs);
        return r;
    }
}

/// <summary>Thrown for expected, user-facing failures ("FFmpeg is not installed").</summary>
public sealed class OpException(string message) : Exception(message);

public sealed class OpContext
{
    public required IReadOnlyList<string> Files { get; init; }
    public required Win32.POINT Anchor { get; init; }
    public CancellationToken Cancel { get; init; }
    internal Action<string>? OnBeginWork;
    internal Action<OpProgress>? OnProgress;

    public string File => Files[0];

    /// <summary>Shows the progress bubble. Interactive ops call this after their dialog is confirmed.</summary>
    public void BeginWork(string title) => OnBeginWork?.Invoke(title);

    public void Report(double fraction, string? status = null) => OnProgress?.Invoke(new OpProgress(fraction, status));

    /// <summary>Reports overall progress for item <paramref name="index"/> of <see cref="Files"/> at <paramref name="fraction"/>.</summary>
    public void ReportItem(int index, double fraction, string? status = null)
    {
        int n = Math.Max(1, Files.Count);
        Report((index + Math.Clamp(fraction, 0, 1)) / n, status ?? (n > 1 ? $"{index + 1} of {n}" : null));
    }
}
