import Foundation
import CoreGraphics

/// All wheel dimensions in points for a given scale. Coordinates are y-down (flipped views), matching the
/// Windows app: angles are degrees clockwise from 3 o'clock and segment 0 sits at 12 o'clock.
public struct WheelLayout {
    public let s: CGFloat
    public let r: CGFloat, rIn: CGFloat, rPlate: CGFloat, rHub: CGFloat, gap: CGFloat
    public let filletOuter: CGFloat, filletInner: CGFloat, hitRadius: CGFloat
    public let width: CGFloat, height: CGFloat
    public let cx: CGFloat, cy: CGFloat
    public let showHints: Bool

    public init(scale: CGFloat = 1, showHints: Bool) {
        s = scale
        self.showHints = showHints
        r = 150 * scale
        rIn = 64 * scale
        rPlate = r + 9 * scale
        rHub = rIn - 8 * scale
        gap = 5 * scale
        filletOuter = 12 * scale
        filletInner = 7 * scale
        hitRadius = r + 46 * scale
        let half = hitRadius + 4 * scale
        width = ceil(half * 2)
        cx = width / 2
        cy = half
        let bottom = showHints ? cy + rPlate + 52 * scale : cy + half
        height = ceil(max(bottom, cy + half))
    }

    /// Center angle of segment i of n.
    public static func midAngle(_ i: Int, _ n: Int) -> CGFloat { -90 + CGFloat(i) * 360 / CGFloat(n) }

    /// Index of the segment under a point (y-down, relative to the wheel's top-left), -1 for the hub,
    /// -2 for outside the magnetic zone.
    public func hitTest(_ x: CGFloat, _ y: CGFloat, _ n: Int) -> Int {
        let dx = x - cx, dy = y - cy
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist < rIn - 2 * s { return -1 }
        if dist > hitRadius || n == 0 { return -2 }
        var ang = atan2(dy, dx) * 180 / .pi + 90 // 0 at the top, clockwise
        let span = 360 / CGFloat(n)
        ang = ((ang + span / 2).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return min(max(Int(ang / span), 0), n - 1)
    }
}

public enum WheelGeometry {
    static let deg = 180 / CGFloat.pi

    /// A ring segment from angle a0 to a1 (degrees) between radii r and R, with parallel gaps of width g and
    /// tangent rounded corners (fo outside, fi inside), centered on the origin.
    public static func segment(a0: CGFloat, a1: CGFloat, r: CGFloat, R: CGFloat, g: CGFloat, fo foIn: CGFloat, fi fiIn: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let span = a1 - a0
        if span >= 359.9 {
            path.addArc(center: .zero, radius: R, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            path.move(to: CGPoint(x: r, y: 0))
            path.addArc(center: .zero, radius: r, startAngle: 2 * .pi, endAngle: 0, clockwise: true)
            path.closeSubpath()
            return path
        }
        let t0 = a0 / deg, t1 = a1 / deg
        let u0 = CGPoint(x: cos(t0), y: sin(t0)), n0 = CGPoint(x: -sin(t0), y: cos(t0)) // into the segment from edge 0
        let u1 = CGPoint(x: cos(t1), y: sin(t1)), n1 = CGPoint(x: sin(t1), y: -cos(t1)) // into the segment from edge 1
        let h = g / 2

        // Shrink fillets if the segment is too narrow for them.
        let half = min(span, 170) / 2 / deg
        let fo = max(0.5, min(foIn, (R * sin(half) - h) * 0.9))
        let fi = max(0.5, min(fiIn, max(0.5, (r * sin(half) - h) * 0.9)))

        func outer(_ u: CGPoint, _ n: CGPoint) -> (center: CGPoint, onEdge: CGPoint, onCircle: CGPoint) {
            let a = max(0, (R - fo) * (R - fo) - (h + fo) * (h + fo)).squareRoot()
            let c = u * a + n * (h + fo)
            return (c, u * a + n * h, c * (R / (R - fo)))
        }
        func inner(_ u: CGPoint, _ n: CGPoint) -> (center: CGPoint, onEdge: CGPoint, onCircle: CGPoint) {
            let b = max(0, (r + fi) * (r + fi) - (h + fi) * (h + fi)).squareRoot()
            let c = u * b + n * (h + fi)
            return (c, u * b + n * h, c * (r / (r + fi)))
        }

        let o0 = outer(u0, n0), o1 = outer(u1, n1)
        let i0 = inner(u0, n0), i1 = inner(u1, n1)

        path.move(to: i0.onEdge)
        path.addLine(to: o0.onEdge)
        fillet(path, o0.center, fo, o0.onEdge, o0.onCircle)
        arcAroundOrigin(path, R, o0.onCircle, o1.onCircle, increasing: true)
        fillet(path, o1.center, fo, o1.onCircle, o1.onEdge)
        path.addLine(to: i1.onEdge)
        fillet(path, i1.center, fi, i1.onEdge, i1.onCircle)
        arcAroundOrigin(path, r, i1.onCircle, i0.onCircle, increasing: false)
        fillet(path, i0.center, fi, i0.onCircle, i0.onEdge)
        path.closeSubpath()
        return path
    }

    static func angleOf(_ p: CGPoint) -> CGFloat { atan2(p.y, p.x) * deg }

    /// Adds an arc from `from` to `to` around `c`, taking the short way round.
    static func fillet(_ path: CGMutablePath, _ c: CGPoint, _ radius: CGFloat, _ from: CGPoint, _ to: CGPoint) {
        let s = angleOf(from - c), e = angleOf(to - c)
        var sweep = e - s
        while sweep > 180 { sweep -= 360 }
        while sweep <= -180 { sweep += 360 }
        path.addArc(center: c, radius: radius, startAngle: s / deg, endAngle: (s + sweep) / deg, clockwise: sweep < 0)
    }

    /// Adds an arc around the origin; `increasing` sweeps toward larger angles (clockwise on a y-down screen).
    static func arcAroundOrigin(_ path: CGMutablePath, _ radius: CGFloat, _ from: CGPoint, _ to: CGPoint, increasing: Bool) {
        let s = angleOf(from), e = angleOf(to)
        var sweep = e - s
        if increasing {
            while sweep <= 0 { sweep += 360 }
            while sweep > 360 { sweep -= 360 }
        } else {
            while sweep >= 0 { sweep -= 360 }
            while sweep < -360 { sweep += 360 }
        }
        path.addArc(center: .zero, radius: radius, startAngle: s / deg, endAngle: (s + sweep) / deg, clockwise: sweep < 0)
    }
}

extension CGPoint {
    static func * (p: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}
