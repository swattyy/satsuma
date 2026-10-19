import AppKit
import SwiftUI

/// Shows SwiftUI content in a regular window (one per id), bringing the menu bar app to the front.
enum Windows {
    private static var open: [String: NSWindow] = [:]
    private final class Closer: NSObject, NSWindowDelegate {
        let id: String
        init(id: String) { self.id = id }
        func windowWillClose(_ notification: Notification) { Windows.open[id] = nil; Windows.closers[id] = nil }
    }
    private static var closers: [String: Closer] = [:]

    @discardableResult
    static func show<V: View>(_ id: String, title: String, size: CGSize, resizable: Bool = false, _ content: () -> V) -> NSWindow {
        if let w = open[id] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return w
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: content())
        w.setContentSize(size)
        w.center()
        let closer = Closer(id: id)
        w.delegate = closer
        closers[id] = closer
        open[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return w
    }

    static func close(_ id: String) { open[id]?.close() }
}

extension Color {
    static let tangerine = Color(red: 1, green: 0x7A / 255.0, blue: 0x1A / 255.0)
}
