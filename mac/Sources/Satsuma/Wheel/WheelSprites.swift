import AppKit
import CoreImage
import SatsumaCore

/// A pre-rendered piece of the wheel. `size` is in points; `anchor` is the layer anchor (unit coordinates, y up)
/// that sits on the point the piece is positioned and rotated around.
struct Sprite {
    let image: CGImage
    let size: CGSize
    let anchor: CGPoint
}

/// The blurred screen (or test wallpaper) behind the wheel, for drawing glass into sprites.
/// `image` covers the whole wheel window; `size` is that window's size in points.
struct Glass {
    let image: CGImage
    let size: CGSize
}

/// Draws the wheel's parts once per open with Core Graphics, following the Windows renderer's numbers.
/// Animation then only moves, scales and fades these images (see WheelLayers).
enum WheelSprites {
    static let blurContext = CIContext(options: [.cacheIntermediates: false])

    /// Draws the glass region under a sprite: `frame` is the sprite's rect in window points (y down).
    static func drawGlass(_ ctx: CGContext, _ glass: Glass?, frame: CGRect, canvasHeight: CGFloat) {
        guard let glass else { return }
        // The canvas is y-down here; draw the backdrop so the sprite's window area lines up.
        let k = CGFloat(glass.image.width) / glass.size.width
        let src = CGRect(x: frame.minX * k, y: frame.minY * k, width: frame.width * k, height: frame.height * k).integral
        guard let piece = glass.image.cropping(to: src) else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasHeight)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(piece, in: CGRect(x: 0, y: canvasHeight - frame.height, width: frame.width, height: frame.height))
        ctx.restoreGState()
    }

    static func tintAlpha(_ dark: Bool, boost: Double = 0) -> Double { min(255, (dark ? 168 : 150) + boost) / 255 }
    static func tintColor(_ dark: Bool, alpha: Double) -> CGColor { dark ? Style.rgb(26, 25, 30, alpha) : Style.rgb(251, 249, 246, alpha) }

    /// Glass, tint and the soft top highlight inside `path` (canvas coordinates, y down).
    static func fillGlass(_ ctx: CGContext, _ path: CGPath, _ L: WheelLayout, dark: Bool, glass: Glass?, frame: CGRect, canvasHeight: CGFloat,
                          boost: Double, tintScale: Double) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        drawGlass(ctx, glass, frame: frame, canvasHeight: canvasHeight)
        let a = tintAlpha(dark, boost: boost) * tintScale
        ctx.setFillColor(tintColor(dark, alpha: a))
        ctx.fill(CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
        let b = path.boundingBox
        let g = Style.linearGradient([Style.white((dark ? 18 : 70) / 255 * a), Style.white(0)])
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])
        ctx.restoreGState()
    }

    // ------------------------------------------------------------------ plate

    /// The soft drop shadow under the plate. Positioned at the wheel center, 10 pt lower.
    static func plateShadow(_ L: WheelLayout, dark: Bool, px: CGFloat) -> Sprite? {
        let r = L.rPlate, outer = r + 34 * L.s
        let side = outer * 2
        guard let ctx = Style.canvas(side, side, px) else { return nil }
        let k = dark ? 0.85 : 0.5
        let colors = [Style.black(58 * k / 255), Style.black(44 * k / 255), Style.black(20 * k / 255), Style.black(6 * k / 255), Style.black(0)]
        let pos: [CGFloat] = [(r - 24 * L.s) / outer, (r - 4 * L.s) / outer, (r + 8 * L.s) / outer, (r + 20 * L.s) / outer, 1]
        let g = Style.linearGradient(colors, pos)
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: outer, y: outer), startRadius: 0, endCenter: CGPoint(x: outer, y: outer), endRadius: outer, options: [])
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: CGSize(width: side, height: side), anchor: CGPoint(x: 0.5, y: 0.5))
    }

    /// Plate glass tint, highlight and hairlines. `tintScale` < 1 when real vibrancy is underneath.
    static func plate(_ L: WheelLayout, dark: Bool, glass: Glass?, tintScale: Double, px: CGFloat) -> Sprite? {
        let r = L.rPlate
        let m = 2 * L.s
        let side = (r + m) * 2
        guard let ctx = Style.canvas(side, side, px) else { return nil }
        Style.flipDown(ctx, height: side)
        let c = CGPoint(x: r + m, y: r + m)
        let circle = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        let frame = CGRect(x: L.cx - r - m, y: L.cy - r - m, width: side, height: side)
        fillGlass(ctx, circle, L, dark: dark, glass: glass, frame: frame, canvasHeight: side, boost: 0, tintScale: tintScale)

        // Hairlines: a bright inner rim and a faint outer edge for definition on any wallpaper.
        ctx.saveGState()
        ctx.setLineWidth(1.2 * L.s)
        ctx.addEllipse(in: CGRect(x: c.x - r + 0.6 * L.s, y: c.y - r + 0.6 * L.s, width: 2 * (r - 0.6 * L.s), height: 2 * (r - 0.6 * L.s)))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rim = Style.linearGradient(dark ? [Style.white(14 / 255), Style.white(4 / 255)] : [Style.white(45 / 255), Style.white(18 / 255)])
        ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: c.y - r), end: CGPoint(x: 0, y: c.y + r), options: [])
        ctx.restoreGState()
        ctx.setLineWidth(1 * L.s)
        ctx.setStrokeColor(dark ? Style.black(90 / 255) : Style.black(20 / 255))
        ctx.strokeEllipse(in: CGRect(x: c.x - r - 0.5 * L.s, y: c.y - r - 0.5 * L.s, width: 2 * (r + 0.5 * L.s), height: 2 * (r + 0.5 * L.s)))
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: CGSize(width: side, height: side), anchor: CGPoint(x: 0.5, y: 0.5))
    }

    // ------------------------------------------------------------------ segments

    /// The canvas every segment sprite shares: the path's bounds plus room for the glow.
    static func segmentBox(_ L: WheelLayout, _ path: CGPath) -> CGRect { path.boundingBoxOfPath.insetBy(dx: -28 * L.s, dy: -28 * L.s) }

    static func segmentPath(_ L: WheelLayout, n: Int) -> CGPath {
        let span = 360 / CGFloat(n)
        return WheelGeometry.segment(a0: -span / 2, a1: span / 2, r: L.rIn, R: L.r, g: L.gap, fo: L.filletOuter, fi: L.filletInner)
    }

    /// Sets up a canvas for `box` (path coordinates, y down) and returns it with the anchor of the path's origin.
    static func segmentCanvas(_ box: CGRect, px: CGFloat) -> (CGContext, CGPoint)? {
        guard let ctx = Style.canvas(box.width, box.height, px) else { return nil }
        Style.flipDown(ctx, height: box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        // Unit anchor, y up: x from the left, y from the bottom.
        let anchor = CGPoint(x: -box.minX / box.width, y: 1 - (-box.minY / box.height))
        return (ctx, anchor)
    }

    static func segmentIdle(_ L: WheelLayout, n: Int, dark: Bool, px: CGFloat) -> Sprite? {
        let path = segmentPath(L, n: n), box = segmentBox(L, path)
        guard let canvas = segmentCanvas(box, px: px) else { return nil }
        let (ctx, anchor) = canvas
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let fill = Style.linearGradient(dark ? [Style.white(22 / 255), Style.white(11 / 255)] : [Style.white(100 / 255), Style.white(62 / 255)])
        ctx.drawLinearGradient(fill, start: CGPoint(x: L.r, y: 0), end: CGPoint(x: L.rIn, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        bevel(ctx, path, L, outer: dark ? 18 : 40, inner: dark ? 4 : 14)
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: box.size, anchor: anchor)
    }

    static func segmentHover(_ L: WheelLayout, n: Int, dark: Bool, px: CGFloat) -> Sprite? {
        let path = segmentPath(L, n: n), box = segmentBox(L, path)
        guard let canvas = segmentCanvas(box, px: px) else { return nil }
        let (ctx, anchor) = canvas
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let fill = Style.linearGradient([Style.with(Style.accentLight, alpha: 130 / 255), Style.with(Style.accentDeep, alpha: 130 / 255)])
        ctx.drawLinearGradient(fill, start: CGPoint(x: L.r, y: -L.r * 0.3), end: CGPoint(x: L.rIn, y: L.r * 0.3),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        bevel(ctx, path, L, outer: 60, inner: dark ? 4 : 14)
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: box.size, anchor: anchor)
    }

    static func bevel(_ ctx: CGContext, _ path: CGPath, _ L: WheelLayout, outer: Double, inner: Double) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(1 * L.s)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let g = Style.linearGradient([Style.white(outer / 255), Style.white(inner / 255)])
        ctx.drawLinearGradient(g, start: CGPoint(x: L.r, y: 0), end: CGPoint(x: L.rIn, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Soft accent glow behind the hovered segment.
    static func segmentGlow(_ L: WheelLayout, n: Int, px: CGFloat) -> Sprite? {
        let path = segmentPath(L, n: n), box = segmentBox(L, path)
        guard let canvas = segmentCanvas(box, px: px) else { return nil }
        let (ctx, anchor) = canvas
        ctx.addPath(path)
        ctx.setFillColor(Style.with(Style.accent, alpha: 120 / 255))
        ctx.fillPath()
        guard let shape = ctx.makeImage() else { return nil }
        let sigma = Double(9 * L.s * px)
        let input = CIImage(cgImage: shape)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let img = blurContext.createCGImage(blurred, from: input.extent) else { return nil }
        return Sprite(image: img, size: box.size, anchor: anchor)
    }

    // ------------------------------------------------------------------ labels

    static func labelColors(dark: Bool) -> (base: CGColor, hover: CGColor) {
        let base = dark ? Style.rgb(244, 240, 236, 0.94) : Style.rgb(43, 36, 31, 0.9)
        return (base, Style.white(dark ? 0.94 : 1))
    }

    /// The segment's label (and icon), upright, centered on the anchor.
    static func label(_ item: WheelItem, n: Int, _ L: WheelLayout, color: CGColor, px: CGFloat) -> Sprite? {
        let arc = 2 * .pi * ((L.r + L.rIn) / 2) / CGFloat(n) - 2 * L.gap
        let maxW = min(arc * 0.84, (L.r - L.rIn) * 0.98)
        let w = max(maxW, 20 * L.s) + 8 * L.s, h = 56 * L.s
        guard let ctx = Style.canvas(w, h, px) else { return nil }
        let cx = w / 2, cy = h / 2
        let text = item.label.uppercased()
        if let glyph = item.glyph {
            let fitted = Style.fit(text, size: 10.5 * L.s, weight: .semibold, maxWidth: maxW, minSize: 8 * L.s, spacing: 0.5 * L.s)
            Style.drawSymbol(ctx, glyph, size: 17 * L.s, weight: .medium, color: color, center: CGPoint(x: cx, y: cy + 8.5 * L.s))
            Style.drawCentered(ctx, fitted.text, fitted.font, color, x: cx, baseline: cy - 15 * L.s, spacing: fitted.spacing)
        } else {
            let fitted = Style.fit(text, size: (n > 8 ? 13.5 : 15) * L.s, weight: .bold, maxWidth: maxW, minSize: 9 * L.s, spacing: 0.6 * L.s)
            let baseline = cy - (Style.ascent(fitted.font) - Style.descent(fitted.font)) / 2
            Style.drawCentered(ctx, fitted.text, fitted.font, color, x: cx, baseline: baseline, spacing: fitted.spacing)
        }
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: CGSize(width: w, height: h), anchor: CGPoint(x: 0.5, y: 0.5))
    }

    // ------------------------------------------------------------------ hub

    static func hubDisc(_ L: WheelLayout, dark: Bool, glass: Glass?, tintScale: Double, px: CGFloat) -> Sprite? {
        let r = L.rHub
        let m = 16 * L.s
        let side = (r + m) * 2
        guard let ctx = Style.canvas(side, side, px) else { return nil }
        Style.flipDown(ctx, height: side)
        let c = CGPoint(x: r + m, y: r + m)
        let circleRect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        // Hub drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10 * L.s * px, color: Style.black((dark ? 70 : 26) / 255))
        ctx.setFillColor(Style.black((dark ? 70 : 26) / 255))
        ctx.fillEllipse(in: circleRect.offsetBy(dx: 0, dy: 2.5 * L.s))
        ctx.restoreGState()
        let circle = CGPath(ellipseIn: circleRect, transform: nil)
        let frame = CGRect(x: L.cx - r - m, y: L.cy - r - m, width: side, height: side)
        // The shadow above also darkens the hub area; clear it before the glass goes on.
        ctx.saveGState()
        ctx.addPath(circle)
        ctx.clip()
        ctx.clear(circleRect.insetBy(dx: -1, dy: -1))
        ctx.restoreGState()
        fillGlass(ctx, circle, L, dark: dark, glass: glass, frame: frame, canvasHeight: side, boost: dark ? 40 : 75, tintScale: tintScale)
        ctx.saveGState()
        ctx.addPath(circle)
        ctx.clip()
        let g = Style.linearGradient(dark ? [Style.white(16 / 255), Style.white(5 / 255)] : [Style.white(132 / 255), Style.white(79 / 255)])
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: c.y - r), end: CGPoint(x: 0, y: c.y + r), options: [])
        ctx.restoreGState()
        ctx.setLineWidth(1 * L.s)
        ctx.setStrokeColor(dark ? Style.white(34 / 255) : Style.white(240 / 255))
        ctx.strokeEllipse(in: circleRect.insetBy(dx: 0.5 * L.s, dy: 0.5 * L.s))
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: CGSize(width: side, height: side), anchor: CGPoint(x: 0.5, y: 0.5))
    }

    /// Hub caption over a bold title, each fitted to the circle's width at its own height.
    static func hubText(caption: String, title: String, accent: Bool, _ L: WheelLayout, dark: Bool, px: CGFloat) -> Sprite? {
        let hub = L.rHub, pad = 9 * L.s
        let side = hub * 2
        guard let ctx = Style.canvas(side, side, px) else { return nil }
        let cap = caption.uppercased()
        let hasCaption = !cap.isEmpty
        // Baselines measured downward from the center, as on Windows.
        let capBase = -9 * L.s, titleBase = (hasCaption ? 10 : 6) * L.s
        func chord(_ radius: CGFloat, _ offset: CGFloat) -> CGFloat { offset >= radius ? 0 : 2 * (radius * radius - offset * offset).squareRoot() }
        let capProbe = Style.font(9 * L.s, .semibold), titleProbe = Style.font(17 * L.s, .bold)
        let capRoom = chord(hub, abs(capBase - Style.capHeight(capProbe))) - 2 * pad
        let titleRoom = chord(hub, max(abs(titleBase - Style.ascent(titleProbe) * 0.85), titleBase + Style.descent(titleProbe))) - 2 * pad
        let capFit = Style.fit(cap, size: 9 * L.s, weight: .semibold, maxWidth: capRoom, minSize: 7 * L.s, spacing: 1.1 * L.s)
        let titleFit = Style.fit(title, size: 17 * L.s, weight: .bold, maxWidth: titleRoom, minSize: 10.5 * L.s, spacing: 0)
        let secondary = dark ? Style.rgb(176, 168, 160) : Style.rgb(125, 116, 108)
        let primary = dark ? Style.rgb(246, 242, 238) : Style.rgb(38, 32, 28)
        if hasCaption { Style.drawCentered(ctx, capFit.text, capFit.font, secondary, x: hub, baseline: hub - capBase, spacing: capFit.spacing) }
        let titleColor = accent ? (dark ? Style.accentLight : Style.accentDeep) : primary
        Style.drawCentered(ctx, titleFit.text, titleFit.font, titleColor, x: hub, baseline: hub - titleBase)
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: CGSize(width: side, height: side), anchor: CGPoint(x: 0.5, y: 0.5))
    }

    // ------------------------------------------------------------------ key hint chips

    struct Chip { let kind: WheelKind; let key: String; let label: String }

    struct HintLayout {
        let chips: [Chip]
        let widths: [CGFloat]
        let lefts: [CGFloat]
        let total: CGFloat
        let height: CGFloat
        let chipHeight: CGFloat
    }

    static func hintLayout(_ L: WheelLayout, chips: [Chip]) -> HintLayout {
        let keyFont = Style.font(9.5 * L.s, .semibold), labelFont = Style.font(11 * L.s, .semibold)
        let padX = 10 * L.s, capPad = 5 * L.s, gapInChip = 6 * L.s, gapBetween = 4 * L.s, h = 26 * L.s
        let widths = chips.map { capPad * 2 + Style.width($0.key, keyFont) + gapInChip + Style.width($0.label, labelFont) + padX * 2 }
        let total = widths.reduce(0, +) + gapBetween * CGFloat(max(0, chips.count - 1)) + 6 * L.s
        var lefts: [CGFloat] = []
        var x = 3 * L.s
        for w in widths { lefts.append(x); x += w + gapBetween }
        return HintLayout(chips: chips, widths: widths, lefts: lefts, total: total, height: h + 6 * L.s, chipHeight: h)
    }

    /// The frosted pill behind the chips; `frame` is its rect in window points (y down) for the glass.
    static func hintPill(_ L: WheelLayout, _ H: HintLayout, dark: Bool, glass: Glass?, frame: CGRect, tintScale: Double, px: CGFloat) -> Sprite? {
        let m = 14 * L.s
        let w = H.total + 2 * m, h = H.height + 2 * m
        guard let ctx = Style.canvas(w, h, px) else { return nil }
        Style.flipDown(ctx, height: h)
        let rect = CGRect(x: m, y: m, width: H.total, height: H.height)
        let pill = CGPath(roundedRect: rect, cornerWidth: H.height / 2, cornerHeight: H.height / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 12 * L.s * px, color: Style.black((dark ? 60 : 22) / 255))
        ctx.addPath(pill)
        ctx.setFillColor(Style.black((dark ? 60 : 22) / 255))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(pill)
        ctx.clip()
        ctx.clear(rect)
        ctx.restoreGState()
        fillGlass(ctx, pill, L, dark: dark, glass: glass, frame: frame.insetBy(dx: -m, dy: -m), canvasHeight: h, boost: 30, tintScale: tintScale)
        ctx.addPath(pill)
        ctx.setLineWidth(1 * L.s)
        ctx.setStrokeColor(dark ? Style.white(30 / 255) : Style.white(220 / 255))
        ctx.strokePath()
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: CGSize(width: w, height: h), anchor: CGPoint(x: 0.5, y: 0.5))
    }

    static func hintHighlight(_ L: WheelLayout, width: CGFloat, height: CGFloat, dark: Bool, px: CGFloat) -> Sprite? {
        guard let ctx = Style.canvas(width, height, px) else { return nil }
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        ctx.setFillColor(dark ? Style.white(26 / 255) : Style.white(230 / 255))
        ctx.fillPath()
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: CGSize(width: width, height: height), anchor: CGPoint(x: 0.5, y: 0.5))
    }

    /// Key caps and labels for all chips, with `active` drawn highlighted. Same size and origin as the pill rect.
    static func hintChips(_ L: WheelLayout, _ H: HintLayout, active: WheelKind?, dark: Bool, px: CGFloat) -> Sprite? {
        let w = H.total, h = H.height
        guard let ctx = Style.canvas(w, h, px) else { return nil }
        let keyFont = Style.font(9.5 * L.s, .semibold), labelFont = Style.font(11 * L.s, .semibold)
        let padX = 10 * L.s, capPad = 5 * L.s, gapInChip = 6 * L.s
        let midY = h / 2 // y up; the pill is symmetric
        for (i, chip) in H.chips.enumerated() {
            let isActive = chip.kind == active
            let x0 = H.lefts[i] + padX
            let keyW = Style.width(chip.key, keyFont) + capPad * 2
            let cap = CGRect(x: x0, y: midY - 8.5 * L.s, width: keyW, height: 17 * L.s)
            let capPath = CGPath(roundedRect: cap, cornerWidth: 4.5 * L.s, cornerHeight: 4.5 * L.s, transform: nil)
            let keyColor: CGColor
            if isActive {
                ctx.saveGState()
                ctx.addPath(capPath)
                ctx.clip()
                // Top-left to bottom-right.
                ctx.drawLinearGradient(Style.linearGradient([Style.accentLight, Style.accentDeep]), start: CGPoint(x: cap.minX, y: cap.maxY),
                                       end: CGPoint(x: cap.maxX, y: cap.minY), options: [])
                ctx.restoreGState()
                keyColor = Style.white(1)
            } else {
                ctx.addPath(capPath)
                ctx.setLineWidth(1 * L.s)
                ctx.setStrokeColor(dark ? Style.white(60 / 255) : Style.black(40 / 255))
                ctx.strokePath()
                keyColor = dark ? Style.rgb(200, 194, 188) : Style.rgb(110, 102, 95)
            }
            let keyBase = midY - (Style.ascent(keyFont) - Style.descent(keyFont)) / 2
            Style.drawCentered(ctx, chip.key, keyFont, keyColor, x: cap.midX, baseline: keyBase)
            let labelColor = isActive ? (dark ? Style.rgb(250, 246, 242) : Style.rgb(38, 32, 28)) : (dark ? Style.rgb(176, 168, 160) : Style.rgb(120, 112, 105))
            let labelBase = midY - (Style.ascent(labelFont) - Style.descent(labelFont)) / 2
            Style.drawLeft(ctx, chip.label, labelFont, labelColor, x: cap.maxX + gapInChip, baseline: labelBase)
        }
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: img, size: CGSize(width: w, height: h), anchor: CGPoint(x: 0.5, y: 0.5))
    }

    // ------------------------------------------------------------------ test backdrop

    /// The render tests' stand-in for the desktop: a gradient with a few "icons", plus its frosted version
    /// (quarter resolution, blur sigma 7, saturation 1.45, like the Windows backdrop).
    static func testBackdrop(width: CGFloat, height: CGFloat, dark: Bool, px: CGFloat) -> (wallpaper: CGImage, glass: Glass)? {
        guard let ctx = Style.canvas(width, height, px) else { return nil }
        let colors = dark ? [Style.rgb(0x1B, 0x22, 0x3A), Style.rgb(0x3A, 0x1D, 0x4A), Style.rgb(0x0E, 0x12, 0x20)]
                          : [Style.rgb(0xFF, 0xB8, 0x6B), Style.rgb(0xF2, 0x5C, 0x54), Style.rgb(0x7B, 0x5C, 0xF0)]
        ctx.drawLinearGradient(Style.linearGradient(colors), start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        var seed: UInt64 = 4
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(max(1, n))) }
        for _ in 0..<14 {
            ctx.setFillColor(Style.rgb(150 + next(105), 150 + next(105), 150 + next(105), 230 / 255))
            let x = CGFloat(next(Int(width))), y = CGFloat(next(Int(height)))
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 35, height: 43), cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        guard let wallpaper = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: wallpaper)
        let small = input.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 7).cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.45])
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        guard let frosted = blurContext.createCGImage(blurred, from: input.extent) else { return nil }
        return (wallpaper, Glass(image: frosted, size: CGSize(width: width, height: height)))
    }
}
