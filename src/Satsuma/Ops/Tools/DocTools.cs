using System.Text.RegularExpressions;
using Satsuma.Core;
using Satsuma.Ops.Convert;
using Satsuma.Ops.Convert.Docs;

namespace Satsuma.Ops.Tools;

/// <summary>Text-level helpers for documents: copy all text, count words.</summary>
public static class DocTools
{
    public static string ExtractText(string path)
    {
        var kind = FileKinds.KindOf(path);
        return kind switch
        {
            FileKind.Pdf => PdfTools.AllText(path),
            FileKind.Sheet => string.Join(Environment.NewLine, SheetConverter.Read(path).SelectMany(s => s.Rows).Select(r => string.Join("\t", r))),
            FileKind.Subtitle or FileKind.Text => DocReaders.ReadText(path),
            _ => DocReaders.Read(path).ToPlainText(),
        };
    }

    public static (int words, int chars, int lines, string readingTime) Count(string text)
    {
        int words = Regex.Matches(text, @"[\p{L}\p{N}][\p{L}\p{N}'’\-]*").Count;
        int chars = text.Count(c => !char.IsWhiteSpace(c));
        int lines = text.Split('\n').Count(l => l.Trim().Length > 0);
        double minutes = words / 238.0;
        string reading = minutes < 1 ? "under a minute" : minutes < 60 ? $"{Math.Round(minutes)} min read" : $"{minutes / 60:0.#} h read";
        return (words, chars, lines, reading);
    }
}
