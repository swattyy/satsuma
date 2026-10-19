import AppKit

public enum Clipboard {
    @MainActor static func write(_ objects: [NSPasteboardWriting]) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.writeObjects(objects) { throw OpError("Couldn't write to the clipboard.") }
    }

    public static func setText(_ text: String) async throws {
        try await MainActor.run { try write([text as NSString]) }
    }

    /// Puts the files on the clipboard the way Finder's Copy does, so Paste in Finder copies them.
    public static func copyFiles(_ files: [String]) async throws {
        try await MainActor.run { try write(files.map { P.url($0) as NSURL }) }
    }
}
