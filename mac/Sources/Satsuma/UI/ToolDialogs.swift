import AppKit
import SwiftUI
import AVFoundation
import SatsumaCore

/// Option dialogs for the interactive tools, with the same choices and defaults as the Windows app.
@MainActor
enum ToolDialogs {
    static func decodeSmall(_ path: String, maxSide: CGFloat) async -> CGImage? {
        guard let d = try? await ImageConverter.decode(path) else { return nil }
        let k = min(1, maxSide / CGFloat(max(d.width, d.height)))
        return k < 1 ? ImageConverter.resample(d.image, width: Int(CGFloat(d.width) * k), height: Int(CGFloat(d.height) * k)) : d.image
    }

    // ------------------------------------------------------------------ image compress

    static func imageCompress(_ files: [String]) async -> CompressOptions? {
        await ToolDialog.present("Compress") { done in CompressView(files: files, done: done) }
    }

    struct CompressView: View {
        let files: [String]
        let done: (CompressOptions?) -> Void
        @State private var mode = 0
        @State private var quality = 72.0
        @State private var target = "500"
        @State private var unit = 0
        @State private var dim = 2
        @State private var format = 0
        @State private var strip = true
        @State private var estimate = "Estimating…"
        @State private var sample: CGImage?
        @State private var fullSize = CGSize.zero
        private let dims = [0, 3840, 2560, 1920, 1280, 800]
        private let formats: [String?] = [nil, "jpg", "webp", "avif", "heic"]

        var body: some View {
            DialogFrame(title: "Compress", subtitle: DialogText.describe(files), primary: files.count == 1 ? "Compress" : "Compress \(files.count)",
                        onCancel: { done(nil) }, onPrimary: submit) {
                Pills(options: ["Quality", "Target size"], selection: $mode)
                if mode == 0 {
                    LabeledSlider(label: "Quality", value: $quality, range: 10...95) { "\(Int($0))%" }
                } else {
                    HStack {
                        Text("Aim for at most")
                        TextField("", text: $target).frame(width: 80).multilineTextAlignment(.trailing)
                        Picker("", selection: $unit) { Text("KB").tag(0); Text("MB").tag(1) }.labelsHidden().frame(width: 70)
                    }
                }
                Text("OPTIONS").font(.caption).bold().foregroundColor(.secondary)
                Picker("Longest side at most", selection: $dim) {
                    ForEach(dims.indices, id: \.self) { i in Text(dims[i] == 0 ? "Keep size" : "\(dims[i]) px").tag(i) }
                }
                Picker("Save as", selection: $format) {
                    ForEach(formats.indices, id: \.self) { i in Text(formats[i]?.uppercased().replacingOccurrences(of: "WEBP", with: "WebP") ?? "Keep format").tag(i) }
                }
                Toggle("Remove metadata (location, camera)", isOn: $strip)
                Text(mode == 1 ? "Quality is chosen automatically to fit the size." : estimate).bold()
            }
            .task { sample = await ToolDialogs.decodeSmall(files[0], maxSide: 1600); await updateEstimate() }
            .onChange(of: quality) { _ in Task { await updateEstimate() } }
            .onChange(of: dim) { _ in Task { await updateEstimate() } }
            .onChange(of: format) { _ in Task { await updateEstimate() } }
        }

        func updateEstimate() async {
            guard let sample else { return }
            let d = dims[dim]
            let fmt = formats[format] ?? ImageTools.editFormat(files[0], hasAlpha: false)
            var img = sample
            if d > 0 && max(sample.width, sample.height) > d {
                let k = Double(d) / Double(max(sample.width, sample.height))
                img = ImageConverter.resample(sample, width: Int(Double(sample.width) * k), height: Int(Double(sample.height) * k))
            }
            let type = fmt == "heic" ? "public.heic" : fmt == "webp" && ImageConverter.writableTypes.contains("org.webmproject.webp") ? "org.webmproject.webp" : "public.jpeg"
            let bytes = ImageConverter.encode(ImageConverter.flatten(img), type: type, quality: quality / 100)?.count ?? 0
            // The sample is downscaled; scale the estimate back up by pixel count.
            if fullSize == .zero, let full = try? await ImageConverter.decode(files[0]) { fullSize = CGSize(width: full.width, height: full.height) }
            var pixels = Double(fullSize.width * fullSize.height)
            let longSide = Double(max(fullSize.width, fullSize.height))
            if d > 0 && longSide > Double(d) { pixels *= pow(Double(d) / longSide, 2) }
            let ratio = max(1, pixels) / Double(max(1, img.width * img.height))
            let size = Int64(Double(bytes) * min(ratio, 50) * (fmt == "avif" ? 0.55 : 1))
            let original = P.size(files[0])
            let pct = 100 * (1 - Double(size) / Double(max(1, original)))
            let sign = pct >= 0 ? "−" : "+"
            estimate = (files.count == 1 ? "≈ " : "First image ≈ ") + "\(FileKinds.humanSize(size))  (\(sign)\(Int(abs(pct).rounded()))%)"
        }

