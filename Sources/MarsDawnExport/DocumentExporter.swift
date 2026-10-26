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
/// and "paginate" in subsystem dev.southern-light.marsdawn-kit, category Performance (the app's
/// own signposts use dev.southern-light.marsdawn, category Performance; a predicate of
/// `subsystem BEGINSWITH "dev.southern-light.marsdawn"`, or `xcrun xctrace record --template
/// 'os_signpost'`, captures both processes). "render" and "push" share their names
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
        /// The manual layout was asked for on a job that doesn't save straight to a file: a
        /// print panel, or a disposition other than `.save` with a saving URL. Its page numbers
        /// come from a first print of the same page, which only a file can give; nothing was
        /// printed. Export the manual layout as a PDF instead (and print that PDF).
        case manualLayoutNeedsSave
        /// The manual layout's second pass paginated differently from the first, so its page
        /// numbers would be wrong; nothing was written.
        case manualLayoutPaginationChanged
        /// The document is larger than `limit` UTF-8 bytes, the renderer's byte cap
        /// (`ParseLimits.defaultMaxBytes`). Refused before the page loaded: nothing was rendered,
        /// printed or written.
        case inputTooLarge(limit: Int)

        public var errorDescription: String? {
            switch self {
            case .pageLoadFailed:
                String(localized: "The document couldn’t be laid out for export.")
            case .contentTimedOut:
                String(localized: "The document took too long to lay out for export.")
            case .printFailed:
                String(localized: "The document couldn’t be exported.")
            case .manualLayoutNeedsSave:
                String(localized: "The Handbook layout can only be exported as a PDF file, not printed directly.")
            case .manualLayoutPaginationChanged:
                String(localized: "The Handbook layout’s page numbers couldn’t be worked out for this document, so nothing was saved. Try again with the Document layout.")
            case .inputTooLarge(let limit):
                String(localized: "The document is too large to export: the limit is \(limit.formatted(.byteCount(style: .memory))).")
            }
        }
    }

    private static let log = Logger(subsystem: "dev.southern-light.marsdawn-kit", category: "Export")
    private nonisolated static let signposter = OSSignposter(subsystem: "dev.southern-light.marsdawn-kit", category: "Performance")
    /// Diagrams and images get this long to finish before export gives up.
    static let contentTimeout: Duration = .seconds(20)
    /// What this export waits; `contentTimeout` unless a test lengthens it (`ManualHooks.contentTimeout`).
    var contentTimeLimit: Duration = DocumentExporter.contentTimeout

    /// Exporters that are still printing; a print operation doesn't retain its web view's owner.
    private static var active: Set<DocumentExporter> = []

    public let webView: PreviewWKWebView
    let assets = DocumentAssetSchemeHandler()
    private var pageLoad: CheckedContinuation<Void, Error>?
    private let allowRemoteImages: Bool
    let layout: ExportLayout
    private var templateSignpost: OSSignpostIntervalState?

    /// - Parameters:
    ///   - baseDirectory: Folder that relative image paths resolve against (the document's folder).
    ///   - allowRemoteImages: Whether web images load; otherwise the page's CSP blocks them.
    ///   - width: Layout width before printing reflows the page: the paper width minus the
    ///     layout's left and right margins (`ExportLayout.printableWidth(paperWidth:)`).
    ///   - layout: The page layout; `.manual` starts every top-level heading on a new page.
    ///   - scopeRoot: The folder images may be read from, which must contain `baseDirectory`: a
    ///     folder the user granted, so `../` images above the document load as they do in the
    ///     app's preview. Nil, the default, is the document's own folder, as before.
    init(baseDirectory: URL?, allowRemoteImages: Bool, width: CGFloat = 700, scopeRoot: URL? = nil, layout: ExportLayout = .document) {
        assets.baseDirectory = baseDirectory
        assets.scopeRoot = scopeRoot
        self.allowRemoteImages = allowRemoteImages
        self.layout = layout
        let configuration = PreviewWebView.makeConfiguration(assets: assets)
        configuration.preferences.shouldPrintBackgrounds = true
        webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1000), configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        super.init()
        webView.navigationDelegate = self
    }

    /// A Mermaid diagram that failed to render (mars-dawn-kit#114). `fenceLine` and `line` are
    /// two different document lines, not a fallback pair — a diagram whose message names no
    /// line (e.g. "No diagram type detected") still has a `fenceLine` with no `line`.
    public struct DiagramError: Sendable, Decodable, Equatable {
        public let message: String
        /// The document line the diagram's fence (` ```mermaid `) starts on — the block's own
        /// `data-line`. Present whenever that's known; absent only when the fence itself has no
        /// `data-line` at all (e.g. a diagram inside a footnote's own text never gets one, #44).
        public let fenceLine: Int?
        /// The document line **of the error itself**: `fenceLine` plus Mermaid's own line number
        /// from inside its message, mapped the same way `preview.js`'s
        /// `mapMermaidLineToDocument` does. Present only when Mermaid's message actually names a
        /// line (some errors, like an undetected diagram type, don't) *and* `fenceLine` is known.
        public let line: Int?
    }

    /// Mermaid diagrams that failed to render in the prepared page, as their error messages.
    ///
    /// Kept as `[String]` — this is a public package and `export --json`'s `diagramErrors` is a
    /// published schema (marsdawn-mcp, mars-dawn-website) with `additionalProperties: false`, so
    /// neither this property's type nor that JSON field can change shape without breaking
    /// existing readers. `diagramErrorDetails` below carries the same failures with their
    /// document line, in the same order, additively.
    public private(set) var diagramErrors: [String] = []

    /// The same failures as `diagramErrors`, in the same order, each with its document line when
    /// known (mars-dawn-kit#114). Additive: `diagramErrors` is unchanged.
    public private(set) var diagramErrorDetails: [DiagramError] = []

    /// The HTML `prepare` put into the page, for the PDF corpus's preview parity check.
    private(set) var renderedHTML: String?

    /// Loads the page and renders `markdown` into it, waiting for diagrams, images and fonts.
    ///
    /// - Parameter footnoteBackLabel: The accessible label on a footnote's back-link, before its
    ///   number (`MarkdownRenderer.Options.footnoteBackLabel`). Defaults to the renderer's own
    ///   English default; the app passes the same localised string it uses for the preview and
    ///   Quick Look (#100).
    /// - Parameter softBreaksAsLineBreaks: `MarkdownRenderer.Options.softBreaksAsLineBreaks`: a
    ///   newline inside a paragraph becomes a line break (#129). The app passes the setting it
    ///   gives the preview and Quick Look, so the three agree.
    /// - Parameter calloutTitles: The default titles of callouts (#135), which the page draws. `nil`
    ///   takes the process's preferred languages (`CalloutTitles.preferred()`); the app passes its
    ///   own UI language, as it does for the labels above.
    public func prepare(
        markdown: String,
        theme: PreviewTheme,
        footnoteBackLabel: String = MarkdownRenderer.Options().footnoteBackLabel,
        softBreaksAsLineBreaks: Bool = false,
        calloutTitles: CalloutTitles? = nil
    ) async throws {
        let options = MarkdownRenderer.Options.preview(
            baseDirectory: assets.baseDirectory, footnoteBackLabel: footnoteBackLabel, softBreaksAsLineBreaks: softBreaksAsLineBreaks
        )
        try Self.refuseOverTheByteCap(markdown, options: options)
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

        // One deadline covers rendering, updating the page and waiting for its content.
        let deadline = ContinuousClock.now + contentTimeLimit
        let rendered = try await withExportDeadline(deadline, timeoutError: ExportError.contentTimedOut) {
            let renderSignpost = Self.signposter.beginInterval("render", id: Self.signposter.makeSignpostID())
            defer { Self.signposter.endInterval("render", renderSignpost) }
            return await MarkdownRenderer.renderResult(markdown, options: options)
        }
        guard let html = rendered?.html else { throw CancellationError() }
        renderedHTML = html
        let updateScript = PreviewWebView.updateScript(html: html, calloutTitles: calloutTitles)
        try await withExportDeadline(deadline, timeoutError: ExportError.contentTimedOut) { @MainActor [webView] in
            let pushSignpost = Self.signposter.beginInterval("push", id: Self.signposter.makeSignpostID())
            defer { Self.signposter.endInterval("push", pushSignpost) }
            _ = try await webView.evaluateJavaScript(updateScript)
        }
        // A collapsed `<details>` prints nothing of its body, so a PDF would lose it. Open every
        // one, before the wait so that diagrams and images inside get laid out. The script is
        // constant: nothing from the document goes into it. An exclusive group (`name`) lets only
        // one of its members stay open, so the name goes first. Front matter is left as it is
        // (print CSS hides it).
        _ = try await webView.evaluateJavaScript(Self.openAllDetailsScript)
        try await waitForContent(until: deadline)
        // JSON-encoded in JS so an unknown fenceLine/line can be genuinely absent from each
        // object, rather than `null`, matching what `DiagramError` expects to decode.
        let errorsJSON = try? await webView.evaluateJavaScript(
            #"""
            JSON.stringify([...document.querySelectorAll(".mermaid-block.error")].map((b) => {
              const fenceLineAttr = b.getAttribute("data-line");
              const errorLine = b.querySelector(".mermaid-error")?.getAttribute("data-doc-line");
              const entry = { message: b.getAttribute("data-error") || "" };
              if (fenceLineAttr !== null && fenceLineAttr !== "") entry.fenceLine = Number(fenceLineAttr);
              if (errorLine !== null && errorLine !== undefined) entry.line = Number(errorLine);
              return entry;
            }))
            """#
        )
        diagramErrorDetails = (errorsJSON as? String).flatMap {
            try? JSONDecoder().decode([DiagramError].self, from: Data($0.utf8))
        } ?? []
        diagramErrors = diagramErrorDetails.map(\.message)
        _ = try? await webView.evaluateJavaScript(Self.keepHeadingsWithNextScript)
        // After keep-with-next, so a heading kept with its block is broken before as one unit.
        _ = try? await webView.evaluateJavaScript(Self.pageBreaksScript(manual: layout == .manual))
    }

    private static let openAllDetailsScript = """
    (() => {
      for (const details of document.querySelectorAll("details:not(.front-matter)")) {
        details.removeAttribute("name");
        details.setAttribute("open", "");
      }
      return 0;
    })()
    """

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

    /// Forced page breaks, done here and not in the renderer, so the preview and Quick Look
    /// never see them. A `<!--BREAK-->` on its own line (the renderer's `div.html-block` that
    /// holds exactly that comment) puts the block after it on a new page, in every layout; in
    /// the manual layout each `h1` that is not the first thing on the page does too. The break
    /// goes before the following block rather than after the marker, so a marker followed by an
    /// `h1` is one break and never an empty page, and a marker with nothing after it is none.
    static func pageBreaksScript(manual: Bool) -> String {
        """
        (() => {
          const content = document.getElementById("content");
          if (!content) return 0;
          const style = document.createElement("style");
          style.textContent = "@media print { .export-page-break, .export-manual .export-h1-break { break-before: page; page-break-before: always; } }";
          document.head.append(style);
          const isMarker = (el) => {
            if (!el.matches || !el.matches("div.html-block")) return false;
            const nodes = [...el.childNodes].filter((n) => !(n.nodeType === 3 && n.textContent.trim() === ""));
            return nodes.length === 1 && nodes[0].nodeType === 8 && nodes[0].data === "BREAK";
          };
          const markers = [...content.querySelectorAll("div.html-block")].filter(isMarker);
          const skipped = (el) => el.classList.contains("front-matter") || markers.includes(el);
          const first = [...content.children].find((el) => !skipped(el));
          const breakBefore = (el, className) => { if (el && el !== first) el.classList.add(className); };
          for (const marker of markers) {
            marker.style.display = "none";
            let node = marker;
            while (node !== content && !node.nextElementSibling) node = node.parentElement;
            if (node !== content) breakBefore(node.nextElementSibling, "export-page-break");
          }
          if (\(manual ? "true" : "false")) {
            document.body.classList.add("export-manual");
            for (const h1 of content.querySelectorAll("h1")) {
              const wrapped = h1.parentElement.classList.contains("keep-with-next") && h1.parentElement.firstElementChild === h1;
              breakBefore(wrapped ? h1.parentElement : h1, "export-h1-break");
            }
          }
          return 0;
        })()
        """
    }

    /// Internal, not private, so `MathExportTests` can watch it return on a page whose math was
    /// skipped rather than rendered.
    func waitForContent(until deadline: ContinuousClock.Instant) async throws {
        // Diagrams settle as "rendered", "error" or "skipped" (over the per-update limit, left as
        // source with a note); "stale" means an older diagram is still shown.
        // Math settles as "math-done", which preview.js sets whether KaTeX rendered the
        // expression, showed an error for it or skipped it for being too long or too numerous.
        // So this waits for every expression to have been dealt with and can't hang on one.
        // KaTeX renders synchronously inside the same update, so in practice this is already
        // true at the first poll; no new timer, just one more term in the same readiness pass.
        // The KaTeX fonts are covered by the `document.fonts` check like any other font.
        let script = """
        const diagramsReady = [...document.querySelectorAll(".mermaid-block")]
          .every((b) => (b.classList.contains("rendered") || b.classList.contains("error") || b.classList.contains("skipped")) && !b.classList.contains("stale"));
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
        let margins = layout.pageMargins
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.leftMargin = margins.left
        info.rightMargin = margins.right
        let operation = webView.printOperation(with: info)
        // WebKit paginates on a secondary thread while the main thread fetches page data;
        // printing on the main thread alone never finishes.
        operation.canSpawnSeparateThread = true
        // WebKit's print view starts with a zero frame, which prints blank pages.
        operation.view?.frame = webView.bounds
        return operation
    }

    // MARK: Running

    /// Over the byte cap the renderer would only show the escaped source; export refuses instead,
    /// before the page loads, rather than paginate that (kit #150).
    static func refuseOverTheByteCap(_ markdown: String, options: MarkdownRenderer.Options) throws {
        if let limit = options.maxBytes, markdown.utf8.count > limit {
            throw ExportError.inputTooLarge(limit: limit)
        }
    }

    /// Prints or exports `markdown`, attached to `window` (or to a hidden window without one).
    /// `configure` adjusts the print info and operation, e.g. to save a PDF instead of printing.
    /// Returns whether the operation completed (false if the user cancelled).
    ///
    /// WebKit supplies page images asynchronously, so the operation always runs through
    /// `runModal(for:)`; a synchronous `run()` on the main thread never finishes paginating.
    ///
    /// - Parameters:
    ///   - footnoteBackLabel: Passed straight to `prepare(markdown:theme:footnoteBackLabel:softBreaksAsLineBreaks:)`
    ///     (#100).
    ///   - softBreaksAsLineBreaks: Likewise (#129).
    ///   - calloutTitles: Likewise (#135): the default titles of callouts in the printed page.
    @discardableResult
    public static func run(
        markdown: String,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        scopeRoot: URL? = nil,
        footnoteBackLabel: String = MarkdownRenderer.Options().footnoteBackLabel,
        softBreaksAsLineBreaks: Bool = false,
        layout: ExportLayout = .document,
        tocTitle: String = "Contents",
        displayName: String? = nil,
        calloutTitles: CalloutTitles? = nil,
        printInfo: NSPrintInfo,
        window: NSWindow?,
        configure: (NSPrintInfo, NSPrintOperation) -> Void = { _, _ in }
    ) async throws -> Bool {
        try await runReportingDiagrams(
            markdown: markdown, theme: theme, baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages,
            scopeRoot: scopeRoot, footnoteBackLabel: footnoteBackLabel, softBreaksAsLineBreaks: softBreaksAsLineBreaks,
            layout: layout, tocTitle: tocTitle, displayName: displayName, calloutTitles: calloutTitles, printInfo: printInfo, window: window, configure: configure
        ).completed
    }

    /// Like `run`, also reporting diagrams that failed to render.
    ///
    /// **Exact original shape, on purpose**: this 2-tuple, with these two labels, is public
    /// source the app already builds against as its own return type (`MarsDawnTests
    /// /ReviewPrompterTests.swift`'s `export(_:)` declares `-> (completed: Bool, diagramErrors:
    /// [String])` and returns this call directly) — kit is a public package, so this can't
    /// change shape. `runReportingDiagramDetails` below is the same operation, additionally
    /// reporting each failure's document line.
    public static func runReportingDiagrams(
        markdown: String,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        scopeRoot: URL? = nil,
        footnoteBackLabel: String = MarkdownRenderer.Options().footnoteBackLabel,
        softBreaksAsLineBreaks: Bool = false,
        layout: ExportLayout = .document,
        tocTitle: String = "Contents",
        displayName: String? = nil,
        calloutTitles: CalloutTitles? = nil,
        printInfo: NSPrintInfo,
        window: NSWindow?,
        configure: (NSPrintInfo, NSPrintOperation) -> Void = { _, _ in }
    ) async throws -> (completed: Bool, diagramErrors: [String]) {
        let result = try await runReportingDiagramDetails(
            markdown: markdown, theme: theme, baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages,
            scopeRoot: scopeRoot, footnoteBackLabel: footnoteBackLabel, softBreaksAsLineBreaks: softBreaksAsLineBreaks,
            layout: layout, tocTitle: tocTitle, displayName: displayName, calloutTitles: calloutTitles, printInfo: printInfo, window: window, configure: configure
        )
        return (result.completed, result.diagramErrors)
    }

    /// Like `runReportingDiagrams`, additionally reporting each failed diagram's document line
    /// (mars-dawn-kit#114). Additive: `runReportingDiagrams` itself is unchanged.
    public static func runReportingDiagramDetails(
        markdown: String,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        scopeRoot: URL? = nil,
        footnoteBackLabel: String = MarkdownRenderer.Options().footnoteBackLabel,
        softBreaksAsLineBreaks: Bool = false,
        layout: ExportLayout = .document,
        tocTitle: String = "Contents",
        displayName: String? = nil,
        calloutTitles: CalloutTitles? = nil,
        printInfo: NSPrintInfo,
        window: NSWindow?,
        configure: (NSPrintInfo, NSPrintOperation) -> Void = { _, _ in }
    ) async throws -> (completed: Bool, diagramErrors: [String], diagramErrorDetails: [DiagramError]) {
        try await runReportingDiagramDetails(
            markdown: markdown, theme: theme, baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages,
            scopeRoot: scopeRoot, footnoteBackLabel: footnoteBackLabel, softBreaksAsLineBreaks: softBreaksAsLineBreaks,
            layout: layout, tocTitle: tocTitle, displayName: displayName, calloutTitles: calloutTitles, printInfo: printInfo, window: window, inspect: nil, configure: configure
        )
    }

    /// What tests get to look at: the exporter that is about to print, after `prepare`.
    typealias Inspection = (DocumentExporter) async throws -> Void

    /// `inspect` runs on the same exporter between `prepare` and printing, so the PDF corpus
    /// checks the page that is actually printed, through the real export path.
    static func runReportingDiagramDetails(
        markdown: String,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        scopeRoot: URL? = nil,
        footnoteBackLabel: String = MarkdownRenderer.Options().footnoteBackLabel,
        softBreaksAsLineBreaks: Bool = false,
        layout: ExportLayout = .document,
        tocTitle: String = "Contents",
        displayName: String? = nil,
        calloutTitles: CalloutTitles? = nil,
        printInfo: NSPrintInfo,
        window: NSWindow?,
        inspect: Inspection?,
        hooks: ManualHooks = ManualHooks(),
        configure: (NSPrintInfo, NSPrintOperation) -> Void = { _, _ in }
    ) async throws -> (completed: Bool, diagramErrors: [String], diagramErrorDetails: [DiagramError]) {
        // Lay out at the printable width, so measured block heights match the printed pages.
        let printableWidth = layout.printableWidth(paperWidth: printInfo.paperSize.width)
        let exporter = DocumentExporter(
            baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages, width: printableWidth,
            scopeRoot: scopeRoot, layout: layout
        )
        if let contentTimeout = hooks.contentTimeout { exporter.contentTimeLimit = contentTimeout }
        active.insert(exporter)
        defer { active.remove(exporter) }
        try await exporter.prepare(
            markdown: markdown, theme: theme, footnoteBackLabel: footnoteBackLabel, softBreaksAsLineBreaks: softBreaksAsLineBreaks,
            calloutTitles: calloutTitles
        )
        try await inspect?(exporter)
        let operation = exporter.printOperation(printInfo: printInfo)
        configure(operation.printInfo, operation)
        let host = window ?? exporter.hiddenWindow()
        if layout == .manual {
            // Decided on the configured job, before anything prints: only a file can give the
            // first pass the page numbers come from.
            guard let destination = manualDestination(of: operation) else { throw ExportError.manualLayoutNeedsSave }
            try hooks.beforePrint?(operation)
            let completed = try await exporter.runManual(
                markdown: markdown, tocTitle: tocTitle, configured: operation, destination: destination,
                host: host, hooks: hooks
            )
            return (completed, exporter.diagramErrors, exporter.diagramErrorDetails)
        }
        if layout == .handout {
            let header = HandoutLayout.header(
                markdown: markdown, displayName: displayName, now: hooks.now ?? Date(), timeZone: hooks.timeZone ?? .current
            )
            let token = ManualLayout.makeToken()
            let tables = try await HandoutLayout.build(
                header, token: token, printableWidth: printableWidth, fitsTables: hooks.handoutFitsTables, in: exporter.webView
            )
            // The footer and the notes column's rule are drawn on a printed file, so a job that
            // doesn't save straight to one (a print panel) gets the header and the margins only.
            if let destination = manualDestination(of: operation) {
                try hooks.beforePrint?(operation)
                let completed = try await exporter.runHandout(
                    markdown: markdown, header: header, token: token, tables: tables, displayName: displayName, configured: operation,
                    destination: destination, host: host, hooks: hooks
                )
                return (completed, exporter.diagramErrors, exporter.diagramErrorDetails)
            }
        }
        try hooks.beforePrint?(operation)
        let completed = await exporter.run(operation, host: host)
        // A PDF saved to a file gets its text layer repaired: CJK radicals where the page shows
        // ideographs (mars-dawn-kit#18). Printing to paper has no text layer to repair.
        if completed, operation.printInfo.jobDisposition == .save,
           let url = operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL {
            ToUnicodeRepair.repairFile(at: url, source: markdown)
        }
        return (completed, exporter.diagramErrors, exporter.diagramErrorDetails)
    }

    /// Runs one print operation to completion through `runModal(for:)`.
    func run(_ operation: NSPrintOperation, host: NSWindow) async -> Bool {
        let paginateSignpost = Self.signposter.beginInterval("paginate", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("paginate", paginateSignpost) }
        return await withCheckedContinuation { continuation in
            let completion = Completion { continuation.resume(returning: $0) }
            operation.runModal(
                for: host,
                delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: Unmanaged.passRetained(completion).toOpaque()
            )
        }
    }

    /// The file a configured job saves to, if it is one the manual layout can run: `.save` to a
    /// file URL, with no print panel (a panel would let the user change the job after the
    /// manual layout's first pass).
    static func manualDestination(of operation: NSPrintOperation) -> URL? {
        guard !operation.showsPrintPanel, operation.printInfo.jobDisposition == .save,
              let url = operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL,
              url.isFileURL else { return nil }
        return url
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
        /// Additive (mars-dawn-kit#114): the same failures as `diagramErrors`, in the same
        /// order, each with its document line when known.
        public let diagramErrorDetails: [DiagramError]
    }

    /// Exports `markdown` straight to a PDF file, with no panels. Needs a running AppKit event loop.
    ///
    /// - Parameters:
    ///   - footnoteBackLabel: Passed straight to `prepare(markdown:theme:footnoteBackLabel:softBreaksAsLineBreaks:)`
    ///     (#100).
    ///   - softBreaksAsLineBreaks: Likewise (#129).
    ///   - calloutTitles: Likewise (#135): the default titles of callouts in the PDF.
    ///   - displayName: The handout layout's document name (S3 of mars-dawn#432), for its
    ///     footer and, without a front-matter title, its header: a file name without its
    ///     extension, never a path. Nil leaves the name out. Other layouts ignore it.
    public static func exportPDF(
        markdown: String,
        to url: URL,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        paper: Paper = .a4,
        scopeRoot: URL? = nil,
        footnoteBackLabel: String = MarkdownRenderer.Options().footnoteBackLabel,
        softBreaksAsLineBreaks: Bool = false,
        layout: ExportLayout = .document,
        tocTitle: String = "Contents",
        displayName: String? = nil,
        calloutTitles: CalloutTitles? = nil
    ) async throws -> PDFResult {
        try await exportPDF(
            markdown: markdown, to: url, theme: theme, baseDirectory: baseDirectory,
            allowRemoteImages: allowRemoteImages, paper: paper, scopeRoot: scopeRoot,
            footnoteBackLabel: footnoteBackLabel, softBreaksAsLineBreaks: softBreaksAsLineBreaks,
            layout: layout, tocTitle: tocTitle, displayName: displayName, calloutTitles: calloutTitles, inspect: nil
        )
    }

    /// `exportPDF` with the corpus's inspection hook; see `runReportingDiagramDetails(…inspect:…)`.
    static func exportPDF(
        markdown: String,
        to url: URL,
        theme: PreviewTheme,
        baseDirectory: URL?,
        allowRemoteImages: Bool,
        paper: Paper = .a4,
        scopeRoot: URL? = nil,
        footnoteBackLabel: String = MarkdownRenderer.Options().footnoteBackLabel,
        softBreaksAsLineBreaks: Bool = false,
        layout: ExportLayout = .document,
        tocTitle: String = "Contents",
        displayName: String? = nil,
        calloutTitles: CalloutTitles? = nil,
        inspect: Inspection?,
        hooks: ManualHooks = ManualHooks()
    ) async throws -> PDFResult {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = paper.size
        printInfo.orientation = .portrait
        let result = try await runReportingDiagramDetails(
            markdown: markdown, theme: theme, baseDirectory: baseDirectory,
            allowRemoteImages: allowRemoteImages, scopeRoot: scopeRoot, footnoteBackLabel: footnoteBackLabel,
            softBreaksAsLineBreaks: softBreaksAsLineBreaks, layout: layout, tocTitle: tocTitle, displayName: displayName,
            calloutTitles: calloutTitles, printInfo: printInfo, window: nil, inspect: inspect, hooks: hooks
        ) { info, operation in
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
        }
        guard result.completed, let document = PDFDocument(url: url) else { throw ExportError.printFailed }
        return PDFResult(
            url: url, pageCount: document.pageCount,
            diagramErrors: result.diagramErrors, diagramErrorDetails: result.diagramErrorDetails
        )
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
