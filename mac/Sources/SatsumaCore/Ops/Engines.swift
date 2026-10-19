import Foundation

/// Which optional engines are around. The catalog checks these where the Windows app checks for
/// Microsoft Office: Cocoa's text system stands in for Word, LibreOffice (when installed) for Excel and PowerPoint.
public enum Engines {
    public struct Flags {
        public var word: Bool
        public var wordPerfect: Bool
        public var excel: Bool
        public var powerPoint: Bool
        public var pdfToPptx: Bool
    }

    /// Set by `--engines` so `--list` can be compared with the Windows app on a machine with or without Office.
    public static var forced: Flags?

    public static var flags: Flags {
        if let f = forced { return f }
        let lo = LibreOffice.path != nil
        return Flags(word: true, wordPerfect: lo, excel: lo, powerPoint: lo, pdfToPptx: lo)
    }

    /// "all" (like Windows with Office), "none" (like Windows without Office) or "auto".
    public static func force(_ spec: String) {
        switch spec.lowercased() {
        case "all": forced = Flags(word: true, wordPerfect: true, excel: true, powerPoint: true, pdfToPptx: true)
        case "none": forced = Flags(word: false, wordPerfect: false, excel: false, powerPoint: false, pdfToPptx: false)
        default: forced = nil
        }
    }
}

/// LibreOffice in headless mode, used for slides, legacy spreadsheets and WordPerfect files when it's installed.
public enum LibreOffice {
    private static var cached: String??

    public static var path: String? {
        if let c = cached { return c }
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            P.join(NSHomeDirectory(), "Applications/LibreOffice.app/Contents/MacOS/soffice"),
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
        ]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        cached = .some(found)
        return found
    }

    public static func reset() { cached = nil }

    /// Converts `input` with `soffice --convert-to` and moves the result to `output`.
    public static func convert(_ input: String, to format: String, output: String, filter: String? = nil, inFilter: String? = nil) async throws {
        guard let exe = path else { throw OpError("This conversion needs LibreOffice. Install it from libreoffice.org.") }
        let tmp = try AppPaths.newTempDir("soffice")
        defer { P.remove(tmp) }
        let profile = URL(fileURLWithPath: P.join(AppPaths.tempDir, "lo-profile")).absoluteString
        var args = ["-env:UserInstallation=\(profile)", "--headless", "--norestore", "--nologo", "--nodefault", "--nolockcheck"]
        if let inFilter { args.append("--infilter=\(inFilter)") }
        args += ["--convert-to", filter.map { "\(format):\($0)" } ?? format, "--outdir", tmp, input]
        let r = try await Proc.run(exe, args, timeout: 240)
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: tmp))?.first { !$0.hasPrefix(".") }
        guard let name = produced else {
            let detail = r.stderr.split(separator: "\n").last.map(String.init) ?? "exit code \(r.code)"
            throw OpError("LibreOffice couldn't convert this file (\(detail)).")
        }
        try P.move(P.join(tmp, name), output)
    }
}