        func submit() {
            var bytes: Int64?
            if mode == 1, let t = Double(target.replacingOccurrences(of: ",", with: ".")), t > 0 { bytes = Int64(t * (unit == 1 ? 1_000_000 : 1_000)) }
            let d = dims[dim]
            done(CompressOptions(quality: Int(quality), maxDimension: d > 0 ? d : nil, format: formats[format], stripMetadata: strip, targetBytes: bytes))
        }
    }

    // ------------------------------------------------------------------ resize

    static func imageResize(_ files: [String]) async -> ResizeChoice? {
        await ToolDialog.present("Resize") { done in ResizeView(files: files, done: done) }
    }

    struct ResizeView: View {
        let files: [String]
        let done: (ResizeChoice?) -> Void
        @State private var mode = 0
        @State private var percent = 50.0
        @State private var width = "1920"
        @State private var height = "1080"
        @State private var original: (Int, Int) = (0, 0)

        var body: some View {
            DialogFrame(title: "Resize", subtitle: DialogText.describe(files), primary: "Resize", onCancel: { done(nil) }, onPrimary: submit) {
                Pills(options: ["Percent", "Width", "Height", "Exact"], selection: $mode)
                if mode == 0 {
                    LabeledSlider(label: "Scale", value: $percent, range: 5...200, step: 5) { "\(Int($0))%" }
                } else {
                    HStack {
                        Text("Pixels")
                        Spacer()
                        TextField("", text: $width).frame(width: 80).disabled(mode == 2)
                        Text("×")
                        TextField("", text: $height).frame(width: 80).disabled(mode == 1)
                    }
                }
                if original.0 > 0 { Text("\(original.0) × \(original.1)  →  \(result.0) × \(result.1)").bold() }
                HStack {
                    ForEach([("4K", 3840), ("1080p", 1920), ("720p", 1280), ("Web", 1024), ("Thumb", 320)], id: \.0) { p in
                        Button(p.0) { mode = 1; width = "\(p.1)" }
                    }
                }
            }
            .task {
                if let d = try? await ImageConverter.decode(files[0]) {
                    original = (d.width, d.height)
                    width = "\(d.width)"
                    height = "\(d.height)"
                }
            }
        }

        var result: (Int, Int) {
            let w = Int(width) ?? 0, h = Int(height) ?? 0
            let (ow, oh) = original
            switch mode {
            case 0: return (Int(Double(ow) * percent / 100), Int(Double(oh) * percent / 100))
            case 1: return (w, ow > 0 ? Int(Double(oh) * Double(w) / Double(ow)) : 0)
            case 2: return (oh > 0 ? Int(Double(ow) * Double(h) / Double(oh)) : 0, h)
            default: return (w, h)
            }
        }

        func submit() {
            let w = Int(width) ?? 0, h = Int(height) ?? 0
            switch mode {
            case 0: done(ResizeChoice(scale: percent / 100, width: nil, height: nil))
            case 1 where w > 0: done(ResizeChoice(scale: nil, width: w, height: nil))
            case 2 where h > 0: done(ResizeChoice(scale: nil, width: nil, height: h))
            case 3 where w > 0 && h > 0: done(ResizeChoice(scale: nil, width: w, height: h))
            default: done(nil)
            }
        }
    }

    // ------------------------------------------------------------------ redact

    static func redact(_ files: [String]) async -> RedactChoice? {
        await ToolDialog.present("Redact", width: 520) { done in RedactView(files: files, done: done) }
    }

    struct RedactView: View {
        let files: [String]
        let done: (RedactChoice?) -> Void
        @State private var faces = true
        @State private var text = false
        @State private var style = 0
        @State private var source: CGImage?
        @State private var preview: CGImage?
        @State private var faceRects: [CGRect] = []
        @State private var textRects: [CGRect] = []
        @State private var status = "Looking for faces and text…"

