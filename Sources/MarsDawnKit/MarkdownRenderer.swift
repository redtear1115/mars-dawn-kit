import Foundation
import Markdown

/// Converts Markdown source into the HTML fragment consumed by the preview page.
///
/// Every block element carries a `data-line` attribute (1-based source line) so the
/// preview can be diffed incrementally and scroll-synced with the editor.
///
/// Front matter (see `FrontMatter`) is not parsed as Markdown. It renders first, as a
/// collapsed `details.front-matter` block holding a table of its `key: value` pairs or its
/// escaped text, and the body's `data-line` values stay file line numbers. Print and PDF
/// export hide the block (preview.css).
///
/// TeX math is lifted out of the body by `MathExtractor` before the body is parsed, and comes
/// back as elements holding only the HTML-escaped TeX; `preview.js` hands each one to KaTeX.
/// See `mathHTML` for the shape. A body with no `$` in it is not scanned at all and renders
/// exactly as it did before math existed.
public enum MarkdownRenderer {
    public struct Options: Sendable {
        /// Maps an image `src` as written in the document to the URL the preview should load.
        public var resolveImageSource: @Sendable (String) -> String
        /// Documents larger than this many UTF-8 bytes render as their escaped source.
        /// `nil` (the default) means no limit.
        public var maxBytes: Int?
        /// Documents with more nodes than this render as their escaped source.
        public var maxNodes: Int
        /// The summary of the front-matter block. Rendered as escaped text; the app passes a
        /// localised string.
        public var frontMatterLabel: String

        public init(
            maxBytes: Int? = nil,
            maxNodes: Int = ParseLimits.defaultMaxNodes,
            frontMatterLabel: String = "Document info",
            resolveImageSource: @escaping @Sendable (String) -> String = { $0 }
        ) {
            self.maxBytes = maxBytes
            self.maxNodes = maxNodes
            self.frontMatterLabel = frontMatterLabel
            self.resolveImageSource = resolveImageSource
        }

        var parseLimits: ParseLimits {
            ParseLimits(maxBytes: maxBytes, maxNodes: maxNodes)
        }
    }

    /// Why a document rendered as its escaped source instead of as Markdown.
    public enum FallbackReason: Sendable, Equatable {
        /// The document nests `depth` levels deep, too deep to render safely.
        case tooDeep(depth: Int)
        /// The document is larger than `Options.maxBytes`.
        case tooLarge
        /// The document has more nodes than `Options.maxNodes`, or tables too costly to build.
        case tooComplex
    }

    public struct RenderResult: Sendable, Equatable {
        public let html: String
        /// Set when `html` is the escaped source rather than rendered Markdown.
        public let fallback: FallbackReason?
    }

    /// Renders `markdown` to HTML. A document larger than `options.maxBytes` renders as its
    /// escaped source in a `pre.source-fallback`. So does a document nested too deeply to
    /// render safely, except that its front matter, if any, still renders as usual and the
    /// fallback holds only the body.
    ///
    /// Parses and renders on a parsing worker and blocks until done (see `MarkdownParsing`).
    public static func render(_ markdown: String, options: Options = Options()) -> String {
        renderResult(markdown, options: options).html
    }

    /// Like `render`, also saying whether the source fallback was used and why.
    public static func renderResult(_ markdown: String, options: Options = Options()) -> RenderResult {
        if let tooLarge = tooLargeResult(markdown, options: options) { return tooLarge }
        return renderSplit(markdown, options: options)
    }

    /// Like `render`, waiting for a parsing worker without blocking.
    /// Returns `nil` only if the task was cancelled before rendering started.
    public static func renderResult(_ markdown: String, options: Options = Options()) async -> RenderResult? {
        if let tooLarge = tooLargeResult(markdown, options: options) { return tooLarge }
        // Pulling the math out parses the body itself, so it has to happen on a worker too,
        // and this overload must not block its caller doing it. Inside `onWorker` every
        // nested `withDocument` runs inline on that one worker, so the extraction and the
        // render still take one worker slot between them, as the render alone did before.
        return await MarkdownParsing.onWorker { renderSplit(markdown, options: options) }
    }

