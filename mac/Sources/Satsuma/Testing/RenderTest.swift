import AppKit
import SatsumaCore

/// Renders wheel frames to PNG for visual checks. (For now: the segment geometry for several segment counts.)
enum RenderTest {
    static func run(_ dir: String) async throws -> [String] {
        try P.createDir(dir)
        var files: [String] = []
        for n in [3, 6, 8, 9, 12] {
            let scale: CGFloat = 2
            let L = WheelLayout(scale: scale, showHints: false)
            let w = Int(L.width), h = Int(L.height)
            guard let ctx = ImageConverter.context(width: w, height: h) else { continue }
            // Flip so the geometry's y-down coordinates draw the right way up.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.94, blue: 0.92, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let span = 360 / CGFloat(n)
            let path = WheelGeometry.segment(a0: -span / 2, a1: span / 2, r: L.rIn, R: L.r, g: L.gap, fo: L.filletOuter, fi: L.filletInner)
            for i in 0..<n {
                ctx.saveGState()
                ctx.translateBy(x: L.cx, y: L.cy)
                ctx.rotate(by: WheelLayout.midAngle(i, n) * .pi / 180)
                ctx.addPath(path)
                ctx.setFillColor(i == 1 ? CGColor(srgbRed: 1, green: 0.48, blue: 0.1, alpha: 1) : CGColor(srgbRed: 0.3, green: 0.28, blue: 0.26, alpha: 0.35))
                ctx.fillPath()
                ctx.restoreGState()
            }
            guard let img = ctx.makeImage() else { continue }
            let out = P.join(dir, "geometry-\(n).png")
            try ImageConverter.write(img, to: out, type: "public.png")
            files.append(out)
        }
        return files
    }
}
