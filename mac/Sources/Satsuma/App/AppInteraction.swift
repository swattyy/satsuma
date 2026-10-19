import AppKit
import SatsumaCore

/// The app's side of wheel items: the tools' option dialogs and the Actions wheel's system integrations.
final class AppInteraction: HeadlessInteraction {
    override func imageCompress(_ files: [String]) async -> CompressOptions? { await ToolDialogs.imageCompress(files) }
    override func imageResize(_ files: [String]) async -> ResizeChoice? { await ToolDialogs.imageResize(files) }
    override func imageCrop(_ file: String) async -> PixelRect? { await ToolDialogs.imageCrop(file) }
    override func redact(_ files: [String]) async -> RedactChoice? { await ToolDialogs.redact(files) }
    override func background(_ files: [String]) async -> BackgroundOptions? { await ToolDialogs.background(files) }
    override func collage(_ files: [String]) async -> CollageOptions? { await ToolDialogs.collage(files) }
    override func videoCompress(_ files: [String]) async -> VideoCompressOptions? { await ToolDialogs.videoCompress(files) }
    override func audioCompress(_ files: [String]) async -> Int? { await ToolDialogs.audioCompress(files) }
    override func trim(_ file: String) async -> (start: Double, end: Double)? { await ToolDialogs.trim(file) }
    override func pages(_ file: String) async -> [Int]? { await ToolDialogs.pages(file) }

    /// A 1x1 invisible panel at a screen point, for anchoring menus and the share picker.
    @MainActor static func anchorView(at p: CGPoint) -> (OverlayPanel, NSView) {
        let panel = OverlayPanel(size: CGSize(width: 1, height: 1))
        panel.setFrameOrigin(p)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        panel.contentView = v
        panel.orderFrontRegardless()
        return (panel, v)
    }

    final class PickerDelegate: NSObject, NSSharingServicePickerDelegate {
        var panel: NSPanel?
        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.panel?.orderOut(nil); self.panel = nil; PickerDelegate.current = nil }
        }
        static var current: PickerDelegate?
    }

    override func share(_ files: [String], anchor: CGPoint) async throws {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            let (panel, view) = AppInteraction.anchorView(at: anchor)
            let picker = NSSharingServicePicker(items: files.map { URL(fileURLWithPath: $0) })
            let delegate = PickerDelegate()
            delegate.panel = panel
            PickerDelegate.current = delegate
            picker.delegate = delegate
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    override func float(_ files: [String], anchor: CGPoint) async throws {
        await MainActor.run { Shelf.shared.add(files, near: anchor) }
    }

    override func move(_ files: [String]) async throws -> [String]? {
        let dest: URL? = await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Move Here"
            panel.message = files.count == 1 ? "Move “\(P.fileName(files[0]))” to…" : "Move \(files.count) items to…"
            panel.directoryURL = URL(fileURLWithPath: P.dir(files[0]))
            return panel.runModal() == .OK ? panel.url : nil
        }
        guard let dest else { return nil }
        var moved: [String] = []
        for f in files {
            let src = P.trimSlash(f)
            if P.dir(src) == dest.path { moved.append(src); continue }
            var target = P.join(dest.path, P.fileName(src))
            if P.exists(target) {
                target = P.isDir(src) ? OutputPaths.unique(dir: dest.path, baseName: P.fileName(src), ext: "")
                                     : OutputPaths.unique(dir: dest.path, baseName: P.stem(src), ext: P.ext(src))
            }
            do { try FileManager.default.moveItem(atPath: src, toPath: target) }
            catch { throw OpError("Couldn't move \(P.fileName(src)): \(error.localizedDescription)") }
            moved.append(target)
        }
        return moved
    }

    override func openTerminal(_ path: String) async throws {
        let dir = P.isDir(path) ? path : P.dir(path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: terminal, configuration: config)
    }

    final class MenuTarget: NSObject {
        let file: URL
        init(file: URL) { self.file = file }
        @objc func open(_ sender: NSMenuItem) {
            guard let app = sender.representedObject as? URL else { return }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    override func openWith(_ file: String, anchor: CGPoint) async throws {
        await MainActor.run {
            let url = URL(fileURLWithPath: file)
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            let target = MenuTarget(file: url)
            let menu = NSMenu(title: "Open With")
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            for app in apps {
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                let item = NSMenuItem(title: app == defaultApp ? "\(name) (default)" : name, action: #selector(MenuTarget.open(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = app
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
            if apps.isEmpty { menu.addItem(withTitle: "No apps can open this file", action: nil, keyEquivalent: "") }
            NSApp.activate(ignoringOtherApps: true)
            let (panel, view) = AppInteraction.anchorView(at: anchor)
            menu.popUp(positioning: nil, at: .zero, in: view)
            panel.orderOut(nil)
            _ = target
        }
    }
}
