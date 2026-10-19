using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Satsuma.Core;
using Satsuma.Ops.Convert.Docs;

namespace Satsuma.Ops.Convert;

/// <summary>SRT ⇄ WebVTT, and either to plain text.</summary>
public static class SubtitleConverter
{
    sealed record Cue(TimeSpan Start, TimeSpan End, string Text);

    static readonly Regex Timing = new(@"((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})", RegexOptions.Compiled);

    public static IEnumerable<string> TargetsFor(string ext) => new[] { "srt", "vtt", "txt" }.Where(t => t != ext);

    public static async Task<string> ConvertAsync(string input, string target, CancellationToken ct)
    {
        var cues = Parse(DocReaders.ReadText(input));
        if (cues.Count == 0) throw new OpException("No subtitle cues found.");
        string output = OutputPaths.For(input, target);
        var sb = new StringBuilder();
        switch (target)
        {
            case "srt":
                for (int i = 0; i < cues.Count; i++)
                    sb.Append(i + 1).Append("\r\n").Append($"{Fmt(cues[i].Start, ',')} --> {Fmt(cues[i].End, ',')}\r\n").Append(cues[i].Text.Replace("\n", "\r\n")).Append("\r\n\r\n");
                break;
            case "vtt":
                sb.Append("WEBVTT\n\n");
                foreach (var c in cues) sb.Append($"{Fmt(c.Start, '.')} --> {Fmt(c.End, '.')}\n{c.Text}\n\n");
                break;
            default:
                foreach (var c in cues) sb.AppendLine(Regex.Replace(c.Text, "<[^>]+>|\\{\\\\[^}]*\\}", "").Replace('\n', ' '));
                break;
        }
        await File.WriteAllTextAsync(output, sb.ToString(), new UTF8Encoding(false), ct);
        return output;
    }

    static List<Cue> Parse(string text)
    {
        var cues = new List<Cue>();
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var m = Timing.Match(lines[i]);
            if (!m.Success) continue;
            var body = new List<string>();
            int j = i + 1;
            for (; j < lines.Length && lines[j].Trim().Length > 0; j++) body.Add(lines[j].TrimEnd());
            cues.Add(new Cue(ParseTime(m.Groups[1].Value), ParseTime(m.Groups[2].Value), string.Join("\n", body)));
            i = j;
        }
        return cues;
    }

    static TimeSpan ParseTime(string s)
    {
        s = s.Replace(',', '.');
        var parts = s.Split(':');
        double seconds = double.Parse(parts[^1], CultureInfo.InvariantCulture);
        int minutes = int.Parse(parts[^2]);
        int hours = parts.Length > 2 ? int.Parse(parts[^3]) : 0;
        return TimeSpan.FromHours(hours) + TimeSpan.FromMinutes(minutes) + TimeSpan.FromSeconds(seconds);
    }

    static string Fmt(TimeSpan t, char sep) =>
        $"{(int)t.TotalHours:00}:{t.Minutes:00}:{t.Seconds:00}{sep}{t.Milliseconds:000}";
}
