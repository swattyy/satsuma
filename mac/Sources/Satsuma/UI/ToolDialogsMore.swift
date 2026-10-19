import AppKit
import SwiftUI
import AVFoundation
import PDFKit
import SatsumaCore

extension ToolDialogs {
    // ------------------------------------------------------------------ crop

    static func imageCrop(_ file: String) async -> PixelRect? {
        await ToolDialog.present("Crop", width: 600) { done in CropView(file: file, done: done) }
    }

    struct CropView: View {
        let file: String
        let done: (PixelRect?) -> Void
        @State private var image: CGImage?
        @State private var pixelSize = CGSize.zero
        /// Selection in image pixels, top-left origin.
        @State private var sel = CGRect.zero
        @State private var start: CGRect?
        @State private var aspect = 0
        private let aspects: [(String, Double?)] = [("Free", nil), ("Original", -1), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]

        var body: some View {
            DialogFrame(title: "Crop", subtitle: P.fileName(file), primary: "Crop", primaryEnabled: sel.width >= 1 && sel.height >= 1,
                        onCancel: { done(nil) }, onPrimary: {
                            let r = sel.integral
                            done(PixelRect(x: Int(r.minX), y: Int(r.minY), width: Int(r.width), height: Int(r.height)))
                        }) {
                GeometryReader { geo in
                    let fit = fitRect(in: geo.size)
                    ZStack(alignment: .topLeading) {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                            let k = fit.width / max(1, pixelSize.width)
                            let box = CGRect(x: fit.minX + sel.minX * k, y: fit.minY + sel.minY * k, width: sel.width * k, height: sel.height * k)
                            Path { p in p.addRect(fit); p.addRect(box) }
                                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                            Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                                .contentShape(Rectangle())
                                .gesture(DragGesture().onChanged { g in move(g.translation, k) }.onEnded { _ in start = nil })
                            ForEach(0..<4, id: \.self) { c in
                                let pt = CGPoint(x: c % 2 == 0 ? box.minX : box.maxX, y: c < 2 ? box.minY : box.maxY)
                                Circle().fill(Color.white).frame(width: 14, height: 14).shadow(radius: 1)
                                    .offset(x: pt.x - 7, y: pt.y - 7)
                                    .gesture(DragGesture().onChanged { g in resize(c, g.translation, k) }.onEnded { _ in start = nil })
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(height: 360)
                Pills(options: aspects.map(\.0), selection: $aspect)
                Text(sel.width > 0 ? "\(Int(sel.width)) × \(Int(sel.height)) px from \(Int(sel.minX)), \(Int(sel.minY))" : "").font(.callout).monospacedDigit()
            }
            .task {
                if let d = try? await ImageConverter.decode(file) {
                    pixelSize = CGSize(width: d.width, height: d.height)
                    let k = min(1, 1600 / CGFloat(max(d.width, d.height)))
                    image = k < 1 ? ImageConverter.resample(d.image, width: Int(CGFloat(d.width) * k), height: Int(CGFloat(d.height) * k)) : d.image
                    sel = CGRect(origin: .zero, size: pixelSize).insetBy(dx: pixelSize.width * 0.1, dy: pixelSize.height * 0.1)
                }
            }
            .onChange(of: aspect) { _ in applyAspect() }
        }

        func fitRect(in size: CGSize) -> CGRect {
            guard pixelSize.width > 0 else { return .zero }
            let k = min(size.width / pixelSize.width, size.height / pixelSize.height)
            let w = pixelSize.width * k, h = pixelSize.height * k
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }

        var ratio: Double? {
            guard let r = aspects[aspect].1 else { return nil }
            return r < 0 ? Double(pixelSize.width / max(1, pixelSize.height)) : r
        }

        func clamp(_ r: CGRect) -> CGRect {
            var r = r.standardized
            r.size.width = min(max(r.width, 8), pixelSize.width)
            r.size.height = min(max(r.height, 8), pixelSize.height)
            r.origin.x = min(max(r.minX, 0), pixelSize.width - r.width)
            r.origin.y = min(max(r.minY, 0), pixelSize.height - r.height)
            return r
        }

        func move(_ t: CGSize, _ k: CGFloat) {
            if start == nil { start = sel }
            guard let s = start else { return }
            sel = clamp(s.offsetBy(dx: t.width / k, dy: t.height / k))
        }

        func resize(_ corner: Int, _ t: CGSize, _ k: CGFloat) {
            if start == nil { start = sel }
            guard let s = start else { return }
            var x0 = s.minX, y0 = s.minY, x1 = s.maxX, y1 = s.maxY
            let dx = t.width / k, dy = t.height / k
            if corner % 2 == 0 { x0 += dx } else { x1 += dx }
            if corner < 2 { y0 += dy } else { y1 += dy }
            var r = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
            if let ratio {
                let h = r.width / CGFloat(ratio)
                if corner < 2 { r.origin.y = r.maxY - h }
                r.size.height = h
            }
            sel = clamp(r)
        }

        func applyAspect() {
            guard let ratio, pixelSize.width > 0 else { return }
            var w = sel.width, h = w / CGFloat(ratio)
            if h > pixelSize.height { h = pixelSize.height; w = h * CGFloat(ratio) }
            if w > pixelSize.width { w = pixelSize.width; h = w / CGFloat(ratio) }
            sel = clamp(CGRect(x: sel.midX - w / 2, y: sel.midY - h / 2, width: w, height: h))
        }
    }

    // ------------------------------------------------------------------ trim

    static func trim(_ file: String) async -> (start: Double, end: Double)? {
        let range: TrimRange? = await ToolDialog.present("Trim", width: 600) { done in TrimView(file: file, done: done) }
        return range.map { ($0.start, $0.end) }
    }

    struct TrimRange { let start: Double; let end: Double }

    struct TrimView: View {
        let file: String
        let done: (TrimRange?) -> Void
        @State private var duration = 0.0
        @State private var start = 0.0
        @State private var end = 0.0
        @State private var peaks: [Float] = []
        @State private var startFrame: CGImage?
        @State private var endFrame: CGImage?
        @State private var isVideo = false
        @State private var grab: Double?

        var body: some View {
            DialogFrame(title: "Trim", subtitle: P.fileName(file), primary: "Trim", primaryEnabled: end - start > 0.05,
                        onCancel: { done(nil) }, onPrimary: { done(TrimRange(start: start, end: end)) }) {
                if isVideo {
                    HStack(spacing: 12) {
                        Preview(image: startFrame, height: 130)
                        Preview(image: endFrame, height: 130)
                    }
                }
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12))
                        Path { p in
                            for (i, v) in peaks.enumerated() {
                                let x = CGFloat(i) / CGFloat(max(1, peaks.count - 1)) * w
                                let a = CGFloat(v) * h * 0.45
                                p.move(to: CGPoint(x: x, y: h / 2 - a))
                                p.addLine(to: CGPoint(x: x, y: h / 2 + a))
                            }
                        }
                        .stroke(Color.secondary.opacity(0.7), lineWidth: 1)
                        if duration > 0 {
                            let x0 = CGFloat(start / duration) * w, x1 = CGFloat(end / duration) * w
                            Rectangle().fill(Color.tangerine.opacity(0.18)).frame(width: max(0, x1 - x0), height: h).offset(x: x0)
                            handle(x0, h)
                            handle(x1, h)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in drag(g.location.x / w) }.onEnded { _ in grab = nil; Task { await frames() } })
                }
                .frame(height: 90)
                HStack {
                    Text("Start \(clock(start))").monospacedDigit()
                    Spacer()
                    Text("Keeps \(clock(end - start))").bold().monospacedDigit()
                    Spacer()
                    Text("End \(clock(end))").monospacedDigit()
                }
                .font(.callout)
            }
            .task { await load() }
        }

