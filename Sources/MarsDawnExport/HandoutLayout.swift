#if os(macOS)
import AppKit
import CoreText
import MarsDawnKit
import PDFKit
import WebKit

/// The handout layout's header, notes column and footer (mars-dawn#432 S3).
///
/// One pass, on the page `DocumentExporter.prepare` already loaded:
/// 1. A title header goes before the body on page 1: the front matter's `title`, else the
///    caller's display name, with the date beneath. The body is inset from the right by the
///    notes column (`ExportLayout.notesColumnWidth`). Each table is measured: one that fits the
///    body keeps its natural width; a wider one runs into the column, up to the full printable
///    width; one wider still gets a fixed layout at that width, its cells wrapping anywhere
///    (amendment A1-R2, the owner's decision on 2026-10-21).
/// 2. The page prints once, at the document layout's margins, into a private folder under the
///    temporary directory.
/// 3. PDFKit draws a thin rule at the notes column's edge and the "name · date · n / N" footer
///    on every page, then the ToUnicode repair runs once on that file, which is then written to
///    the caller's URL in one atomic write.
///
/// Trust boundaries are the manual layout's (`ManualLayout`): the title, date and display name
/// reach the page only as `callAsyncJavaScript` arguments and the DOM only through
/// `textContent`. The stylesheet is scoped to an attribute on the root element named by a
/// random token made per export, which nothing inside the document's own HTML can set. The
/// display name is never a path, and it goes into no PDF metadata or outline.
@MainActor
enum HandoutLayout {
    /// What page 1's header shows: `title` is nil when the front matter has no title and the
    /// caller gave no display name (then there is no header).
    struct Header: Equatable {
        var title: String?
        var date: String
        /// Whether `title` is the display name, which then also prints in the body's fonts.
        var titleIsDisplayName: Bool
    }

    /// The header from the front matter's `title` and `date` (read like the manual layout's
    /// cover fields), falling back to `displayName` and to the export date.
    static func header(markdown: String, displayName: String?, now: Date, timeZone: TimeZone) -> Header {
        let values = frontMatterValues(markdown: markdown, keys: ["title", "date"])
        let name = displayName.map(sanitized).flatMap { $0.isEmpty ? nil : $0 }
        let title = values["title"].map(sanitized).flatMap { $0.isEmpty ? nil : $0 }
        let date = values["date"].map(sanitized).flatMap { $0.isEmpty ? nil : $0 } ?? exportDate(now: now, timeZone: timeZone)
        return Header(title: title ?? name, date: date, titleIsDisplayName: title == nil && name != nil)
    }

    /// The first value of each of `keys` in the front matter, unquoted, empty values left out.
    static func frontMatterValues(markdown: String, keys: Set<String>) -> [String: String] {
        guard let frontMatter = FrontMatter.split(markdown).frontMatter else { return [:] }
        var values: [String: String] = [:]
        for line in frontMatter.lines {
            guard let pair = FrontMatter.keyValue(in: line), keys.contains(pair.key), values[pair.key] == nil else { continue }
            values[pair.key] = ManualLayout.unquoted(pair.value)
        }
        return values.filter { !$0.value.isEmpty }
    }

