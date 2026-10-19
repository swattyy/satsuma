import Foundation

public enum BlockType { case heading, paragraph, listItem, code, quote, table, rule, pageBreak }

public final class Inline {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public var link: String?

    public init(_ text: String = "", bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.code = code; self.link = link
    }

    public func with(_ text: String) -> Inline { Inline(text, bold: bold, italic: italic, code: code, link: link) }
}

public final class Block {
    public var type: BlockType
    /// Heading level (1-6) or list nesting level (0-based).
    public var level = 0
    public var ordered = false
    public var number = 1
    public var inlines: [Inline] = []
    public var rows: [[String]]?
    public var codeText: String?

    public init(type: BlockType) { self.type = type }

    public static func para(_ text: String) -> Block { let b = Block(type: .paragraph); b.inlines = [Inline(text)]; return b }
    public static func heading(_ level: Int, _ text: String) -> Block { let b = Block(type: .heading); b.level = level; b.inlines = [Inline(text)]; return b }

    public var plainText: String { type == .code ? (codeText ?? "") : inlines.map(\.text).joined() }
}

public final class DocModel {
    public var title = ""
    public var blocks: [Block] = []

    public init() {}

    public func guessTitle() -> String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return blocks.first { $0.type == .heading }?.plainText.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Merges adjacent inlines with identical formatting and drops empty paragraphs.
    @discardableResult
    public func normalize() -> DocModel {
        for b in blocks {
            var merged: [Inline] = []
            for i in b.inlines where !i.text.isEmpty {
                if let last = merged.last, last.bold == i.bold, last.italic == i.italic, last.code == i.code, last.link == i.link {
                    last.text += i.text
                } else {
                    merged.append(Inline(i.text, bold: i.bold, italic: i.italic, code: i.code, link: i.link))
                }
            }
            b.inlines = merged
        }
        blocks.removeAll { [.paragraph, .heading, .listItem, .quote].contains($0.type) && $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return self
    }

    public func toPlainText() -> String {
        var out = ""
        for b in blocks {
            switch b.type {
            case .listItem:
                out += String(repeating: " ", count: b.level * 2) + (b.ordered ? "\(b.number). " : "• ") + b.plainText + "\n"
                continue
            case .table:
                for row in b.rows ?? [] { out += row.joined(separator: "\t") + "\n" }
            case .rule:
                out += "---\n"
            case .pageBreak:
                out += "\u{0C}\n"
                continue
            default:
                out += b.plainText + "\n"
            }
            out += "\n"
        }
        while out.last?.isWhitespace == true { out.removeLast() }
        return out + "\n"
    }
}
