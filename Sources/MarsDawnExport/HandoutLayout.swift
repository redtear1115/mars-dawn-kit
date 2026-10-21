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
///    caller's display name, with the date beneath. Tables get a fixed layout at the body's
///    width, so a wide table wraps inside the body instead of running into the notes column.
/// 2. The page prints once, at the document layout's margins plus the notes column
///    (`ExportLayout.notesColumnWidth`), into a private folder under the temporary directory.
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

    static func stylesheet(token: String) -> String {
        let root = ":root[\(rootAttribute(token))]"
        func c(_ name: String) -> String { "." + ManualLayout.className(token, name) }
        return """
        \(c("header")) { margin: 0 0 1.4em; break-inside: avoid; page-break-inside: avoid; }
        \(c("title")) { font-size: 1.6em; font-weight: 700; line-height: 1.25; color: var(--heading); overflow-wrap: anywhere; }
        \(c("date")) { margin-top: 0.3em; color: var(--muted); overflow-wrap: anywhere; }
        @media print {
          \(root) table { table-layout: fixed; width: 100%; }
          \(root) th, \(root) td { overflow-wrap: anywhere; }
        }
        """
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
    return true;
    """

    /// Runs `buildScript` on `webView` for `header`.
    static func build(_ header: Header, token: String, in webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript(
            buildScript,
            arguments: ["token": token, "css": stylesheet(token: token), "title": header.title ?? "", "date": header.date],
            in: nil, contentWorld: world
        )
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

        func draw(page index: Int, in context: CGContext, mediaBox: CGRect) {
            context.saveGState()
            context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: mediaBox.minX + ruleX, y: mediaBox.minY + ruleMinY))
            context.addLine(to: CGPoint(x: mediaBox.minX + ruleX, y: mediaBox.minY + ruleMaxY))
            context.strokePath()
            context.restoreGState()
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
}

extension DocumentExporter {
    /// The handout's header, print and post-processing (see `HandoutLayout`). Writes only the
    /// final file to `destination`, in one atomic write; the printed file lives in a private
    /// folder under the temporary directory that is removed on every way out.
    func runHandout(
        markdown: String,
        header: HandoutLayout.Header,
        token: String,
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
            name: displayName, date: header.date, pageCount: printed.pageCount, margins: layout.pageMargins,
            paperSize: configured.printInfo.paperSize
        )
        printed.delegate = footers
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
            footerName: footers.name, footerDate: footers.date, repairSource: source
        ))

        let finished = try Data(contentsOf: finalURL)
        try finished.write(to: destination, options: .atomic)
        return true
    }
}
#endif
