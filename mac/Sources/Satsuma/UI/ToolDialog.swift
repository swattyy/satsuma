import AppKit
import SwiftUI
import SatsumaCore

/// Presents an option dialog for an interactive tool in its own window and waits for the answer.
/// Each dialog calls `finish(value)` to run the tool, or `finish(nil)` (or closes the window) to cancel.
@MainActor
enum ToolDialog {
    /// Keeps the window and its delegate alive while the dialog is up, and answers the caller exactly once.
    @MainActor
    final class Session: NSObject, NSWindowDelegate {
        static var live: [Session] = []
        var window: NSWindow?
        var answer: ((Any?) -> Void)?

        func end(_ value: Any?) {
            guard let answer else { return }
            self.answer = nil
            window?.delegate = nil
            window?.close()
            window = nil
            Session.live.removeAll { $0 === self }
            answer(value)
        }

        func windowWillClose(_ notification: Notification) { end(nil) }
    }

    static func present<T, V: View>(_ title: String, width: CGFloat = 460, _ content: (@escaping (T?) -> Void) -> V) async -> T? {
        let session = Session()
        let root = content { [weak session] value in session?.end(value) }
        let host = NSHostingController(rootView: root.padding(22).frame(width: width))
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        session.window = w
        w.delegate = session
        Session.live.append(session)
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            session.answer = { value in c.resume(returning: value as? T) }
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
            // Snapped in the binding: with `step:` the macOS slider draws a tick mark for every value.
            Slider(value: Binding(get: { value }, set: { value = (($0 - range.lowerBound) / step).rounded() * step + range.lowerBound }), in: range)
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
