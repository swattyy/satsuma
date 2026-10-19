import Foundation

public enum TriggerKey: String, Codable, CaseIterable {
    case none = "None", shift = "Shift", control = "Control", option = "Option", command = "Command"

    /// Symbol for key caps and hint chips.
    public var symbol: String {
        switch self {
        case .none: return ""
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }

    public var title: String {
        switch self {
        case .none: return "None"
        case .shift: return "Shift"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        }
    }
}

public enum OutputLocation: String, Codable { case nextToOriginal = "NextToOriginal", downloads = "Downloads", customFolder = "CustomFolder" }
public enum ThemePreference: String, Codable, CaseIterable { case system = "System", light = "Light", dark = "Dark" }

public final class AppSettings: Codable {
    public var enabled = true
    public var convertKey: TriggerKey = .shift
    public var toolsKey: TriggerKey = .command
    public var actionsKey: TriggerKey = .option

    public var output: OutputLocation = .nextToOriginal
    public var customOutputFolder: String?

    public var imageQuality = 90
    public var keepMetadata = true
    public var hardwareVideoEncoding = true
    public var pdfRenderDpi = 300

    public var showKeyHints = true
    public var sounds = true
    public var revealAfterConvert = false
    public var theme: ThemePreference = .system
    public var wheelScale = 1.0

    public var ffmpegPath: String?
    public var firstRunDone = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, convertKey, toolsKey, actionsKey, output, customOutputFolder, imageQuality, keepMetadata
        case hardwareVideoEncoding, pdfRenderDpi, showKeyHints, sounds, revealAfterConvert, theme, wheelScale
        case ffmpegPath, firstRunDone
    }

    // Every key is optional so settings files from older versions keep loading.
    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        enabled = get(.enabled, true)
        convertKey = get(.convertKey, TriggerKey.shift)
        toolsKey = get(.toolsKey, TriggerKey.command)
        actionsKey = get(.actionsKey, TriggerKey.option)
        output = get(.output, OutputLocation.nextToOriginal)
        customOutputFolder = get(.customOutputFolder, String?.none)
        imageQuality = get(.imageQuality, 90)
        keepMetadata = get(.keepMetadata, true)
        hardwareVideoEncoding = get(.hardwareVideoEncoding, true)
        pdfRenderDpi = get(.pdfRenderDpi, 300)
        showKeyHints = get(.showKeyHints, true)
        sounds = get(.sounds, true)
        revealAfterConvert = get(.revealAfterConvert, false)
        theme = get(.theme, ThemePreference.system)
        wheelScale = get(.wheelScale, 1.0)
        ffmpegPath = get(.ffmpegPath, String?.none)
        firstRunDone = get(.firstRunDone, false)
    }

    public func key(for kind: WheelKind) -> TriggerKey {
        switch kind {
        case .convert: return convertKey
        case .tools: return toolsKey
        case .actions: return actionsKey
        }
    }
}

public enum Settings {
    public static let changed = Notification.Name("SatsumaSettingsChanged")
    public static var current = AppSettings()

    public static func load() {
        guard let data = try? Data(contentsOf: P.url(AppPaths.settingsFile)) else { return }
        do { current = try JSONDecoder().decode(AppSettings.self, from: data) }
        catch {
            Log.warn("Settings load failed, using defaults: \(error)")
            current = AppSettings()
        }
    }

    public static func save() {
        do {
            try P.createDir(AppPaths.dataDir)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(current).write(to: P.url(AppPaths.settingsFile))
        } catch { Log.warn("Settings save failed: \(error)") }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
