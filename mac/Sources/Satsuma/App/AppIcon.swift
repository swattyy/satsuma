import AppKit
import SatsumaCore

/// The app icon (a dark tile with the wheel, one segment orange) and the monochrome menu bar icon,
/// drawn with the same segment geometry as the wheel.
enum AppIcon {
    /// `size` pixels square. `tray` draws the bare wheel without the tile.
    static func render(size: Int, tray: Bool, enabled: Bool = true, template: Bool = false) -> CGImage? {
        let s = CGFloat(size) / 64
        guard let ctx = Style.canvas(CGFloat(size), CGFloat(size), 1) else { return nil }
        Style.flipDown(ctx, height: CGFloat(size))
        if !tray {
            // Rounded tile with a warm dark gradient (macOS icon grid: 824/1024 of the canvas).
            let inset = CGFloat(size) * 100 / 1024
            let tile = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
            let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: CGFloat(size) * 0.012), blur: CGFloat(size) * 0.03, color: Style.black(0.35))
            ctx.addPath(path)
            ctx.setFillColor(Style.rgb(0x20, 0x1C, 0x1A))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(Style.linearGradient([Style.rgb(0x2B, 0x26, 0x23), Style.rgb(0x17, 0x14, 0x12)]),
                                   start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
            ctx.restoreGState()
        }
        let cx = CGFloat(size) / 2, cy = CGFloat(size) / 2
        let R = (tray ? 30 : 20) * s, r = (tray ? 12 : 8.7) * s
        let n = 6
        let span = 360 / CGFloat(n)
        let seg = WheelGeometry.segment(a0: -span / 2, a1: span / 2, r: r, R: R, g: max(1.2, (tray ? 3.4 : 2.2) * s), fo: (tray ? 5 : 4) * s, fi: 2 * s)
        for i in 0..<n {
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: (-90 + CGFloat(i) * span) * .pi / 180)
            ctx.addPath(seg)
            if template {
                ctx.setFillColor(Style.black(enabled ? (i == 1 ? 1 : 0.45) : 0.3))
                ctx.fillPath()
            } else if i == 1 && enabled {
                ctx.clip()
                ctx.drawLinearGradient(Style.linearGradient([Style.accentLight, Style.accentDeep]), start: CGPoint(x: R, y: -R * 0.4),
                                       end: CGPoint(x: r, y: R * 0.4), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                ctx.setFillColor(Style.white(enabled ? 215 / 255 : 120 / 255))
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func menuBarImage(enabled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for scale in [1, 2] {
            if let cg = render(size: 18 * scale, tray: true, enabled: enabled, template: true) {
                let rep = NSBitmapImageRep(cgImage: cg)
                rep.size = NSSize(width: 18, height: 18)
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        return image
    }

    static func appImage(size: CGFloat = 128) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        if let cg = render(size: Int(size * 2), tray: false) {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: size, height: size)
            image.addRepresentation(rep)
        }
        return image
    }

    /// Writes an .iconset folder (for iconutil) with every size macOS asks for.
    static func writeIconset(_ dir: String) throws -> [String] {
        try P.createDir(dir)
        var files: [String] = []
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let img = render(size: px, tray: false) else { continue }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let path = P.join(dir, name)
                try ImageConverter.write(img, to: path, type: "public.png")
                files.append(path)
            }
        }
        return files
    }
}
