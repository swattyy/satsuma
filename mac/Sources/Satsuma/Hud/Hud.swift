import AppKit
import SatsumaCore

/// The little glass bubble at the drop point: a progress ring while working, then a drawn-on checkmark
/// ("Saved photo.webp", click to show it in Finder) or an error. Drawn with Core Graphics, like the Windows HUD.
final class Hud {
    enum Phase { case working, done, failed, closing }

    private static var active: [Hud] = []

    let s: CGFloat
    let dark: Bool
    private(set) var phase = Phase.working
    var title: String
    var subtitle = ""
    let glyph: String
    var fraction = -1.0
    let appear = Spring(0, response: 0.42, damping: 0.66)
    let fade = Spring(0, response: 0.12, damping: 1)
    let progress = Spring(0, response: 0.35, damping: 1)
    let done = Spring(0, response: 0.5, damping: 0.85)
    let widthAnim = Spring(0, response: 0.3, damping: 0.86)
    var spin = 0.0
    let bubbleH: CGFloat
    private(set) var outputs: [String] = []
    private var dismissAt = Double.greatestFiniteMagnitude
    private var hovered = false

    private var panel: OverlayPanel?
    private var view: HudView?
    private var ticker: FrameTicker?
    private var center: CGPoint

    var canvasSize: CGSize { CGSize(width: 440 * s + 72 * s, height: bubbleH + 72 * s) }

    /// Offscreen instance for the render tests.
    init(title: String, subtitle: String, glyph: String, scale: CGFloat, dark: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
        s = scale
        self.dark = dark
        bubbleH = 56 * scale
        center = .zero
        widthAnim.snap(Double(measureWidth()))
        appear.snap(1)
        fade.snap(1)
    }

    init(anchor: CGPoint, title: String, glyph: String) {
        self.title = title
        self.glyph = glyph
        s = CGFloat(min(max(Settings.current.wheelScale, 0.6), 1.6))
        dark = Theme.isDark
        bubbleH = 56 * s
        center = anchor
        widthAnim.snap(Double(measureWidth()))
        layoutWindow()
        appear.to(1)
        fade.to(1)
        Hud.active.append(self)
        ticker?.start()
    }

    // ------------------------------------------------------------------ public API (main thread)

    func report(_ f: Double, _ status: String?) {
        guard phase == .working else { return }
        fraction = f
        if f >= 0 { progress.to(min(max(f, 0), 1)) }
        if let status, status != subtitle { subtitle = status; resize() }
        ticker?.start()
    }

    func complete(_ title: String, _ subtitle: String, outputs: [String]) {
        guard phase != .closing else { return }
        phase = .done
        self.title = title
        self.subtitle = subtitle
        self.outputs = outputs
        progress.to(1)
        done.to(1, delay: 0.08)
        resize()
        panel?.ignoresMouseEvents = outputs.isEmpty
        dismissAt = CACurrentMediaTime() + 2.6
        SoundFx.play(.done)
        ticker?.start()
    }

    func fail(_ title: String, _ message: String) {
        guard phase != .closing else { return }
        phase = .failed
        self.title = title
        subtitle = message
        done.to(1)
        resize()
        panel?.ignoresMouseEvents = false
        dismissAt = CACurrentMediaTime() + 6
        SoundFx.play(.error)
        ticker?.start()
    }

    func dismiss() {
        guard phase != .closing else { return }
        phase = .closing
        appear.configure(response: 0.25, damping: 1).to(0.92)
        fade.configure(response: 0.12, damping: 1).to(0)
        panel?.ignoresMouseEvents = true
        ticker?.start()
    }

