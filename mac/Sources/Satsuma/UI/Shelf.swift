import AppKit
import QuickLookThumbnailing
import SatsumaCore

/// A small floating shelf for parking files: drop files on it (or use the Float action), then drag them out
/// into any app. Dragging out is a normal file drag, so Finder, browsers and Mail all accept it.
final class Shelf: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = Shelf()

    struct Entry { let path: String; let name: String; let detail: String; var icon: NSImage }

    private var panel: NSPanel?
    private var table: NSTableView?
    private var countLabel: NSTextField?
    private var hint: NSTextField?
    private var items: [Entry] = []

    func add(_ paths: [String], near anchor: CGPoint) {
        if panel == nil { build(near: anchor) }
        for p in paths where !items.contains(where: { $0.path == p }) { items.append(entry(p)) }
        refresh()
        panel?.orderFrontRegardless()
    }

    func showEmpty() { add([], near: NSEvent.mouseLocation) }

    private func entry(_ path: String) -> Entry {
        let detail = P.isDir(path) ? "Folder" : P.isFile(path) ? FileKinds.humanSize(P.size(path)) : ""
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        loadThumbnail(path)
        return Entry(path: path, name: P.fileName(path), detail: detail, icon: icon)
    }

    /// Finder-quality previews (photos, video frames, PDF pages) replace the generic icon when they're ready.
    private func loadThumbnail(_ path: String) {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 32, height: 32), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, let i = self.items.firstIndex(where: { $0.path == path }) else { return }
                self.items[i].icon = image
                self.table?.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    private func build(near anchor: CGPoint) {
        let size = NSSize(width: 300, height: 260)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Shelf"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.minSize = NSSize(width: 240, height: 160)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        p.contentView = effect

        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 12)
        count.textColor = .secondaryLabelColor
        count.frame = NSRect(x: 64, y: size.height - 26, width: 120, height: 16)
        count.autoresizingMask = [.minYMargin]
        effect.addSubview(count)

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        clear.bezelStyle = .inline
        clear.frame = NSRect(x: size.width - 64, y: size.height - 27, width: 54, height: 18)
        clear.autoresizingMask = [.minXMargin, .minYMargin]
        effect.addSubview(clear)

        let scroll = NSScrollView(frame: NSRect(x: 6, y: 34, width: size.width - 12, height: size.height - 70))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let t = NSTableView(frame: scroll.bounds)
        t.headerView = nil
        t.backgroundColor = .clear
        t.rowHeight = 40
        t.intercellSpacing = NSSize(width: 0, height: 2)
        t.allowsMultipleSelection = true
        t.style = .plain
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.resizingMask = .autoresizingMask
        t.addTableColumn(col)
        t.dataSource = self
        t.delegate = self
        t.doubleAction = #selector(openSelected)
        t.target = self
        t.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        t.registerForDraggedTypes([.fileURL])
        scroll.documentView = t
        effect.addSubview(scroll)

        let h = NSTextField(wrappingLabelWithString: "Drop files here, then drag them out anywhere.")
        h.font = .systemFont(ofSize: 12)
        h.textColor = .secondaryLabelColor
        h.frame = NSRect(x: 14, y: 8, width: size.width - 28, height: 20)
        h.autoresizingMask = [.width]
        effect.addSubview(h)

        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - size.width - 8)
            origin.y = min(max(origin.y, v.minY + 8), v.maxY - size.height - 8)
        }
        p.setFrameOrigin(origin)
        panel = p
        table = t
        countLabel = count
        hint = h
    }

    private func refresh() {
        table?.reloadData()
        countLabel?.stringValue = items.isEmpty ? "" : items.count == 1 ? "1 item" : "\(items.count) items"
        hint?.isHidden = !items.isEmpty
    }

    @objc private func clearAll() {
        items = []
        refresh()
    }

    @objc private func openSelected() {
        guard let t = table, t.clickedRow >= 0, t.clickedRow < items.count else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: items[t.clickedRow].path))
    }

    func windowWillClose(_ notification: Notification) {
        items = []
        panel = nil
        table = nil
    }

    // ------------------------------------------------------------------ table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = items[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: e.icon)
        icon.frame = NSRect(x: 4, y: 4, width: 32, height: 32)
        cell.addSubview(icon)
        let name = NSTextField(labelWithString: e.name)
        name.font = .systemFont(ofSize: 12.5)
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 44, y: 19, width: tableView.bounds.width - 52, height: 16)
        name.autoresizingMask = [.width]
        cell.addSubview(name)
        let detail = NSTextField(labelWithString: e.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 44, y: 4, width: tableView.bounds.width - 52, height: 14)
        detail.autoresizingMask = [.width]
        cell.addSubview(detail)
        cell.toolTip = e.path
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        URL(fileURLWithPath: items[row].path) as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Items that were moved away no longer exist; drop them from the shelf.
        items.removeAll { !P.exists($0.path) }
        refresh()
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if info.draggingSource as? NSTableView === tableView { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .link
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for u in urls where !items.contains(where: { $0.path == u.path }) { items.append(entry(u.path)) }
        refresh()
        return !urls.isEmpty
    }
}
