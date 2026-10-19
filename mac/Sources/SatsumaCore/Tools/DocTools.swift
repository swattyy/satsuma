import Foundation

/// Text-level helpers for documents: copy all text, count words.
public enum DocTools {
    public static func extractText(_ path: String) async throws -> String {
        switch FileKinds.kindOf(path) {
        case .pdf: return try PdfTools.allText(path)
        case .sheet: return try SheetConverter.read(path).flatMap(\.rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .subtitle, .text: return try DocReaders.readText(path)
        default: return try await DocConverter.readModel(path, FileKinds.ext(path)).toPlainText()
        }
    }

    static let wordRx = Rx("[\\p{L}\\p{N}][\\p{L}\\p{N}'’\\-]*")

    public static func count(_ text: String) -> (words: Int, chars: Int, lines: Int, readingTime: String) {
        let words = wordRx.count(text)
        let chars = text.filter { !$0.isWhitespace }.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let minutes = Double(words) / 238
        let reading = minutes < 1 ? "under a minute" : minutes < 60 ? "\(Int(minutes.rounded())) min read" : "\(TextUtil.num(minutes / 60, decimals: 1)) h read"
        return (words, chars, lines, reading)
    }
}