    /// Splits off the front matter, lifts the math out and renders what is left. Parses, so it
    /// blocks unless it is already on a parsing worker.
    private static func renderSplit(_ markdown: String, options: Options) -> RenderResult {
        let split = SplitSource(markdown, options: options)
        return MarkdownParsing.withDocument(split.parsedBody, options: options.parseLimits) { outcome in
            renderResult(outcome, split: split, options: options)
        }
    }

    /// A document split into its front matter, rendered up front (it is never parsed as
    /// Markdown), and the body to parse.
    ///
    /// The body is parsed on its own, so cmark treats its start as a document start: a
    /// U+FEFF right after the closing delimiter is dropped as a byte order mark, where it
    /// would otherwise have been text. Everything else matches parsing the body in place.
    private struct SplitSource: Sendable {
        /// The rendered front matter, or "" when there is none.
        let frontMatterHTML: String
        /// The body as written. This, not `parsedBody`, is what the source fallback shows.
        let body: String
        /// `body` with its math swapped for placeholders: the source that is parsed. Has the
        /// same number of lines as `body`, so `data-line` numbers still address the file.
        let parsedBody: String
        /// The expressions `parsedBody`'s placeholders stand for.
        let math: MathExtractor.Extraction
        let bodyLineOffset: Int

        init(_ markdown: String, options: Options) {
            let (frontMatter, body, offset) = FrontMatter.split(markdown)
            if let frontMatter {
                frontMatterHTML = MarkdownRenderer.frontMatterHTML(frontMatter, label: options.frontMatterLabel)
                self.body = String(body)
            } else {
                frontMatterHTML = ""
                self.body = markdown
            }
            math = MathExtractor.extract(from: self.body)
            parsedBody = math.markdown
            bodyLineOffset = offset
        }
    }

    /// The byte limit applies to the whole file, front matter included. A file over it isn't
    /// split or parsed at all, and the fallback holds the whole source.
    private static func tooLargeResult(_ markdown: String, options: Options) -> RenderResult? {
        guard let maxBytes = options.parseLimits.maxBytes, markdown.utf8.count > maxBytes else { return nil }
        return RenderResult(html: sourceFallbackHTML(markdown), fallback: .tooLarge)
    }

    private static func renderResult(_ outcome: ParseOutcome, split: SplitSource, options: Options) -> RenderResult {
        switch outcome {
        case .document(let document):
            var visitor = HTMLVisitor(options: options, lineOffset: split.bodyLineOffset, math: split.math)
            return RenderResult(html: split.frontMatterHTML + visitor.visit(document), fallback: nil)
        case .tooDeep(let depth):
            return sourceFallback(split, reason: .tooDeep(depth: depth))
        case .tooLarge:
            // Not expected: the whole file was checked first, and the body is no larger.
            return sourceFallback(split, reason: .tooLarge)
        case .tooComplex:
            return sourceFallback(split, reason: .tooComplex)
        }
    }

    /// The one fallback for every document that isn't rendered; only the reason differs.
    /// Front matter still renders, and the body keeps its file line numbers.
    private static func sourceFallback(_ split: SplitSource, reason: FallbackReason) -> RenderResult {
        let fallback = sourceFallbackHTML(split.body, firstLine: split.bodyLineOffset + 1)
        return RenderResult(html: split.frontMatterHTML + fallback, fallback: reason)
    }

    static func sourceFallbackHTML(_ source: String, firstLine: Int = 1) -> String {
        #"<pre class="source-fallback" data-line=""# + String(firstLine) + #"">"# + escapeHTML(source) + "</pre>"
    }

    /// `<details class="front-matter" data-line="1"><summary>label</summary>`, then a table
    /// of the pairs or a `<pre>` of the inner lines, then `</details>`. Everything taken from
    /// the document or the label is escaped text: no links, no markup, no attributes.
    static func frontMatterHTML(_ frontMatter: FrontMatter, label: String) -> String {
        var html = #"<details class="front-matter" data-line=""# + String(frontMatter.lineRange.lowerBound)
            + #""><summary>"# + frontMatterText(label) + "</summary>"
        if let pairs = frontMatter.pairs {
            html += "<table><tbody>"
            for pair in pairs {
                html += "<tr><th>" + frontMatterText(pair.key) + "</th><td>" + frontMatterText(pair.value) + "</td></tr>"
            }
            html += "</tbody></table>"
        } else {
            html += "<pre>" + frontMatterText(frontMatter.lines.joined(separator: "\n")) + "</pre>"
        }
        return html + "</details>\n"
    }

