import AppKit
import QuartzCore
import SatsumaCore

/// The wheel as a Core Animation layer tree. Sprites are drawn once per open; every frame only sets
/// transforms and opacities from the springs, so Core Animation composites on the GPU and nothing is redrawn.
/// The root layer is y-up and `layout.width` x `layout.height` points; the Windows y-down numbers are mirrored here.
final class WheelLayers {
    let root = CALayer()
    let px: CGFloat
    /// Baked-in glass for offscreen renders; nil when real vibrancy views sit underneath.
    var glass: Glass?
    var tintScale: Double

    private let shadow = CALayer(), plate = CALayer(), hubDisc = CALayer()
    /// The plate's shadow. The live wheel hosts it below the vibrancy view so it can't darken the glass.
    var shadowLayer: CALayer { shadow }
    private let hubFrom = CALayer(), hubTo = CALayer()
    private let segmentsHost = CALayer()
    let hintPill = CALayer()
    private let hintHighlight = CALayer(), hintChips = CALayer()

    private final class SegLayers {
        let container = CALayer(), glow = CALayer(), idle = CALayer(), hover = CALayer()
        let labelHolder = CALayer(), labelBase = CALayer(), labelHover = CALayer()
        var n = 0
    }
    private var segLayers: [ObjectIdentifier: SegLayers] = [:]

    private var layoutKey = ""
    private var shapeSprites: [Int: (idle: Sprite, hover: Sprite, glow: Sprite)] = [:]
    private var hubFromText = HubText(), hubToText = HubText()
    private var hubTextCache: [String: Sprite] = [:]
    private var hint: WheelSprites.HintLayout?
    private var hintActive: WheelKind?
    private var hintKeys = ""

    init(px: CGFloat, glass: Glass?, tintScale: Double) {
        self.px = px
        self.glass = glass
        self.tintScale = tintScale
        for l in [shadow, plate, segmentsHost, hubDisc, hubFrom, hubTo, hintPill, hintHighlight, hintChips] {
            l.contentsScale = px
            l.actions = WheelLayers.noActions
        }
        root.actions = WheelLayers.noActions
        root.addSublayer(shadow)
        root.addSublayer(plate)
        root.addSublayer(segmentsHost)
        root.addSublayer(hubDisc)
        root.addSublayer(hubFrom)
        root.addSublayer(hubTo)
        root.addSublayer(hintPill)
        hintPill.addSublayer(hintHighlight)
        hintPill.addSublayer(hintChips)
    }

