import AppKit
import QuartzCore
import CoreVideo

/// Calls `tick(dt)` on the main thread once per display refresh (120 Hz on ProMotion) while something is moving,
/// and stops completely when `tick` returns false, so an idle wheel costs nothing.
final class FrameTicker {
    private var link: AnyObject?
    private var cvLink: CVDisplayLink?
    private var last: CFTimeInterval = 0
    private let tick: (Double) -> Bool
    private weak var view: NSView?
    private var running = false

    init(view: NSView, tick: @escaping (Double) -> Bool) {
        self.view = view
        self.tick = tick
    }

    func start() {
        if running { return }
        running = true
        last = CACurrentMediaTime()
        if #available(macOS 14.0, *), let view {
            let l = view.displayLink(target: self, selector: #selector(step(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            startCVDisplayLink()
        }
    }

    func stop() {
        running = false
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        link = nil
        if let cv = cvLink { CVDisplayLinkStop(cv) }
        cvLink = nil
    }

    @objc private func step(_ sender: AnyObject) { frame() }

    private func frame() {
        guard running else { return }
        let now = CACurrentMediaTime()
        // Clamp so a stall (or the first frame) doesn't fling the springs.
        let dt = min(max(now - last, 1.0 / 240), 1.0 / 30)
        last = now
        if !tick(dt) { stop() }
    }

    private func startCVDisplayLink() {
        var cv: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&cv)
        guard let cv else { return }
        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(cv, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let me = Unmanaged<FrameTicker>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { me.frame() }
            return kCVReturnSuccess
        }, unmanaged)
        CVDisplayLinkStart(cv)
        cvLink = cv
    }

    deinit { stop() }
}
