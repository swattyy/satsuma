import AppKit
import ApplicationServices
import SatsumaCore

/// Watches the mouse and modifier keys system-wide. A trigger key only opens the wheel while the left button is
/// held, the pointer has moved past the drag threshold, and the drag pasteboard changed since the button went
/// down (a real drag-and-drop is under way) and carries files or file promises.
final class DragMonitor {
    static let shared = DragMonitor()

    private var monitors: [Any] = []
    private var buttonDown = false
    private var moved = false
    private var downPoint = CGPoint.zero
    private var downChangeCount = 0
    private var flags: NSEvent.ModifierFlags = []
    private let threshold: CGFloat = 4

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) { monitors.append(m) }
        // Our own windows (the welcome window's practice picture) don't reach the global monitor.
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) { monitors.append(m) }
        flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            buttonDown = true
            moved = false
            downPoint = NSEvent.mouseLocation
            downChangeCount = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            if buttonDown && !moved {
                let p = NSEvent.mouseLocation
                if abs(p.x - downPoint.x) > threshold || abs(p.y - downPoint.y) > threshold { moved = true }
            }
        case .leftMouseUp:
            buttonDown = false
            moved = false
            WheelController.shared.onMouseUp()
        case .flagsChanged:
            let now = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let pressed = now.subtracting(flags)
            flags = now
            for key in [TriggerKey.shift, .control, .option, .command] where pressed.contains(key.flag) {
                trigger(key)
            }
        case .keyDown:
            if e.keyCode == 53 && WheelController.shared.isOpen { WheelController.shared.onEscape() } // Esc
        default:
            break
        }
    }

    /// For drags our own app starts (the practice picture), which skip the monitors.
    func noteOwnDrag(started point: CGPoint) {
        buttonDown = true
        moved = true
        downPoint = point
        downChangeCount = NSPasteboard(name: .drag).changeCount - 1
    }

    func trigger(_ key: TriggerKey) {
        let s = Settings.current
        guard s.enabled else { return }
        let kind: WheelKind
        if key == s.convertKey { kind = .convert }
        else if key == s.toolsKey { kind = .tools }
        else if key == s.actionsKey { kind = .actions }
        else { return }
        // The button state from the events can lag; ask the system too.
        let leftDown = buttonDown || (NSEvent.pressedMouseButtons & 1) != 0
        guard leftDown, moved || WheelController.shared.isOpen else { return }
        if WheelController.shared.isOpen {
            WheelController.shared.open(kind, at: NSEvent.mouseLocation, files: DragFiles.Snapshot())
            return
        }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != downChangeCount else { return }
        let files = DragFiles.read(pb)
        guard !files.isEmpty else { return } // a text or image-data drag, not files
        WheelController.shared.open(kind, at: NSEvent.mouseLocation, files: files)
    }
}

extension TriggerKey {
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .none: return []
        }
    }
}
