import AppKit
import SwiftUI
import ServiceManagement
import SatsumaCore

enum Welcome {
    static func show() {
        Windows.show("welcome", title: "Welcome to Satsuma", size: CGSize(width: 640, height: 600)) { WelcomeView() }
    }

    /// A picture to practice on, written once to Application Support.
    static func samplePicture() -> String {
        let dir = P.join(AppPaths.dataDir, "Try")
        let path = P.join(dir, "sample.png")
        if P.exists(path) { return path }
        try? P.createDir(dir)
        let w = 1200, h = 800
        guard let ctx = ImageConverter.context(width: w, height: h) else { return path }
        let g = Style.linearGradient([Style.rgb(0xFF, 0xC9, 0x7A), Style.rgb(0xFF, 0x7A, 0x1A), Style.rgb(0xD9, 0x3F, 0x1E)])
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        ctx.setFillColor(Style.white(60 / 255))
        for i in 0..<7 {
            let r = CGFloat(70 + (i % 2) * 40)
            ctx.fillEllipse(in: CGRect(x: CGFloat(160 + i * 160) - r, y: CGFloat(h) - CGFloat(620 - (i % 3) * 120) - r, width: 2 * r, height: 2 * r))
        }
        Style.drawCentered(ctx, "Satsuma", Style.font(120, .bold), Style.white(235 / 255), x: 600, baseline: 400)
        Style.drawCentered(ctx, "a sample picture to convert", Style.font(40, .semibold), Style.white(200 / 255), x: 600, baseline: 330)
        if let img = ctx.makeImage() { try? ImageConverter.write(img, to: path, type: "public.png") }
        return path
    }
}

final class WelcomeModel: ObservableObject {
    @Published var trusted = DragMonitor.isTrusted
    @Published var practiced = false
    @Published var launchAtLogin = true
    private var timer: Timer?

    init() {
        launchAtLogin = Settings.current.firstRunDone ? SMAppService.mainApp.status == .enabled : true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = DragMonitor.isTrusted
            if t != self.trusted {
                self.trusted = t
                if t { DragMonitor.shared.start() }
            }
        }
    }

    deinit { timer?.invalidate() }

    func finish() {
        Settings.current.firstRunDone = true
        Settings.save()
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { Log.warn("Launch at login: \(error.localizedDescription)") }
        Windows.close("welcome")
    }
}

struct WelcomeView: View {
    @StateObject private var m = WelcomeModel()
    private let sample = Welcome.samplePicture()
    // WebP like on Windows when this Mac can write it; without FFmpeg it can't, so the practice run would fail.
    private let target = ImageConverter.canWriteWebP ? "WEBP" : "JPG"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.appImage(size: 48)).resizable().frame(width: 48, height: 48)
                Text("Drag. Tap. Drop.").font(.system(size: 28, weight: .semibold))
            }
            Text("Convert files while you're dragging them. There's no app to open and nothing gets uploaded; it all runs on this Mac.")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                card("1", "Start dragging", "Any file or folder, from Finder, the desktop or a browser.")
                VStack(alignment: .leading, spacing: 4) {
                    Text("2").font(.title2).bold().foregroundColor(.tangerine)
                    Text("Tap a key").bold()
                    keyLine(Settings.current.convertKey, "Convert")
                    keyLine(Settings.current.toolsKey, "Tools")
                    keyLine(Settings.current.actionsKey, "Actions")
                }
                .padding(12).frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                card("3", "Drop on it", "Release over a format or tool. The new file appears next to the original.")
            }
            .fixedSize(horizontal: false, vertical: true) // the cards share the tallest one's height
            if !m.trusted {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "hand.raised.fill").foregroundColor(.orange).font(.title2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("One permission first").bold()
                        Text("To notice the key you tap while you drag, Satsuma needs Accessibility access. Turn on Satsuma in System Settings > Privacy & Security > Accessibility. It only watches for the wheel keys during a drag.")
                            .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open Accessibility Settings") { DragMonitor.requestTrust(); DragMonitor.openAccessibilitySettings() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.6)))
            }
            HStack(spacing: 16) {
                PracticeTile(path: sample) { m.practiced = true }
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Try it now").bold()
                    Text(m.practiced ? "Nice. Converted files show up next to the original. Click the bubble to see it in Finder."
                                     : "Drag this picture a little, tap \(Settings.current.convertKey.title), then drop it on \(target).")
                        .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).stroke(Color.tangerine, lineWidth: 1.5))
            Spacer(minLength: 0)
            HStack {
                Toggle("Open Satsuma when I log in", isOn: $m.launchAtLogin)
                Spacer()
                Button("Get Started") { m.finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 640)
    }

    private func card(_ n: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(n).font(.title2).bold().foregroundColor(.tangerine)
            Text(title).bold()
            Text(text).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private func keyLine(_ key: TriggerKey, _ label: String) -> some View {
        if key != .none {
            HStack(spacing: 6) {
                Text(key.symbol + " " + key.title).font(.caption).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5)))
                Text(label).font(.callout)
            }
        }
    }
}

/// The practice picture: a real file drag, so Finder could take it too. While it's being dragged, the
/// tile watches the modifier keys itself, because the system monitors don't see drags this app starts.
struct PracticeTile: NSViewRepresentable {
    let path: String
    let onDrag: () -> Void

    func makeNSView(context: Context) -> TileView {
        let v = TileView()
        v.path = path
        v.onDrag = onDrag
        return v
    }

    func updateNSView(_ nsView: TileView, context: Context) {}

    final class TileView: NSView, NSDraggingSource {
        var path = ""
        var onDrag: (() -> Void)?
        private var down: NSPoint?
        private var timer: Timer?
        private var flags: NSEvent.ModifierFlags = []

        override func draw(_ dirtyRect: NSRect) {
            guard let image = NSImage(contentsOfFile: path) else { return }
            let r = bounds.insetBy(dx: 1, dy: 1)
            let clip = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            let s = image.size
            let k = max(r.width / s.width, r.height / s.height)
            let w = s.width * k, h = s.height * k
            image.draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            clip.stroke()
        }

        override func mouseDown(with event: NSEvent) { down = event.locationInWindow }

        override func mouseDragged(with event: NSEvent) {
            guard let d = down else { return }
            let p = event.locationInWindow
            if abs(p.x - d.x) < 3 && abs(p.y - d.y) < 3 { return }
            down = nil
            let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
            item.setDraggingFrame(bounds, contents: NSImage(contentsOfFile: path))
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : [.copy, .link]
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            DragMonitor.shared.noteOwnDrag(started: screenPoint)
            flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.pollKeys() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private func pollKeys() {
            let now = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let pressed = now.subtracting(flags)
            flags = now
            for key in [TriggerKey.shift, .control, .option, .command] where pressed.contains(key.flag) {
                DragMonitor.shared.trigger(key)
            }
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            timer?.invalidate()
            timer = nil
            WheelController.shared.onMouseUp()
            if !operation.isEmpty { onDrag?() }
        }
    }
}
