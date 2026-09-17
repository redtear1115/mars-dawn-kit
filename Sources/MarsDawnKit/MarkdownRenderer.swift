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

        public init(resolveImageSource: @escaping @Sendable (String) -> String = { $0 }) {
            self.resolveImageSource = resolveImageSource
        }
    }

    public static func render(_ markdown: String, options: Options = Options()) -> String {
        let document = Document(parsing: markdown)
        var visitor = HTMLVisitor(options: options)
        return visitor.visit(document)
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

func escapeHTML(_ string: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(string.utf8.count)
    for character in string {
        switch character {
        case "&": escaped += "&amp;"
        case "<": escaped += "&lt;"
        case ">": escaped += "&gt;"
        default: escaped.append(character)
        }
    }
    return escaped
}

func escapeAttribute(_ string: String) -> String {
    escapeHTML(string)
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// Allows relative URLs and a short list of schemes; everything else becomes "#".
/// Tabs and newlines are removed first, as browsers do when parsing URLs.
func sanitizedURL(_ url: String, allowData: Bool) -> String {
    let cleaned = String(url.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        .trimmingCharacters(in: .whitespaces)
    guard let colon = cleaned.firstIndex(of: ":") else { return cleaned }
    let scheme = cleaned[..<colon].lowercased()
    // A "scheme" containing '/', '?' or '#' is really a relative path.
    if scheme.contains(where: { "/?#".contains($0) }) { return cleaned }
    switch scheme {
    case "http", "https", "mailto", DocumentAssetSchemeHandler.scheme:
        return cleaned
    case "data":
        let lower = cleaned.lowercased()
        return allowData && lower.hasPrefix("data:image/") && !lower.hasPrefix("data:image/svg") ? cleaned : "#"
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