    func clicked(right: Bool) {
        if !right && phase == .done && !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs.map { URL(fileURLWithPath: $0) })
        }
        dismiss()
    }

    func hover(_ inside: Bool) {
        hovered = inside
        if !inside { dismissAt = max(dismissAt, CACurrentMediaTime() + 1.2) }
        ticker?.start()
    }

    // ------------------------------------------------------------------ layout

    func measureWidth() -> CGFloat {
        let t = Style.width(title, Style.font(13.5 * s, .semibold)), sub = Style.width(subtitle, Style.font(11.5 * s, .regular))
        return min(max(max(t, sub) + 82 * s, 230 * s), 440 * s)
    }

    private func resize() { widthAnim.to(Double(measureWidth())) }

    private func layoutWindow() {
        var c = center
        // Stack below other bubbles that are already in that spot (AppKit's y axis points up).
        for other in Hud.active where other !== self && other.phase != .closing {
            if abs(other.center.x - c.x) < 300 * s && abs(other.center.y - c.y) < bubbleH + 8 * s { c.y = other.center.y - (bubbleH + 10 * s) }
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(c, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.frame
            c.y = min(max(c.y, f.minY + bubbleH), f.maxY - bubbleH)
            c.x = min(max(c.x, f.minX + 230 * s), f.maxX - 230 * s)
        }
        center = c
        let size = canvasSize
        let p = OverlayPanel(size: size)
        p.ignoresMouseEvents = true
        let v = HudView(frame: NSRect(origin: .zero, size: size))
        v.hud = self
        p.contentView = v
        p.setFrameOrigin(CGPoint(x: (c.x - size.width / 2).rounded(), y: (c.y - size.height / 2).rounded()))
        panel = p
        view = v
        ticker = FrameTicker(view: v) { [weak self] dt in self?.tick(dt) ?? false }
        v.glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        p.orderFrontRegardless()
    }

    // ------------------------------------------------------------------ frames

    private func tick(_ dt: Double) -> Bool {
        var moving = false
        for spring in [appear, fade, progress, done, widthAnim] where spring.step(dt) { moving = true }
        if phase == .working { spin += dt * 300; moving = true }
        let now = CACurrentMediaTime()
        if (phase == .done || phase == .failed) && !hovered && now >= dismissAt { dismiss() }
        if phase == .closing && fade.value < 0.01 && fade.target <= 0 {
            Hud.active.removeAll { $0 === self }
            panel?.orderOut(nil)
            panel = nil
            view = nil
            return false
        }
        view?.needsDisplay = true
        view?.updateGlass()
        let waiting = phase == .done || phase == .failed
        if !moving && waiting {
            // Nothing to animate until the dismiss time: sleep instead of drawing frames.
            let wait = max(0.05, dismissAt - now)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.ticker?.start() }
            return false
        }
        return moving
    }

    /// The bubble's rect inside the canvas (y up), before the appear scale.
    var bubbleRect: CGRect {
        let size = canvasSize
        let bw = CGFloat(widthAnim.value)
        return CGRect(x: size.width / 2 - bw / 2, y: size.height / 2 - bubbleH / 2, width: bw, height: bubbleH)
    }

    // ------------------------------------------------------------------ drawing

    /// Draws the bubble into a y-up context sized `canvasSize`. `glass` bakes in a blurred backdrop for tests.
    func draw(_ c: CGContext, glass: Glass?, tintScale: Double) {
        let f = CGFloat(Ease.clamp01(fade.value))
        if f <= 0.003 { return }
        let size = canvasSize
        let scale = 0.72 + 0.28 * CGFloat(appear.value)
        let rect = bubbleRect
        c.saveGState()
        c.setAlpha(f)
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.translateBy(x: size.width / 2, y: size.height / 2)
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: -size.width / 2, y: -size.height / 2)
        let radius = bubbleH / 2
        let bubble = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Shadow
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 24 * s, color: Style.black((dark ? 90 : 46) / 255))
        c.addPath(bubble)
        c.setFillColor(Style.black((dark ? 90 : 46) / 255))
        c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(bubble)
        c.clip()
        c.clear(rect)
        if let glass {
            let k = CGFloat(glass.image.width) / glass.size.width
            if let piece = glass.image.cropping(to: CGRect(x: 0, y: 0, width: size.width * k, height: size.height * k)) {
                c.draw(piece, in: CGRect(origin: .zero, size: size))
            }
        }
        c.setFillColor(dark ? Style.rgb(30, 29, 34, 205 / 255 * tintScale) : Style.rgb(252, 250, 247, 200 / 255 * tintScale))
        c.fill(rect)
        c.restoreGState()
        c.setLineWidth(1 * s)
        c.addPath(bubble)
        c.setStrokeColor(dark ? Style.white(34 / 255) : Style.white(235 / 255))
        c.strokePath()
        let outer = rect.insetBy(dx: -0.6 * s, dy: -0.6 * s)
        c.addPath(CGPath(roundedRect: outer, cornerWidth: radius + 0.6 * s, cornerHeight: radius + 0.6 * s, transform: nil))
        c.setStrokeColor(dark ? Style.black(80 / 255) : Style.black(18 / 255))
        c.strokePath()

        // Status disc
        let dr = 17 * s
        let disc = CGPoint(x: rect.minX + 10 * s + dr, y: rect.midY)
        drawDisc(c, disc, dr)

        // Text
        let primary = dark ? Style.rgb(246, 242, 238) : Style.rgb(36, 30, 26)
        let secondary = dark ? Style.rgb(176, 168, 160) : Style.rgb(120, 112, 105)
        let tf = Style.font(13.5 * s, .semibold), sf = Style.font(11.5 * s, .regular)
        let tx = disc.x + dr + 12 * s
        let maxW = rect.maxX - 18 * s - tx
        c.saveGState()
        c.clip(to: CGRect(x: tx, y: rect.minY, width: rect.maxX - 14 * s - tx, height: rect.height))
        let hasSub = !subtitle.isEmpty
        Style.drawLeft(c, Hud.ellipsize(title, tf, maxW), tf, primary, x: tx, baseline: rect.midY + (hasSub ? 3 * s : -5 * s))
        if hasSub { Style.drawLeft(c, Hud.ellipsize(subtitle, sf, maxW), sf, secondary, x: tx, baseline: rect.midY - 14 * s) }
        c.restoreGState()
        c.endTransparencyLayer()
        c.restoreGState()
    }

    private func drawDisc(_ c: CGContext, _ p: CGPoint, _ r: CGFloat) {
        let d = CGFloat(Ease.clamp01(done.value))
        let failed = phase == .failed
        // Track + progress arc
        let arcR = r - 1.5 * s
        c.saveGState()
        c.setLineWidth(3 * s)
        c.setLineCap(.round)
        c.setStrokeColor(dark ? Style.white(30 / 255) : Style.black(22 / 255))
        c.strokeEllipse(in: CGRect(x: p.x - arcR, y: p.y - arcR, width: 2 * arcR, height: 2 * arcR))
        let arc = CGMutablePath()
        if phase == .working && fraction < 0 {
            let start = -CGFloat(spin.truncatingRemainder(dividingBy: 360)) * .pi / 180
            arc.addArc(center: p, radius: arcR, startAngle: start, endAngle: start - 100 * .pi / 180, clockwise: true)
        } else {
            let sweep = 2 * .pi * CGFloat(Ease.clamp01(progress.value))
            if sweep > 0.01 { arc.addArc(center: p, radius: arcR, startAngle: .pi / 2, endAngle: .pi / 2 - sweep, clockwise: true) }
        }
        if !arc.isEmpty {
            c.addPath(arc)
            c.replacePathWithStrokedPath()
            c.clip()
            // Sweep gradient approximated with a two-stop linear gradient across the ring.
            c.drawLinearGradient(Style.linearGradient([Style.accentLight, Style.accentDeep]), start: CGPoint(x: p.x - r, y: p.y + r),
                                 end: CGPoint(x: p.x + r, y: p.y - r), options: [])
        }
        c.restoreGState()

        // Working: small glyph inside. Done or failed: filled disc with a drawn-on mark.
        if d < 0.02 {
            Style.drawSymbol(c, glyph, size: 12 * s, weight: .semibold, color: dark ? Style.rgb(230, 224, 218) : Style.rgb(70, 62, 56), center: p)
            return
        }
        let rr = r * (0.55 + 0.45 * d)
        c.saveGState()
        c.setAlpha(min(1, d * 1.5))
        c.addEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr))
        c.clip()
        let colors = failed ? [Style.rgb(245, 110, 96), Style.rgb(214, 52, 44)] : [Style.accentLight, Style.accentDeep]
        c.drawLinearGradient(Style.linearGradient(colors), start: CGPoint(x: p.x - r, y: p.y + r), end: CGPoint(x: p.x + r, y: p.y - r), options: [])
        c.restoreGState()

        c.saveGState()
        c.setLineWidth(2.6 * s)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        c.setStrokeColor(Style.white(1))
        c.setFillColor(Style.white(1))
        if failed {
            c.move(to: CGPoint(x: p.x, y: p.y + 7 * s))
            c.addLine(to: CGPoint(x: p.x, y: p.y - 2 * s))
            c.strokePath()
            c.fillEllipse(in: CGRect(x: p.x - 1.6 * s, y: p.y - 7 * s - 1.6 * s, width: 3.2 * s, height: 3.2 * s))
        } else {
            // Drawn on: the stroke grows along the check's two legs.
            let a = CGPoint(x: p.x - 7 * s, y: p.y - 0.5 * s), b = CGPoint(x: p.x - 2 * s, y: p.y - 5.5 * s), e = CGPoint(x: p.x + 7.5 * s, y: p.y + 5 * s)
            let l1 = hypot(b.x - a.x, b.y - a.y), l2 = hypot(e.x - b.x, e.y - b.y)
            let t = CGFloat(Ease.outCubic(Ease.clamp01((Double(d) - 0.25) / 0.75))) * (l1 + l2)
            c.move(to: a)
            if t <= l1 {
                c.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t / l1, y: a.y + (b.y - a.y) * t / l1))
            } else {
                c.addLine(to: b)
                let k = (t - l1) / l2
                c.addLine(to: CGPoint(x: b.x + (e.x - b.x) * k, y: b.y + (e.y - b.y) * k))
            }
            if t > 0.5 { c.strokePath() }
        }
        c.restoreGState()
    }

    /// Keeps the extension visible: "very-long-name….png".
    static func ellipsize(_ text: String, _ font: CTFont, _ max: CGFloat) -> String {
        if Style.width(text, font) <= max { return text }
        var ext = P.ext(text)
        if ext.count > 6 { ext = "" }
        var head = String(text.dropLast(ext.count))
        while head.count > 1 && Style.width(head + "…" + ext, font) > max { head.removeLast() }
        return head + "…" + ext
    }
}

/// The bubble's window content: vibrancy glass behind a Core Graphics drawing.
final class HudView: NSView {
    weak var hud: Hud?
    let glass = GlassView(frame: .zero)
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    func updateGlass() {
        guard let hud else { return }
        let scale = 0.72 + 0.28 * CGFloat(hud.appear.value)
        let r = hud.bubbleRect
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let scaled = CGRect(x: c.x + (r.minX - c.x) * scale, y: c.y + (r.minY - c.y) * scale, width: r.width * scale, height: r.height * scale)
        glass.place(scaled)
        glass.alphaValue = CGFloat(Ease.clamp01(hud.fade.value))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let hud, let ctx = NSGraphicsContext.current?.cgContext else { return }
        hud.draw(ctx, glass: nil, tintScale: 0.6)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hud?.hover(true) }
    override func mouseExited(with event: NSEvent) { hud?.hover(false) }
    override func mouseUp(with event: NSEvent) { hud?.clicked(right: false) }
    override func rightMouseUp(with event: NSEvent) { hud?.clicked(right: true) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
