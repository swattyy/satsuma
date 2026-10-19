import AppKit
import SatsumaCore

/// Runs a wheel item off the main thread and mirrors its progress into a bubble at the drop point.
enum OpRunner {
    /// The bubble for one run. Only touched on the main thread.
    final class HudBox: @unchecked Sendable {
        var hud: Hud?
        let anchor: CGPoint
        let title: String
        let glyph: String

        init(anchor: CGPoint, title: String, glyph: String) {
            self.anchor = anchor
            self.title = title
            self.glyph = glyph
        }

        /// The bubble, created at the drop point if the operation didn't start one (quick results, early errors).
        func ensure(_ title: String? = nil) -> Hud {
            if let hud { return hud }
            let h = Hud(anchor: anchor, title: title ?? self.title, glyph: glyph)
            hud = h
            return h
        }
    }

    static func start(_ item: WheelItem, files: [String], anchor: CGPoint) {
        let box = HudBox(anchor: anchor, title: item.label, glyph: item.glyph ?? Glyphs.convert)
        let ctx = OpContext(files: files, anchor: anchor)
        ctx.onBeginWork = { title in DispatchQueue.main.async { _ = box.ensure(title) } }
        ctx.onProgress = { f, status in DispatchQueue.main.async { box.hud?.report(f, status) } }
        if !item.interactive { ctx.beginWork(item.workingTitle ?? "\(item.caption) \(item.label)…") }

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
                    box.ensure().complete(title, subtitle, outputs: r.outputs)
                    if Settings.current.revealAfterConvert && !r.outputs.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(r.outputs.map { URL(fileURLWithPath: $0) })
                    }
                }
            } catch is CancellationError {
                await MainActor.run { box.hud?.dismiss() }
            } catch let e as OpError {
                Log.warn("\(item.id) failed: \(e.message)")
                await MainActor.run { box.ensure().fail("Couldn't finish", e.message) }
            } catch {
                Log.error("\(item.id) crashed", error)
                let first = error.localizedDescription.split(whereSeparator: \.isNewline).first.map(String.init) ?? "\(error)"
                await MainActor.run { box.ensure().fail("Something went wrong", first) }
            }
        }
    }
}
