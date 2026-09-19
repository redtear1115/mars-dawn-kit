#if os(macOS)
import AppKit
import MarsDawnKit
import OSLog
import PDFKit
import WebKit

/// Lays a document out in an offscreen preview page for printing and export.
///
/// Independent of any window's layout, so a document can be printed or exported even
/// while only its source is showing, or from a command-line tool with no window at all.
/// Always uses the light palette of the given theme.
///
/// Timing for the benchmark harness: intervals "template", "render", "push", "waitForContent"
/// and "paginate" in subsystem dev.southern-light.marsdawn, category Performance (the app side
/// uses the same subsystem/category, so one `log stream --signpost` or `xcrun xctrace record
/// --template 'os_signpost'` captures both processes). "render" and "push" share their names
/// with the app's preview signposts, but are distinct intervals here. Names and arguments:
///   - "template": the offscreen page's navigation, from `load(_:)` to `didFinish`/failure.
///   - "render": the `MarkdownRenderer.renderResult` call that turns Markdown into HTML.
///   - "push": the `evaluateJavaScript` call that updates the page with the rendered HTML.
///   - "waitForContent": the readiness poll loop. Its end event carries
///     `polls=<Int> outcome=<ready|timeout|error>`, the number of polls taken and how the
///     wait ended.
///   - "paginate": `NSPrintOperation.runModal`, which paginates and produces the PDF data.
@MainActor
public final class DocumentExporter: NSObject, WKNavigationDelegate {
    public enum ExportError: LocalizedError {
        case pageLoadFailed(Error)
        case contentTimedOut
        case printFailed

        public var errorDescription: String? {
            switch self {
            case .pageLoadFailed:
                String(localized: "The document couldn’t be laid out for export.")
            case .contentTimedOut:
                String(localized: "The document took too long to lay out for export.")
            case .printFailed:
                String(localized: "The document couldn’t be exported.")
            }
        }
    }

    private static let log = Logger(subsystem: "dev.southern-light.marsdawn", category: "Export")
    private nonisolated static let signposter = OSSignposter(subsystem: "dev.southern-light.marsdawn", category: "Performance")
    /// Diagrams and images get this long to finish before export gives up.
    private static let contentTimeout: Duration = .seconds(20)
    /// Side and top/bottom page margins in points (about 16 mm and 18 mm).
    private static let pageMargins = NSSize(width: 45, height: 51)

    /// Exporters that are still printing; a print operation doesn't retain its web view's owner.
    private static var active: Set<DocumentExporter> = []

    public let webView: PreviewWKWebView
    private let assets = DocumentAssetSchemeHandler()
    private var pageLoad: CheckedContinuation<Void, Error>?
    private let allowRemoteImages: Bool
    private var templateSignpost: OSSignpostIntervalState?