        var body: some View {
            DialogFrame(title: "Redact", subtitle: DialogText.describe(files) + " · detection runs on this Mac", primary: "Redact",
                        primaryEnabled: faces || text, onCancel: { done(nil) },
                        onPrimary: { done(RedactChoice(faces: faces, text: text, style: RedactStyle(rawValue: style) ?? .blur)) }) {
                Preview(image: preview ?? source, height: 260)
                Text(status).font(.callout).foregroundColor(.secondary)
                Toggle("Blur faces", isOn: $faces)
                Toggle("Blur text", isOn: $text)
                Text("STYLE").font(.caption).bold().foregroundColor(.secondary)
                Pills(options: ["Blur", "Pixelate", "Black box"], selection: $style)
            }
            .task { await detect() }
            .onChange(of: faces) { _ in render() }
            .onChange(of: text) { _ in render() }
            .onChange(of: style) { _ in render() }
        }

        func detect() async {
            guard let img = await ToolDialogs.decodeSmall(files[0], maxSide: 1000) else { status = "Couldn't read this image."; return }
            source = img
            faceRects = (try? ImageTools.detectFaces(img)) ?? []
            textRects = (try? ImageTools.detectText(img)) ?? []
            if faceRects.isEmpty && !textRects.isEmpty { faces = false; text = true }
            render()
            if faceRects.isEmpty && textRects.isEmpty {
                status = files.count == 1 ? "No faces or text found in this image." : "No faces or text in the first image; the others are checked when you click Redact."
            } else {
                status = "Found \(faceRects.count) face\(faceRects.count == 1 ? "" : "s") and \(textRects.count) line\(textRects.count == 1 ? "" : "s") of text."
            }
        }

        func render() {
            guard let source else { return }
            var regions: [(rect: CGRect, oval: Bool)] = []
            if faces { regions += faceRects.map { (rect: $0, oval: true) } }
            if text { regions += textRects.map { (rect: $0, oval: false) } }
            preview = ImageTools.applyRedactions(source, regions, style: RedactStyle(rawValue: style) ?? .blur)
        }
    }

    // ------------------------------------------------------------------ backdrop

    static func background(_ files: [String]) async -> BackgroundOptions? {
        await ToolDialog.present("Backdrop", width: 520) { done in BackdropView(files: files, done: done) }
    }

    struct BackdropView: View {
        let files: [String]
        let done: (BackgroundOptions?) -> Void
        @State private var swatch = 0
        @State private var padding = 8.0
        @State private var radius = 3.0
        @State private var shadow = true
        @State private var aspect = 0
        @State private var small: CGImage?
        private let aspects: [Double?] = [nil, 1, 4.0 / 3, 16.0 / 9, 9.0 / 16]

        var options: BackgroundOptions {
            BackgroundOptions(colors: Backdrops.all[swatch].colors, paddingFraction: padding / 100, radius: radius / 100, aspect: aspects[aspect], shadow: shadow)
        }

        var body: some View {
            DialogFrame(title: "Backdrop", subtitle: "Put the image on a background. Handy for screenshots.", primary: "Save",
                        onCancel: { done(nil) }, onPrimary: { done(options) }) {
                Preview(image: small.flatMap { ImageTools.composeBackground($0, options) }, height: 240)
                Swatches(selection: $swatch)
                LabeledSlider(label: "Spacing", value: $padding, range: 0...30) { "\(Int($0))%" }
                LabeledSlider(label: "Corner radius", value: $radius, range: 0...15) { "\(Int($0))%" }
                Toggle("Drop shadow", isOn: $shadow)
                Text("SHAPE").font(.caption).bold().foregroundColor(.secondary)
                Pills(options: ["Auto", "1:1", "4:3", "16:9", "9:16"], selection: $aspect)
            }
            .task { small = await ToolDialogs.decodeSmall(files[0], maxSide: 640) }
        }
    }

    // ------------------------------------------------------------------ collage

    static func collage(_ files: [String]) async -> CollageOptions? {
        await ToolDialog.present("Collage", width: 540) { done in CollageView(files: files, done: done) }
    }

    struct CollageView: View {
        let files: [String]
        let done: (CollageOptions?) -> Void
        @State private var layout = 0
        @State private var spacing = 16.0
        @State private var radius = 3.0
        @State private var swatch = 6
        @State private var width = 1
        @State private var thumbs: [CGImage] = []
        private let widths = [1600, 2400, 3600]

        func options(_ outWidth: Int) -> CollageOptions {
            CollageOptions(layout: CollageLayout(rawValue: layout) ?? .grid, spacing: spacing * Double(outWidth) / 2400, radius: radius / 100,
                           background: Backdrops.all[swatch].colors[0], width: outWidth)
        }

