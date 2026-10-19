import AppKit
import SwiftUI
import SatsumaCore

/// Presents an option dialog for an interactive tool in its own window and waits for the answer.
/// Each dialog calls `finish(value)` to run the tool, or `finish(nil)` (or closes the window) to cancel.
@MainActor
enum ToolDialog {
    @MainActor final class Session: NSObject, NSWindowDelegate {
        var window: NSWindow?
        var onClose: (() -> Void)?
        func close() {
            window?.delegate = nil
            window?.close()
            window = nil
            ToolDialog.sessions.removeAll { $0 === self }
        }
        func windowWillClose(_ notification: Notification) {
            let c = onClose
            onClose = nil
            ToolDialog.sessions.removeAll { $0 === self }
            c?()
        }
    }

    fileprivate static var sessions: [Session] = []

    static func present<T, V: View>(_ title: String, width: CGFloat = 460, _ content: (@escaping (T?) -> Void) -> V) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let session = Session()
            var resumed = false
            func finish(_ value: T?) {
                if resumed { return }
                resumed = true
                session.onClose = nil
                session.close()
                c.resume(returning: value)
            }
            session.onClose = { finish(nil) }
            let root = content { value in finish(value) }
            let host = NSHostingController(rootView: root.padding(22).frame(width: width))
            let w = NSWindow(contentViewController: host)
            w.title = title
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.center()
            session.window = w
            w.delegate = session
            sessions.append(session)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }
}

/// Header, body and the Cancel / primary buttons every dialog shares.
struct DialogFrame<Content: View>: View {
    let title: String
    let subtitle: String
    let primary: String
    var primaryEnabled = true
    let onCancel: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2).bold()
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundColor(.secondary).lineLimit(2) }
            }
            content
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(primary, action: onPrimary).keyboardShortcut(.defaultAction).disabled(!primaryEnabled)
            }
        }
    }
}

enum DialogText {
    static func describe(_ files: [String]) -> String {
        files.count == 1 ? "\(P.fileName(files[0])) · \(FileKinds.humanSize(P.size(files[0])))"
                         : "\(files.count) files · \(FileKinds.humanSize(FileKinds.totalSize(files)))"
    }
}

/// A row of mutually exclusive pill buttons (the Windows "Segmented" control).
struct Pills: View {
    let options: [String]
    @Binding var selection: Int
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let format: (Double) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(format(value)).bold().monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

/// Image preview that fits its frame.
struct Preview: View {
    let image: CGImage?
    var height: CGFloat = 220
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12))
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(4)
            } else {
                ProgressView()
            }
        }
        .frame(height: height)
    }
}

/// Background swatches shared by Backdrop and Collage.
struct Swatches: View {
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Backdrops.all.indices, id: \.self) { i in
                let colors = Backdrops.all[i].colors.map { Color(cgColor: $0.cgColor) }
                Circle()
                    .fill(colors.count > 1 ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                           : AnyShapeStyle(colors[0]))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(i == selection ? Color.tangerine : Color.gray.opacity(0.3), lineWidth: i == selection ? 2.5 : 1))
                    .help(Backdrops.all[i].name)
                    .onTapGesture { selection = i }
            }
        }
    }
}
