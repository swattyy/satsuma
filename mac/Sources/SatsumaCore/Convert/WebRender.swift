import AppKit
import WebKit

/// WebKit, offscreen: prints HTML to paginated PDF and rasterizes SVG. Everything here runs on the main thread.
public enum WebRender {
    @MainActor
    final class Page: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        let window: NSWindow
        private var waiting: CheckedContinuation<Void, Error>?

        init(width: CGFloat, height: CGFloat, transparent: Bool) {
            let config = WKWebViewConfiguration()
            config.suppressesIncrementalRendering = true
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
            // Printing and snapshots should never pick up dark mode.
            webView.appearance = NSAppearance(named: .aqua)
            if transparent { webView.setValue(false, forKey: "drawsBackground") }
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            super.init()
            webView.navigationDelegate = self
        }

        func load(html: String, baseURL: URL?) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiting = c
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }

        func load(file: URL, readAccess: URL) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiting = c
                webView.loadFileURL(file, allowingReadAccessTo: readAccess)
            }
        }

        private func finish(_ error: Error?) {
            guard let c = waiting else { return }
            waiting = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }

        func close() {
            webView.navigationDelegate = nil
            window.contentView = nil
            window.close()
        }
    }

    final class PrintWaiter: NSObject {
        var done: ((Bool) -> Void)?
        @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            done?(success)
            done = nil
        }
    }

    /// A4 with the margins the Windows app's print CSS uses (18 mm top/bottom, 17 mm left/right).
    @MainActor static func a4(saveTo output: String) -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 51
        info.bottomMargin = 51
        info.leftMargin = 48
        info.rightMargin = 48
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = URL(fileURLWithPath: output)
        return info
    }

    /// Prints an HTML string to a paginated PDF. Relative links resolve against `baseURL`.
    @MainActor public static func printHTML(_ html: String, baseURL: URL?, to output: String) async throws {
        let page = Page(width: 499, height: 700, transparent: false)
        defer { page.close() }
        try await page.load(html: html, baseURL: baseURL)
        try await run(page, output)
    }

    /// Prints an HTML file (its folder is readable, so images next to it load).
    @MainActor public static func printFile(_ path: String, to output: String) async throws {
        let page = Page(width: 499, height: 700, transparent: false)
        defer { page.close() }
        let url = P.url(path)
        try await page.load(file: url, readAccess: url.deletingLastPathComponent())
        try await run(page, output)
    }

    @MainActor static func run(_ page: Page, _ output: String) async throws {
        let op = page.webView.printOperation(with: a4(saveTo: output))
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = page.webView.bounds
        let waiter = PrintWaiter()
        let ok: Bool = await withCheckedContinuation { c in
            waiter.done = { c.resume(returning: $0) }
            op.runModal(for: page.window, delegate: waiter, didRun: #selector(PrintWaiter.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        if !ok || P.size(output) == 0 { throw OpError("Couldn't print this page to PDF.") }
    }

    /// Lays rich text out on A4 pages and saves them as PDF (DOCX, RTF, ODT and DOC input).
    @MainActor public static func printAttributed(_ text: NSAttributedString, to output: String) throws {
        let info = a4(saveTo: output)
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.isEditable = false
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(text)
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            view.frame = NSRect(x: 0, y: 0, width: width, height: max(100, ceil(used.height)))
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() || P.size(output) == 0 { throw OpError("Couldn't lay this document out as PDF.") }
    }

    // ------------------------------------------------------------------ SVG

    /// Rasterizes SVG at its own size, but at least 1024 px on the long side, with transparency.
    public static func rasterizeSVG(_ path: String) async throws -> CGImage {
        let data = try Data(contentsOf: P.url(path))
        var (w, h) = svgSize(data)
        let k = max(1, 1024 / max(w, h))
        w = (w * k).rounded(.up)
        h = (h * k).rounded(.up)
        let html = """
        <!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}\
        img{display:block;width:\(Int(w))px;height:\(Int(h))px}</style></head>\
        <body><img src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
        """
        return try await snapshot(html: html, width: Int(w), height: Int(h))
    }

    static func svgSize(_ data: Data) -> (Double, Double) {
        guard let doc = try? XMLDocument(data: data, options: []), let root = doc.rootElement() else { return (1024, 1024) }
        func number(_ s: String?) -> Double {
            guard let s else { return 0 }
            let digits = s.prefix { $0.isNumber || $0 == "." }
            return Double(digits) ?? 0
        }
        let aw = number(root.attribute(forName: "width")?.stringValue), ah = number(root.attribute(forName: "height")?.stringValue)
        if aw > 0 && ah > 0 { return (aw, ah) }
        if let vb = root.attribute(forName: "viewBox")?.stringValue {
            let parts = vb.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if parts.count == 4 && parts[2] > 0 && parts[3] > 0 { return (parts[2], parts[3]) }
        }
        return (1024, 1024)
    }

    @MainActor static func snapshot(html: String, width: Int, height: Int) async throws -> CGImage {
        let page = Page(width: CGFloat(width), height: CGFloat(height), transparent: true)
        defer { page.close() }
        try await page.load(html: html, baseURL: nil)
        _ = try? await page.webView.callAsyncJavaScript("const i = document.images[0]; if (i && i.decode) { await i.decode(); } return 1;",
                                                        arguments: [:], in: nil, in: .page)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        config.snapshotWidth = NSNumber(value: width)
        let image: NSImage = try await withCheckedThrowingContinuation { c in
            page.webView.takeSnapshot(with: config) { img, err in
                if let img { c.resume(returning: img) } else { c.resume(throwing: err ?? OpError("WebKit couldn't render this SVG.")) }
            }
        }
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw OpError("WebKit couldn't render this SVG.") }
        return cg.width == width && cg.height == height ? cg : ImageConverter.resample(cg, width: width, height: height)
    }
}
