#if os(macOS)
import AppKit
import MarsDawnKit
import PDFKit
import WebKit

/// Test seams for the manual layout's run (internal; production passes none).
struct ManualHooks {
    /// Called with the configured operation right before anything prints, in every layout;
    /// throwing stops the run there.
    var beforePrint: ((NSPrintOperation) throws -> Void)?
    /// Called after pass A printed, with its file; throwing (or cancelling the task) stops the run.
    var afterPassA: ((URL) throws -> Void)?
    /// Receives what the manual run measured, before its private folder is removed.
    var report: ((ManualReport) -> Void)?
    /// Called with the page after pass B printed, to read its state (the injection tests).
    var afterPassB: (@MainActor (WKWebView) async throws -> Void)?
}

/// What one manual run did, for the tests.
struct ManualReport {
    var workDirectory: URL
    var passAURL: URL
    var token: String
    var cover: ManualLayout.Cover?
    var coverHTML: String
    var headings: [ManualLayout.Heading]
    var placements: [ManualLayout.Placement?]
    var numbers: [Int?]
    var bodyStart: Int
    var hasContents: Bool
    var passA: Data
    var passB: Data
    /// The footer and bookmarks drawn, before the repair.
    var unrepaired: Data
    var repair: ToUnicodeRepair.Outcome
    var footerFont: String
    var footerText: String
}

extension DocumentExporter {
    /// The manual layout's two passes and post-processing (see `ManualLayout`). Writes only the
    /// final file to `destination`, in one atomic write; every intermediate file lives in a
    /// private folder under the temporary directory that is removed on every way out.
    func runManual(
        markdown: String,
        tocTitle: String,
        configured: NSPrintOperation,
        destination: URL,
        host: NSWindow,
        hooks: ManualHooks
    ) async throws -> Bool {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("marsdawn-manual-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: work) }

        let token = ManualLayout.makeToken()
        let cover = ManualLayout.cover(markdown: markdown)
        let imageOptions = MarkdownRenderer.Options.preview(baseDirectory: assets.baseDirectory)
        let coverHTML = cover.map { ManualLayout.coverHTML($0, token: token, imageOptions: imageOptions) } ?? ""
        let built = try await webView.callAsyncJavaScript(
            ManualLayout.buildScript,
            arguments: ["token": token, "css": ManualLayout.stylesheet(token: token), "coverHTML": coverHTML, "tocTitle": tocTitle],
            in: nil, contentWorld: ManualLayout.world
        )
        guard let rows = built as? [[String: Any]] else { throw ExportError.printFailed }
        let headings = rows.map { ManualLayout.Heading(level: ($0["level"] as? Int) ?? 2, text: ($0["text"] as? String) ?? "") }
        // The cover's logo, like any image, has to be in before the page prints.
        try await waitForContent(until: ContinuousClock.now + Self.contentTimeout)
        _ = try await webView.callAsyncJavaScript(
            ManualLayout.addMarkersScript, arguments: ["token": token], in: nil, contentWorld: ManualLayout.world
        )

        let passAURL = work.appendingPathComponent("pass-a.pdf")
        guard await printPass(like: configured, to: passAURL, host: host) else { return false }
        try Task.checkCancellation()
        try hooks.afterPassA?(passAURL)
        try Task.checkCancellation()
        guard let passA = PDFDocument(url: passAURL) else { throw ExportError.printFailed }

        let placements = headings.indices.map { ManualLayout.place(ManualLayout.headingMarker(token, $0), in: passA) }
        let hasFront = cover != nil || !headings.isEmpty
        let frontMarker = hasFront ? ManualLayout.place(ManualLayout.frontEndMarker(token), in: passA) : nil
        guard let bodyStart = ManualLayout.bodyStart(frontMarker: frontMarker, hasFront: hasFront) else {
            throw ExportError.manualLayoutPaginationChanged
        }
        let numbers = ManualLayout.numbers(for: placements, bodyStart: bodyStart)
        // A heading whose marker wasn't found exactly once gets no number, and no bookmark.
        let usable = zip(placements, numbers).map { $1 == nil ? nil : $0 }
        _ = try await webView.callAsyncJavaScript(
            ManualLayout.fillNumbersScript,
            arguments: ["numbers": numbers.map { $0.map(String.init) ?? "\u{00A0}" }],
            in: nil, contentWorld: ManualLayout.world
        )

        let passBURL = work.appendingPathComponent("pass-b.pdf")
        guard await printPass(like: configured, to: passBURL, host: host) else { return false }
        try Task.checkCancellation()
        guard let passB = PDFDocument(url: passBURL) else { throw ExportError.printFailed }
        guard passB.pageCount == passA.pageCount else { throw ExportError.manualLayoutPaginationChanged }
        try await hooks.afterPassB?(webView)

        // The footer is drawn as PDFKit writes each page; the delegate must be in place before
        // a page is first touched, so that every page is a FooterPage.
        let footers = ManualLayout.Footers(
            bodyStart: bodyStart, pageCount: passB.pageCount, margins: layout.pageMargins,
            paperWidth: configured.printInfo.paperSize.width
        )
        passB.delegate = footers
        if let outline = ManualLayout.outline(headings: headings, placements: usable, in: passB) {
            passB.outlineRoot = outline
        }
        let finalURL = work.appendingPathComponent("manual.pdf")
        guard withExtendedLifetime(footers, { passB.write(to: finalURL) }) else { throw ExportError.printFailed }
        try Task.checkCancellation()

        let unrepaired = hooks.report == nil ? Data() : ((try? Data(contentsOf: finalURL)) ?? Data())
        // Once, on the final file. The caller's contents title is drawn in the body's fonts, so
        // its radicals (if any) are kept like the document's own; the footer has its own font.
        let generated = ToUnicodeRepair.GeneratedText(fonts: [footers.fontName], text: footers.allText)
        let outcome = ToUnicodeRepair.repairFile(at: finalURL, source: markdown + "\n" + tocTitle, generated: generated)

        if let report = hooks.report {
            report(ManualReport(
                workDirectory: work, passAURL: passAURL, token: token, cover: cover, coverHTML: coverHTML,
                headings: headings, placements: placements, numbers: numbers, bodyStart: bodyStart,
                hasContents: !headings.isEmpty, passA: (try? Data(contentsOf: passAURL)) ?? Data(),
                passB: (try? Data(contentsOf: passBURL)) ?? Data(), unrepaired: unrepaired, repair: outcome,
                footerFont: footers.fontName, footerText: footers.allText
            ))
        }

        // Our own file from the private folder, written to the caller's URL in one atomic
        // write: a copy, not a move, since the temporary folder may be on another volume.
        let finished = try Data(contentsOf: finalURL)
        try finished.write(to: destination, options: .atomic)
        return true
    }

    /// Prints the prepared page as `configured` would, but to `url` and never with a panel.
    private func printPass(like configured: NSPrintOperation, to url: URL, host: NSWindow) async -> Bool {
        let info = configured.printInfo.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = printOperation(printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = configured.showsProgressPanel
        return await run(operation, host: host)
    }
}
#endif
