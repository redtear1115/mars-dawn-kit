import Foundation
import Markdown

/// Converts Markdown source into the HTML fragment consumed by the preview page.
///
/// Every block element carries a `data-line` attribute (1-based source line) so the
/// preview can be diffed incrementally and scroll-synced with the editor.
public enum MarkdownRenderer {
    public struct Options: Sendable {
        /// Maps an image `src` as written in the document to the URL the preview should load.
        public var resolveImageSource: @Sendable (String) -> String
        /// Documents larger than this many UTF-8 bytes render as their escaped source.
        /// `nil` (the default) means no limit.
        public var maxBytes: Int?

        public init(maxBytes: Int? = nil, resolveImageSource: @escaping @Sendable (String) -> String = { $0 }) {
            self.maxBytes = maxBytes
            self.resolveImageSource = resolveImageSource
        }

        var parseLimits: ParseLimits {
            ParseLimits(maxBytes: maxBytes)
        }
    }

    /// Why a document rendered as its escaped source instead of as Markdown.
    public enum FallbackReason: Sendable, Equatable {
        /// The document nests `depth` levels deep, too deep to render safely.
        case tooDeep(depth: Int)
        /// The document is larger than `Options.maxBytes`.
        case tooLarge
    }

    public struct RenderResult: Sendable, Equatable {
        public let html: String
        /// Set when `html` is the escaped source rather than rendered Markdown.
        public let fallback: FallbackReason?
    }

    /// Renders `markdown` to HTML. A document nested too deeply to render safely, or larger
    /// than `options.maxBytes`, renders as its escaped source in a `pre.source-fallback`.
    ///
    /// Parses and renders on a parsing worker and blocks until done (see `MarkdownParsing`).
    public static func render(_ markdown: String, options: Options = Options()) -> String {
        renderResult(markdown, options: options).html
    }

    /// Like `render`, also saying whether the source fallback was used and why.
    public static func renderResult(_ markdown: String, options: Options = Options()) -> RenderResult {
        MarkdownParsing.withDocument(markdown, options: options.parseLimits) { outcome in
            renderResult(outcome, source: markdown, options: options)
        }
    }

    /// Like `render`, waiting for a parsing worker without blocking.
    /// Returns `nil` only if the task was cancelled before rendering started.
    public static func renderResult(_ markdown: String, options: Options = Options()) async -> RenderResult? {
        await MarkdownParsing.withDocument(markdown, options: options.parseLimits) { outcome in
            renderResult(outcome, source: markdown, options: options)
        }
    }

    private static func renderResult(_ outcome: ParseOutcome, source: String, options: Options) -> RenderResult {
        switch outcome {
        case .document(let document):
            var visitor = HTMLVisitor(options: options)
            return RenderResult(html: visitor.visit(document), fallback: nil)
        case .tooDeep(let depth):
            return RenderResult(html: sourceFallbackHTML(source), fallback: .tooDeep(depth: depth))
        case .tooLarge:
            return RenderResult(html: sourceFallbackHTML(source), fallback: .tooLarge)
        }
    }

    static func sourceFallbackHTML(_ source: String) -> String {
        #"<pre class="source-fallback" data-line="1">"# + escapeHTML(source) + "</pre>"
    }
}

// MARK: - Visitor

private struct HTMLVisitor: MarkupVisitor {
    let options: MarkdownRenderer.Options
    private var usedSlugs: [String: Int] = [:]
    private var tightListStack: [Bool] = []

    init(options: MarkdownRenderer.Options) {
        self.options = options
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
        return " data-line=\"\(line)\""
    }

    // MARK: Blocks

    mutating func visitDocument(_ document: Document) -> String {
        visitChildren(document)
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
        let id = uniqueSlug(for: heading.plainText)
        return "<h\(level) id=\"\(escapeAttribute(id))\"\(lineAttribute(heading))>\(visitChildren(heading))</h\(level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr\(lineAttribute(thematicBreak))>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote\(lineAttribute(blockQuote))>\n\(visitChildren(blockQuote))</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
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

    mutating func visitText(_ text: Text) -> String {
        escapeHTML(text.string)
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

    private mutating func uniqueSlug(for text: String) -> String {
        let base = slugify(text)
        let count = usedSlugs[base, default: 0]
        usedSlugs[base] = count + 1
        return count == 0 ? base : "\(base)-\(count)"
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
