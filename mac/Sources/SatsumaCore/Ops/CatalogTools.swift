import Foundation

extension Catalog {
    static func tool(_ id: String, _ label: String, _ glyph: String, _ caption: String, interactive: Bool = false, working: String? = nil,
                     _ run: @escaping (OpContext) async throws -> OpResult) -> WheelItem {
        WheelItem(id: "tool:" + id, label: label, glyph: glyph, caption: caption, dropText: label,
                  workingTitle: working ?? label + "…", interactive: interactive, run: run)
    }

    static func toolItems(_ files: [String]) -> [WheelItem] {
        let groups = distinct(files.map(groupOf))
        let many = files.count > 1
        var list: [WheelItem] = []
        var group = groups.count == 1 ? groups[0] : Group.none
        if groups.count == 2 && groups.contains(.gif) && groups.contains(.image) { group = .image }
        let ui = { Interact.current }

        switch group {
        case .image, .gif:
            list.append(tool("compress", "Compress", Glyphs.compress, "Smaller file", interactive: true) { ctx in
                guard let o = await ui().imageCompress(ctx.files) else { return .cancel() }
                ctx.beginWork("Compressing…")
                return try await forEach(ctx) { f, _ in try await ImageTools.compress(f, o) }
            })
            list.append(tool("resize", "Resize", Glyphs.resize, "Change size", interactive: true) { ctx in
                guard let o = await ui().imageResize(ctx.files) else { return .cancel() }
                ctx.beginWork("Resizing…")
                return try await forEach(ctx) { f, _ in try await ImageTools.resize(f, scale: o.scale, width: o.width, height: o.height) }
            })
            if !many {
                list.append(tool("crop", "Crop", Glyphs.crop, "Trim the edges", interactive: true) { ctx in
                    guard let rect = await ui().imageCrop(ctx.file) else { return .cancel() }
                    ctx.beginWork("Cropping…")
                    return .files([try await ImageTools.crop(ctx.file, rect)])
                })
            }
            list.append(tool("rotate", "Rotate", Glyphs.rotate, "90° clockwise", working: "Rotating…") { ctx in
                try await forEach(ctx) { f, _ in try await ImageTools.rotate(f, degrees: 90) }
            })
            list.append(tool("metadata", "Metadata", Glyphs.tag, "Strip photo info", working: "Removing metadata…") { ctx in
                try await forEach(ctx) { f, _ in try await ImageTools.stripMetadata(f) }
            })
            list.append(tool("ocr", "Text", Glyphs.text, "Copy its text", working: "Reading text…") { ctx in
                var texts: [String] = []
                for (i, f) in ctx.files.enumerated() {
                    texts.append(try await ImageTools.recognizeText(f))
                    ctx.reportItem(i, 1)
                }
                let all = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if all.isEmpty { throw OpError("No text found.") }
                try await ui().setClipboardText(all)
                return .done("Text copied", "\(DocTools.count(all).words) words on the clipboard")
            })
            list.append(tool("redact", "Redact", Glyphs.redact, "Hide faces, text", interactive: true) { ctx in
                guard let o = await ui().redact(ctx.files) else { return .cancel() }
                ctx.beginWork("Redacting…")
                return try await forEach(ctx) { f, _ in try await ImageTools.redact(f, faces: o.faces, text: o.text, style: o.style).output }
            })
            list.append(tool("background", "Backdrop", Glyphs.background, "Add background", interactive: true) { ctx in
                guard let o = await ui().background(ctx.files) else { return .cancel() }
                ctx.beginWork("Adding background…")
                return try await forEach(ctx) { f, _ in try await ImageTools.background(f, o) }
            })
            if many {
                list.append(tool("makepdf", "Make PDF", Glyphs.document, "Page per image", working: "Making PDF…") { ctx in
                    .files([try await ImageTools.makePdf(ctx.files) { p in ctx.report(p) }])
                })
                list.append(tool("collage", "Collage", Glyphs.grid, "Combine images", interactive: true) { ctx in
                    guard let o = await ui().collage(ctx.files) else { return .cancel() }
                    ctx.beginWork("Making collage…")
                    return .files([try await ImageTools.collage(ctx.files, o) { p in ctx.report(p) }])
                })
            }

        case .video:
            list.append(tool("compress", "Compress", Glyphs.compress, "Smaller file", interactive: true) { ctx in
                guard let o = await ui().videoCompress(ctx.files) else { return .cancel() }
                ctx.beginWork("Compressing video…")
                return try await forEach(ctx) { f, i in try await MediaTools.compressVideo(f, o) { p in ctx.reportItem(i, p) } }
            })
            if !many {
                list.append(tool("trim", "Trim", Glyphs.cut, "Cut start or end", interactive: true) { ctx in
                    guard let r = await ui().trim(ctx.file) else { return .cancel() }
                    ctx.beginWork("Trimming…")
                    return .files([try await MediaTools.trim(ctx.file, start: r.start, end: r.end) { p in ctx.report(p) }])
                })
            }
            list.append(tool("mute", "Mute", Glyphs.mute, "Remove audio", working: "Removing audio…") { ctx in
                try await forEach(ctx) { f, i in try await MediaTools.mute(f) { p in ctx.reportItem(i, p) } }
            })
            list.append(tool("720p", "720p", Glyphs.resize, "Scale to 720p", working: "Resizing to 720p…") { ctx in
                try await forEach(ctx) { f, i in try await MediaTools.resizeVideo(f, height: 720) { p in ctx.reportItem(i, p) } }
            })
            list.append(tool("rotate", "Rotate", Glyphs.rotate, "90° clockwise", working: "Rotating…") { ctx in
                try await forEach(ctx) { f, i in try await MediaTools.rotateVideo(f, clockwise: true) { p in ctx.reportItem(i, p) } }
            })
            list.append(tool("snapshot", "Frame", Glyphs.camera, "Still image", working: "Grabbing a frame…") { ctx in
                try await forEach(ctx) { f, _ in try await MediaTools.snapshot(f, at: nil) }
            })
            list.append(tool("normalize", "Loudness", Glyphs.volume, "Even volume", working: "Normalizing…") { ctx in
                try await forEach(ctx) { f, i in try await MediaTools.normalize(f) { p in ctx.reportItem(i, p) } }
            })
            if many {
                list.append(tool("merge", "Merge", Glyphs.merge, "Join clips", working: "Merging clips…") { ctx in
                    .files([try await MediaTools.merge(ctx.files) { p in ctx.report(p) }])
                })
            }

        case .audio:
            list.append(tool("compress", "Compress", Glyphs.compress, "Smaller file", interactive: true) { ctx in
                guard let kbps = await ui().audioCompress(ctx.files) else { return .cancel() }
                ctx.beginWork("Compressing audio…")
                return try await forEach(ctx) { f, i in try await MediaTools.compressAudio(f, kbps: kbps) { p in ctx.reportItem(i, p) } }
            })
            if !many {
                list.append(tool("trim", "Trim", Glyphs.cut, "Cut start or end", interactive: true) { ctx in
                    guard let r = await ui().trim(ctx.file) else { return .cancel() }
                    ctx.beginWork("Trimming…")
                    return .files([try await MediaTools.trim(ctx.file, start: r.start, end: r.end) { p in ctx.report(p) }])
                })
            }
            list.append(tool("normalize", "Loudness", Glyphs.volume, "Even volume", working: "Normalizing…") { ctx in
                try await forEach(ctx) { f, i in try await MediaTools.normalize(f) { p in ctx.reportItem(i, p) } }
            })
            list.append(tool("mono", "Mono", Glyphs.speaker, "One channel", working: "Mixing to mono…") { ctx in
                try await forEach(ctx) { f, i in try await MediaTools.mono(f) { p in ctx.reportItem(i, p) } }
            })
            list.append(tool("fade", "Fade", Glyphs.audio, "Fade in and out", working: "Adding fades…") { ctx in
                try await forEach(ctx) { f, i in try await MediaTools.fade(f, seconds: 2) { p in ctx.reportItem(i, p) } }
            })
            if many {
                list.append(tool("merge", "Merge", Glyphs.merge, "Join tracks", working: "Merging tracks…") { ctx in
                    .files([try await MediaTools.merge(ctx.files) { p in ctx.report(p) }])
                })
            }

        case .pdf:
            if many {
                list.append(tool("merge", "Merge", Glyphs.merge, "Into one PDF", working: "Merging PDFs…") { ctx in
                    .files([try PdfTools.merge(ctx.files)])
                })
            }
            list.append(tool("split", "Split", Glyphs.split, "PDF per page", working: "Splitting…") { ctx in
                try await forEach(ctx) { f, i in try PdfTools.split(f) { p in ctx.reportItem(i, p) } }
            })
            if !many {
                list.append(tool("extract", "Pages", Glyphs.pages, "Pick pages", interactive: true) { ctx in
                    guard let pages = await ui().pages(ctx.file) else { return .cancel() }
                    ctx.beginWork("Extracting pages…")
                    return .files([try PdfTools.extractPages(ctx.file, pages)])
                })
            }
            list.append(tool("images", "Images", Glyphs.photo, "Save images", working: "Extracting images…") { ctx in
                try await forEachMany(ctx) { f, i in try PdfTools.extractImages(f) { p in ctx.reportItem(i, p) } }
            })
            list.append(tool("compress", "Compress", Glyphs.compress, "Shrink file", working: "Compressing PDF…") { ctx in
                try await forEach(ctx) { f, i in try await PdfTools.flattenCompress(f, dpi: 150, quality: 72) { p in ctx.reportItem(i, p) } }
            })
            addTextTools(&list)

        case .doc, .sheet, .subtitle:
            addTextTools(&list)

        case .archive:
            list.append(tool("extract", "Extract", Glyphs.folderOpen, "Unpack here", working: "Extracting…") { ctx in
                try await forEach(ctx) { f, _ in try await ArchiveConverter.extract(f) }
            })

        case .folder:
            list.append(tool("zip", "Zip", Glyphs.package, "Make a ZIP", working: "Zipping…") { ctx in
                .files([try await ArchiveConverter.create(ctx.files, format: "zip") { p in ctx.report(p) }])
            })
            list.append(tool("info", "Size", Glyphs.info, "Folder size", working: "Measuring…") { ctx in
                var bytes: Int64 = 0
                var count = 0
                for dir in ctx.files {
                    guard let e = FileManager.default.enumerator(at: P.url(dir), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
                    for case let url as URL in e {
                        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                        bytes += Int64(v.fileSize ?? 0)
                        count += 1
                    }
                }
                return .done(FileKinds.humanSize(bytes), "\(TextUtil.n0(count)) files")
            })

        case .slides, .none:
            break
        }

        if many && group != .folder && !list.contains(where: { $0.id == "tool:zip" }) {
            list.append(tool("zip", "Zip", Glyphs.package, "One ZIP file", working: "Zipping…") { ctx in
                .files([try await ArchiveConverter.create(ctx.files, format: "zip") { p in ctx.report(p) }])
            })
        }
        return list
    }

    static func addTextTools(_ list: inout [WheelItem]) {
        list.append(tool("copytext", "Copy text", Glyphs.copy, "Copy all text", working: "Reading text…") { ctx in
            var parts: [String] = []
            for f in ctx.files { parts.append(try await DocTools.extractText(f)) }
            let text = parts.joined(separator: "\n\n")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OpError("No text found.") }
            try await Interact.current.setClipboardText(text)
            return .done("Text copied", "\(TextUtil.n0(DocTools.count(text).words)) words on the clipboard")
        })
        list.append(tool("count", "Count", Glyphs.text, "Word count", working: "Counting…") { ctx in
            var parts: [String] = []
            for f in ctx.files { parts.append(try await DocTools.extractText(f)) }
            let c = DocTools.count(parts.joined(separator: "\n"))
            return .done("\(TextUtil.n0(c.words)) words", "\(TextUtil.n0(c.chars)) characters · \(c.readingTime)")
        })
    }
}
