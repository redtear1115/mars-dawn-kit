#if os(macOS)
import AppKit
import MarsDawnKit
import MarsDawnThemes
import WebKit

/// Renders a document to PNG images, for `marsdawn export --format png` (kit #243): what the
/// preview shows, one continuous page, so an agent can check its tables, diagrams, math and
/// images before a person reads the document.
///
/// The page is `DocumentExporter`'s offscreen page, prepared exactly as for a PDF (the same
/// template, content rules, CSP, byte cap and readiness wait), so a PNG and a PDF of one file show
/// the same content. Then, instead of printing:
///
/// 1. Every top-level block of `#content` gets the source lines it covers: from its own
///    `data-line` to the line before the next block's (the last block runs to the end of the
///    file). A block with no `data-line` of its own (the footnotes, which stand at the end) belongs
///    to the block before it. With a line range, every block that doesn't overlap it is hidden,
///    so a block is always shown whole (as Copy for AI widens a selection to whole blocks).
/// 2. The page is laid out at `width` CSS pixels and measured.
/// 3. It is cut into images of at most `maxHeight` pixels, each cut halfway into the gap between
///    two top-level blocks, never inside one: a table, a code block or a diagram is never split
///    (`slices`). A single block taller than `maxHeight` gets an image of its own, as tall as it
///    is, and is reported in `oversizedBlocks`.
/// 4. Each slice is captured and drawn into an sRGB bitmap of exactly its size
///    (`ThemePreviewRenderer.encode`), so the pixels don't depend on the display's colour profile
///    (kit #241).
package enum DocumentImageRenderer {
    package static let widthRange = ThemePreviewRenderer.widthRange
    package static let defaultWidth = ThemePreviewRenderer.defaultWidth
    /// The tallest image made, unless one block is taller than this on its own.
    package static let maxHeight = ThemePreviewRenderer.maxHeight

    /// A top-level block of the laid-out page: its vertical extent in CSS pixels from the top of
    /// the page, and the source lines it covers.
    package struct Block: Equatable, Sendable {
        package var top: Int
        package var bottom: Int
        package var firstLine: Int
        package var lastLine: Int
        /// A heading: the page is cut after it only when there is no other way to keep an image
        /// within `maxHeight`, so a heading doesn't end one image with its section in the next.
        package var keepsWithNext: Bool

        package init(top: Int, bottom: Int, firstLine: Int, lastLine: Int, keepsWithNext: Bool = false) {
            self.top = top
            self.bottom = bottom
            self.firstLine = firstLine
            self.lastLine = lastLine
            self.keepsWithNext = keepsWithNext
        }
    }

    /// One image's part of the page.
    package struct Slice: Equatable, Sendable {
        package var top: Int
        package var bottom: Int
        package var firstLine: Int
        package var lastLine: Int
        /// The slice is one block taller than `maxHeight` on its own.
        package var oversized: Bool

        package var height: Int { bottom - top }
    }

    package struct Image: Sendable {
        package let png: Data
        package let width: Int
        package let height: Int
        package let firstLine: Int
        package let lastLine: Int
    }

    package struct Result: Sendable {
        package let images: [Image]
        /// Mermaid diagrams that failed to render, among the blocks shown.
        package let diagramErrors: [DocumentExporter.DiagramError]
        /// The first source line of each block taller than `maxHeight` (its image is taller too).
        package let oversizedBlocks: [Int]
    }

    package enum RenderError: LocalizedError {
        case widthOutOfRange(Int)
        case nothingToRender

        package var errorDescription: String? {
            switch self {
            case .widthOutOfRange(let width): "width \(width) is outside \(widthRange.lowerBound)–\(widthRange.upperBound)"
            case .nothingToRender: "no block of the document is in the requested lines"
            }
        }
    }

    // MARK: Slicing

    /// Cuts the page from `pageTop` to `pageBottom` into slices of at most `maxHeight`, each cut
    /// halfway into the gap between two consecutive `blocks` (which must be in page order and not
    /// overlap). A slice never ends inside a block, and ends right after a heading
    /// (`keepsWithNext`) only when no other cut fits. When the next block alone doesn't fit in a
    /// slice of `maxHeight`, it gets a slice of its own as tall as it is (`oversized`). Pure, so
    /// the rule is tested without a page.
    package static func slices(blocks: [Block], pageTop: Int = 0, pageBottom: Int, maxHeight: Int = maxHeight) -> [Slice] {
        guard !blocks.isEmpty, pageBottom > pageTop else { return [] }
        // The cut between block i and block i + 1, halfway into the gap (or at the next block's
        // top if they touch or overlap by rounding).
        let cuts: [Int] = blocks.indices.dropLast().map { index in
            let gapTop = blocks[index].bottom, gapBottom = blocks[index + 1].top
            return gapBottom > gapTop ? gapTop + (gapBottom - gapTop) / 2 : gapBottom
        }
        var result: [Slice] = []
        var start = pageTop
        var firstBlock = 0
        while firstBlock < blocks.count {
            if pageBottom - start <= maxHeight {
                result.append(slice(start, pageBottom, blocks[firstBlock...]))
                break
            }
            // The last cut after `firstBlock` that keeps the slice within `maxHeight`, preferring
            // one that doesn't follow a heading.
            var preferred: Int?
            var any: Int?
            var index = firstBlock
            while index < cuts.count, cuts[index] - start <= maxHeight {
                if cuts[index] > start {
                    any = index
                    if !blocks[index].keepsWithNext { preferred = index }
                }
                index += 1
            }
            if let lastBlock = preferred ?? any {
                let end = cuts[lastBlock]
                result.append(slice(start, end, blocks[firstBlock...lastBlock]))
                start = end
                firstBlock = lastBlock + 1
            } else {
                // `blocks[firstBlock]` doesn't fit on its own: it gets a slice to the next cut.
                let end = firstBlock < cuts.count ? cuts[firstBlock] : pageBottom
                var oversized = slice(start, end, blocks[firstBlock...firstBlock])
                oversized.oversized = true
                result.append(oversized)
                start = end
                firstBlock += 1
            }
        }
        return result
    }

    private static func slice(_ top: Int, _ bottom: Int, _ blocks: ArraySlice<Block>) -> Slice {
        Slice(top: top, bottom: bottom, firstLine: blocks.first!.firstLine, lastLine: blocks.last!.lastLine, oversized: false)
    }

    /// The source lines of the section under the first heading whose title is `title`: from the
    /// heading's line to the line before the next heading of the same or a higher level, or to
    /// `lineCount`. The match ignores case and runs of whitespace. Nil if no heading matches.
    package static func headingLines(_ title: String, markdown: String) -> ClosedRange<Int>? {
        let wanted = normalizedTitle(title)
        guard !wanted.isEmpty else { return nil }
        let split = FrontMatter.split(markdown)
        let headings = DocumentOutline(markdownBody: String(split.body), lineOffset: split.bodyLineOffset).headings
        guard let index = headings.firstIndex(where: { normalizedTitle($0.title) == wanted }) else { return nil }
        let heading = headings[index]
        let end = headings[(index + 1)...].first(where: { $0.level <= heading.level }).map { $0.line - 1 } ?? lineCount(markdown)
        return heading.line...max(heading.line, end)
    }

    package static func normalizedTitle(_ title: String) -> String {
        title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// The number of lines in `markdown`, as the editor counts them (a final newline ends the last
    /// line; it doesn't start another).
    package static func lineCount(_ markdown: String) -> Int {
        guard !markdown.isEmpty else { return 1 }
        let newlines = markdown.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return markdown.utf8.last == 0x0A ? newlines : newlines + 1
    }

    // MARK: Rendering

    /// Renders `markdown` with `theme` in `appearance` at `width`, keeping only the blocks that
    /// overlap `lines` when given, and returns its images.
    ///
    /// `registry` serves the page's theme CSS; nil is the built-in themes (a `--theme`). A
    /// `--theme-file` passes `ThemeRegistry(serving: [validated])`, as `theme preview` does.
    /// `inspect` is for tests: it runs against the prepared, laid-out page before it is captured.
    @MainActor
    package static func render(
        markdown: String,
        theme: PreviewTheme,
        registry: ThemeRegistry? = nil,
        appearance: ThemePreviewRenderer.Appearance = .light,
        width: Int = defaultWidth,
        baseDirectory: URL?,
        allowRemoteImages: Bool = false,
        softBreaksAsLineBreaks: Bool = false,
        lines: ClosedRange<Int>? = nil,
        calloutTitles: CalloutTitles? = nil,
        maxHeight: Int = maxHeight,
        inspect: ((PreviewWKWebView) async throws -> Void)? = nil
    ) async throws -> Result {
        guard widthRange.contains(width) else { throw RenderError.widthOutOfRange(width) }
        let make = { DocumentExporter(baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages, width: CGFloat(width)) }
        let exporter = registry.map { ThemeRegistry.$override.withValue($0, operation: make) } ?? make()
        let webView = exporter.webView
        webView.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        try await exporter.prepare(
            markdown: markdown, theme: theme, softBreaksAsLineBreaks: softBreaksAsLineBreaks, calloutTitles: calloutTitles
        )

        let total = lineCount(markdown)
        let lower = lines?.lowerBound ?? 1, upper = lines?.upperBound ?? total
        _ = try await webView.evaluateJavaScript(Self.selectBlocksScript(lineCount: total, lower: lower, upper: upper))
        // Measured in a view 1 pixel tall: the page's scroll height is never less than the
        // view's, so a short page measured in the exporter's own frame would get blank space.
        webView.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 1)
        webView.layoutSubtreeIfNeeded()
        _ = try? await webView.evaluateJavaScript("document.documentElement.getBoundingClientRect().height")
        let pageHeight = try await measuredHeight(webView)
        webView.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(pageHeight))
        webView.layoutSubtreeIfNeeded()
        // Layout after the resize (reading a layout property forces it); no requestAnimationFrame:
        // an offscreen view gets no frames.
        _ = try? await webView.evaluateJavaScript("document.documentElement.getBoundingClientRect().height")
        let blocks = try await shownBlocks(webView)
        guard !blocks.isEmpty else { throw RenderError.nothingToRender }
        if let inspect { try await inspect(webView) }

        let pageSlices = slices(blocks: blocks, pageBottom: try await measuredHeight(webView), maxHeight: maxHeight)
        var images: [Image] = []
        for slice in pageSlices {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = NSRect(x: 0, y: CGFloat(slice.top), width: CGFloat(width), height: CGFloat(slice.height))
            configuration.snapshotWidth = NSNumber(value: width)
            configuration.afterScreenUpdates = true
            let image = try await webView.takeSnapshot(configuration: configuration)
            let encoded = try ThemePreviewRenderer.encode(image, width: width, height: slice.height)
            images.append(Image(png: encoded.png, width: width, height: slice.height, firstLine: slice.firstLine, lastLine: slice.lastLine))
        }
        let shown = blocks.map { $0.firstLine...$0.lastLine }
        let errors = exporter.diagramErrorDetails.filter { error in
            guard let line = error.fenceLine else { return lines == nil }
            return shown.contains { $0.contains(line) }
        }
        let oversized = pageSlices.filter(\.oversized).map(\.firstLine)
        return Result(images: images, diagramErrors: errors, oversizedBlocks: oversized)
    }

    @MainActor
    private static func measuredHeight(_ webView: PreviewWKWebView) async throws -> Int {
        let measured = try await webView.evaluateJavaScript(
            "Math.ceil(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight))"
        ) as? Int ?? 0
        return max(measured, 1)
    }

    /// Marks every top-level block of `#content` with the lines it covers (`data-md-first`,
    /// `data-md-last`) and hides the ones outside `lower...upper`. Only numbers this function was
    /// given go into the script; nothing from the document does.
    package static func selectBlocksScript(lineCount: Int, lower: Int, upper: Int) -> String {
        """
        (() => {
          const content = document.getElementById("content");
          if (!content) return 0;
          const blocks = [...content.children];
          const lineOf = (el) => {
            const own = el.getAttribute("data-line") ?? el.querySelector("[data-line]")?.getAttribute("data-line");
            const n = Number(own);
            return own !== null && own !== undefined && Number.isFinite(n) && n > 0 ? n : null;
          };
          const firsts = blocks.map(lineOf);
          let previous = 1;
          for (let i = 0; i < firsts.length; i++) {
            if (firsts[i] === null || firsts[i] < previous) firsts[i] = null; else previous = firsts[i];
          }
          for (let i = 0; i < blocks.length; i++) {
            let first = firsts[i];
            if (first === null) {
              // No line of its own (the footnotes): part of the block before it.
              let j = i - 1;
              while (j >= 0 && firsts[j] === null) j--;
              first = j >= 0 ? Number(blocks[j].dataset.mdLast) : 1;
            }
            let next = null;
            for (let j = i + 1; j < blocks.length; j++) { if (firsts[j] !== null) { next = firsts[j]; break; } }
            const last = Math.max(first, next === null ? \(lineCount) : next - 1);
            blocks[i].dataset.mdFirst = String(first);
            blocks[i].dataset.mdLast = String(last);
            if (first > \(upper) || last < \(lower)) blocks[i].style.display = "none";
          }
          return 0;
        })()
        """
    }

    /// The shown top-level blocks, in page order, with their extents and lines.
    @MainActor
    private static func shownBlocks(_ webView: PreviewWKWebView) async throws -> [Block] {
        let json = try await webView.evaluateJavaScript(
            #"""
            JSON.stringify([...document.getElementById("content")?.children ?? []]
              .filter((el) => el.style.display !== "none" && el.dataset.mdFirst && el.getClientRects().length > 0)
              .map((el) => {
                const rect = el.getBoundingClientRect();
                return { heading: /^H[1-6]$/.test(el.tagName), top: Math.floor(rect.top + window.scrollY), bottom: Math.ceil(rect.bottom + window.scrollY),
                         firstLine: Number(el.dataset.mdFirst), lastLine: Number(el.dataset.mdLast) };
              }))
            """#
        ) as? String ?? "[]"
        struct Raw: Decodable { let heading: Bool, top: Int, bottom: Int, firstLine: Int, lastLine: Int }
        let raw = (try? JSONDecoder().decode([Raw].self, from: Data(json.utf8))) ?? []
        return raw.map { Block(top: $0.top, bottom: $0.bottom, firstLine: $0.firstLine, lastLine: $0.lastLine, keepsWithNext: $0.heading) }
    }
}
#endif
