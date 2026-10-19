import AppKit
import CoreText
import SatsumaCore

/// Colors, fonts and text helpers shared by the wheel, the bubble and the icon.
enum Style {
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a))
    }
    static func white(_ a: Double) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: CGFloat(a)) }
    static func black(_ a: Double) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CGFloat(a)) }

    static let accent = rgb(0xFF, 0x7A, 0x1A)
    static let accentLight = rgb(0xFF, 0xB0, 0x52)
    static let accentDeep = rgb(0xFF, 0x5A, 0x14)
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func with(_ c: CGColor, alpha: Double) -> CGColor { c.copy(alpha: CGFloat(alpha)) ?? c }

    static func lerp(_ a: CGColor, _ b: CGColor, _ t: Double) -> CGColor {
        let ca = a.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        let cb = b.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        let k = CGFloat(Ease.clamp01(t))
        return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * k, green: ca[1] + (cb[1] - ca[1]) * k,
                       blue: ca[2] + (cb[2] - ca[2]) * k, alpha: ca[3] + (cb[3] - ca[3]) * k)
    }

    enum Weight { case regular, semibold, bold }

    static func font(_ size: CGFloat, _ weight: Weight) -> CTFont {
        let w: NSFont.Weight = weight == .bold ? .bold : weight == .semibold ? .semibold : .regular
        return NSFont.systemFont(ofSize: size, weight: w) as CTFont
    }

    static func line(_ text: String, _ font: CTFont, _ color: CGColor, spacing: CGFloat = 0) -> CTLine {
        let attr = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        if spacing > 0.01 && attr.length > 1 {
            // Letter spacing between characters, none after the last one.
            attr.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: spacing, range: NSRange(location: 0, length: attr.length - 1))
        }
        return CTLineCreateWithAttributedString(attr)
    }

    static func width(_ text: String, _ font: CTFont, spacing: CGFloat = 0) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font, black(1), spacing: spacing), nil, nil, nil))
    }

    struct Fitted { let text: String; let font: CTFont; let spacing: CGFloat }

    /// Makes text fit `maxWidth`: first tightens the letter spacing, then shrinks the font down to `minSize`,
    /// and only then cuts it short with an ellipsis.
    static func fit(_ text: String, size: CGFloat, weight: Weight, maxWidth: CGFloat, minSize: CGFloat, spacing: CGFloat) -> Fitted {
        var f = font(size, weight)
        if maxWidth <= 0 || width(text, f, spacing: spacing) <= maxWidth { return Fitted(text: text, font: f, spacing: spacing) }
        var sp = spacing
        while sp > 0.01 && width(text, f, spacing: sp) > maxWidth { sp = max(0, sp - spacing * 0.25) }
        var s = size
        while s > minSize && width(text, f, spacing: sp) > maxWidth {
            s = max(minSize, s - 0.5)
            f = font(s, weight)
        }
        if width(text, f, spacing: sp) <= maxWidth { return Fitted(text: text, font: f, spacing: sp) }
        var cut = text
        while cut.count > 1 && width(cut + "…", f, spacing: sp) > maxWidth { cut.removeLast() }
        while cut.last == " " { cut.removeLast() }
        return Fitted(text: cut + "…", font: f, spacing: sp)
    }

    /// Draws text centered on x with its baseline at y (Core Graphics coordinates, y up).
    static func drawCentered(_ ctx: CGContext, _ text: String, _ font: CTFont, _ color: CGColor, x: CGFloat, baseline y: CGFloat, spacing: CGFloat = 0) {
        let l = line(text, font, color, spacing: spacing)
        let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x - w / 2, y: y)
        CTLineDraw(l, ctx)
    }

    static func drawLeft(_ ctx: CGContext, _ text: String, _ font: CTFont, _ color: CGColor, x: CGFloat, baseline y: CGFloat) {
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line(text, font, color), ctx)
    }

    static func ascent(_ f: CTFont) -> CGFloat { CTFontGetAscent(f) }
    static func descent(_ f: CTFont) -> CGFloat { CTFontGetDescent(f) }
    static func capHeight(_ f: CTFont) -> CGFloat { CTFontGetCapHeight(f) }

    /// Draws an SF Symbol tinted with `color`, centered at `center`, `size` points tall.
    static func drawSymbol(_ ctx: CGContext, _ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: CGColor, center: CGPoint) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color) ?? .black]))
        guard let image = base.withSymbolConfiguration(config) else { return }
        let s = image.size
        let rect = CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A bitmap context in points: `width` x `height` points at `pixelScale` pixels per point.
    static func canvas(_ width: CGFloat, _ height: CGFloat, _ pixelScale: CGFloat) -> CGContext? {
        let w = max(1, Int(ceil(width * pixelScale))), h = max(1, Int(ceil(height * pixelScale)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        return ctx
    }

    /// Flips a points canvas so drawing uses y-down coordinates, like the Windows renderer.
    static func flipDown(_ ctx: CGContext, height: CGFloat) {
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
    }

    static func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
    }
}
