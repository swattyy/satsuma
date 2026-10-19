import AppKit
import SatsumaCore

/// Runs a wheel item off the main thread and mirrors its progress into a bubble at the drop point.
enum OpRunner {
    final class HudBox { var hud: Hud? }

    static func start(_ item: WheelItem, files: [String], anchor: CGPoint) {
        let box = HudBox()
        let glyph = item.glyph ?? Glyphs.convert
        let ctx = OpContext(files: files, anchor: anchor)
        ctx.onBeginWork = { title in
            DispatchQueue.main.async { if box.hud == nil { box.hud = Hud(anchor: anchor, title: title, glyph: glyph) } }
        }
        ctx.onProgress = { f, status in DispatchQueue.main.async { box.hud?.report(f, status) } }
        if !item.interactive { ctx.beginWork(item.workingTitle ?? "\(item.caption) \(item.label)…") }

        func ensureHud() -> Hud {
            if let h = box.hud { return h }
            let h = Hud(anchor: anchor, title: item.label, glyph: glyph)
            box.hud = h
            return h
        }

        Task.detached {
            do {
                let r = try await item.run(ctx)
                await MainActor.run {
                    if r.canceled || r.quiet { box.hud?.dismiss(); return }
                    let title: String, subtitle: String
                    if let t = r.title { title = t; subtitle = r.message ?? (r.outputs.isEmpty ? "" : "Click to show in Finder") }
                    else if r.outputs.count == 1 { title = "Saved " + P.fileName(r.outputs[0]); subtitle = "Click to show in Finder" }
                    else if r.outputs.count > 1 { title = "Saved \(r.outputs.count) files"; subtitle = "Click to show in Finder" }
                    else { title = "Done"; subtitle = "" }
                    ensureHud().complete(title, subtitle, outputs: r.outputs)
                    if Settings.current.revealAfterConvert && !r.outputs.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(r.outputs.map { URL(fileURLWithPath: $0) })
                    }
                }
            } catch is CancellationError {
                await MainActor.run { box.hud?.dismiss() }
            } catch let e as OpError {
                Log.warn("\(item.id) failed: \(e.message)")
                await MainActor.run { ensureHud().fail("Couldn't finish", e.message) }
            } catch {
                Log.error("\(item.id) crashed", error)
                let first = error.localizedDescription.split(whereSeparator: \.isNewline).first.map(String.init) ?? "\(error)"
                await MainActor.run { ensureHud().fail("Something went wrong", first) }
            }
        }
    }
}
