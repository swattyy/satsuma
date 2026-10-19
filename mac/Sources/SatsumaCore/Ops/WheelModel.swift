import Foundation
import CoreGraphics

public enum WheelKind: String, CaseIterable {
    case convert = "Convert", tools = "Tools", actions = "Actions"
}

public struct WheelItem {
    /// Stable id, e.g. "convert:png" or "tool:compress".
    public var id: String
    /// Short label drawn on the segment ("PNG", "Compress").
    public var label: String
    /// Optional SF Symbol name, drawn above the label.
    public var glyph: String?
    /// Caption shown in the hub while hovering ("Convert to", "Smaller file").
    public var caption: String
    /// Fuller wording, e.g. "Convert to %1". %1 is replaced by the label.
    public var dropText: String
    /// Title of the progress bubble ("Converting to PNG…").
    public var workingTitle: String?
    /// The item opens a dialog first and calls OpContext.beginWork itself once confirmed.
    public var interactive: Bool
    public var run: (OpContext) async throws -> OpResult

    public init(id: String, label: String, glyph: String? = nil, caption: String = "Convert to", dropText: String = "Convert to %1",
                workingTitle: String? = nil, interactive: Bool = false, run: @escaping (OpContext) async throws -> OpResult) {
        self.id = id
        self.label = label
        self.glyph = glyph
        self.caption = caption
        self.dropText = dropText
        self.workingTitle = workingTitle
        self.interactive = interactive
        self.run = run
    }
}

public struct WheelContent {
    public var kind: WheelKind
    public var items: [WheelItem]
    /// Hub text when nothing is hovered.
    public var hubCaption: String
    public var hubTitle: String
    /// Shown in the hub when there are no items.
    public var emptyMessage: String

    public init(kind: WheelKind, items: [WheelItem], hubCaption: String = "", hubTitle: String = "", emptyMessage: String = "No options") {
        self.kind = kind
        self.items = items
        self.hubCaption = hubCaption
        self.hubTitle = hubTitle
        self.emptyMessage = emptyMessage
    }
}

/// SF Symbols used on the Tools and Actions wheels (the Windows app uses Segoe Fluent Icons).
public enum Glyphs {
    public static let convert = "arrow.triangle.2.circlepath"
    public static let compress = "arrow.down.right.and.arrow.up.left"
    public static let resize = "arrow.up.left.and.arrow.down.right"
    public static let crop = "crop"
    public static let rotate = "rotate.right"
    public static let info = "info.circle"
    public static let tag = "tag"
    public static let text = "textformat"
    public static let redact = "eye.slash"
    public static let background = "paintpalette"
    public static let photo = "photo"
    public static let grid = "square.grid.2x2"
    public static let document = "doc"
    public static let pages = "doc.on.doc"
    public static let cut = "scissors"
    public static let mute = "speaker.slash"
    public static let volume = "speaker.wave.2"
    public static let speaker = "hifispeaker"
    public static let camera = "camera"
    public static let video = "video"
    public static let audio = "waveform"
    public static let package = "archivebox"
    public static let folderOpen = "folder"
    public static let share = "square.and.arrow.up"
    public static let pin = "pin"
    public static let copy = "doc.on.clipboard"
    public static let move = "arrowshape.turn.up.right"
    public static let link = "link"
    public static let terminal = "terminal"
    public static let openWith = "arrow.up.forward.app"
    public static let merge = "square.on.square"
    public static let split = "square.split.2x1"
    public static let check = "checkmark"
}
