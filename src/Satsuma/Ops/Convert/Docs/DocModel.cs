using System.Text;

namespace Satsuma.Ops.Convert.Docs;

public enum BlockType { Heading, Paragraph, ListItem, Code, Quote, Table, Rule, PageBreak }

public sealed class Inline
{
    public string Text = "";
    public bool Bold, Italic, Code;
    public string? Link;

    public Inline() { }
    public Inline(string text, bool bold = false, bool italic = false, bool code = false, string? link = null)
    {
        Text = text; Bold = bold; Italic = italic; Code = code; Link = link;
    }

    public Inline With(string text) => new(text, Bold, Italic, Code, Link);
}

public sealed class Block
{
    public BlockType Type;
    /// <summary>Heading level (1-6) or list nesting level (0-based).</summary>
    public int Level;
    public bool Ordered;
    public int Number = 1;
    public List<Inline> Inlines = new();
    public List<List<string>>? Rows;
    public string? CodeText;

    public static Block Para(string text) => new() { Type = BlockType.Paragraph, Inlines = { new Inline(text) } };
    public static Block Heading(int level, string text) => new() { Type = BlockType.Heading, Level = level, Inlines = { new Inline(text) } };

    public string PlainText => Type == BlockType.Code ? CodeText ?? "" : string.Concat(Inlines.Select(i => i.Text));
}

public sealed class DocModel
{
    public string Title = "";
    public List<Block> Blocks = new();

    public string GuessTitle()
    {
        if (!string.IsNullOrWhiteSpace(Title)) return Title;
        var h = Blocks.FirstOrDefault(b => b.Type == BlockType.Heading);
        return h?.PlainText.Trim() ?? "";
    }

    /// <summary>Merges adjacent inlines with identical formatting and drops empty paragraphs.</summary>
    public DocModel Normalize()
    {
        foreach (var b in Blocks)
        {
            var merged = new List<Inline>();
            foreach (var i in b.Inlines)
            {
                if (i.Text.Length == 0) continue;
                var last = merged.Count > 0 ? merged[^1] : null;
                if (last != null && last.Bold == i.Bold && last.Italic == i.Italic && last.Code == i.Code && last.Link == i.Link)
                    last.Text += i.Text;
                else merged.Add(new Inline(i.Text, i.Bold, i.Italic, i.Code, i.Link));
            }
            b.Inlines = merged;
        }
        Blocks.RemoveAll(b => b.Type is BlockType.Paragraph or BlockType.Heading or BlockType.ListItem or BlockType.Quote
                              && string.IsNullOrWhiteSpace(b.PlainText));
        return this;
    }

    public string ToPlainText()
    {
        var sb = new StringBuilder();
        foreach (var b in Blocks)
        {
            switch (b.Type)
            {
                case BlockType.ListItem:
                    sb.Append(new string(' ', b.Level * 2)).Append(b.Ordered ? $"{b.Number}. " : "• ").AppendLine(b.PlainText);
                    continue;
                case BlockType.Table when b.Rows != null:
                    foreach (var row in b.Rows) sb.AppendLine(string.Join("\t", row));
                    break;
                case BlockType.Rule: sb.AppendLine("---"); break;
                case BlockType.PageBreak: sb.AppendLine("\f"); continue;
                default: sb.AppendLine(b.PlainText); break;
            }
            sb.AppendLine();
        }
        return sb.ToString().TrimEnd() + Environment.NewLine;
    }
}