    /// - Parameters:
    ///   - baseDirectory: Folder that relative image paths resolve against (the document's folder).
    ///   - allowRemoteImages: Whether web images load; otherwise the page's CSP blocks them.
    ///   - width: Layout width before printing reflows the page.
    ///   - scopeRoot: The folder images may be read from, which must contain `baseDirectory`: a
    ///     folder the user granted, so `../` images above the document load as they do in the
    ///     app's preview. Nil, the default, is the document's own folder, as before.
    init(baseDirectory: URL?, allowRemoteImages: Bool, width: CGFloat = 700, scopeRoot: URL? = nil) {
        assets.baseDirectory = baseDirectory
        assets.scopeRoot = scopeRoot
        self.allowRemoteImages = allowRemoteImages
        let configuration = PreviewWebView.makeConfiguration(assets: assets)
        configuration.preferences.shouldPrintBackgrounds = true
        webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1000), configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        super.init()
        webView.navigationDelegate = self
    }

    /// Mermaid diagrams that failed to render in the prepared page, as their error messages.
    public private(set) var diagramErrors: [String] = []

    /// Loads the page and renders `markdown` into it, waiting for diagrams, images and fonts.
    public func prepare(markdown: String, theme: PreviewTheme) async throws {
        // The network rules go on before the page loads; without them, nothing loads.
        let rules: WKContentRuleList
        do {
            rules = try await PreviewContentRules.ruleList(allowRemoteImages: allowRemoteImages)
        } catch {
            Self.log.error("Export content rules failed to compile: \(error.localizedDescription, privacy: .public)")
            throw ExportError.pageLoadFailed(error)
        }
        webView.applyContentRuleList(rules)
        // Its own id, not the exclusive one: two exports, or an export during a preview load,
        // would otherwise report one tangled "template" interval instead of two.
        templateSignpost = Self.signposter.beginInterval("template", id: Self.signposter.makeSignpostID())
        try await withCheckedThrowingContinuation { continuation in
            pageLoad = continuation
            let url = PreviewSchemeHandler.pageURL(theme: theme, allowRemoteImages: allowRemoteImages)
            if webView.load(URLRequest(url: url)) == nil {
                failPageLoad(URLError(.cancelled))
            }
        }
        _ = try? await webView.evaluateJavaScript(PreviewWebView.themeScript(theme))
        // The export page has no window to offer a "Load Images" or "Grant Access" button (both
        // are hidden by print CSS anyway), so it only needs placeholder labels. A blocked remote
        // image gets the app's "Web image" wording; an http one gets the kit's own wording, since
        // no setting would have loaded it; a local image the exporter couldn't read gets one
        // neutral label, since the exporter can't tell a missing file from an ungranted folder.
        _ = try? await webView.evaluateJavaScript(PreviewWebView.remoteImagesScript(
            blocked: !allowRemoteImages,
            message: "",
            buttonLabel: "",
            placeholderLabel: PreviewWebView.webImagePlaceholderLabel,
            insecureLabel: PreviewWebView.insecureImagePlaceholderLabel
        ))
        _ = try? await webView.evaluateJavaScript(PreviewWebView.assetStateScript(
            needsAccess: false,
            grantLabel: "",
            missingLabel: PreviewWebView.unloadableImagePlaceholderLabel,
            blockedLabel: PreviewWebView.unloadableImagePlaceholderLabel
        ))

        let baseDirectory = assets.baseDirectory
        let options = MarkdownRenderer.Options { source in
            DocumentAssetSchemeHandler.previewURL(forImageSource: source, baseDirectory: baseDirectory) ?? source
        }
        // One deadline covers rendering, updating the page and waiting for its content.
        let deadline = ContinuousClock.now + Self.contentTimeout
        let rendered = try await withExportDeadline(deadline, timeoutError: ExportError.contentTimedOut) {
            let renderSignpost = Self.signposter.beginInterval("render", id: Self.signposter.makeSignpostID())
            defer { Self.signposter.endInterval("render", renderSignpost) }
            return await MarkdownRenderer.renderResult(markdown, options: options)
        }
        guard let html = rendered?.html else { throw CancellationError() }
        let updateScript = PreviewWebView.updateScript(html: html)
        try await withExportDeadline(deadline, timeoutError: ExportError.contentTimedOut) { @MainActor [webView] in
            let pushSignpost = Self.signposter.beginInterval("push", id: Self.signposter.makeSignpostID())
            defer { Self.signposter.endInterval("push", pushSignpost) }
            _ = try await webView.evaluateJavaScript(updateScript)
        }
        try await waitForContent(until: deadline)
        let errors = try? await webView.evaluateJavaScript(
            #"[...document.querySelectorAll(".mermaid-block.error")].map((b) => b.getAttribute("data-error") || "")"#
        )
        diagramErrors = errors as? [String] ?? []
        _ = try? await webView.evaluateJavaScript(Self.keepHeadingsWithNextScript)
    }

    /// Wraps each heading with the block that follows it, so a page never ends on a heading.
    /// Runs from the last heading up, so a heading followed by a subheading keeps both with
    /// the text after them. Blocks taller than about 40% of a page are left alone: keeping
    /// those together would leave large gaps.
    private static let keepHeadingsWithNextScript = """
    (() => {
      const budget = 300;
      const headings = [...document.querySelectorAll("#content > :is(h1, h2, h3, h4, h5, h6)")];
      for (const heading of headings.reverse()) {
        const next = heading.nextElementSibling;
        if (!next || next.offsetHeight > budget) continue;
        const keep = document.createElement("div");
        keep.className = "keep-with-next";
        heading.before(keep);
        keep.append(heading, next);
      }
      return 0;
    })()
    """


    /// Internal, not private, so `MathExportTests` can watch it return on a page whose math was
    /// skipped rather than rendered.
    func waitForContent(until deadline: ContinuousClock.Instant) async throws {
        // Diagrams settle as "rendered" or "error"; "stale" means an older diagram is still shown.
        // Math settles as "math-done", which preview.js sets whether KaTeX rendered the
        // expression, showed an error for it or skipped it for being too long or too numerous.
        // So this waits for every expression to have been dealt with and can't hang on one.
        // KaTeX renders synchronously inside the same update, so in practice this is already
        // true at the first poll; no new timer, just one more term in the same readiness pass.
        // The KaTeX fonts are covered by the `document.fonts` check like any other font.
        let script = """
        const diagramsReady = [...document.querySelectorAll(".mermaid-block")]
          .every((b) => (b.classList.contains("rendered") || b.classList.contains("error")) && !b.classList.contains("stale"));
        const mathReady = document.querySelectorAll(".math-inline:not(.math-done), .math-block:not(.math-done)").length === 0;
        const imagesReady = [...document.images].every((img) => img.complete);
        return diagramsReady && mathReady && imagesReady && document.fonts.status === "loaded";
        """
        let signpost = Self.signposter.beginInterval("waitForContent", id: Self.signposter.makeSignpostID())
        var polls = 0
        do {
            while ContinuousClock.now < deadline {
                polls += 1
                let ready = try await webView.callAsyncJavaScript(script, contentWorld: .page) as? Bool ?? false
                if ready {
                    Self.signposter.endInterval("waitForContent", signpost, "polls=\(polls) outcome=ready")
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            Self.signposter.endInterval("waitForContent", signpost, "polls=\(polls) outcome=error")
            throw error
        }
        Self.signposter.endInterval("waitForContent", signpost, "polls=\(polls) outcome=timeout")
        throw ExportError.contentTimedOut
    }

    /// A print operation for the prepared page. Keep the exporter alive until it has run.
    public func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = Self.pageMargins.height
        info.bottomMargin = Self.pageMargins.height
        info.leftMargin = Self.pageMargins.width
        info.rightMargin = Self.pageMargins.width
        let operation = webView.printOperation(with: info)
        // WebKit paginates on a secondary thread while the main thread fetches page data;
        // printing on the main thread alone never finishes.
        operation.canSpawnSeparateThread = true
        // WebKit's print view starts with a zero frame, which prints blank pages.
        operation.view?.frame = webView.bounds
        return operation
    }

    // MARK: Running

    /// Prints or exports `markdown`, attached to `window` (or to a hidden window without one).
    /// `configure` adjusts the print info and operation, e.g. to save a PDF instead of printing.
    /// Returns whether the operation completed (false if the user cancelled).
    ///
    /// WebKit supplies page images asynchronously, so the operation always runs through
    /// `runModal(for:)`; a synchronous `run()` on the main thread never finishes paginating.
    @discardableResult
    public static func run(
        markdown: String,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        scopeRoot: URL? = nil,
        printInfo: NSPrintInfo,
        window: NSWindow?,
        configure: (NSPrintInfo, NSPrintOperation) -> Void = { _, _ in }
    ) async throws -> Bool {
        try await runReportingDiagrams(
            markdown: markdown, theme: theme, baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages,
            scopeRoot: scopeRoot, printInfo: printInfo, window: window, configure: configure
        ).completed
    }

    /// Like `run`, also reporting diagrams that failed to render.
    public static func runReportingDiagrams(
        markdown: String,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        scopeRoot: URL? = nil,
        printInfo: NSPrintInfo,
        window: NSWindow?,
        configure: (NSPrintInfo, NSPrintOperation) -> Void = { _, _ in }
    ) async throws -> (completed: Bool, diagramErrors: [String]) {
        // Lay out at the printable width, so measured block heights match the printed pages.
        let printableWidth = printInfo.paperSize.width - 2 * pageMargins.width
        let exporter = DocumentExporter(
            baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages, width: printableWidth, scopeRoot: scopeRoot
        )
        active.insert(exporter)
        defer { active.remove(exporter) }
        try await exporter.prepare(markdown: markdown, theme: theme)
        let operation = exporter.printOperation(printInfo: printInfo)
        configure(operation.printInfo, operation)
        let host = window ?? exporter.hiddenWindow()
        let paginateSignpost = signposter.beginInterval("paginate", id: signposter.makeSignpostID())
        let completed = await withCheckedContinuation { continuation in
            let completion = Completion { continuation.resume(returning: $0) }
            operation.runModal(
                for: host,
                delegate: exporter,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: Unmanaged.passRetained(completion).toOpaque()
            )
        }
        signposter.endInterval("paginate", paginateSignpost)
        // A PDF saved to a file gets its text layer repaired: CJK radicals where the page shows
        // ideographs (mars-dawn-kit#18). Printing to paper has no text layer to repair.
        if completed, operation.printInfo.jobDisposition == .save,
           let url = operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL {
            ToUnicodeRepair.repairFile(at: url, source: markdown)
        }
        return (completed, exporter.diagramErrors)
    }

    public enum Paper: String, CaseIterable, Sendable {
        case a4, letter

        var size: NSSize {
            switch self {
            case .a4: NSSize(width: 595, height: 842)
            case .letter: NSSize(width: 612, height: 792)
            }
        }
    }

    public struct PDFResult: Sendable {
        public let url: URL
        public let pageCount: Int
        public let diagramErrors: [String]
    }

    /// Exports `markdown` straight to a PDF file, with no panels. Needs a running AppKit event loop.
    public static func exportPDF(
        markdown: String,
        to url: URL,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        paper: Paper = .a4,
        scopeRoot: URL? = nil
    ) async throws -> PDFResult {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = paper.size
        printInfo.orientation = .portrait
        let result = try await runReportingDiagrams(
            markdown: markdown, theme: theme, baseDirectory: baseDirectory,
            allowRemoteImages: allowRemoteImages, scopeRoot: scopeRoot, printInfo: printInfo, window: nil
        ) { info, operation in
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
        }
        guard result.completed, let document = PDFDocument(url: url) else { throw ExportError.printFailed }
        return PDFResult(url: url, pageCount: document.pageCount, diagramErrors: result.diagramErrors)
    }

    private var hostWindow: NSWindow?

    /// A never-shown window to attach the operation to when there is no document window.
    private func hiddenWindow() -> NSWindow {
        if let hostWindow { return hostWindow }
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        hostWindow = window
        return window
    }

    private final class Completion: @unchecked Sendable {
        let handler: (Bool) -> Void
        init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    }

    /// AppKit may call this off the main thread when the operation shows no panels.
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        let completion = Unmanaged<Completion>.fromOpaque(contextInfo).takeRetainedValue()
        completion.handler(success)
    }

    // MARK: WKNavigationDelegate

    /// Tells the page whether web images are blocked, with the app preview's placeholder label.
    /// Sent before the content, so a blocked image's placeholder already has the label.
    private func pushRemoteImageState() {
        webView.evaluateJavaScript(PreviewWebView.remoteImagesScript(
            blocked: !allowRemoteImages, message: "", buttonLabel: "", placeholderLabel: KitStrings.webImage
        ))
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let templateSignpost {
            Self.signposter.endInterval("template", templateSignpost)
            self.templateSignpost = nil
        }
        if pageLoad != nil { pushRemoteImageState() }
        pageLoad?.resume()
        pageLoad = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failPageLoad(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failPageLoad(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failPageLoad(URLError(.cancelled))
    }

    private func failPageLoad(_ error: Error) {
        Self.log.error("Export page failed to load: \(error.localizedDescription, privacy: .public)")
        if let templateSignpost {
            Self.signposter.endInterval("template", templateSignpost, "outcome=failed")
            self.templateSignpost = nil
        }
        pageLoad?.resume(throwing: ExportError.pageLoadFailed(error))
        pageLoad = nil
    }

    /// Only the page template itself may load; links never navigate the export page.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isTemplate = url?.scheme == PreviewSchemeHandler.scheme
            && url?.host == PreviewSchemeHandler.pageURL.host
            && url?.path == PreviewSchemeHandler.pageURL.path
            && navigationAction.navigationType == .other
        decisionHandler(isTemplate && pageLoad != nil ? .allow : .cancel)
    }
}
#endif
