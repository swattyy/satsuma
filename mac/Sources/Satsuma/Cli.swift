import AppKit
import AVFoundation
import SatsumaCore

/// Command line modes for testing without touching the mouse (the app is otherwise a menu bar app):
///   --convert <target> <files…>     run a Convert segment headlessly
///   --tool <id> <files…>            run a Tools segment with default options
///   --list <files…> [--engines all|none|auto]   list what each wheel would show
///   --selftest <files…>             offscreen checks of the drop path and hit-testing
///   --make-samples <dir>            write real sample files (photo, PDF, video, audio, documents...)
///   --render-test <dir>             render wheel frames and bubbles to PNG
/// Add --result out.json to any of them to get the result as JSON.
enum Cli {
    static let verbs: Set<String> = ["--convert", "--tool", "--list", "--selftest", "--make-samples", "--render-test", "--render-ui", "--make-icon"]

    static func handles(_ args: [String]) -> Bool { args.first.map(verbs.contains) ?? false }

    static func run(_ args: [String]) async -> Int32 {
        Runtime.isTestMode = true
        var resultPath: String?
        var rest: [String] = []
        var i = 1
        while i < args.count {
            if args[i] == "--result" && i + 1 < args.count { resultPath = args[i + 1]; i += 2; continue }
            if args[i] == "--engines" && i + 1 < args.count { Engines.force(args[i + 1]); i += 2; continue }
            rest.append(args[i])
            i += 1
        }
        var result: [String: Any] = [:]
        var code: Int32 = 0
        do {
            switch args[0] {
            case "--list":
                let files = rest.map(P.full)
                for kind in WheelKind.allCases {
                    let c = Catalog.build(kind, files)
                    result[kind.rawValue] = c.items.map(\.label)
                    result[kind.rawValue + "Hub"] = "\(c.hubCaption) | \(c.hubTitle)"
                }
                result["ok"] = true
            case "--convert", "--tool":
                guard let target = rest.first else { throw OpError("Usage: \(args[0]) <id> <files>") }
                let files = rest.dropFirst().map(P.full)
                let kind: WheelKind = args[0] == "--convert" ? .convert : .tools
                let items = Catalog.build(kind, files).items
                guard let item = items.first(where: { $0.id.lowercased().hasSuffix(":" + target.lowercased()) }) else {
                    throw OpError("No '\(target)' on the \(kind.rawValue) wheel for these files. Options: \(items.map(\.id).joined(separator: ", "))")
                }
                let ctx = OpContext(files: files)
                let events = Counter()
                ctx.onProgress = { _, _ in events.add() }
                let started = Date()
                let r = try await item.run(ctx)
                result["ok"] = !r.canceled
                result["outputs"] = r.outputs
                result["title"] = orNull(r.title)
                result["message"] = orNull(r.message)
                result["seconds"] = (Date().timeIntervalSince(started) * 100).rounded() / 100
                result["progressEvents"] = events.value
                result["outputSizes"] = r.outputs.map { P.isDir($0) ? -1 : P.size($0) }
            case "--selftest":
                let (checks, ok) = await SelfTest.run(rest.map(P.full))
                result["checks"] = checks
                result["environment"] = SelfTest.environment()
                result["ok"] = ok
                code = ok ? 0 : 1
            case "--make-samples":
                guard let dir = rest.first else { throw OpError("Usage: --make-samples <dir>") }
                result["files"] = try await Samples.make(in: P.full(dir))
                result["ok"] = true
            case "--make-icon":
                guard let dir = rest.first else { throw OpError("Usage: --make-icon <dir.iconset>") }
                result["files"] = try await MainActor.run { try AppIcon.writeIconset(P.full(dir)) }
                result["ok"] = true
            case "--render-test":
                guard let dir = rest.first else { throw OpError("Usage: --render-test <dir>") }
                result["files"] = try await RenderTest.run(P.full(dir))
                result["ok"] = true
            case "--render-ui":
                guard let dir = rest.first else { throw OpError("Usage: --render-ui <dir> [image] [video] [audio] [pdf]") }
                let samples = rest.dropFirst().map(P.full)
                result["files"] = try await MainActor.run { try RenderTest.ui(P.full(dir), samples) }
                result["ok"] = true
            default:
                break
            }
        } catch {
            code = 1
            result["ok"] = false
            result["error"] = (error as? OpError)?.message ?? "\(error)"
        }
        let json = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        if let resultPath { try? json.write(to: P.url(resultPath)) }
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        Log.info("CLI \(args.joined(separator: " ")) -> \(String(decoding: json, as: UTF8.self))")
        return code
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}

enum SelfTest {
    static func run(_ files: [String]) async -> ([String], Bool) {
        var checks: [String] = []
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            checks.append((cond ? "PASS " : "FAIL ") + what)
            ok = ok && cond
        }

        // The wheel reads dragged files from a pasteboard; make sure file URLs survive the trip.
        let read: [String] = await MainActor.run {
            let pb = NSPasteboard(name: NSPasteboard.Name("com.satsuma.selftest"))
            pb.clearContents()
            pb.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            pb.releaseGlobally()
            return urls.map { $0.path }
        }
        check(read == files, "file URL pasteboard round trip (\(read.count) paths)")

        let content = Catalog.build(.convert, read)
        check(!content.items.isEmpty, "convert wheel has \(content.items.count) items")
        for scale in [1.0, 1.25, 1.5, 2.0] as [CGFloat] {
            let L = WheelLayout(scale: scale, showHints: true)
            let n = max(1, content.items.count)
            var all = true
            for i in 0..<n {
                let a = WheelLayout.midAngle(i, n) * .pi / 180, r = (L.r + L.rIn) / 2
                all = all && L.hitTest(L.cx + cos(a) * r, L.cy + sin(a) * r, n) == i
                let span = 360 / CGFloat(n)
                for off in [-span * 0.45, span * 0.45] {
                    let b = (WheelLayout.midAngle(i, n) + off) * .pi / 180
                    all = all && L.hitTest(L.cx + cos(b) * L.r * 0.95, L.cy + sin(b) * L.r * 0.95, n) == i
                }
            }
            check(all, "hit-testing every segment at \(scale)x")
            check(L.hitTest(L.cx, L.cy, n) == -1, "hub is a no-drop zone at \(scale)x")
            check(L.hitTest(L.cx + L.r + 20 * scale, L.cy, n) >= 0, "magnetic zone just outside the ring at \(scale)x")
            check(L.hitTest(L.cx + L.hitRadius + 5, L.cy, n) == -2, "outside the halo at \(scale)x")
        }
        for kind in WheelKind.allCases {
            check(Catalog.build(kind, read).items.allSatisfy { !$0.label.isEmpty }, "\(kind.rawValue) wheel labels")
        }
        return (checks, ok)
    }

    static func environment() -> [String: Any] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "macOS": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "arch": machine(),
            "imageIOWritable": ImageConverter.writableTypes.sorted(),
            "imageIOReadable": ImageConverter.readableTypes.sorted(),
            "exportPresets": AVAssetExportSession.allExportPresets().sorted(),
            "ffmpeg": orNull(Ffmpeg.path),
            "libreOffice": orNull(LibreOffice.path),
            "homebrew": orNull(Ffmpeg.brewPath),
        ]
    }

    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

func orNull(_ s: String?) -> Any {
    if let s { return s }
    return NSNull()
}