    /// One TeX expression, as the element `preview.js` hands to KaTeX.
    ///
    /// Three shapes, and the class is the whole of what the page reads besides the text:
    ///   - `<span class="math-inline">` — `$…$`;
    ///   - `<span class="math-inline math-display">` — `$$…$$` that stayed inside a
    ///     paragraph, heading or cell, so it has to be an inline element, but is still set
    ///     in display mode;
    ///   - `<div class="math-block" data-line="N">` — a `math` fence, written or rewritten
    ///     from a top-level `$$` paragraph.
    ///
    /// The element holds the TeX and nothing else, escaped by the same `escapeHTML` as any
    /// other text: `preview.js` reads it back with `textContent`, so `</span><script>` in an
    /// expression is TeX to KaTeX and never markup to the parser. There is no attribute
    /// carrying TeX and none carrying options.
    static func mathHTML(tex: String, display: Bool, lineAttribute: String?) -> String {
        guard let lineAttribute else {
            let classes = display ? "math-inline math-display" : "math-inline"
            return "<span class=\"\(classes)\">\(escapeHTML(tex))</span>"
        }
        return "<div class=\"math-block\"\(lineAttribute)>\(escapeHTML(tex))</div>\n"
    }

    /// Escaped text for the front-matter block, through the shared `escapeHTML`. NUL becomes
    /// U+FFFD first, as cmark does for the Markdown body, so no raw NUL reaches the page.
    private static func frontMatterText(_ text: String) -> String {
        guard text.utf8.contains(0) else { return escapeHTML(text) }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(scalar == "\u{0}" ? "\u{FFFD}" : scalar)
        }
        return escapeHTML(String(scalars))
    }
}

// MARK: - Visitor

private struct HTMLVisitor: MarkupVisitor {
    let options: MarkdownRenderer.Options
    /// Source lines before the parsed text (the front matter), added to every `data-line`.
    let lineOffset: Int
    /// The math taken out of the body before it was parsed.
    let math: MathExtractor.Extraction
    /// The next number to try for each base, as `base-N`.
    private var usedSlugs: [String: Int] = [:]
    /// Every heading `id` given out so far in this render.
    private var usedIDs: Set<String> = []
    /// Every heading's own slug, in document order, taken before any heading is written.
    private var headingSlugs: [String] = []
    /// For each slug some heading has as its own, the first such heading: it keeps that slug.
    private var slugOwners: [String: Int] = [:]
    private var headingIndex = 0
    private var tightListStack: [Bool] = []

    init(options: MarkdownRenderer.Options, lineOffset: Int, math: MathExtractor.Extraction) {
        self.options = options
        self.lineOffset = lineOffset
        self.math = math
    }

    mutating func defaultVisit(_ markup: any Markup) -> String {
        visitChildren(markup)
    }

    private mutating func visitChildren(_ markup: any Markup) -> String {
        var html = ""
        for child in markup.children {
            html += visit(child)
        }
        return html
    }

    private func lineAttribute(_ markup: any Markup) -> String {
        guard let line = markup.range?.lowerBound.line else { return "" }
        return " data-line=\"\(line + lineOffset)\""
    }

    // MARK: Blocks

    mutating func visitDocument(_ document: Document) -> String {
        collectHeadingSlugs(document)
        return visitChildren(document)
    }

