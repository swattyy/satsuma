import Foundation
import CoreGraphics

public struct RGBA: Equatable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = 1
    }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
}

public enum RedactStyle: Int { case blur, pixelate, box }

public struct CompressOptions {
    public var quality: Int
    public var maxDimension: Int?
    public var format: String?
    public var stripMetadata: Bool
    public var targetBytes: Int64?
    public init(quality: Int, maxDimension: Int?, format: String?, stripMetadata: Bool, targetBytes: Int64?) {
        self.quality = quality; self.maxDimension = maxDimension; self.format = format; self.stripMetadata = stripMetadata; self.targetBytes = targetBytes
    }
}

public struct ResizeChoice {
    public var scale: Double?
    public var width: Int?
    public var height: Int?
    public init(scale: Double?, width: Int?, height: Int?) { self.scale = scale; self.width = width; self.height = height }
}

public struct RedactChoice {
    public var faces: Bool
    public var text: Bool
    public var style: RedactStyle
    public init(faces: Bool, text: Bool, style: RedactStyle) { self.faces = faces; self.text = text; self.style = style }
}

public struct BackgroundOptions {
    public var colors: [RGBA]
    public var paddingFraction: Double
    public var radius: Double
    public var aspect: Double?
    public var shadow: Bool
    public init(colors: [RGBA], paddingFraction: Double, radius: Double, aspect: Double?, shadow: Bool) {
        self.colors = colors; self.paddingFraction = paddingFraction; self.radius = radius; self.aspect = aspect; self.shadow = shadow
    }
}

public enum CollageLayout: Int, CaseIterable { case grid, row, column, featured }

public struct CollageOptions {
    public var layout: CollageLayout
    public var spacing: Double
    public var radius: Double
    public var background: RGBA
    public var width: Int
    public init(layout: CollageLayout, spacing: Double, radius: Double, background: RGBA, width: Int) {
        self.layout = layout; self.spacing = spacing; self.radius = radius; self.background = background; self.width = width
    }
}

public struct VideoCompressOptions {
    public var crf: Int
    public var maxHeight: Int?
    public var audioKbps: Int
    public var targetBytes: Int64?
    public init(crf: Int, maxHeight: Int?, audioKbps: Int, targetBytes: Int64?) {
        self.crf = crf; self.maxHeight = maxHeight; self.audioKbps = audioKbps; self.targetBytes = targetBytes
    }
}

/// Integer pixel rectangle with a top-left origin.
public struct PixelRect: Equatable {
    public var x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Background presets shared by the Backdrop and Collage tools.
public enum Backdrops {
    public static let all: [(name: String, colors: [RGBA])] = [
        ("Tangerine", [RGBA(hex: 0xFFC47A), RGBA(hex: 0xFF5A14)]),
        ("Sunset", [RGBA(hex: 0xFF9A8B), RGBA(hex: 0xA155E8)]),
        ("Ocean", [RGBA(hex: 0x4FC3F7), RGBA(hex: 0x2B4EE0)]),
        ("Mint", [RGBA(hex: 0xA8F0C6), RGBA(hex: 0x1FA27E)]),
        ("Graphite", [RGBA(hex: 0x4A4A55), RGBA(hex: 0x15151A)]),
        ("Paper", [RGBA(hex: 0xFAF7F2)]),
        ("White", [RGBA.white]),
        ("Black", [RGBA.black]),
    ]
}

/// Everything a wheel item needs from the UI: option dialogs and the Actions wheel's system integrations.
/// The app installs its own implementation; headless runs (the CLI) use `HeadlessInteraction`.
public protocol Interaction: AnyObject {
    func imageCompress(_ files: [String]) async -> CompressOptions?
    func imageResize(_ files: [String]) async -> ResizeChoice?
    func imageCrop(_ file: String) async -> PixelRect?
    func redact(_ files: [String]) async -> RedactChoice?
    func background(_ files: [String]) async -> BackgroundOptions?
    func collage(_ files: [String]) async -> CollageOptions?
    func videoCompress(_ files: [String]) async -> VideoCompressOptions?
    func audioCompress(_ files: [String]) async -> Int?
    func trim(_ file: String) async -> (start: Double, end: Double)?
    func pages(_ file: String) async -> [Int]?

    func share(_ files: [String], anchor: CGPoint) async throws
    func float(_ files: [String], anchor: CGPoint) async throws
    func copyFiles(_ files: [String]) async throws
    func setClipboardText(_ text: String) async throws
    func move(_ files: [String]) async throws -> [String]?
    func openTerminal(_ path: String) async throws
    func openWith(_ file: String, anchor: CGPoint) async throws
}

public enum Interact {
    public static var current: Interaction = HeadlessInteraction()
}

/// Answers every dialog with the Windows app's defaults, so `--tool` runs never open a window.
open class HeadlessInteraction: Interaction {
    public init() {}

    open func imageCompress(_ files: [String]) async -> CompressOptions? {
        CompressOptions(quality: 72, maxDimension: 2560, format: nil, stripMetadata: true, targetBytes: nil)
    }
    open func imageResize(_ files: [String]) async -> ResizeChoice? { ResizeChoice(scale: 0.5, width: nil, height: nil) }
    open func imageCrop(_ file: String) async -> PixelRect? { nil }
    open func redact(_ files: [String]) async -> RedactChoice? { RedactChoice(faces: true, text: false, style: .blur) }
    open func background(_ files: [String]) async -> BackgroundOptions? {
        BackgroundOptions(colors: Backdrops.all[0].colors, paddingFraction: 0.08, radius: 0.03, aspect: nil, shadow: true)
    }
    open func collage(_ files: [String]) async -> CollageOptions? {
        CollageOptions(layout: .grid, spacing: 16, radius: 0.03, background: .white, width: 2400)
    }
    open func videoCompress(_ files: [String]) async -> VideoCompressOptions? { VideoCompressOptions(crf: 28, maxHeight: 1080, audioKbps: 128, targetBytes: nil) }
    open func audioCompress(_ files: [String]) async -> Int? { 128 }
    open func trim(_ file: String) async -> (start: Double, end: Double)? { nil }
    open func pages(_ file: String) async -> [Int]? { [1] }

    open func share(_ files: [String], anchor: CGPoint) async throws { throw OpError("Sharing needs the app.") }
    open func float(_ files: [String], anchor: CGPoint) async throws { throw OpError("The shelf needs the app.") }
    open func copyFiles(_ files: [String]) async throws { try await Clipboard.copyFiles(files) }
    open func setClipboardText(_ text: String) async throws { try await Clipboard.setText(text) }
    open func move(_ files: [String]) async throws -> [String]? { nil }
    open func openTerminal(_ path: String) async throws { throw OpError("Opening Terminal needs the app.") }
    open func openWith(_ file: String, anchor: CGPoint) async throws { throw OpError("Open with needs the app.") }
}
