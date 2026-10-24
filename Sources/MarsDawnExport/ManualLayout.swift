#if os(macOS)
import AppKit
import CoreText
import MarsDawnKit
import PDFKit
import WebKit

/// The manual layout's cover, table of contents, page numbers and bookmarks (mars-dawn#432 S2).
///
/// The flow, on the page `DocumentExporter.prepare` already loaded (it is never rendered twice):
/// 1. A cover (only when the front matter has a `title`) and a table of contents (only when the
///    document has `h1`/`h2` headings) go before the body, each starting a new page; the body
///    starts a new page after them.
/// 2. Pass A prints with an invisible marker at the start of every listed heading and at the
///    end of the cover/contents, into a private folder under the temporary directory.
/// 3. PDFKit finds each marker's page: the heading map. Page numbers count from the body's
///    first page.
/// 4. The markers go, the numbers go into fixed-width slots (so pagination cannot move), and
///    pass B prints. A pass B with a different page count fails the export.
/// 5. PDFKit draws the "n / N" footer on the body pages and adds the bookmarks from the map,
///    then the ToUnicode repair runs once on that file, which is then written to the caller's
///    URL in one atomic write. The private folder is removed whatever happens.
///
/// Trust boundaries: everything taken from the document — front-matter values, heading text,
/// the logo path — and the caller's contents title reach the page only as data. Scripts here
/// are constants; their data travels as `callAsyncJavaScript` arguments; the DOM gets text
/// through `textContent` and links through `setAttribute`. The one piece of HTML, the cover, is
/// built in Swift from the kit's own escapers (`frontMatterText`, `escapeAttribute`), and the
/// logo goes through exactly the chain a body image does (`resolveImageSource`,
/// `sanitizedURL`, `escapeAttribute`), so it is loaded only by WebKit through the exporter's
/// `DocumentAssetSchemeHandler` — never read here. The elements this adds are found again by
/// reference or by a random token made per export, never by a fixed class or id a document
/// could imitate.
@MainActor
enum ManualLayout {
    /// The contents title when the caller passes none.
    static let defaultTOCTitle = "Contents"

    /// The front-matter keys the cover shows, in the order it shows them.
    static let coverKeys = ["title", "subtitle", "version", "date", "author", "logo"]

    // MARK: Cover fields

    /// The cover's fields, or nil when the front matter has no `title` (no cover).
    struct Cover: Equatable {
        var title: String
        var subtitle: String?
        var version: String?
        var date: String?
        var author: String?
        var logo: String?
    }

    /// Reads the whitelisted keys from the front matter, one line at a time with the same
    /// `key: value` rule the front-matter table uses, so a block that also has lists, comments
    /// or nested values still yields its simple lines. The first occurrence of a key wins, one
    /// matching pair of surrounding `"` or `'` is removed, and an empty value counts as absent.
    static func cover(markdown: String) -> Cover? {
        guard let frontMatter = FrontMatter.split(markdown).frontMatter else { return nil }
        var values: [String: String] = [:]
        for line in frontMatter.lines {
            guard let pair = FrontMatter.keyValue(in: line), coverKeys.contains(pair.key), values[pair.key] == nil else { continue }
            values[pair.key] = pair.value
        }
        func field(_ key: String) -> String? {
            guard let raw = values[key] else { return nil }
            let value = unquoted(raw)
            return value.isEmpty ? nil : value
        }
        guard let title = field("title") else { return nil }
        return Cover(
            title: title, subtitle: field("subtitle"), version: field("version"), date: field("date"),
            author: field("author"), logo: field("logo")
        )
    }

    /// `value` without one matching pair of surrounding `"` or `'`, compared as scalars.
    static func unquoted(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count >= 2, let first = scalars.first, let last = scalars.last, first == last,
              first == "\"" || first == "'" else { return value }
        return String(String.UnicodeScalarView(scalars.dropFirst().dropLast()))
    }

