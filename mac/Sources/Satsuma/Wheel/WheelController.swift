import AppKit
import SatsumaCore

/// Owns the wheel panel, its animation state and the drop handling. Everything here runs on the main thread.
/// Lifecycle: open (trigger key) -> drag hovers segments -> drop runs the item -> close.
final class WheelController {
    static let shared = WheelController()

    let st = WheelState()
    private var panel: OverlayPanel?
    private var view: WheelView?
    private var layers: WheelLayers?
    private var ticker: FrameTicker?

    private var files = DragFiles.Snapshot()
    private(set) var visible = false
    private var closing = false, committed = false
    private var openedAt = 0.0
    private var hit = -1
    private var clearToken = 0, dimToken = 0
    private var dragInside = false
    private var lastPoint = CGPoint.zero

    var isOpen: Bool { visible && !closing }
    var kind: WheelKind { st.kind }

    // ------------------------------------------------------------------ open / close

    func open(_ kind: WheelKind, at cursor: CGPoint, files snapshot: DragFiles.Snapshot) {
        if visible && !closing {
            if kind == st.kind { close() } else { switchTo(kind) }
            return
        }
        finishClose()

        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let scale = CGFloat(min(max(Settings.current.wheelScale, 0.6), 1.6))
        let L = WheelLayout(scale: scale, showHints: Settings.current.showKeyHints)
        let px = screen.backingScaleFactor
        let frame = screen.frame
        let margin = 6 * scale
        // Keep the whole wheel (and its hint chips) on screen; AppKit's y axis points up.
        let bottomNeed = L.showHints ? L.rPlate + 50 * scale : L.rPlate
        let cx = min(max(cursor.x, frame.minX + L.rPlate + margin), frame.maxX - L.rPlate - margin)
        let cy = min(max(cursor.y, frame.minY + bottomNeed + margin), frame.maxY - L.rPlate - margin)
        let origin = CGPoint(x: (cx - L.cx).rounded(), y: (cy - (L.height - L.cy)).rounded())

        if panel == nil || layers?.px != px {
            ticker?.stop()
            panel?.orderOut(nil)
            let p = OverlayPanel(size: CGSize(width: L.width, height: L.height))
            let v = WheelView(frame: NSRect(x: 0, y: 0, width: L.width, height: L.height))
            v.controller = self
            p.contentView = v
            let l = WheelLayers(px: px, glass: nil, tintScale: 0.55)
            v.layerHost.layer?.addSublayer(l.root)
            v.shadowHost.layer?.addSublayer(l.shadowLayer)
            panel = p
            view = v
            layers = l
            ticker = FrameTicker(view: v) { [weak self] dt in self?.tick(dt) ?? false }
        }
        guard let panel, let view, let layers else { return }
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: L.width, height: L.height)), display: false)
        view.frame = NSRect(x: 0, y: 0, width: L.width, height: L.height)

        st.layout = L
        st.dark = Theme.isDark
        for g in [view.plateGlass, view.pillGlass] { g.appearance = NSAppearance(named: st.dark ? .darkAqua : .aqua) }
        st.kind = kind
        st.segments = []
        st.leaving = []
        st.hover = -1
        hit = -1
        dragInside = false
        clearToken += 1
        dimToken += 1
        st.loading = true
        st.open.configure(response: 0.36, damping: 0.72).snap(0); st.open.to(1)
        st.fade.configure(response: 0.13, damping: 1).snap(0); st.fade.to(1)
        st.hubPop.snap(0); st.hubPop.to(1, delay: 0.03)
        st.dim.snap(0)
        st.chipX.snap(0)
        st.hubFrom = HubText()
        st.hubTo = HubText()
        st.hubFade.snap(1)

        visible = true
        closing = false
        committed = false
        openedAt = CACurrentMediaTime()
        lastPoint = cursor
        files = snapshot
        // The drag pasteboard was read when the key went down, so the first frame already has its segments.
        if !files.isEmpty { applyContent(initial: true) }

        render()
        panel.orderFrontRegardless()
        ticker?.start()
        SoundFx.play(.open)
        Log.info("Wheel open: \(kind.rawValue) at \(Int(cursor.x)),\(Int(cursor.y)) scale \(scale), \(files.paths.count) item(s)")
    }

    func switchTo(_ kind: WheelKind) {
        guard visible, !closing, kind != st.kind else { return }
        st.kind = kind
        for s in st.segments {
            s.appear.configure(response: 0.16, damping: 1).to(0)
            s.hover.to(0)
            st.leaving.append(s)
        }
        st.segments = []
        st.hover = -1
        applyContent(initial: false)
        _ = updateHover(lastPoint)
        ticker?.start()
        SoundFx.play(.switchWheel)
    }

    func close(commit: Bool = false) {
        guard visible, !closing else { return }
        closing = true
        if commit {
            st.open.configure(response: 0.3, damping: 0.9).to(1.07)
            st.fade.configure(response: 0.12, damping: 1).to(0, delay: 0.07)
        } else {
            st.open.configure(response: 0.22, damping: 1).to(0.9)
            st.fade.configure(response: 0.1, damping: 1).to(0)
        }
        ticker?.start()
    }

    private func finishClose() {
        guard visible else { return }
        panel?.orderOut(nil)
        visible = false
        closing = false
        st.segments = []
        st.leaving = []
    }

    /// Forget the dragged files once the drag is over.
    func resetDrag() { files = DragFiles.Snapshot() }

    func onMouseUp() {
        guard isOpen else { resetDrag(); return }
        // A drop on the wheel arrives right around the button release; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if self.isOpen && !self.committed { self.close() }
            self.resetDrag()
        }
    }

    func onEscape() {
        if isOpen { close() }
        resetDrag()
    }

    // ------------------------------------------------------------------ content

    private func applyContent(initial: Bool) {
        let content = Catalog.build(st.kind, files.paths, virtualOnly: files.promised)
        st.content = content
        st.loading = false
        let baseDelay = initial ? max(0, 0.04 - (CACurrentMediaTime() - openedAt)) : 0.06
        for (i, item) in content.items.enumerated() {
            let seg = SegmentState(item: item)
            seg.appear.snap(0)
            seg.appear.to(1, delay: baseDelay + Double(i) * 0.016)
            st.segments.append(seg)
        }
        setHub(defaultHub())
    }

    private func defaultHub() -> HubText {
        guard let c = st.content, !files.isEmpty else { return HubText() }
        if c.items.isEmpty { return HubText(caption: c.hubCaption, title: c.emptyMessage) }
        return HubText(caption: c.hubCaption, title: c.hubTitle)
    }

    private func setHub(_ text: HubText) {
        if st.hubTo == text { return }
        st.hubFrom = st.hubFade.value > 0.5 ? st.hubTo : st.hubFrom
        st.hubTo = text
        st.hubFade.snap(0)
        st.hubFade.to(1)
    }

    // ------------------------------------------------------------------ drag events (from WheelView)

    private func screenPoint(_ info: NSDraggingInfo) -> CGPoint {
        guard let panel else { return .zero }
        return panel.convertPoint(toScreen: info.draggingLocation)
    }

    func dragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        let snapshot = DragFiles.read(info.draggingPasteboard)
        let changed = snapshot != files
        if changed { Log.info("Drag entered: \(snapshot.paths.count) item(s)\(snapshot.promised ? " (promised)" : "")") }
        files = snapshot
        if visible && (changed || st.loading) {
            for s in st.segments { s.appear.configure(response: 0.16, damping: 1).to(0); st.leaving.append(s) }
            st.segments = []
            applyContent(initial: true)
        }
        dragInside = true
        dimToken += 1
        st.dim.to(0)
        ticker?.start()
        return dragUpdated(info)
    }

    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        lastPoint = screenPoint(info)
        guard isOpen else { return [] }
        if updateHover(lastPoint) < 0 { return [] }
        return allowed(info.draggingSourceOperationMask)
    }

    /// Never answer move (or generic, which Finder treats as move): the original must stay where it is.
    private func allowed(_ mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(.copy) { return .copy }
        if mask.contains(.link) { return .link }
        return []
    }

    func dragExited() {
        guard isOpen else { return }
        hit = -1
        dragInside = false
        clearHoverSoon()
        // Only dim if the drag stays outside for a moment; a quick pass outside the ring shouldn't flash the wheel.
        dimToken += 1
        let token = dimToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, token == self.dimToken, !self.dragInside, self.isOpen else { return }
            self.st.dim.to(1)
            self.ticker?.start()
        }
    }

    func perform(_ info: NSDraggingInfo) -> Bool {
        guard isOpen else { return false }
        let idx = updateHover(screenPoint(info))
        guard idx >= 0 && idx < st.segments.count, !allowed(info.draggingSourceOperationMask).isEmpty else {
            close()
            resetDrag()
            return false
        }
        let seg = st.segments[idx]
        committed = true
        seg.press.snap(0)
        seg.press.to(1)
        let L = st.layout
        let anchor = panel.map { CGPoint(x: $0.frame.minX + L.cx, y: $0.frame.minY + (L.height - L.cy)) } ?? lastPoint
        close(commit: true)
        SoundFx.play(.commit)
        Log.info("Drop: \(seg.item.id) on \(files.paths.count) item(s)")
        let item = seg.item
        if files.promised {
            DragFiles.receive(info.draggingPasteboard) { paths in
                if !paths.isEmpty { OpRunner.start(item, files: paths, anchor: anchor) }
            }
        } else if !files.isEmpty {
            OpRunner.start(item, files: files.paths, anchor: anchor)
        }
        resetDrag()
        return true
    }

    @discardableResult
    private func updateHover(_ screen: CGPoint) -> Int {
        guard let panel else { return -2 }
        let L = st.layout
        // Hit-test in the Windows-style y-down coordinates of the wheel.
        let x = screen.x - panel.frame.minX
        let yDown = L.height - (screen.y - panel.frame.minY)
        let idx = L.hitTest(x, yDown, st.segments.count)
        hit = idx >= 0 ? idx : -1
        if hit >= 0 { setHoverIndex(hit) } else { clearHoverSoon() }
        return idx
    }

    /// Leaving a segment for the hub or the outside clears the highlight after a short pause, so sweeping
    /// across the center to another segment doesn't flash the wheel back to its idle look.
    private func clearHoverSoon() {
        guard st.hover >= 0 else { return }
        clearToken += 1
        let token = clearToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, token == self.clearToken, self.hit < 0 else { return }
            self.setHoverIndex(-1)
        }
    }

    private func setHoverIndex(_ idx: Int) {
        clearToken += 1 // any real hover change cancels a pending clear
        if idx == st.hover { return }
        WheelState.applyHover(st, from: st.hover, to: idx)
        if idx >= 0 && idx < st.segments.count {
            let item = st.segments[idx].item
            setHub(HubText(caption: item.caption, title: item.label, accent: true))
            SoundFx.play(.tick)
        } else {
            setHub(defaultHub())
        }
        ticker?.start()
    }

    // ------------------------------------------------------------------ frames

    private func tick(_ dt: Double) -> Bool {
        guard visible else { return false }
        var moving = false
        for s in st.allSprings where s.step(dt) { moving = true }
        st.leaving.removeAll { $0.appear.target <= 0 && $0.appear.value < 0.01 }
        if closing && st.fade.target <= 0 && st.fade.value < 0.01 && !st.fade.isMoving {
            finishClose()
            return false
        }
        render()
        return moving || closing
    }

    private func render() {
        guard let layers, let view else { return }
        layers.update(st)
        let L = st.layout
        let fade = Float(layers.root.opacity)
        view.shadowHost.layer?.opacity = fade
        let plateScale = 0.8 + 0.2 * CGFloat(st.open.value)
        let r = L.rPlate * plateScale
        let center = CGPoint(x: L.cx, y: L.height - L.cy)
        view.plateGlass.place(CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        view.plateGlass.alphaValue = CGFloat(fade)
        if let pill = layers.hintPillFrame(st) {
            view.pillGlass.isHidden = false
            view.pillGlass.place(pill)
            view.pillGlass.alphaValue = CGFloat(fade)
        } else {
            view.pillGlass.isHidden = true
        }
    }
}

enum Theme {
    static var isDark: Bool {
        switch Settings.current.theme {
        case .light: return false
        case .dark: return true
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}
