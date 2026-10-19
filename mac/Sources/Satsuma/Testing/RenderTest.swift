import AppKit
import QuartzCore
import SwiftUI
import SatsumaCore

/// Renders wheel frames and progress bubbles to PNG over a synthetic wallpaper, using the same sprites and
/// layer tree as the live wheel (the live blur comes from vibrancy, so the tests bake in a frosted wallpaper).
enum RenderTest {
    @MainActor
    static func run(_ dir: String) async throws -> [String] {
        try P.createDir(dir)
        // Placeholder files only need names and sizes (sparse, so the 148 MB "video" takes no space).
        let samples = try AppPaths.newTempDir("render-samples")
        defer { P.remove(samples) }
        func make(_ name: String, _ bytes: Int64) -> String {
            let p = P.join(samples, name)
            if !P.exists(p) {
                FileManager.default.createFile(atPath: p, contents: nil)
                if let h = FileHandle(forWritingAtPath: p) { h.truncateFile(atOffset: UInt64(bytes)); h.closeFile() }
            }
            return p
        }
        let jpg = make("holiday.jpg", 2_400_000)
        let wav = make("mixtape.wav", 31_000_000)
        let pdf = make("field-notes.pdf", 820_000)
        let mov = make("weekend.mov", 148_000_000)
        let unknown = make("firmware.bin", 4_000)
        let folder = P.join(samples, "Project")
        try P.createDir(folder)
        let longFolder = P.join(samples, "Vacation photos from summer 2024 (backup copy)")
        try P.createDir(longFolder)

        let cases: [(String, WheelKind, [String], Int, Double, Bool)] = [
            ("convert-jpg-idle", .convert, [jpg], -1, 1, false),
            ("convert-jpg-hover", .convert, [jpg], 1, 1, false),
            ("convert-jpg-opening", .convert, [jpg], -1, 0.45, false),
            ("convert-wav-hover-dark", .convert, [wav], 2, 1, true),
            ("convert-pdf-hover", .convert, [pdf], 0, 1, false),
            ("convert-mov-dark", .convert, [mov], 6, 1, true),
            ("tools-jpg-hover", .tools, [jpg], 3, 1, false),
            ("tools-jpg-dark", .tools, [jpg], 0, 1, true),
            ("actions-hover", .actions, [jpg], 1, 1, false),
            ("folder-convert", .convert, [folder], -1, 1, false),
            ("fit-actions-share", .actions, [jpg], 0, 1, true),
            ("fit-actions-openwith", .actions, [jpg], 6, 1, false),
            ("fit-tools-metadata", .tools, [jpg], 4, 1, false),
            ("fit-tools-redact", .tools, [jpg], 6, 1, true),
            ("fit-tools-background", .tools, [jpg], 7, 1, false),
            ("fit-tools-trim", .tools, [mov], 1, 1, false),
            ("fit-tools-pdf-pages", .tools, [pdf], 1, 1, true),
            ("fit-tools-multi-zip", .tools, [jpg, pdf, mov], 0, 1, false),
            ("fit-convert-mp3", .convert, [mov], 6, 1, false),
            ("fit-long-folder", .convert, [longFolder], -1, 1, false),
            ("fit-empty-tools", .tools, [unknown], -1, 1, true),
        ]
        var files: [String] = []
        let px: CGFloat = 2
        for (name, kind, paths, hover, t, dark) in cases {
            if let img = wheelFrame(kind, paths, hover: hover, t: t, dark: dark, px: px) {
                let out = P.join(dir, name + ".png")
                try ImageConverter.write(img, to: out, type: "public.png")
                files.append(out)
            }
        }

        let hudCases: [(String, Int, String, String, Double, Bool)] = [
            ("hud-working", 0, "Converting to WEBP…", "holiday.jpg · 42%", 0.42, false),
            ("hud-done", 1, "Saved holiday.webp", "Click to show in Finder", 1, false),
            ("hud-done-dark", 1, "Saved 12 files", "Click to show in Finder", 1, true),
            ("hud-failed-dark", 2, "Couldn't finish", "FFmpeg isn't installed. Open Satsuma Settings > Engines to install it.", 1, true),
        ]
        for (name, phase, title, sub, p, dark) in hudCases {
            if let img = hudFrame(phase: phase, title: title, subtitle: sub, progress: p, dark: dark, px: px) {
                let out = P.join(dir, name + ".png")
                try ImageConverter.write(img, to: out, type: "public.png")
                files.append(out)
            }
        }

        for (size, tray) in [(256, false), (64, false), (36, true)] {
            if let img = AppIcon.render(size: size, tray: tray, template: tray) {
                let out = P.join(dir, "icon-\(size)\(tray ? "-menubar" : "").png")
                try ImageConverter.write(img, to: out, type: "public.png")
                files.append(out)
            }
        }
        return files
    }