    /// The first pass for heading `id`s: every heading's own slug, in the order `visit` meets
    /// them, and the first heading that has each one. Headings are blocks, so inline nodes are
    /// never descended into.
    private mutating func collectHeadingSlugs(_ document: Document) {
        var stack: [any Markup] = Array(document.children).reversed()
        while let node = stack.popLast() {
            if let heading = node as? Heading {
                let slug = slugify(slugSource(heading.plainText))
                if !slug.isEmpty, slugOwners[slug] == nil { slugOwners[slug] = headingSlugs.count }
                headingSlugs.append(slug)
                continue
            }
            stack.append(contentsOf: node.children.filter { !($0 is InlineMarkup) }.reversed())
        }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = visitChildren(paragraph)
        if tightListStack.last == true, paragraph.parent is ListItem {
            return inner + "\n"
        }
        return "<p\(lineAttribute(paragraph))>\(inner)</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = min(max(heading.level, 1), 6)
        let id = headingID(headingIndex)
        headingIndex += 1
        return "<h\(level) id=\"\(escapeAttribute(id))\"\(lineAttribute(heading))>\(visitChildren(heading))</h\(level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr\(lineAttribute(thematicBreak))>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote\(lineAttribute(blockQuote))>\n\(visitChildren(blockQuote))</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        // Before the language is cleaned up: a rewritten `$$` block carries its placeholder in
        // the info string, which the clean-up would strip.
        if MathExtractor.isMathFence(language: codeBlock.language) {
            let tex = math.tex(forMathFence: codeBlock.language, code: codeBlock.code)
            return MarkdownRenderer.mathHTML(tex: tex, display: true, lineAttribute: lineAttribute(codeBlock))
        }
        let language = codeBlock.language?
            .split(whereSeparator: \.isWhitespace).first
            .map(String.init)?
            .filter { $0.isLetter || $0.isNumber || "_+#.-".contains($0) } ?? ""

        if language.lowercased() == "mermaid" {
            return "<div class=\"mermaid-block\"\(lineAttribute(codeBlock))><pre class=\"mermaid-source\">\(escapeHTML(codeBlock.code))</pre></div>\n"
        }
        let classAttribute = language.isEmpty ? "" : " class=\"language-\(escapeAttribute(language))\""
        return "<pre\(lineAttribute(codeBlock))><code\(classAttribute)>\(escapeHTML(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        "<div class=\"html-block\"\(lineAttribute(html))>\(neutralizingLinkTags(html.rawHTML))</div>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        tightListStack.append(!isLoose(list))
        defer { tightListStack.removeLast() }
        let taskClass = list.listItems.contains { $0.checkbox != nil } ? " class=\"contains-task-list\"" : ""
        return "<ul\(taskClass)\(lineAttribute(list))>\n\(visitChildren(list))</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        tightListStack.append(!isLoose(list))
        defer { tightListStack.removeLast() }
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        return "<ol\(start)\(lineAttribute(list))>\n\(visitChildren(list))</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        guard let checkbox = listItem.checkbox else {
            return "<li\(lineAttribute(listItem))>\(visitChildren(listItem))</li>\n"
        }
        let checked = checkbox == .checked ? " checked" : ""
        return "<li class=\"task-list-item\"\(lineAttribute(listItem))><input type=\"checkbox\" disabled\(checked)> \(visitChildren(listItem))</li>\n"
    }

    mutating func visitTable(_ table: Table) -> String {
        let alignments = table.columnAlignments
        var html = "<table\(lineAttribute(table))>\n<thead>\n<tr\(lineAttribute(table.head))>"
        for (index, cell) in table.head.cells.enumerated() {
            html += "<th\(alignAttribute(alignments, index))>\(visitChildren(cell))</th>"
        }
        html += "</tr>\n</thead>\n"
        let rows = Array(table.body.rows)
        if !rows.isEmpty {
            html += "<tbody>\n"
            for row in rows {
                html += "<tr\(lineAttribute(row))>"
                for (index, cell) in row.cells.enumerated() {
                    html += "<td\(alignAttribute(alignments, index))>\(visitChildren(cell))</td>"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }
        return html + "</table>\n"
    }

    // MARK: Inlines

    /// Text is the only place a math placeholder is ever expanded: not in a link destination
    /// or title, not in an image's alt text, not in raw HTML, not in a heading slug. Anything
    /// that looks like a placeholder but isn't one of this render's comes back as text and is
    /// escaped like the rest.
    mutating func visitText(_ text: Text) -> String {
        guard math.expressionCount > 0 else { return escapeHTML(text.string) }
        var html = ""
        for segment in math.segments(in: text.string) {
            switch segment {
            case .text(let string):
                html += escapeHTML(string)
            case .math(let tex, let display):
                html += MarkdownRenderer.mathHTML(tex: tex, display: display, lineAttribute: nil)
            }
        }
        return html
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(visitChildren(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(visitChildren(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(visitChildren(strikethrough))</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(escapeHTML(inlineCode.code))</code>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        neutralizingLinkTags(inlineHTML.rawHTML)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        let href = sanitizedURL(link.destination ?? "", allowData: false)
        let title = link.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
        return "<a href=\"\(escapeAttribute(href))\"\(title)>\(visitChildren(link))</a>"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> String {
        "<code>\(escapeHTML(symbolLink.destination ?? ""))</code>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let source = sanitizedURL(options.resolveImageSource(image.source ?? ""), allowData: true)
        let title = image.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
        return "<img src=\"\(escapeAttribute(source))\" alt=\"\(escapeAttribute(image.plainText))\"\(title)>"
    }

    // MARK: Helpers

    private func isLoose(_ list: some ListItemContainer) -> Bool {
        var previousEnd: Int?
        for item in list.listItems {
            guard let range = item.range else { continue }
            if let previousEnd, range.lowerBound.line > previousEnd + 1 { return true }
            var childEnd: Int?
            for child in item.children {
                guard let childRange = child.range else { continue }
                if let childEnd, childRange.lowerBound.line > childEnd + 1 { return true }
                childEnd = childRange.upperBound.line
            }
            // An item's own range swallows trailing blank lines, so measure from its content.
            previousEnd = childEnd ?? range.upperBound.line
        }
        return false
    }

    private func alignAttribute(_ alignments: [Table.ColumnAlignment?], _ index: Int) -> String {
        guard index < alignments.count, let alignment = alignments[index] else { return "" }
        switch alignment {
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
    }

    /// A heading's text as the document has it, for the slug: every placeholder of this render
    /// written back as the delimiters and TeX it stands for (`$a$`, `$$x^2$$`).
    ///
    /// Two things have to hold at once. The `id` must not move between renders, and a
    /// placeholder carries a per-render nonce, so slugging the placeholder itself would give a
    /// heading with math in it a different `id` on every keystroke — a moving anchor, and a
    /// block the preview's diff could never match. And the `id` must be the one the heading had
    /// before math existed, because that is what the links already written to it use. Writing
    /// the source back satisfies both: it never holds the nonce, and `slugify` reads it exactly
    /// as it read the same characters when nothing was extracted. Dropping the math instead
    /// would satisfy only the first, and would leave `## $a$` with no `id` at all.
    ///
    /// This is not the expansion S5-2 keeps to `visitText`: no TeX reaches the page, and the
    /// result only ever passes through `slugify`, which keeps letters, digits, `-` and `_` and
    /// drops everything else — the delimiters, and the U+E000/U+E001 of any placeholder that
    /// isn't this render's and so comes back as text.
    private func slugSource(_ text: String) -> String {
        guard math.expressionCount > 0 else { return text }
        return math.segments(in: text).reduce(into: "") { result, segment in
            switch segment {
            case .text(let string):
                result += string
            case .math(let tex, let display):
                let delimiter = display ? "$$" : "$"
                result += delimiter + tex + delimiter
            }
        }
    }

    /// The `id` of the heading at `index` in document order, in two passes (#14).
    ///
    /// 1. A heading whose own slug no earlier heading has keeps it. That is decided for the
    ///    whole document first (`collectHeadingSlugs`), so a heading with a real slug is never
    ///    displaced by one without: `# section` stays `section` whatever comes before it.
    /// 2. Every other heading takes the next free number. A repeated slug is `base-1`,
    ///    `base-2`, …; a heading with nothing to slug (`# $$`, `# !!!`) is `section`, then
    ///    `section-1`, …, as in Pandoc, rather than an empty `id` nothing can link to. A number
    ///    is free when no heading has it as its own slug and it hasn't been given out, so no
    ///    two headings share an `id`.
    private mutating func headingID(_ index: Int) -> String {
        let slug = index < headingSlugs.count ? headingSlugs[index] : ""
        if !slug.isEmpty, slugOwners[slug] == index {
            usedIDs.insert(slug)
            usedSlugs[slug] = max(usedSlugs[slug, default: 0], 1)
            return slug
        }
        let base = slug.isEmpty ? "section" : slug
        var count = usedSlugs[base, default: slug.isEmpty ? 0 : 1]
        var id = count == 0 ? base : "\(base)-\(count)"
        while slugOwners[id] != nil || usedIDs.contains(id) {
            count += 1
            id = "\(base)-\(count)"
        }
        usedSlugs[base] = count + 1
        usedIDs.insert(id)
        return id
    }
}

// MARK: - Escaping

func slugify(_ text: String) -> String {
    var slug = ""
    for character in text.lowercased() {
        if character.isLetter || character.isNumber || character == "-" || character == "_" {
            slug.append(character)
        } else if character == " " {
            slug.append("-")
        }
    }
    return slug
}

// The escapers and the URL check below work on UTF-8 bytes or Unicode scalars, never on
// `Character`s. A `Character` is a grapheme cluster, which can hold an ASCII-significant
// character together with its neighbour: a Prepend scalar before it (`\u{600}<`) or a combining
// mark, ZWJ or variation selector after it (`>\u{301}`). A `Character` comparison doesn't see
// the `<` in such a cluster, yet the HTML tokenizer does.

/// Escapes `&`, `<` and `>` for HTML text.
func escapeHTML(_ string: String) -> String {
    escapeMarkupBytes(string, quotes: false)
}

/// Escapes `&`, `<`, `>`, `"` and `'` for a quoted attribute value.
func escapeAttribute(_ string: String) -> String {
    escapeMarkupBytes(string, quotes: true)
}

/// One pass over the UTF-8 bytes. The entity spellings are the ones the renderer has always used.
private func escapeMarkupBytes(_ string: String, quotes: Bool) -> String {
    func needsEscape(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "&"), UInt8(ascii: "<"), UInt8(ascii: ">"): true
        case UInt8(ascii: "\""), UInt8(ascii: "'"): quotes
        default: false
        }
    }
    let source = string.utf8
    guard source.contains(where: needsEscape) else { return string }
    var escaped: [UInt8] = []
    escaped.reserveCapacity(source.count + 16)
    for byte in source {
        switch byte {
        case UInt8(ascii: "&"): escaped += "&amp;".utf8
        case UInt8(ascii: "<"): escaped += "&lt;".utf8
        case UInt8(ascii: ">"): escaped += "&gt;".utf8
        case UInt8(ascii: "\"") where quotes: escaped += "&quot;".utf8
        case UInt8(ascii: "'") where quotes: escaped += "&#39;".utf8
        default: escaped.append(byte)
        }
    }
    // Only ASCII bytes were replaced, and only with ASCII, so this is still valid UTF-8.
    return String(decoding: escaped, as: UTF8.self)
}

/// Allows relative URLs and a short list of schemes; everything else becomes "#".
/// Tabs and newlines are removed first, as browsers do when parsing URLs.
///
/// The scheme is read as a browser reads it: up to the first `:` scalar, and only if it is an
/// ASCII scheme name. Anything else before a colon (other than a relative path) becomes "#".
func sanitizedURL(_ url: String, allowData: Bool) -> String {
    let cleaned = String(url.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        .trimmingCharacters(in: .whitespaces)
    let scalars = cleaned.unicodeScalars
    guard let colon = scalars.firstIndex(of: ":") else { return cleaned }
    let prefix = scalars[..<colon]
    // A "scheme" containing '/', '?' or '#' is really a relative path.
    if prefix.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { return cleaned }
    guard let scheme = asciiURLScheme(prefix) else { return "#" }
    switch scheme {
    case "http", "https", "mailto", DocumentAssetSchemeHandler.scheme:
        return cleaned
    case "data":
        let allowed = allowData
            && asciiCaseInsensitiveHasPrefix(cleaned.utf8, "data:image/")
            && !asciiCaseInsensitiveHasPrefix(cleaned.utf8, "data:image/svg")
        return allowed ? cleaned : "#"
    default:
        return "#"
    }
}

// MARK: - Line index

/// UTF-16 offsets of line starts, for mapping between text positions and source lines.
public struct LineIndex: Sendable {
    public private(set) var lineStarts: [Int]

    public init(_ string: String) {
        var starts = [0]
        var offset = 0
        for unit in string.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
    }

    public var lineCount: Int { lineStarts.count }

    /// 1-based line containing a UTF-16 offset.
    public func line(containing offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// UTF-16 offset where a 1-based line starts (clamped to the document).
    public func offset(ofLine line: Int) -> Int {
        lineStarts[min(max(line, 1), lineStarts.count) - 1]
    }
}
