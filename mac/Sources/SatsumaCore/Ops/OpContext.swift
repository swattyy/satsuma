import Foundation
import CoreGraphics

/// Expected, user-facing failures ("FFmpeg isn't installed").
public struct OpError: LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public final class OpResult {
    public var outputs: [String] = []
    public var title: String?
    public var message: String?
    public var canceled = false
    /// Don't show a success bubble (e.g. the action opened its own window).
    public var quiet = false

    public init() {}

    public static func cancel() -> OpResult { let r = OpResult(); r.canceled = true; return r }
    public static func quietDone() -> OpResult { let r = OpResult(); r.quiet = true; return r }
    public static func done(_ title: String, _ message: String? = nil) -> OpResult {
        let r = OpResult()
        r.title = title
        r.message = message
        return r
    }
    public static func files(_ outputs: [String]) -> OpResult {
        let r = OpResult()
        r.outputs = outputs
        return r
    }
}

public final class OpContext {
    public let files: [String]
    /// Screen point (AppKit coordinates) where the files were dropped.
    public let anchor: CGPoint
    public var onBeginWork: ((String) -> Void)?
    public var onProgress: ((Double, String?) -> Void)?

    public init(files: [String], anchor: CGPoint = .zero) {
        self.files = files
        self.anchor = anchor
    }

    public var file: String { files[0] }

    /// Shows the progress bubble. Interactive items call this after their dialog is confirmed.
    public func beginWork(_ title: String) { onBeginWork?(title) }

    public func report(_ fraction: Double, _ status: String? = nil) { onProgress?(fraction, status) }

    /// Reports overall progress for item `index` of `files` at `fraction`.
    public func reportItem(_ index: Int, _ fraction: Double, _ status: String? = nil) {
        let n = max(1, files.count)
        let f = min(max(fraction, 0), 1)
        report((Double(index) + f) / Double(n), status ?? (n > 1 ? "\(index + 1) of \(n)" : nil))
    }
}
