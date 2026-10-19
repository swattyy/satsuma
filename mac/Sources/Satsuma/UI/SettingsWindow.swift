import AppKit
import SwiftUI
import ServiceManagement
import SatsumaCore

enum SettingsWindow {
    static func show() {
        Windows.show("settings", title: "Satsuma Settings", size: CGSize(width: 560, height: 720), resizable: true) { SettingsView() }
    }
}

/// Settings mirror the Windows app's sections: wheel keys, saving, quality, look and feel, engines.
final class SettingsModel: ObservableObject {
    @Published var s = Settings.current
    @Published var trusted = DragMonitor.isTrusted
    @Published var ffmpeg = Ffmpeg.path
    @Published var installing = false
    @Published var installStatus = ""
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var timer: Timer?

    init() {
        // Accessibility can be granted while the window is open.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = DragMonitor.isTrusted
            if t != self.trusted {
                self.trusted = t
                if t { DragMonitor.shared.start() }
            }
        }
    }

    deinit { timer?.invalidate() }

    func save() {
        Settings.current = s
        Settings.save()
        objectWillChange.send()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.warn("Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            s.customOutputFolder = url.path
            s.output = .customFolder
            save()
        }
    }

    func installFfmpeg() {
        guard let brew = Ffmpeg.brewPath else { return }
        installing = true
        installStatus = "Running brew install ffmpeg…"
        Task {
            let env = ["PATH": "\(P.dir(brew)):/usr/bin:/bin:/usr/sbin:/sbin", "HOMEBREW_NO_ENV_HINTS": "1"]
            let r = try? await Proc.run(brew, ["install", "ffmpeg"], env: env, lowPriority: false) { line in
                DispatchQueue.main.async { if !line.isEmpty { self.installStatus = String(line.prefix(90)) } }
            }
            await MainActor.run {
                Ffmpeg.reset()
                ffmpeg = Ffmpeg.path
                installing = false
                installStatus = ffmpeg != nil ? "Installed." : "Homebrew didn't finish: \(r?.lastError ?? "unknown error")"
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var m = SettingsModel()
    private let keys: [TriggerKey] = [.shift, .command, .option, .control, .none]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                section("Wheel keys") {
                    keyRow("Convert", "Change the file to another format", \.convertKey)
                    keyRow("Tools", "Compress, resize, crop, trim, merge…", \.toolsKey)
                    keyRow("Actions", "Share, shelf, copy, move, copy path, terminal", \.actionsKey)
                    Text("Start dragging a file, then tap the key. The wheel stays open until you drop; tap another key to switch wheels, or the same key to close it.")
                        .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                section("Accessibility") {
                    HStack(alignment: .top) {
                        Image(systemName: m.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(m.trusted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.trusted ? "Satsuma can see the wheel keys." : "Satsuma needs Accessibility access to notice the wheel keys while you drag.")
                            if !m.trusted {
                                Text("It only watches for those keys during a drag. Nothing is recorded or sent anywhere.")
                                    .font(.callout).foregroundColor(.secondary)
                                Button("Open Accessibility Settings") { DragMonitor.requestTrust(); DragMonitor.openAccessibilitySettings() }
                            }
                        }
                    }
                }
                section("Saving") {
                    Picker("", selection: Binding(get: { m.s.output }, set: { m.s.output = $0; m.save() })) {
                        Text("Next to the original file").tag(OutputLocation.nextToOriginal)
                        Text("Downloads folder").tag(OutputLocation.downloads)
                        Text(m.s.customOutputFolder.map { "This folder: " + P.fileName($0) } ?? "A folder of my choice").tag(OutputLocation.customFolder)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Button("Choose Folder…") { m.chooseFolder() }
                    Toggle("Show the result in Finder after converting", isOn: Binding(get: { m.s.revealAfterConvert }, set: { m.s.revealAfterConvert = $0; m.save() }))
                }
                section("Quality") {
                    HStack {
                        Text("JPEG / WebP / HEIC / AVIF quality")
                        Spacer()
                        Text("\(m.s.imageQuality)").bold().frame(width: 36, alignment: .trailing)
                    }
                    Slider(value: Binding(get: { Double(m.s.imageQuality) }, set: { m.s.imageQuality = Int($0.rounded()); m.save() }), in: 40...100, step: 1)
                    Toggle("Keep photo metadata (date, camera, location) when converting", isOn: Binding(get: { m.s.keepMetadata }, set: { m.s.keepMetadata = $0; m.save() }))
                    Toggle("Use the hardware video encoder (VideoToolbox) with FFmpeg", isOn: Binding(get: { m.s.hardwareVideoEncoding }, set: { m.s.hardwareVideoEncoding = $0; m.save() }))
                    Picker("PDF page images", selection: Binding(get: { m.s.pdfRenderDpi }, set: { m.s.pdfRenderDpi = $0; m.save() })) {
                        ForEach([150, 200, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                    }
                    .frame(width: 260)
                }
                section("Look and feel") {
                    Toggle("Open Satsuma when I log in", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                    Toggle("Show key hints under the wheel", isOn: Binding(get: { m.s.showKeyHints }, set: { m.s.showKeyHints = $0; m.save() }))
                    Toggle("Play subtle sounds", isOn: Binding(get: { m.s.sounds }, set: { m.s.sounds = $0; m.save() }))
                    Picker("Wheel theme", selection: Binding(get: { m.s.theme }, set: { m.s.theme = $0; m.save() })) {
                        Text("Match the system").tag(ThemePreference.system)
                        Text("Light").tag(ThemePreference.light)
                        Text("Dark").tag(ThemePreference.dark)
                    }
                    .frame(width: 260)
                    HStack {
                        Text("Wheel size")
                        Spacer()
                        Text("\(Int((m.s.wheelScale * 100).rounded()))%").bold().frame(width: 48, alignment: .trailing)
                    }
                    Slider(value: Binding(get: { m.s.wheelScale }, set: { m.s.wheelScale = ($0 * 20).rounded() / 20; m.save() }), in: 0.7...1.4)
                }
                section("Engines") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FFmpeg (more audio and video formats)").bold()
                        if let path = m.ffmpeg {
                            Text("Found at \(path)").font(.callout).foregroundColor(.secondary)
                        } else if Ffmpeg.brewPath != nil {
                            Text("Not installed. MP3, OGG, OPUS, WMA, MKV, WEBM, AVI, WMV and loudness need it.").font(.callout).foregroundColor(.secondary)
                            HStack {
                                Button(m.installing ? "Installing…" : "Install with Homebrew") { m.installFfmpeg() }.disabled(m.installing)
                                Text(m.installStatus).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        } else {
                            Text("Not installed. Install Homebrew from brew.sh, then run “brew install ffmpeg” in Terminal, or put an ffmpeg binary in /usr/local/bin.")
                                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LibreOffice (slides, XLS and WordPerfect)").bold()
                        Text(LibreOffice.path != nil ? "Found in Applications." : "Not installed. Slide conversions stay hidden until it is (libreoffice.org).")
                            .font(.callout).foregroundColor(.secondary)
                    }
                }
                HStack {
                    Text("Everything runs on this Mac. Nothing is uploaded.").font(.callout).foregroundColor(.secondary)
                    Spacer()
                    Button("How It Works") { Welcome.show() }
                    Button("Open Log") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppPaths.logFile)]) }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: AppIcon.appImage(size: 52)).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading) {
                Text("Satsuma").font(.title).bold()
                Text("Drag a file, tap a key, drop on what you want.").foregroundColor(.secondary)
            }
            Spacer()
            Toggle("Active", isOn: Binding(get: { m.s.enabled }, set: { m.s.enabled = $0; m.save() })).toggleStyle(.switch)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption).bold().foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private func keyRow(_ title: String, _ hint: String, _ key: WritableKeyPath<AppSettings, TriggerKey>) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(hint).font(.callout).foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(get: { m.s[keyPath: key] }, set: { m.s[keyPath: key] = $0; m.save() })) {
                ForEach(keys, id: \.self) { k in Text(k == .none ? "None" : "\(k.symbol) \(k.title)").tag(k) }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }
}