        var body: some View {
            DialogFrame(title: "Collage", subtitle: "\(files.count) images", primary: "Make Collage",
                        onCancel: { done(nil) }, onPrimary: { done(options(widths[width])) }) {
                Preview(image: thumbs.isEmpty ? nil : ImageTools.composeCollage(thumbs, options(800)), height: 260)
                Pills(options: ["Grid", "Row", "Column", "Featured"], selection: $layout)
                LabeledSlider(label: "Spacing", value: $spacing, range: 0...60) { "\(Int($0)) px" }
                LabeledSlider(label: "Corner radius", value: $radius, range: 0...15) { "\(Int($0))%" }
                Text("BACKGROUND").font(.caption).bold().foregroundColor(.secondary)
                Swatches(selection: $swatch)
                Picker("Size", selection: $width) { ForEach(widths.indices, id: \.self) { Text("\(widths[$0]) px wide").tag($0) } }
            }
            .task {
                var list: [CGImage] = []
                for f in files.prefix(24) { if let t = await ToolDialogs.decodeSmall(f, maxSide: 500) { list.append(t) } }
                thumbs = list
            }
        }
    }

    // ------------------------------------------------------------------ video and audio

    static func videoCompress(_ files: [String]) async -> VideoCompressOptions? {
        await ToolDialog.present("Compress video") { done in VideoCompressView(files: files, done: done) }
    }

    struct VideoCompressView: View {
        let files: [String]
        let done: (VideoCompressOptions?) -> Void
        @State private var preset = 0
        @State private var resolution = 3
        @State private var audio = 2
        @State private var target = "25"
        @State private var info = ""
        private let heights = [0, 2160, 1440, 1080, 720, 480]
        private let audios = [64, 96, 128, 160, 192]
        private let crfs = [23, 28, 32]
        private let hints = ["Visually close to the original, usually 40–70% smaller.", "Noticeably smaller files; fine for sharing in chats.",
                             "As small as possible; softer image.", "Aims just under the size (for example 25 MB for mail, 10 MB for Discord)."]

        var body: some View {
            DialogFrame(title: "Compress video", subtitle: DialogText.describe(files) + info, primary: "Compress", onCancel: { done(nil) }, onPrimary: submit) {
                Pills(options: ["Balanced", "Smaller", "Smallest", "Target size"], selection: $preset)
                Text(hints[preset]).font(.callout).foregroundColor(.secondary)
                Text("OPTIONS").font(.caption).bold().foregroundColor(.secondary)
                Picker("Resolution at most", selection: $resolution) {
                    ForEach(heights.indices, id: \.self) { i in Text(i == 0 ? "Keep resolution" : i == 1 ? "4K (2160p)" : "\(heights[i])p").tag(i) }
                }
                Picker("Audio", selection: $audio) { ForEach(audios.indices, id: \.self) { Text("\(audios[$0]) kbps").tag($0) } }
                if preset == 3 {
                    HStack { Text("Aim for at most"); TextField("", text: $target).frame(width: 70); Text("MB") }
                }
            }
            .onChange(of: preset) { p in if p == 2 && resolution < 4 { resolution = 4 } }
            .task {
                if let i = try? await AVMedia.info(files[0]), i.hasVideo {
                    let m = Int(i.duration) / 60, s = Int(i.duration) % 60
                    info = " · \(i.width)×\(i.height) · \(m):\(String(format: "%02d", s))"
                }
            }
        }

        func submit() {
            let bytes: Int64? = preset == 3 ? Double(target.replacingOccurrences(of: ",", with: ".")).map { Int64($0 * 1_000_000) } : nil
            let h = heights[resolution]
            done(VideoCompressOptions(crf: crfs[min(preset, 2)], maxHeight: h > 0 ? h : nil, audioKbps: audios[audio], targetBytes: bytes))
        }
    }

    static func audioCompress(_ files: [String]) async -> Int? {
        await ToolDialog.present("Compress audio") { done in AudioCompressView(files: files, done: done) }
    }

    struct AudioCompressView: View {
        let files: [String]
        let done: (Int?) -> Void
        @State private var rate = 2
        @State private var duration = 0.0
        private let rates = [64, 96, 128, 160, 192]

        var body: some View {
            DialogFrame(title: "Compress audio", subtitle: DialogText.describe(files), primary: "Compress",
                        onCancel: { done(nil) }, onPrimary: { done(rates[rate]) }) {
                HStack { Text("Bitrate (kbps)"); Pills(options: rates.map(String.init), selection: $rate) }
                if duration > 0 { Text("≈ \(FileKinds.humanSize(Int64(duration * Double(rates[rate]) * 1000 / 8))) per file").bold() }
                Text("128 kbps sounds great for speech and most music. 64–96 kbps is fine for podcasts and voice notes.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .task { duration = (try? await AVMedia.info(files[0]).duration) ?? 0 }
        }
    }
}