    /// The cover's HTML. Text is escaped by the front-matter block's own escaper (NUL becomes
    /// U+FFFD, then `escapeHTML`); the logo is a body image's `<img>`, built by the same chain as
    /// the renderer's `visitImage`, so it is loaded (or refused) exactly as a body image is.
    static func coverHTML(_ cover: Cover, token: String, imageOptions: MarkdownRenderer.Options) -> String {
        func block(_ name: String, _ text: String?) -> String {
            guard let text else { return "" }
            return "<div class=\"\(className(token, name))\">" + MarkdownRenderer.frontMatterText(text) + "</div>"
        }
        var html = ""
        if let logo = cover.logo {
            let source = sanitizedURL(imageOptions.resolveImageSource(logo), allowData: true)
            html += "<div class=\"\(className(token, "logo"))\"><img src=\"\(escapeAttribute(source))\" alt=\"\"></div>"
        }
        html += block("title", cover.title)
        html += block("subtitle", cover.subtitle)
        html += block("version", cover.version)
        html += block("date", cover.date)
        html += block("author", cover.author)
        return html
    }

    // MARK: Token

    /// A fresh random token: the prefix of every class and marker this export adds.
    /// Upper-case letters and digits only, so it is safe in a class name and in CSS, and no
    /// ligature can change how PDFKit reads it back.
    static func makeToken() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXY")
        var generator = SystemRandomNumberGenerator()
        return "M" + String((0..<14).map { _ in alphabet.randomElement(using: &generator)! })
    }

    static func className(_ token: String, _ name: String) -> String { "\(token.lowercased())-\(name)" }

    /// The marker text for heading `index`; `Z` ends it, so heading 1's marker is not a prefix
    /// of heading 12's.
    static func headingMarker(_ token: String, _ index: Int) -> String { "\(token)H\(index)Z" }
    /// The marker at the end of the cover/contents: the body starts on the next page.
    static func frontEndMarker(_ token: String) -> String { "\(token)EZ" }

    /// The stylesheet for the added elements, scoped by the token.
    static func stylesheet(token: String) -> String {
        func c(_ name: String) -> String { "." + className(token, name) }
        return """
        \(c("cover")) { break-after: page; page-break-after: always; padding-top: 96px; }
        \(c("cover")) > div { break-inside: avoid; page-break-inside: avoid; }
        \(c("logo")) { margin-bottom: 40px; }
        \(c("logo")) img { max-width: 60%; max-height: 200px; width: auto; height: auto; vertical-align: top; }
        \(c("title")) { font-size: 2.4em; font-weight: 700; line-height: 1.2; color: var(--heading); margin-bottom: 0.4em; overflow-wrap: anywhere; }
        \(c("subtitle")) { font-size: 1.4em; line-height: 1.3; color: var(--muted); margin-bottom: 1.6em; overflow-wrap: anywhere; }
        \(c("version")), \(c("date")), \(c("author")) { margin: 0.25em 0; overflow-wrap: anywhere; }
        \(c("toc")) { break-after: page; page-break-after: always; }
        \(c("toc-title")) { font-size: 1.6em; font-weight: 700; line-height: 1.25; color: var(--heading); margin: 0 0 0.8em; overflow-wrap: anywhere; }
        \(c("toc-line")) { display: flex; align-items: flex-end; gap: 6px; margin: 3px 0; break-inside: avoid; page-break-inside: avoid; }
        \(c("toc-line"))\(c("l1")) { font-weight: 600; margin-top: 0.5em; }
        \(c("toc-line"))\(c("l2")) { padding-left: 1.5em; }
        \(c("toc-label")) { flex: 1 1 auto; min-width: 0; color: inherit; text-decoration: none; overflow-wrap: anywhere; }
        \(c("toc-num")) { flex: 0 0 auto; display: inline-block; width: 2.4em; text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
        \(c("mark")) { position: absolute; color: transparent; font-size: 1px; line-height: 1px; white-space: nowrap; }
        """
    }

    // MARK: Scripts (constants; data only through arguments)

    /// The content world the manual scripts run in, so the references they keep between calls
    /// are out of the page's reach.
    static let world = WKContentWorld.world(name: "dev.southern-light.marsdawn-kit.manual")

    /// Builds the cover (from `coverHTML`, parsed inert and filtered like the body's HTML) and the
    /// contents, keeps references to the headings and number slots, and returns the headings'
    /// levels, texts and whether they link.
    static let buildScript = """
    const content = document.getElementById("content");
    if (!content) return null;
    const cls = (name) => token.toLowerCase() + "-" + name;
    const style = document.createElement("style");
    style.textContent = css;
    document.head.append(style);
    const state = { cover: null, toc: null, headings: [], slots: [], marks: [] };
    globalThis.marsDawnManual = state;
    if (coverHTML) {
      const template = document.createElement("template");
      template.innerHTML = coverHTML;
      template.content.querySelectorAll("script, style, link, meta, base, iframe, frame, object, embed, portal, fencedframe").forEach((el) => el.remove());
      const cover = document.createElement("section");
      cover.className = cls("cover");
      cover.append(template.content);
      content.before(cover);
      state.cover = cover;
    }
    const headings = [...content.querySelectorAll("h1[id], h2[id]")].filter((h) => !h.closest("details.front-matter"));
    // Read before the anchors below go in.
    const texts = headings.map((h) => {
      const clone = h.cloneNode(true);
      clone.querySelectorAll(".katex-mathml, sup.footnote-ref").forEach((el) => el.remove());
      return clone.textContent.replace(/\\s+/g, " ").trim();
    });
    if (headings.length) {
      const toc = document.createElement("nav");
      toc.className = cls("toc");
      if (tocTitle) {
        const title = document.createElement("div");
        title.className = cls("toc-title");
        title.textContent = tocTitle;
        toc.append(title);
      }
      headings.forEach((h, i) => {
        // The link goes to an anchor of our own at the start of the heading: an id made of the
        // token, unique and ASCII. (A link to the heading's own id is dropped from the PDF when
        // the id isn't ASCII, and a document can repeat an id.) Empty, so it changes no layout.
        const anchor = document.createElement("span");
        anchor.id = token.toLowerCase() + "-a" + i;
        h.prepend(anchor);
        const line = document.createElement("div");
        line.className = cls("toc-line") + " " + cls(h.tagName === "H1" ? "l1" : "l2");
        const label = document.createElement("a");
        label.className = cls("toc-label");
        label.setAttribute("href", "#" + anchor.id);
        label.textContent = texts[i];
        const slot = document.createElement("span");
        slot.className = cls("toc-num");
        slot.textContent = "0";
        line.append(label, slot);
        toc.append(line);
        state.slots.push(slot);
      });
      content.before(toc);
      state.toc = toc;
    }
    state.headings = headings;
    return headings.map((h, i) => ({ level: h.tagName === "H1" ? 1 : 2, text: texts[i] }));
    """

    /// Pass A's markers: one at the start of each heading, one at the start of the last line of
    /// the contents (or the last block of the cover), each found again by reference.
    static let addMarkersScript = """
    const state = globalThis.marsDawnManual;
    if (!state) return false;
    const cls = (name) => token.toLowerCase() + "-" + name;
    const mark = (parent, text) => {
      const span = document.createElement("span");
      span.className = cls("mark");
      span.textContent = text;
      parent.prepend(span);
      state.marks.push(span);
    };
    state.headings.forEach((h, i) => mark(h, token + "H" + i + "Z"));
    const front = state.toc || state.cover;
    if (front) {
      const blocks = [...front.children].filter((el) => el.tagName === "DIV");
      mark(blocks.length ? blocks[blocks.length - 1] : front, token + "EZ");
    }
    return true;
    """

    /// Removes the markers and puts the page numbers in their slots.
    static let fillNumbersScript = """
    const state = globalThis.marsDawnManual;
    if (!state) return false;
    for (const span of state.marks) span.remove();
    state.marks = [];
    state.slots.forEach((slot, i) => { slot.textContent = numbers[i] ?? "\\u00A0"; });
    return true;
    """

    // MARK: Map

    struct Heading: Equatable {
        var level: Int
        var text: String
    }

    /// Where pass A put each heading: its page index and the top of its marker, in page space.
    struct Placement: Equatable {
        var page: Int
        var top: CGFloat
    }

    /// The page and position of a marker that occurs exactly once in `document`, else nil.
    static func place(_ marker: String, in document: PDFDocument) -> Placement? {
        let found = document.findString(marker, withOptions: [])
        guard found.count == 1, let selection = found.first, selection.pages.count == 1,
              let page = selection.pages.first else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        return Placement(page: index, top: selection.bounds(for: page).maxY)
    }

    /// The body's first page (index) from the end-of-front marker: the page after it, or 0 when
    /// there is neither cover nor contents.
    static func bodyStart(frontMarker: Placement?, hasFront: Bool) -> Int? {
        guard hasFront else { return 0 }
        guard let frontMarker else { return nil }
        return frontMarker.page + 1
    }

    /// The body-relative number of each placement (1 = the body's first page), or nil for a
    /// heading whose marker was not found exactly once or lies before the body.
    static func numbers(for placements: [Placement?], bodyStart: Int) -> [Int?] {
        placements.map { placement in
            guard let placement, placement.page >= bodyStart else { return nil }
            return placement.page - bodyStart + 1
        }
    }

    // MARK: Footer and outline

    /// The footer's font. A Latin-only face the body's font stacks never name, so its CMap can
    /// hold no CJK radical and no body text shares its name (`ToUnicodeRepair.GeneratedText`).
    nonisolated static let footerFontName = "AvenirNext-Regular"
    nonisolated static let footerFontSize: CGFloat = 9

    nonisolated static func footerText(number: Int, of total: Int) -> String { "\(number) / \(total)" }

    /// Draws each body page's "n / N" footer when PDFKit draws the page for `write(to:)`.
    final class FooterPage: PDFPage {
        override func draw(with box: PDFDisplayBox, to context: CGContext) {
            super.draw(with: box, to: context)
            guard let document, let footers = document.delegate as? Footers else { return }
            let index = document.index(for: self)
            guard let text = footers.text(forPage: index) else { return }
            footers.draw(text, in: context, mediaBox: bounds(for: .mediaBox))
        }
    }

    /// The footer data, reached by `FooterPage` through its document's delegate.
    final class Footers: NSObject, PDFDocumentDelegate {
        let bodyStart: Int
        let pageCount: Int
        let centerX: CGFloat
        let baselineY: CGFloat
        let font: CTFont

        init(bodyStart: Int, pageCount: Int, margins: NSEdgeInsets, paperWidth: CGFloat) {
            self.bodyStart = bodyStart
            self.pageCount = pageCount
            centerX = (margins.left + paperWidth - margins.right) / 2
            baselineY = margins.bottom / 2 - ManualLayout.footerFontSize / 3
            font = CTFontCreateWithName(ManualLayout.footerFontName as CFString, ManualLayout.footerFontSize, nil)
        }

        /// The PostScript name the footer is actually drawn with.
        var fontName: String { CTFontCopyPostScriptName(font) as String }

        var bodyPageCount: Int { max(0, pageCount - bodyStart) }

        func text(forPage index: Int) -> String? {
            guard index >= bodyStart, index < pageCount else { return nil }
            return ManualLayout.footerText(number: index - bodyStart + 1, of: bodyPageCount)
        }

        /// Every footer string, for the repair's generated-text keep set.
        var allText: String {
            (bodyStart..<max(bodyStart, pageCount)).compactMap { text(forPage: $0) }.joined(separator: "\n")
        }

        func classForPage() -> AnyClass { FooterPage.self }

        func draw(_ text: String, in context: CGContext, mediaBox: CGRect) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0.35, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: mediaBox.minX + centerX - width / 2, y: mediaBox.minY + baselineY)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    /// Bookmarks: `h1` entries at the root, each `h2` under the `h1` before it (at the root when
    /// none came before). Headings without a placement get no entry.
    static func outline(headings: [Heading], placements: [Placement?], in document: PDFDocument) -> PDFOutline? {
        let root = PDFOutline()
        var chapter: PDFOutline?
        for (heading, placement) in zip(headings, placements) {
            guard let placement, let page = document.page(at: placement.page) else { continue }
            let entry = PDFOutline()
            entry.label = heading.text
            entry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: placement.top))
            if heading.level == 1 || chapter == nil {
                root.insertChild(entry, at: root.numberOfChildren)
                if heading.level == 1 { chapter = entry }
            } else if let chapter {
                chapter.insertChild(entry, at: chapter.numberOfChildren)
            }
        }
        return root.numberOfChildren > 0 ? root : nil
    }
}
#endif
