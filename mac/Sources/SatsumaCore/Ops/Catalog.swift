import Foundation

/// Decides which segments a wheel shows for a set of dragged files. A segment-for-segment port of the
/// Windows app's Catalog*.cs; Tests/Fixtures/windows-wheels.json records what Windows shows.
public enum Catalog {
    public static func build(_ kind: WheelKind, _ files: [String], virtualOnly: Bool = false) -> WheelContent {
        let (caption, title) = hubText(files)
        var items: [WheelItem] = []
        if !files.isEmpty {
            switch kind {
            case .convert: items = convertItems(files)
            case .tools: items = toolItems(files)
            case .actions: items = actionItems(files, virtualOnly)
            }
        }
        let empty: String
        switch kind {
        case .convert: empty = "No conversions"
        case .tools: empty = "No tools"
        case .actions: empty = "No actions"
        }
        return WheelContent(kind: kind, items: items, hubCaption: caption, hubTitle: title, emptyMessage: empty)
    }

    static func hubText(_ files: [String]) -> (String, String) {
        if files.isEmpty { return ("", "") }
        if files.count == 1 {
            let f = files[0]
            if P.isDir(f) { return ("Folder", P.fileName(f)) }
            let size = P.isFile(f) ? FileKinds.humanSize(P.size(f)) : ""
            let ext = FileKinds.ext(f).uppercased()
            return (ext.isEmpty ? "File" : ext, size.isEmpty ? P.fileName(f) : size)
        }
        let exts = distinct(files.map { P.isDir($0) ? "FOLDER" : FileKinds.ext($0).uppercased() })
        let cap = exts.count == 1 ? "\(files.count) \(exts[0])s" : "\(files.count) items"
        let total = FileKinds.totalSize(files)
        return (cap, total > 0 ? FileKinds.humanSize(total) : "\(files.count) items")
    }

    static func distinct<T: Equatable>(_ values: [T]) -> [T] {
        var out: [T] = []
        for v in values where !out.contains(v) { out.append(v) }
        return out
    }

    /// Items in `a` that are also in every other list, in `a`'s order (LINQ's Intersect).
    static func intersect(_ lists: [[String]]) -> [String] {
        guard var common = lists.first else { return [] }
        for l in lists.dropFirst() { common = distinct(common.filter { l.contains($0) }) }
        return common
    }

    // ------------------------------------------------------------------ running items over a selection

    /// Runs a per-file job over the selection, collecting outputs and tolerating individual failures.
    public static func forEach(_ ctx: OpContext, _ job: (String, Int) async throws -> String) async throws -> OpResult {
        try await forEachMany(ctx) { f, i in [try await job(f, i)] }
    }

    public static func forEachMany(_ ctx: OpContext, _ job: (String, Int) async throws -> [String]) async throws -> OpResult {
        let result = OpResult()
        var errors: [String] = []
        let many = ctx.files.count > 1
        for i in 0..<ctx.files.count {
            try Task.checkCancellation()
            ctx.reportItem(i, 0)
            do {
                result.outputs += try await job(ctx.files[i], i)
            } catch let e as OpError where many {
                errors.append("\(P.fileName(ctx.files[i])): \(e.message)")
            } catch let e where many && !(e is CancellationError) {
                Log.error("Item failed", e)
                errors.append("\(P.fileName(ctx.files[i])): \(e.localizedDescription)")
            }
            ctx.reportItem(i, 1)
        }
        if !errors.isEmpty {
            if result.outputs.isEmpty { throw OpError(errors[0]) }
            result.title = "Saved \(result.outputs.count) of \(ctx.files.count)"
            result.message = "\(errors.count) failed: \(errors[0])"
        }
        return result
    }
}
