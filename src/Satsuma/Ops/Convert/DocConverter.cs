using Satsuma.Core;
using Satsuma.Ops.Convert.Docs;

namespace Satsuma.Ops.Convert;

/// <summary>Word processing, text, Markdown, HTML and EPUB conversions (Word when installed, built-in readers/writers otherwise).</summary>
public static class DocConverter
{
    static readonly HashSet<string> OwnReadable = new() { "docx", "docm", "dotx", "rtf", "odt", "txt", "text", "log", "md", "markdown", "mdown", "mkd", "html", "htm", "xhtml", "epub" };
    static readonly HashSet<string> WordFamily = new() { "docx", "doc", "docm", "dotx", "odt", "rtf", "wpd" };

    public static IEnumerable<string> TargetsFor(string ext)
    {
        bool word = Office.HasWord;
        string[] list = ext switch
        {
            "docx" or "docm" or "dotx" => new[] { "pdf", "txt", "md", "html", "rtf", "odt", "epub", "docx" },
            "doc" or "wpd" => word ? new[] { "pdf", "docx", "txt", "md", "html", "rtf", "odt", "epub" } : Array.Empty<string>(),
            "odt" => new[] { "pdf", "docx", "txt", "md", "html", "rtf", "epub" },
            "rtf" => new[] { "pdf", "docx", "txt", "md", "html", "odt", "epub" },
            "txt" or "text" or "log" => new[] { "docx", "pdf", "md", "html", "epub", "rtf" },
            "md" or "markdown" or "mdown" or "mkd" => new[] { "html", "docx", "pdf", "txt", "epub", "rtf" },
            "html" or "htm" or "xhtml" or "mht" or "mhtml" => new[] { "pdf", "docx", "md", "txt", "epub" },
            "epub" => new[] { "txt", "md", "html", "docx", "pdf" },
            "pages" => Array.Empty<string>(),
            _ => Array.Empty<string>(),
        };
        foreach (var t in list)
        {
            if (t == ext || (t == "docx" && ext is "docm" or "dotx" && !word)) continue;
            if (t == "odt" && !word) continue;               // only Word writes ODT
            if (t == "docx" && ext is "docx") continue;
            yield return t;
        }
    }

    public static async Task<string> ConvertAsync(string input, string target, CancellationToken ct)
    {
        string ext = FileKinds.Ext(input);
        string output = OutputPaths.For(input, target);
        try
        {
            bool wordInput = WordFamily.Contains(ext);
            bool htmlInput = ext is "html" or "htm" or "mht" or "mhtml";
            bool mdInput = ext is "md" or "markdown" or "mdown" or "mkd";
            if (Office.HasWord && (wordInput && target is "pdf" or "docx" or "rtf" or "odt" || htmlInput && target is "docx" or "rtf" or "odt"))
            {
                int fmt = target switch { "pdf" => Office.WdFormat.Pdf, "docx" => Office.WdFormat.Docx, "rtf" => Office.WdFormat.Rtf, _ => Office.WdFormat.Odt };
                await Office.WordAsync(input, output, fmt);
                return output;
            }
            string? MarkdownHtml()
            {
                if (!mdInput) return null;
                var md = DocReaders.ReadText(input);
                var body = Markdig.Markdown.ToHtml(md, DocReaders.Pipeline);
                var title = DocReaders.Markdown(md).GuessTitle();
                return DocWriters.Page(title.Length > 0 ? title : FileKinds.BaseName(input), body);
            }
            if (mdInput && target == "html")
            {
                await File.WriteAllTextAsync(output, MarkdownHtml()!, new System.Text.UTF8Encoding(false), ct);
                return output;
            }
            if (target == "pdf" && EdgeRenderer.Available)
            {
                // Edge prints our styled HTML: crisp type, every script, subset fonts → small PDFs.
                if (htmlInput) await EdgeRenderer.PrintToPdfAsync(input, output, ct);
                else
                {
                    string html = MarkdownHtml() ?? DocWriters.Html(await Task.Run(() => OwnReadable.Contains(ext) ? DocReaders.Read(input) : throw new OpException($"Opening .{ext} files needs Microsoft Word."), ct));
                    await EdgeRenderer.HtmlToPdfAsync(html, Path.GetDirectoryName(input), output, ct);
                }
                return output;
            }

            DocModel doc;
            if (OwnReadable.Contains(ext)) doc = await Task.Run(() => DocReaders.Read(input), ct);
            else if (Office.HasWord && wordInput)
            {
                // Legacy binary formats: let Word turn them into DOCX first, then read that.
                var tmpDir = AppPaths.NewTempDir("doc");
                var tmp = Path.Combine(tmpDir, FileKinds.BaseName(input) + ".docx");
                try
                {
                    await Office.WordAsync(input, tmp, Office.WdFormat.Docx);
                    doc = DocReaders.Read(tmp);
                    doc.Title = FileKinds.BaseName(input);
                }
                finally { try { Directory.Delete(tmpDir, true); } catch { } }
            }
            else throw new OpException($"Opening .{ext} files needs Microsoft Word.");

            await Task.Run(() => DocWriters.Write(doc, output, target), ct);
            return output;
        }
        catch { OutputPaths.Discard(output); throw; }
    }
}
