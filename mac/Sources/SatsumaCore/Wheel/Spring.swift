import Foundation

/// Damped harmonic spring (unit mass). `response` is the undamped period in seconds and `damping` the damping
/// ratio (1 = critically damped, below 1 overshoots). Retargeting mid-flight keeps velocity, which is what makes
/// interrupted animations feel continuous. Same integrator as the Windows app.
public final class Spring {
    public var value: Double
    public var velocity: Double = 0
    public private(set) var target: Double
    private var stiffness = 0.0, dampingCoeff = 0.0
    private var pendingTarget = 0.0, delay = 0.0, hasPending = false

    public init(_ value: Double, response: Double = 0.3, damping: Double = 0.85) {
        self.value = value
        target = value
        configure(response: response, damping: damping)
    }

    @discardableResult
    public func configure(response: Double, damping: Double) -> Spring {
        let w = 2 * Double.pi / max(0.01, response)
        stiffness = w * w
        dampingCoeff = 2 * damping * w
        return self
    }

    public func to(_ target: Double, delay: Double = 0) {
        if delay > 0 { pendingTarget = target; self.delay = delay; hasPending = true }
        else { self.target = target; hasPending = false }
    }

    public func snap(_ v: Double) {
        value = v
        target = v
        velocity = 0
        hasPending = false
    }

    public var isMoving: Bool { hasPending || abs(value - target) > 0.0004 || abs(velocity) > 0.004 }

    /// Advances the spring; returns true while still in motion.
    @discardableResult
    public func step(_ dtIn: Double) -> Bool {
        var dt = dtIn
        if hasPending {
            delay -= dt
            if delay <= 0 { target = pendingTarget; hasPending = false; dt = -delay }
            else { return true }
        }
        if !isMoving {
            value = target
            velocity = 0
            return false
        }
        let steps = max(1, Int((dt / (1.0 / 960)).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let accel = -stiffness * (value - target) - dampingCoeff * velocity
            velocity += accel * h
            value += velocity * h
        }
        return true
    }
}

public enum Ease {
    public static func clamp01(_ v: Double) -> Double { v < 0 ? 0 : v > 1 ? 1 : v }
    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    public static func outCubic(_ t: Double) -> Double { let u = 1 - clamp01(t); return 1 - u * u * u }
}