        func handle(_ x: CGFloat, _ h: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: 2).fill(Color.tangerine).frame(width: 4, height: h).offset(x: x - 2)
        }

        func drag(_ f: Double) {
            let t = min(max(f, 0), 1) * duration
            if grab == nil { grab = abs(t - start) < abs(t - end) ? 0 : 1 }
            if grab == 0 { start = min(t, end - 0.1) } else { end = max(t, start + 0.1) }
        }

        func clock(_ t: Double) -> String {
            let total = max(0, t)
            let m = Int(total) / 60, s = total - Double(m * 60)
            return String(format: "%d:%04.1f", m, s)
        }

        func load() async {
            if let i = try? await AVMedia.info(file) {
                duration = i.duration
                isVideo = i.hasVideo
            } else if Ffmpeg.available {
                let i = Ffmpeg.probe(file)
                duration = i.duration
                isVideo = i.video != nil
            }
            end = duration
            peaks = await Waveform.peaks(file, buckets: 300)
            await frames()
        }

        func frames() async {
            guard isVideo, AVMedia.isNativeVideo(file) else { return }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: file)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            // The default tolerance returns the nearest keyframe, which for short clips is often the first frame.
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            startFrame = try? gen.copyCGImage(at: CMTime(seconds: start, preferredTimescale: 600), actualTime: nil)
            endFrame = try? gen.copyCGImage(at: CMTime(seconds: max(0, end - 0.05), preferredTimescale: 600), actualTime: nil)
        }
    }

    // ------------------------------------------------------------------ pages

    static func pages(_ file: String) async -> [Int]? {
        await ToolDialog.present("Extract pages", width: 640) { done in PagesView(file: file, done: done) }
    }

    /// Pick pages by clicking thumbnails or typing ranges like "1-3, 7". Every page starts out selected.
    struct PagesView: View {
        let file: String
        let done: ([Int]?) -> Void
        @State private var count = 0
        @State private var thumbs: [Int: NSImage] = [:]
        @State private var selected = Set<Int>()
        @State private var text = ""
        @State private var failed = false

        var body: some View {
            DialogFrame(title: "Extract pages", subtitle: failed ? "Couldn't read this PDF." : count > 0 ? "\(P.fileName(file)) · \(count) pages" : P.fileName(file),
                        primary: "Extract", primaryEnabled: !selected.isEmpty,
                        onCancel: { done(nil) }, onPrimary: { done(selected.sorted()) }) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(0..<count, id: \.self) { i in
                            VStack(spacing: 4) {
                                ZStack {
                                    if let t = thumbs[i] {
                                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Rectangle().fill(Color.gray.opacity(0.12))
                                    }
                                }
                                .frame(height: 134)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected.contains(i + 1) ? Color.tangerine : Color.gray.opacity(0.3),
                                                                                 lineWidth: selected.contains(i + 1) ? 3 : 1))
                                Text(verbatim: "\(i + 1)").font(.caption)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selected.contains(i + 1) { selected.remove(i + 1) } else { selected.insert(i + 1) }
                                text = PageRanges.format(selected.sorted())
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(height: 330)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pages to keep")
                    TextField("e.g. 1-3, 7", text: $text)
                }
                HStack(spacing: 6) {
                    pick("All") { _ in true }
                    pick("None") { _ in false }
                    pick("Odd") { $0 % 2 == 1 }
                    pick("Even") { $0 % 2 == 0 }
                }
            }
            .task {
                guard let doc = PDFDocument(url: URL(fileURLWithPath: file)), doc.pageCount > 0 else { failed = true; return }
                count = doc.pageCount
                selected = Set(1...count)
                text = PageRanges.format(selected.sorted())
                // Like Windows, only the first 120 pages get thumbnails; drawing them in small batches keeps the dialog responsive.
                for i in 0..<min(count, 120) {
                    if let p = doc.page(at: i) { thumbs[i] = p.thumbnail(of: NSSize(width: 208, height: 268), for: .cropBox) }
                    if i % 6 == 5 { await Task.yield() }
                }
            }
            .onChange(of: text) { t in selected = Set(PageRanges.parse(t, max: count)) }
        }

        private func pick(_ label: String, _ keep: @escaping (Int) -> Bool) -> some View {
            Button(label) {
                selected = Set((0..<count).map { $0 + 1 }.filter(keep))
                text = PageRanges.format(selected.sorted())
            }
        }
    }
}

