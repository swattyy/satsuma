import Foundation

extension Catalog {
    enum Group { case none, image, gif, video, audio, pdf, doc, slides, sheet, subtitle, archive, folder }

    static func groupOf(_ path: String) -> Group {
        switch FileKinds.kindOf(path) {
        case .image, .rawImage, .svg: return .image
        case .gif: return .gif
        case .video: return .video
        case .audio: return .audio
        case .pdf: return .pdf
        case .wordDoc, .text, .markdown, .html, .epub: return .doc
        case .slides: return .slides
        case .sheet: return .sheet
        case .subtitle: return .subtitle
        case .archive: return .archive
        case .folder: return .folder
        case .unknown: return .none
        }
    }

    static func convertItems(_ files: [String]) -> [WheelItem] {
        var groups = distinct(files.map(groupOf))
        // GIFs mixed with stills behave as images.
        if groups.count == 2 && groups.contains(.gif) && groups.contains(.image) { groups = [.image] }
        let exts = distinct(files.map(FileKinds.ext))
        let only: String? = exts.count == 1 ? exts[0] : nil
        func isSelf(_ t: String) -> Bool {
            guard let o = only else { return false }
            return o == t || (o == "jpeg" && t == "jpg") || (o == "tif" && t == "tiff") || (o == "heif" && t == "heic")
        }

        if groups.count != 1 { return ArchiveConverter.archiveTargets().map(archiveAll) }

        switch groups[0] {
        case .image:
            return ImageConverter.targets.filter { !isSelf($0) }.map { t in
                item(t) { f, _, _ in try await ImageConverter.convert(f, to: t) }
            }
        case .gif:
            return ["mp4", "webm", "webp", "png", "jpg", "pdf"].map { t in
                item(t) { f, _, _ in try await ImageConverter.convert(f, to: t) }
            }
        case .video:
            return MediaConverter.videoTargets.filter { !isSelf($0) && !($0 == "mp4" && only == "m4v") }.map { t in
                item(t, caption: t == "mp3" ? "Extract audio" : "Convert to",
                     dropText: t == "mp3" ? "Extract audio as %1" : nil,
                     working: t == "mp3" ? "Extracting audio…" : nil) { f, ctx, i in
                    try await MediaConverter.convert(f, to: t) { p in ctx.reportItem(i, p) }
                }
            }
        case .audio:
            return MediaConverter.audioTargets.filter { !isSelf($0) }.map { t in
                item(t) { f, ctx, i in try await MediaConverter.convert(f, to: t) { p in ctx.reportItem(i, p) } }
            }
        case .pdf:
            return PdfConverter.targets().map { t in
                itemMulti(t) { f, ctx, i in try await PdfConverter.convert(f, to: t) { p in ctx.reportItem(i, p) } }
            }
        case .doc:
            // Offer what every selected document can become.
            return intersect(exts.map { DocConverter.targets(for: $0) }).map { t in
                item(t) { f, _, _ in try await DocConverter.convert(f, to: t) }
            }
        case .slides:
            if !Engines.flags.powerPoint { return [] }
            var list = [
                item("pdf") { f, _, _ in try await SlidesConverter.convert(f, to: "pdf") },
                itemMulti("png") { f, _, _ in [try await SlidesConverter.images(f, format: "png")] },
                itemMulti("jpg") { f, _, _ in [try await SlidesConverter.images(f, format: "jpg")] },
            ]
            if only != "pptx" { list.insert(item("pptx") { f, _, _ in try await SlidesConverter.convert(f, to: "pptx") }, at: 1) }
            return list
        case .sheet:
            return intersect(exts.map { SheetConverter.targets(for: $0) }).map { t in
                item(t) { f, _, _ in try await SheetConverter.convert(f, to: t) }
            }
        case .subtitle:
            return SubtitleConverter.targets(for: only ?? "").map { t in
                item(t) { f, _, _ in try await SubtitleConverter.convert(f, to: t) }
            }
        case .archive:
            var list = [
                WheelItem(id: "convert:extract", label: "Extract", glyph: Glyphs.folderOpen, caption: "Unpack",
                          dropText: "Extract here", workingTitle: "Extracting…") { ctx in
                    try await forEach(ctx) { f, _ in try await ArchiveConverter.extract(f) }
                },
            ]
            list += ArchiveConverter.archiveTargets(excluding: only).map { t in
                item(t, label: ArchiveConverter.label(t)) { f, ctx, i in
                    try await ArchiveConverter.repack(f, to: t) { p in ctx.reportItem(i, p) }
                }
            }
            return list
        case .folder, .none:
            return ArchiveConverter.archiveTargets().map(archiveAll)
        }
    }

    /// A convert segment that runs `convert` on each file in turn.
    static func item(_ target: String, caption: String = "Convert to", label: String? = nil, dropText: String? = nil, working: String? = nil,
                     _ convert: @escaping (String, OpContext, Int) async throws -> String) -> WheelItem {
        let lbl = label ?? target.uppercased()
        return WheelItem(
            id: "convert:" + target,
            label: lbl,
            caption: caption,
            dropText: dropText ?? (caption == "Convert to" ? "Convert to %1" : caption + " %1"),
            workingTitle: working ?? ((caption == "Convert to" ? "Converting to " : caption + " ") + lbl + "…")
        ) { ctx in
            try await forEach(ctx) { f, i in try await convert(f, ctx, i) }
        }
    }

    static func itemMulti(_ target: String, _ convert: @escaping (String, OpContext, Int) async throws -> [String]) -> WheelItem {
        WheelItem(id: "convert:" + target, label: target.uppercased(), workingTitle: "Converting to \(target.uppercased())…") { ctx in
            try await forEachMany(ctx) { f, i in try await convert(f, ctx, i) }
        }
    }

    static func archiveAll(_ format: String) -> WheelItem {
        let label = ArchiveConverter.label(format)
        return WheelItem(id: "archive:" + format, label: label, caption: "Compress into", dropText: "Compress into %1",
                         workingTitle: "Compressing into \(label)…") { ctx in
            OpResult.files([try await ArchiveConverter.create(ctx.files, format: format) { p in ctx.report(p) }])
        }
    }
}