    /// Renders the windows and tool dialogs offscreen (their async previews don't load here, only the layout).
    @MainActor
    static func ui(_ dir: String, _ samples: [String]) throws -> [String] {
        try P.createDir(dir)
        let img = samples.first ?? Welcome.samplePicture()
        let video = samples.count > 1 ? samples[1] : img
        let audio = samples.count > 2 ? samples[2] : img
        let pdf = samples.count > 3 ? samples[3] : img
        var files: [String] = []
        func shot<V: View>(_ name: String, width: CGFloat, _ view: V) throws {
            for dark in [false, true] {
                let r = ImageRenderer(content: view.frame(width: width).padding(0)
                    .background(Color(nsColor: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)))
                    .environment(\.colorScheme, dark ? .dark : .light))
                r.scale = 2
                guard let cg = r.cgImage else { continue }
                let out = P.join(dir, name + (dark ? "-dark" : "") + ".png")
                try ImageConverter.write(cg, to: out, type: "public.png")
                files.append(out)
            }
        }
        try shot("settings", width: 560, SettingsView(scrolls: false))
        try shot("welcome", width: 640, WelcomeView())
        try shot("compress", width: 460, ToolDialogs.CompressView(files: [img], done: { _ in }).padding(22))
        try shot("resize", width: 460, ToolDialogs.ResizeView(files: [img], done: { _ in }).padding(22))
        try shot("crop", width: 600, ToolDialogs.CropView(file: img, done: { _ in }).padding(22))
        try shot("redact", width: 520, ToolDialogs.RedactView(files: [img], done: { _ in }).padding(22))
        try shot("backdrop", width: 520, ToolDialogs.BackdropView(files: [img], done: { _ in }).padding(22))
        try shot("collage", width: 540, ToolDialogs.CollageView(files: [img, img, img], done: { _ in }).padding(22))
        try shot("video-compress", width: 460, ToolDialogs.VideoCompressView(files: [video], done: { _ in }).padding(22))
        try shot("audio-compress", width: 460, ToolDialogs.AudioCompressView(files: [audio], done: { _ in }).padding(22))
        try shot("trim", width: 600, ToolDialogs.TrimView(file: video, done: { _ in }).padding(22))
        try shot("pages", width: 560, ToolDialogs.PagesView(file: pdf, done: { _ in }).padding(22))
        return files
    }

    /// One wheel frame at animation time `t` (0...1), like the Windows RenderPreview.
    @MainActor
    static func wheelFrame(_ kind: WheelKind, _ paths: [String], hover: Int, t: Double, dark: Bool, px: CGFloat) -> CGImage? {
        let st = WheelState()
        st.layout = WheelLayout(scale: 1, showHints: true)
        st.dark = dark
        st.kind = kind
        let L = st.layout
        let content = Catalog.build(kind, paths)
        st.content = content
        st.loading = false
        st.segments = content.items.map { SegmentState(item: $0) }
        st.open.snap(t)
        st.fade.snap(min(1, t * 1.6))
        st.hubPop.snap(t)
        for (i, s) in st.segments.enumerated() { s.appear.snap(min(max(t * 1.3 - Double(i) * 0.03, 0), 1)) }
        if hover >= 0 && hover < st.segments.count {
            st.segments[hover].hover.snap(1)
            st.hover = hover
            st.hubTo = HubText(caption: st.segments[hover].item.caption, title: st.segments[hover].item.label, accent: true)
        } else {
            st.hubTo = HubText(caption: content.hubCaption, title: content.items.isEmpty ? content.emptyMessage : content.hubTitle)
        }
        guard let backdrop = WheelSprites.testBackdrop(width: L.width, height: L.height, dark: dark, px: px) else { return nil }
        let layers = WheelLayers(px: px, glass: backdrop.glass, tintScale: 1)
        layers.update(st)
        layers.update(st) // the chip highlight snaps into place on the first pass
        guard let ctx = Style.canvas(L.width, L.height, px) else { return nil }
        ctx.draw(backdrop.wallpaper, in: CGRect(x: 0, y: 0, width: L.width, height: L.height))
        layers.root.render(in: ctx)
        return ctx.makeImage()
    }

    @MainActor
    static func hudFrame(phase: Int, title: String, subtitle: String, progress: Double, dark: Bool, px: CGFloat) -> CGImage? {
        let hud = Hud(title: title, subtitle: subtitle, glyph: Glyphs.convert, scale: 1, dark: dark)
        hud.fraction = progress
        hud.progress.snap(phase == 0 ? progress : 1)
        hud.done.snap(phase == 0 ? 0 : 1)
        hud.spin = 40
        if phase == 1 { hud.complete(title, subtitle, outputs: []) } else if phase == 2 { hud.fail(title, subtitle) }
        hud.done.snap(phase == 0 ? 0 : 1)
        let size = hud.canvasSize
        guard let backdrop = WheelSprites.testBackdrop(width: size.width, height: size.height, dark: dark, px: px),
              let ctx = Style.canvas(size.width, size.height, px) else { return nil }
        ctx.draw(backdrop.wallpaper, in: CGRect(origin: .zero, size: size))
        hud.draw(ctx, glass: backdrop.glass, tintScale: 1)
        return ctx.makeImage()
    }
}