    /// `now` as `yyyy-MM-dd` in `timeZone`, on the Gregorian calendar whatever the locale.
    nonisolated static func exportDate(now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    /// The Bidi_Control characters, which could reorder the footer around them.
    nonisolated static let bidiControls: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    /// `text` with Bidi_Control characters removed, C0/C1 controls and line or paragraph
    /// separators turned into spaces, and every run of whitespace collapsed into one space.
    nonisolated static func sanitized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !bidiControls.contains(scalar.value) {
            let isBreak = scalar.properties.generalCategory == .control || scalar.value == 0x2028 || scalar.value == 0x2029
            scalars.append(isBreak ? " " : scalar)
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Page

    /// The content world the handout's script runs in.
    static let world = WKContentWorld.world(name: "dev.southern-light.marsdawn-kit.handout")

    /// The root element's attribute that scopes the handout's stylesheet.
    static func rootAttribute(_ token: String) -> String { "data-" + token.lowercased() }

    /// A table's attribute for each width decision (`buildScript`), scoped like the root's.
    static func tableAttribute(_ token: String, _ fit: TableFit.Kind) -> String { rootAttribute(token) + "-" + fit.rawValue }

    /// WebKit lays a page out for printing at this many times the printable width, then scales
    /// it down to fit (its minimum shrink factor): a 15 px date prints at 12 pt. The export's own
    /// layout is at the printable width, so the script scales its measurements by this.
    nonisolated static let printLayoutScale = 1.25

    /// A table cell with a run of at least this many characters without a space (a URL, a
    /// path) may wrap inside it when the table is too wide otherwise.
    nonisolated static let longWord = 20

    /// The body's inset and the table rules, in fractions of the printable width, which hold
    /// at any print scale. Not print-only, so the page the script measures has the same body.
    static func stylesheet(token: String, printableWidth: CGFloat) -> String {
        let root = ":root[\(rootAttribute(token))]"
        let column = ExportLayout.notesColumnWidth / printableWidth
        let inset = String(format: "%.4f%%", column * 100)
        // 100% of the body widened to the printable width.
        let full = String(format: "%.4f%%", 100 / (1 - column))
        let span = "[\(tableAttribute(token, .span))]", wide = "[\(tableAttribute(token, .wide))]"
        func c(_ name: String) -> String { "." + ManualLayout.className(token, name) }
        return """
        \(c("header")) { margin: 0 \(inset) 1.4em 0; break-inside: avoid; page-break-inside: avoid; }
        \(c("title")) { font-size: 1.6em; font-weight: 700; line-height: 1.25; color: var(--heading); overflow-wrap: anywhere; }
        \(c("date")) { margin-top: 0.3em; color: var(--muted); overflow-wrap: anywhere; }
        \(root) .markdown-body, \(root) [data-theme] .markdown-body { max-width: none; margin: 0; padding: 0 \(inset) 0 0; }
        \(root) table\(span), \(root) table\(wide) { break-inside: avoid; page-break-inside: avoid; }
        \(root) table\(span) { max-width: \(full); background-color: white; }
        \(root) table\(wide) { display: table; table-layout: fixed; width: \(full); max-width: none; overflow: visible; background-color: white; }
        \(root) table\(wide) th, \(root) table\(wide) td, \(root) table [\(rootAttribute(token))-long] { overflow-wrap: anywhere; }
        """
    }

    /// How a table was fitted (amendment A1-R2), with its text for the tests' column probe.
    struct TableFit: Equatable {
        enum Kind: String { case natural, span, wide }
        var kind: Kind
        /// Its natural (max-content) width, CSS px.
        var width: Double
        var text: String
    }

    /// Marks the root, adds the stylesheet, and puts the header (when there is a title) before
    /// the body. Its data comes only through the arguments.
    static let buildScript = """
    const content = document.getElementById("content");
    if (!content) return false;
    const cls = (name) => token.toLowerCase() + "-" + name;
    document.documentElement.setAttribute("data-" + token.toLowerCase(), "");
    const style = document.createElement("style");
    style.textContent = css;
    document.head.append(style);
    if (title) {
      const header = document.createElement("header");
      header.className = cls("header");
      const titleLine = document.createElement("div");
      titleLine.className = cls("title");
      titleLine.textContent = title;
      const dateLine = document.createElement("div");
      dateLine.className = cls("date");
      dateLine.textContent = date;
      header.append(titleLine, dateLine);
      content.before(header);
    }
    // A span or wide table is kept whole (the stylesheet), so when it doesn't fit under its
    // heading it moves to the next page and leaves the heading alone at the foot of this one
    // (mars-dawn#491). Export's keep-with-next skips blocks taller than its budget, so wrap the
    // heading (and a heading run, or a kept heading pair, right before it) with the table here.
    const isHeading = (node) => node && /^H[1-6]$/.test(node.tagName);
    const endsWithHeading = (node) => node && node.classList.contains("keep-with-next") && isHeading(node.lastElementChild);
    const keepHeadingWith = (table) => {
      if (table.parentElement !== content) return;
      const lead = [];
      let previous = table.previousElementSibling;
      while (isHeading(previous) || endsWithHeading(previous)) {
        lead.unshift(previous);
        if (!isHeading(previous)) break;
        previous = previous.previousElementSibling;
      }
      if (lead.length === 0) return;
      const keep = document.createElement("div");
      keep.className = "keep-with-next";
      lead[0].before(keep);
      keep.append(...lead, table);
    };
    // Each table against the body's and the column's right edges as they will print: text
    // keeps its size in px, the page is `scale` times wider. A table whose natural width fits
    // the body stays; one that can wrap, at word breaks, within body and column spans; one
    // whose narrowest layout is still wider gets the fixed layout.
    const left = content.getBoundingClientRect().left;
    const full = content.clientWidth * scale;
    const bodyRight = full * (1 - column);
    const attribute = "data-" + token.toLowerCase();
    const fits = [];
    for (const table of fitsTables ? content.querySelectorAll("table") : []) {
      const saved = [table.style.maxWidth, table.style.width];
      const offset = table.getBoundingClientRect().left - left;
      table.style.maxWidth = "none";
      const natural = table.scrollWidth;
      table.style.width = "min-content";
      const narrowest = table.scrollWidth;
      [table.style.maxWidth, table.style.width] = saved;
      let kind = offset + natural > bodyRight + 0.5 ? "span" : "natural";
      if (kind === "span" && offset + narrowest > full + 0.5) {
        // Too wide even wrapped at word breaks: let the cells holding a long unbreakable run
        // (a URL, a path) wrap anywhere, and measure again; only then fall back to fixed.
        for (const cell of table.querySelectorAll("th, td")) {
          if (cell.textContent.split(/\\s+/).some((word) => word.length >= longWord)) cell.setAttribute(attribute + "-long", "");
        }
        table.style.width = "min-content";
        table.style.maxWidth = "none";
        const narrower = table.scrollWidth;
        [table.style.maxWidth, table.style.width] = saved;
        if (offset + narrower > full + 0.5) kind = "wide";
      }
      if (kind !== "natural") {
        table.setAttribute(attribute + "-" + kind, "");
        keepHeadingWith(table);
      }
      fits.push({ kind: kind, width: natural, text: table.textContent });
    }
    return fits;
    """

    /// Runs `buildScript` on `webView` for `header`, and returns how it fitted each table.
    @discardableResult
    static func build(
        _ header: Header, token: String, printableWidth: CGFloat, fitsTables: Bool = true, in webView: WKWebView
    ) async throws -> [TableFit] {
        let result = try await webView.callAsyncJavaScript(
            buildScript,
            arguments: [
                "token": token, "css": stylesheet(token: token, printableWidth: printableWidth), "title": header.title ?? "",
                "date": header.date, "column": Double(ExportLayout.notesColumnWidth / printableWidth), "scale": printLayoutScale,
                "longWord": longWord, "fitsTables": fitsTables,
            ],
            in: nil, contentWorld: world
        )
        return (result as? [[String: Any]] ?? []).compactMap { fit in
            guard let kind = (fit["kind"] as? String).flatMap(TableFit.Kind.init(rawValue:)) else { return nil }
            return TableFit(kind: kind, width: (fit["width"] as? NSNumber)?.doubleValue ?? 0, text: fit["text"] as? String ?? "")
        }
    }

    // MARK: Footer and notes column

    /// The footer's fonts: the manual layout's Latin face, then a CJK face no body font stack
    /// names and WebKit doesn't fall back to (the body's are PingFang, Songti and Hiragino), so
    /// the repair can tell the footer's CMaps from the body's by name
    /// (`ToUnicodeRepair.GeneratedText`). It ships in /System/Library/Fonts.
    nonisolated static let footerCJKFontName = "STHeitiTC-Light"
    /// The longest date the footer shows, in characters, before it is cut with an ellipsis.
    nonisolated static let maxDateLength = 40

    /// Draws the notes column's rule and the footer on each page when PDFKit draws it for
    /// `write(to:)`.
    final class Page: PDFPage {
        override func draw(with box: PDFDisplayBox, to context: CGContext) {
            super.draw(with: box, to: context)
            guard let document, let footers = document.delegate as? Footers else { return }
            footers.draw(page: document.index(for: self), in: context, mediaBox: bounds(for: .mediaBox))
        }
    }

    /// The footer and rule data, reached by `Page` through its document's delegate.
    final class Footers: NSObject, PDFDocumentDelegate {
        let pageCount: Int
        let bodyMinX: CGFloat
        let bodyMaxX: CGFloat
        let ruleX: CGFloat
        let ruleMinY: CGFloat
        let ruleMaxY: CGFloat
        /// Pages where a table runs into the notes column: they get no rule, which would cross it.
        var pagesWithoutRule: Set<Int> = []
        let baselineY: CGFloat
        let font: CTFont
        /// The name and date as drawn (sanitized and truncated), nil name when none.
        let name: String?
        let date: String

        init(name: String?, date: String, pageCount: Int, margins: NSEdgeInsets, paperSize: CGSize) {
            self.pageCount = pageCount
            bodyMinX = margins.left
            bodyMaxX = paperSize.width - margins.right
            ruleX = bodyMaxX + 12
            ruleMinY = margins.bottom
            ruleMaxY = paperSize.height - margins.top
            baselineY = margins.bottom / 2 - ManualLayout.footerFontSize / 3
            let base = CTFontCreateWithName(ManualLayout.footerFontName as CFString, ManualLayout.footerFontSize, nil)
            let cascade = [CTFontDescriptorCreateWithNameAndSize(HandoutLayout.footerCJKFontName as CFString, ManualLayout.footerFontSize)]
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(base), [kCTFontCascadeListAttribute: cascade] as CFDictionary
            )
            font = CTFontCreateWithFontDescriptor(descriptor, ManualLayout.footerFontSize, nil)
            (self.name, self.date) = Self.fit(
                name: name.map(HandoutLayout.sanitized).flatMap { $0.isEmpty ? nil : $0 },
                date: HandoutLayout.sanitized(date), pageCount: pageCount, width: bodyMaxX - bodyMinX, font: font
            )
        }

        /// The PostScript names the footer can be drawn with, for the repair.
        var fontNames: Set<String> { [ManualLayout.footerFontName, HandoutLayout.footerCJKFontName] }

        func text(forPage index: Int) -> String? {
            guard index >= 0, index < pageCount else { return nil }
            return Self.compose(name: name, date: date, number: index + 1, total: pageCount)
        }

        /// Every footer string as drawn, for the repair's generated-text keep set.
        var allText: String { (0..<pageCount).compactMap { text(forPage: $0) }.joined(separator: "\n") }

        func classForPage() -> AnyClass { Page.self }

        /// The footer as drawn: name, date and "n / N", joined by " · ".
        static func compose(name: String?, date: String, number: Int, total: Int) -> String {
            segments(name: name, date: date, number: number, total: total).map(\.text).joined()
        }

        /// The footer's pieces, drawn one after another from the left. The name and the date
        /// each take their direction from their own first strong character, as an FSI…PDI
        /// isolate would, and nothing outside them can reorder: a right-to-left name stays in
        /// its place and "n / N" stays last, left to right. (Isolate characters themselves are
        /// not drawn: CoreGraphics folds a PDI into the ActualText of the glyph before it, and
        /// PDFKit then ignores that ActualText, so a radical twin there extracted wrongly.)
        static func segments(name: String?, date: String, number: Int, total: Int) -> [(text: String, natural: Bool)] {
            var result: [(String, Bool)] = []
            if let name { result += [(name, true), (" · ", false)] }
            result += [(date, true), (" · ", false), (ManualLayout.footerText(number: number, of: total), false)]
            return result
        }

        static func line(_ text: String, natural: Bool, font: CTFont) -> CTLine {
            var direction = natural ? CTWritingDirection.natural : CTWritingDirection.leftToRight
            let style = withUnsafeBytes(of: &direction) { bytes in
                var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: bytes.count, value: bytes.baseAddress!)
                return CTParagraphStyleCreate(&setting, 1)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: CGColor(gray: 0.35, alpha: 1), .paragraphStyle: style,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }

        static func lines(name: String?, date: String, number: Int, total: Int, font: CTFont) -> [(line: CTLine, width: CGFloat)] {
            segments(name: name, date: date, number: number, total: total).map { segment in
                let line = line(segment.text, natural: segment.natural, font: font)
                return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            }
        }

        /// The name and date cut so that the widest footer ("N / N") fits `width`: the date first
        /// to `maxDateLength` characters, then the name in its middle, then the date at its end.
        /// "n / N" is always whole. Characters are grapheme clusters, so no cut splits one.
        static func fit(name: String?, date: String, pageCount: Int, width: CGFloat, font: CTFont) -> (String?, String) {
            func fits(_ name: String?, _ date: String) -> Bool {
                lines(name: name, date: date, number: pageCount, total: pageCount, font: font).reduce(0) { $0 + $1.width } <= width
            }
            /// The largest `n` in 0...upper for which `ok(n)` holds, given `ok` is monotone.
            func largest(_ upper: Int, _ ok: (Int) -> Bool) -> Int? {
                guard ok(0) else { return nil }
                var low = 0, high = upper
                while low < high {
                    let mid = (low + high + 1) / 2
                    if ok(mid) { low = mid } else { high = mid - 1 }
                }
                return low
            }
            func middle(_ text: String, keeping count: Int) -> String {
                let characters = Array(text)
                guard count < characters.count else { return text }
                let head = (count + 1) / 2
                return String(characters.prefix(head)) + "…" + String(characters.suffix(count - head))
            }
            func end(_ text: String, keeping count: Int) -> String {
                let characters = Array(text)
                guard count < characters.count else { return text }
                return String(characters.prefix(count)) + "…"
            }
            var date = date.count > maxDateLength ? end(date, keeping: maxDateLength - 1) : date
            if fits(name, date) { return (name, date) }
            var name = name
            if let full = name {
                if let kept = largest(full.count - 1, { fits(middle(full, keeping: $0), date) }) {
                    return (middle(full, keeping: kept), date)
                }
                name = nil
            }
            if fits(nil, date) { return (nil, date) }
            let whole = date
            if let kept = largest(whole.count - 1, { fits(nil, end(whole, keeping: $0)) }) {
                date = end(whole, keeping: kept)
            } else {
                date = "…"
            }
            return (name, date)
        }

        func drawRule(in context: CGContext, mediaBox: CGRect) {
            // WebKit paints the page's white, so the rule has to go on top of it.
            context.saveGState()
            context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: mediaBox.minX + ruleX, y: mediaBox.minY + ruleMinY))
            context.addLine(to: CGPoint(x: mediaBox.minX + ruleX, y: mediaBox.minY + ruleMaxY))
            context.strokePath()
            context.restoreGState()
        }

