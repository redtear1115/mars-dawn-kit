import Foundation
import Markdown

/// The headings of a Markdown document, for the app's sidebar outline.
///
/// Both ATX (`#`) and setext (`===`/`---`) headings are included, in document order,
/// including ones inside block quotes and list items. Headings inside code blocks or
/// HTML blocks aren't headings at all as far as the parser is concerned, so they're
/// naturally excluded.
public struct DocumentOutline: Sendable, Equatable {
    /// One heading in the document.
    public struct Heading: Sendable, Equatable, Hashable {
        /// The heading level, from `1` to `6`.
        public let level: Int
        /// The heading's text, with inline markup resolved to plain text and
        /// runs of whitespace collapsed to a single space. Can be empty.
        public let title: String
        /// The 1-based line in the full file where the heading starts.
        public let line: Int
    }

    /// The document's headings, in document order.
    public let headings: [Heading]

    /// Parses `markdownBody` and collects its headings.
    ///
    /// - Parameters:
    ///   - markdownBody: The document body with its front matter already removed, as
    ///     `FrontMatter.split` returns it. Nothing is split off here; a whole file passed
    ///     in would have its front matter parsed as Markdown, and a `---` delimiter read
    ///     as a setext heading underline.
    ///   - lineOffset: The number of source lines before `markdownBody` in the full file:
    ///     pass the `bodyLineOffset` that `FrontMatter.split` returned with it, which is
    ///     the length of the front-matter block including both `---` delimiters, or `0`
    ///     when the file has no front matter. A heading's `line` is its line within
    ///     `markdownBody` plus this offset, so it addresses the full file.
    ///
    /// The parse and the walk over its nodes run on a parsing worker
    /// (`MarkdownParsing.withDocument`), and this initializer blocks until they finish.
    /// A body the worker refuses to parse — `.tooDeep`, `.tooLarge` or `.tooComplex` —
    /// has no headings: the sidebar then shows an empty outline, which matches the
    /// preview, since the renderer shows such a body as escaped source with no headings
    /// in it. Guessing headings from the source without a parse would list ones the
    /// preview does not show.
    public init(markdownBody: String, lineOffset: Int = 0) {
        headings = DocumentOutline.parseHeadings(markdownBody, lineOffset: lineOffset)
    }

    /// The index of the heading whose section contains `line`: the last heading at or
    /// before it. Returns `nil` if `line` comes before the first heading, or there are
    /// no headings.
    public func sectionIndex(containingLine line: Int) -> Int? {
        var result: Int?
        for (index, heading) in headings.enumerated() {
            guard heading.line <= line else { break }
            result = index
        }
        return result
    }

    // MARK: - Parsing

    /// Walks the parsed document with an explicit stack (no recursion) and collects
    /// every `Heading` node, in document order. The body is parsed once, on a parsing
    /// worker; the walk and the title visitor run there too, and only the headings —
    /// plain values — come back. Over any budget, there are no headings.
    private static func parseHeadings(_ markdownBody: String, lineOffset: Int) -> [Heading] {
        guard !markdownBody.isEmpty else { return [] }
        return MarkdownParsing.withDocument(markdownBody) { outcome -> [Heading] in
            guard case .document(let document) = outcome else { return [] }

            var result: [Heading] = []
            var stack: [Markup] = Array(document.children.reversed())
            while let node = stack.popLast() {
                if let heading = node as? Markdown.Heading {
                    let sourceLine = heading.range?.lowerBound.line ?? 1
                    result.append(
                        Heading(
                            level: heading.level,
                            title: plainTitle(of: heading),
                            line: sourceLine + lineOffset
                        )
                    )
                } else {
                    stack.append(contentsOf: node.children.reversed())
                }
            }
            return result
        }
    }

    /// The heading's text with inline markup resolved and whitespace collapsed.
    private static func plainTitle(of heading: Markdown.Heading) -> String {
        var visitor = HeadingTitleVisitor()
        visitor.visit(heading)
        let collapsed = visitor.output.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }
}

// MARK: - Heading title visitor

/// Collects a heading's text: emphasis, links and code spans keep their text, images
/// use their alt text, and inline HTML is dropped.
private struct HeadingTitleVisitor: MarkupWalker {
    var output = ""

    mutating func visitText(_ text: Text) {
        output += text.string
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        output += inlineCode.code
    }

    mutating func visitImage(_ image: Image) {
        output += image.plainText
        output += " "
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        output += " "
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        output += " "
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        // HTML tags aren't part of the title.
    }
}
