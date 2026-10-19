import AppKit
import UniformTypeIdentifiers
import SatsumaCore

/// Borderless, non-activating panel that floats above everything (full-screen apps and all Spaces included)
/// and never takes focus, so it can appear under the pointer in the middle of a drag.
class OverlayPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A view-hosted NSVisualEffectView clipped to a circle or capsule (behind-window blur of the desktop).
final class GlassView: NSVisualEffectView {
    var cornerFraction: CGFloat = 0.5 // 0.5 of the height = capsule or circle
    private var maskSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        blendingMode = .behindWindow
        state = .active
        material = .popover
        isEmphasized = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Places the glass and refreshes its mask when the size changes.
    func place(_ rect: CGRect) {
        if frame != rect { frame = rect }
        if rect.size != maskSize {
            maskSize = rect.size
            let radius = min(rect.width, rect.height) * cornerFraction
            maskImage = NSImage(size: rect.size, flipped: false) { r in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
                return true
            }
        }
    }
}

/// The wheel window's content: the plate shadow, the vibrancy glass, then the layer tree on top.
/// It is also the drop destination for the drag that's in progress.
final class WheelView: NSView {
    weak var controller: WheelController?
    let shadowHost = NSView()
    let plateGlass = GlassView(frame: .zero)
    let pillGlass = GlassView(frame: .zero)
    let layerHost = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        for v in [shadowHost, layerHost] {
            v.wantsLayer = true
            v.layer?.backgroundColor = .clear
            v.autoresizingMask = [.width, .height]
            v.frame = bounds
        }
        addSubview(shadowHost)
        addSubview(plateGlass)
        addSubview(pillGlass)
        addSubview(layerHost)
        registerForDraggedTypes([.fileURL, .URL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.perform(sender) ?? false }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
}

/// Reads the files a drag carries, as soon as the drag starts and again when it reaches the wheel.
enum DragFiles {
    struct Snapshot: Equatable {
        var paths: [String] = []
        /// True when the drag only promises files (Safari images, Mail attachments); `paths` are stand-in names.
        var promised = false
        var isEmpty: Bool { paths.isEmpty }
    }

    static func read(_ pb: NSPasteboard) -> Snapshot {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return Snapshot(paths: urls.map { $0.standardizedFileURL.path }, promised: false) }
        let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        var names: [String] = []
        for r in receivers {
            let type = r.fileTypes.first.flatMap { UTType($0) }
            let ext = type?.preferredFilenameExtension ?? ""
            let name = r.fileNames.first ?? ("Dropped item" + (ext.isEmpty ? "" : "." + ext))
            names.append(P.join(AppPaths.tempDir, "promised", name))
        }
        return Snapshot(paths: names, promised: !names.isEmpty)
    }

    /// Receives promised files into a fresh temp folder.
    static func receive(_ pb: NSPasteboard, completion: @escaping ([String]) -> Void) {
        let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        guard !receivers.isEmpty, let dir = try? AppPaths.newTempDir("in") else { completion([]); return }
        let queue = OperationQueue()
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []
        for r in receivers {
            group.enter()
            var pending = max(1, r.fileNames.count)
            r.receivePromisedFiles(atDestination: URL(fileURLWithPath: dir), options: [:], operationQueue: queue) { url, error in
                lock.lock()
                if error == nil { paths.append(url.path) }
                pending -= 1
                let done = pending <= 0
                lock.unlock()
                if done { group.leave() }
            }
        }
        group.notify(queue: .main) { completion(paths.sorted()) }
    }
}