        func draw(page index: Int, in context: CGContext, mediaBox: CGRect) {
            if !pagesWithoutRule.contains(index) { drawRule(in: context, mediaBox: mediaBox) }
            guard index >= 0, index < pageCount else { return }
            let pieces = Self.lines(name: name, date: date, number: index + 1, total: pageCount, font: font)
            var x = mediaBox.minX + (bodyMinX + bodyMaxX) / 2 - pieces.reduce(0) { $0 + $1.width } / 2
            context.saveGState()
            context.textMatrix = .identity
            for piece in pieces {
                context.textPosition = CGPoint(x: x, y: mediaBox.minY + baselineY)
                CTLineDraw(piece.line, context)
                x += piece.width
            }
            context.restoreGState()
        }
    }
}

/// What one handout run did, for the tests.
struct HandoutReport {
    var token: String
    var header: HandoutLayout.Header
    var repair: ToUnicodeRepair.Outcome
    var footerFonts: Set<String>
    var footerText: String
    var footerName: String?
    var footerDate: String
    /// The repair's source: the document plus the display name when the header prints it.
    var repairSource: String
    /// How each table was fitted, in document order.
    var tables: [HandoutLayout.TableFit]
}

extension DocumentExporter {
    /// The handout's header, print and post-processing (see `HandoutLayout`). Writes only the
    /// final file to `destination`, in one atomic write; the printed file lives in a private
    /// folder under the temporary directory that is removed on every way out.
    func runHandout(
        markdown: String,
        header: HandoutLayout.Header,
        token: String,
        tables: [HandoutLayout.TableFit],
        displayName: String?,
        configured: NSPrintOperation,
        destination: URL,
        host: NSWindow,
        hooks: ManualHooks
    ) async throws -> Bool {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("marsdawn-handout-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: work) }

        let printedURL = work.appendingPathComponent("printed.pdf")
        guard await printPass(like: configured, to: printedURL, host: host) else { return false }
        try Task.checkCancellation()
        guard let printed = PDFDocument(url: printedURL) else { throw ExportError.printFailed }
        try await hooks.afterPassB?(webView)

        let footers = HandoutLayout.Footers(
            name: displayName, date: header.date, pageCount: printed.pageCount, margins: layout.bodyMargins,
            paperSize: configured.printInfo.paperSize
        )
        // The delegate first: PDFKit picks a page's class (`Page`) when it first makes the page.
        printed.delegate = footers
        // A page whose text runs past the body's edge carries a table spanning into the column.
        footers.pagesWithoutRule = Set((0..<printed.pageCount).filter { index in
            guard let page = printed.page(at: index) else { return false }
            return (page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []).contains {
                $0.bounds(for: page).maxX > footers.bodyMaxX + 0.5
            }
        })
        let finalURL = work.appendingPathComponent("handout.pdf")
        guard withExtendedLifetime(footers, { printed.write(to: finalURL) }) else { throw ExportError.printFailed }
        try Task.checkCancellation()

        // A display name shown as the header's title is drawn in the body's fonts, so its
        // radicals (if any) are kept like the document's own; the footer has its own fonts.
        let source = header.titleIsDisplayName ? markdown + "\n" + (header.title ?? "") : markdown
        let generated = ToUnicodeRepair.GeneratedText(fonts: footers.fontNames, text: footers.allText)
        let outcome = ToUnicodeRepair.repairFile(at: finalURL, source: source, generated: generated)
        hooks.handoutReport?(HandoutReport(
            token: token, header: header, repair: outcome, footerFonts: footers.fontNames, footerText: footers.allText,
            footerName: footers.name, footerDate: footers.date, repairSource: source, tables: tables
        ))

        let finished = try Data(contentsOf: finalURL)
        try finished.write(to: destination, options: .atomic)
        return true
    }
}
#endif
