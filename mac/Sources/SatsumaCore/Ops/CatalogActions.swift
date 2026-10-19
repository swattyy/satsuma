import Foundation

extension Catalog {
    /// `caption` is the short line for the wheel's center; `drop` is the fuller wording.
    static func action(_ id: String, _ label: String, _ glyph: String, _ caption: String, _ drop: String, interactive: Bool = true,
                       _ run: @escaping (OpContext) async throws -> OpResult) -> WheelItem {
        WheelItem(id: "action:" + id, label: label, glyph: glyph, caption: caption, dropText: drop,
                  workingTitle: drop + "…", interactive: interactive, run: run)
    }

    static func actionItems(_ files: [String], _ virtualOnly: Bool) -> [WheelItem] {
        let ui = { Interact.current }
        var list = [
            action("share", "Share", Glyphs.share, "Share menu", "Share with an app") { ctx in
                try await ui().share(ctx.files, anchor: ctx.anchor)
                return .quietDone()
            },
            action("float", "Float", Glyphs.pin, "Floating shelf", "Keep on a floating shelf") { ctx in
                try await ui().float(ctx.files, anchor: ctx.anchor)
                return .quietDone()
            },
            action("copy", "Copy", Glyphs.copy, "To clipboard", "Copy to clipboard", interactive: false) { ctx in
                try await ui().copyFiles(ctx.files)
                return .done(ctx.files.count == 1 ? "Copied " + P.fileName(ctx.file) : "Copied \(ctx.files.count) items", "Paste anywhere")
            },
        ]
        if !virtualOnly {
            list.append(action("move", "Move", Glyphs.move, "Pick a folder", "Move to a folder") { ctx in
                guard let moved = try await ui().move(ctx.files) else { return .cancel() }
                let r = OpResult.files(moved)
                r.title = moved.count == 1 ? "Moved " + P.fileName(moved[0]) : "Moved \(moved.count) items"
                return r
            })
            list.append(action("path", "Copy Path", Glyphs.link, "Full path", "Copy full path", interactive: false) { ctx in
                try await ui().setClipboardText(ctx.files.joined(separator: "\n"))
                return .done(ctx.files.count == 1 ? "Path copied" : "\(ctx.files.count) paths copied", ctx.files.count == 1 ? ctx.file : "One per line")
            })
            list.append(action("terminal", "Terminal", Glyphs.terminal, "Open here", "Open a terminal here") { ctx in
                try await ui().openTerminal(ctx.file)
                return .quietDone()
            })
            if files.count == 1 && P.isFile(files[0]) {
                list.append(action("openwith", "Open with", Glyphs.openWith, "Choose an app", "Open with another app") { ctx in
                    try await ui().openWith(ctx.file, anchor: ctx.anchor)
                    return .quietDone()
                })
            }
        }
        return list
    }
}