    static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull(),
                                                 "contents": NSNull(), "hidden": NSNull(), "sublayers": NSNull(), "anchorPoint": NSNull()]

    static func apply(_ sprite: Sprite?, to layer: CALayer) {
        guard let sprite else { layer.contents = nil; return }
        layer.contents = sprite.image
        layer.bounds = CGRect(origin: .zero, size: sprite.size)
        layer.anchorPoint = sprite.anchor
    }

    // ------------------------------------------------------------------ building

    /// Redraws the static parts when the scale or theme changes (normally once per open).
    func prepare(_ st: WheelState) {
        let L = st.layout
        let key = "\(L.s)|\(L.showHints)|\(st.dark)|\(glass != nil)"
        root.bounds = CGRect(x: 0, y: 0, width: L.width, height: L.height)
        root.anchorPoint = .zero
        if key == layoutKey { return }
        layoutKey = key
        shapeSprites = [:]
        hubTextCache = [:]
        hubFromText = HubText(caption: "\u{1}", title: "")
        hubToText = hubFromText
        hint = nil
        hintKeys = ""
        WheelLayers.apply(WheelSprites.plateShadow(L, dark: st.dark, px: px), to: shadow)
        WheelLayers.apply(WheelSprites.plate(L, dark: st.dark, glass: glass, tintScale: tintScale, px: px), to: plate)
        WheelLayers.apply(WheelSprites.hubDisc(L, dark: st.dark, glass: glass, tintScale: tintScale, px: px), to: hubDisc)
        for (_, s) in segLayers { s.container.removeFromSuperlayer() }
        segLayers = [:]
    }

    private func shapes(_ st: WheelState, n: Int) -> (idle: Sprite, hover: Sprite, glow: Sprite)? {
        if let s = shapeSprites[n] { return s }
        let L = st.layout
        guard let idle = WheelSprites.segmentIdle(L, n: n, dark: st.dark, px: px),
              let hover = WheelSprites.segmentHover(L, n: n, dark: st.dark, px: px),
              let glow = WheelSprites.segmentGlow(L, n: n, px: px) else { return nil }
        shapeSprites[n] = (idle, hover, glow)
        return (idle, hover, glow)
    }

    private func layers(for seg: SegmentState, n: Int, _ st: WheelState) -> SegLayers {
        let id = ObjectIdentifier(seg)
        if let s = segLayers[id], s.n == n { return s }
        segLayers[id]?.container.removeFromSuperlayer()
        let s = SegLayers()
        s.n = n
        for l in [s.container, s.glow, s.idle, s.hover, s.labelHolder, s.labelBase, s.labelHover] {
            l.contentsScale = px
            l.actions = WheelLayers.noActions
        }
        if let shapes = shapes(st, n: n) {
            WheelLayers.apply(shapes.idle, to: s.container)
            s.container.contents = nil
            for (layer, sprite) in [(s.glow, shapes.glow), (s.idle, shapes.idle), (s.hover, shapes.hover)] {
                WheelLayers.apply(sprite, to: layer)
                layer.anchorPoint = .zero
                layer.position = .zero
                s.container.addSublayer(layer)
            }
            let colors = WheelSprites.labelColors(dark: st.dark)
            WheelLayers.apply(WheelSprites.label(seg.item, n: n, st.layout, color: colors.base, px: px), to: s.labelBase)
            WheelLayers.apply(WheelSprites.label(seg.item, n: n, st.layout, color: colors.hover, px: px), to: s.labelHover)
            s.labelHolder.bounds = s.labelBase.bounds
            s.labelHolder.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            for l in [s.labelBase, s.labelHover] {
                l.anchorPoint = .zero
                l.position = .zero
                s.labelHolder.addSublayer(l)
            }
            s.container.addSublayer(s.labelHolder)
        }
        segmentsHost.addSublayer(s.container)
        segLayers[id] = s
        return s
    }

    private func hubTextSprite(_ t: HubText, _ st: WheelState) -> Sprite? {
        let key = "\(t.caption)\u{0}\(t.title)\u{0}\(t.accent)"
        if let s = hubTextCache[key] { return s }
        let s = WheelSprites.hubText(caption: t.caption, title: t.title, accent: t.accent, st.layout, dark: st.dark, px: px)
        if let s { hubTextCache[key] = s }
        return s
    }

    private func prepareHints(_ st: WheelState) {
        let L = st.layout
        let s = Settings.current
        var chips: [WheelSprites.Chip] = []
        if s.convertKey != .none { chips.append(.init(kind: .convert, key: s.convertKey.symbol, label: "Convert")) }
        if s.toolsKey != .none { chips.append(.init(kind: .tools, key: s.toolsKey.symbol, label: "Tools")) }
        if s.actionsKey != .none { chips.append(.init(kind: .actions, key: s.actionsKey.symbol, label: "Actions")) }
        let keys = chips.map { $0.key + $0.label }.joined(separator: "|")
        if hint != nil && keys == hintKeys && hintActive == st.kind { return }
        if hint == nil || keys != hintKeys {
            hintKeys = keys
            let H = WheelSprites.hintLayout(L, chips: chips)
            hint = H
            let top = L.cy + L.rPlate + 14 * L.s
            let frame = CGRect(x: L.cx - H.total / 2, y: top, width: H.total, height: H.height)
            WheelLayers.apply(chips.isEmpty ? nil : WheelSprites.hintPill(L, H, dark: st.dark, glass: glass, frame: frame, tintScale: tintScale, px: px), to: hintPill)
        }
        hintActive = st.kind
        guard let H = hint, !H.chips.isEmpty else { hintChips.contents = nil; hintHighlight.contents = nil; return }
        WheelLayers.apply(WheelSprites.hintChips(L, H, active: st.kind, dark: st.dark, px: px), to: hintChips)
        hintChips.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        hintChips.position = CGPoint(x: hintPill.bounds.width / 2, y: hintPill.bounds.height / 2)
        if let i = H.chips.firstIndex(where: { $0.kind == st.kind }) {
            WheelLayers.apply(WheelSprites.hintHighlight(L, width: H.widths[i], height: H.chipHeight, dark: st.dark, px: px), to: hintHighlight)
        } else {
            hintHighlight.contents = nil
        }
    }

    // ------------------------------------------------------------------ per frame

    func update(_ st: WheelState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        prepare(st)
        let L = st.layout
        let H = L.height
        func up(_ y: CGFloat) -> CGFloat { H - y }
        let open = CGFloat(st.open.value)
        let fade = Ease.clamp01(st.fade.value) * (1 - 0.35 * st.dim.value)
        root.opacity = Float(fade)
        let plateScale = 0.8 + 0.2 * open
        let center = CGPoint(x: L.cx, y: up(L.cy))

        shadow.position = CGPoint(x: L.cx, y: up(L.cy + 10 * L.s))
        shadow.transform = CATransform3DMakeScale(plateScale, plateScale, 1)
        plate.position = center
        plate.transform = CATransform3DMakeScale(plateScale, plateScale, 1)

        // Segments: the leaving ones (fading out after a wheel switch) and the current ones.
        var live = Set<ObjectIdentifier>()
        for list in [st.leaving, st.segments] {
            let n = list.count
            for (i, seg) in list.enumerated() {
                let s = layers(for: seg, n: n, st)
                live.insert(ObjectIdentifier(seg))
                let appear = seg.appear.value
                if appear <= 0.003 { s.container.isHidden = true; continue }
                s.container.isHidden = false
                let hover = Ease.clamp01(seg.hover.value)
                let press = seg.press.value
                let alpha = Ease.clamp01(appear)
                let angle = Double(WheelLayout.midAngle(i, n)) + st.spin.value + (1 - appear) * -16
                let scale = Double(plateScale) * (0.78 + 0.22 * alpha) * (1 + 0.035 * press)
                let pop = (5 * hover + 3 * press) * Double(L.s)
                let radians = CGFloat(angle * .pi / 180)
                var t = CATransform3DMakeTranslation(CGFloat(pop), 0, 0)
                t = CATransform3DConcat(t, CATransform3DMakeRotation(-radians, 0, 0, 1)) // y is up: clockwise is negative
                t = CATransform3DConcat(t, CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1))
                s.container.position = center
                s.container.transform = t
                s.glow.opacity = hover > 0.01 ? Float(hover * alpha) : 0
                s.idle.opacity = Float(alpha)
                s.hover.opacity = Float(hover * alpha)
                // Label sits midway across the ring and stays upright.
                let bounds = s.container.bounds
                let origin = CGPoint(x: s.container.anchorPoint.x * bounds.width, y: s.container.anchorPoint.y * bounds.height)
                s.labelHolder.position = CGPoint(x: origin.x + (L.r + L.rIn) / 2 + 2 * L.s, y: origin.y)
                s.labelHolder.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
                s.labelBase.opacity = Float((1 - hover) * alpha)
                s.labelHover.opacity = Float(hover * alpha)
            }
        }
        for (id, s) in segLayers where !live.contains(id) {
            s.container.removeFromSuperlayer()
            segLayers[id] = nil
        }

        // Hub: pops in slightly after the plate; its text cross-fades and drifts.
        let pop = CGFloat(st.hubPop.value)
        let hubScale = plateScale * (0.72 + 0.28 * pop)
        hubDisc.isHidden = L.rHub * hubScale <= 1
        hubDisc.position = center
        hubDisc.transform = CATransform3DMakeScale(hubScale, hubScale, 1)
        if st.hubFrom != hubFromText { hubFromText = st.hubFrom; WheelLayers.apply(hubTextSprite(st.hubFrom, st), to: hubFrom) }
        if st.hubTo != hubToText { hubToText = st.hubTo; WheelLayers.apply(hubTextSprite(st.hubTo, st), to: hubTo) }
        let f = CGFloat(Ease.clamp01(st.hubFade.value)), a = CGFloat(Ease.clamp01(Double(pop)))
        hubFrom.opacity = Float((1 - f) * a)
        hubFrom.position = CGPoint(x: L.cx, y: up(L.cy - 5 * L.s * f))
        hubTo.opacity = Float(f * a)
        hubTo.position = CGPoint(x: L.cx, y: up(L.cy + 5 * L.s * (1 - f)))

        // Key hint chips under the wheel, with a sliding highlight behind the active one.
        hintPill.isHidden = !L.showHints
        if L.showHints {
            prepareHints(st)
            if let Hh = hint, !Hh.chips.isEmpty {
                let top = L.cy + L.rPlate + 14 * L.s + (1 - open) * -10 * L.s
                hintPill.position = CGPoint(x: L.cx, y: up(top + Hh.height / 2))
                if let i = Hh.chips.firstIndex(where: { $0.kind == st.kind }) {
                    let target = Double(Hh.lefts[i] + Hh.widths[i] / 2)
                    if st.chipX.target != target {
                        if st.chipX.value == 0 { st.chipX.snap(target) } else { st.chipX.to(target) }
                    }
                    let m = (hintPill.bounds.width - Hh.total) / 2
                    hintHighlight.position = CGPoint(x: m + CGFloat(st.chipX.value), y: hintPill.bounds.height / 2)
                    hintHighlight.isHidden = false
                } else {
                    hintHighlight.isHidden = true
                }
            }
        }
    }

    /// Where the hint pill is, in root (y-up) coordinates, for the vibrancy view underneath it.
    func hintPillFrame(_ st: WheelState) -> CGRect? {
        guard st.layout.showHints, let Hh = hint, !Hh.chips.isEmpty else { return nil }
        let p = hintPill.position
        return CGRect(x: p.x - Hh.total / 2, y: p.y - Hh.height / 2, width: Hh.total, height: Hh.height)
    }

    var hintCornerRadius: CGFloat { (hint?.height ?? 0) / 2 }
}