enum PageRanges {
    static func format(_ pages: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < pages.count {
            var j = i
            while j + 1 < pages.count && pages[j + 1] == pages[j] + 1 { j += 1 }
            parts.append(j > i ? "\(pages[i])-\(pages[j])" : "\(pages[i])")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    static func parse(_ text: String, max: Int) -> [Int] {
        var result = Set<Int>()
        for part in text.split(whereSeparator: { ",; ".contains($0) }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let bits = part.split(whereSeparator: { $0 == "-" || $0 == "–" })
            if bits.count == 2, let a = Int(bits[0]), let b = Int(bits[1]) {
                for p in Swift.min(a, b)...Swift.max(a, b) where p >= 1 && (max == 0 || p <= max) { result.insert(p) }
            } else if let single = Int(part), single >= 1 && (max == 0 || single <= max) {
                result.insert(single)
            }
        }
        return result.sorted()
    }
}

/// Peak levels for the trim timeline, read with AVFoundation (empty if the file can't be read natively).
enum Waveform {
    static func peaks(_ file: String, buckets: Int) async -> [Float] {
        guard AVMedia.canRead(file) else { return [] }
        let asset = AVURLAsset(url: URL(fileURLWithPath: file))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000,
        ])
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        reader.startReading()
        var samples: [Int16] = []
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            chunk.withUnsafeMutableBytes { raw in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!) }
            samples += chunk
        }
        guard !samples.isEmpty else { return [] }
        let per = max(1, samples.count / buckets)
        var peaks: [Float] = []
        var i = 0
        while i < samples.count {
            let slice = samples[i..<min(samples.count, i + per)]
            let peak = slice.reduce(0) { max($0, abs(Int($1))) }
            peaks.append(Float(peak) / 32768)
            i += per
        }
        let top = peaks.max() ?? 1
        return top > 0 ? peaks.map { $0 / top } : peaks
    }
}
