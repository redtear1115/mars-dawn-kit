import Foundation
import Markdown

/// Callouts (#135): GitHub alerts and HackMD containers, read from the parsed tree.
///
/// - **Alerts.** A block quote whose first paragraph's first line is exactly `[!NOTE]`, `[!TIP]`,
///   `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]` (any case, nothing else on that line) is a callout.
/// - **Containers.** A line that is exactly `:::info`, `:::success`, `:::warning`, `:::danger` (each
///   with an optional title), `:::spoiler Title` or the closer `:::` is a marker. A marker is a
///   whole paragraph or a line inside one (the usual HackMD form has no blank lines), and an
///   opener with a matching closer makes a callout (or, for `spoiler`, a closed `<details>`).
///
/// The reading happens on the tree: no source pre-pass, no recursion. Markers are found with one
/// forward scan over each paragraph's inline children, paired with a stack of at most
/// `maxNesting` entries, and handed to the renderer as a flat list of `Event`s. Everything that
/// does not pair stays what cmark made of it, so an unknown type or an unclosed `:::` renders
/// exactly as it did before callouts existed.
///
/// The type is only ever one of a fixed set, and each maps to a fixed class string: author text
/// reaches the page as the escaped text of a title and nowhere else.
enum Callouts {
    /// How many `:::` containers may be open at once inside one run of sibling blocks. An opener
    /// past this depth stays literal, and so does its closer. ParseLimits does not bound this:
    /// the containers are flat siblings in cmark, however many there are.
    static let maxNesting = 8

    /// The five looks of a callout. GitHub's names; HackMD's `info`, `success`, `warning` and
    /// `danger` are `note`, `tip`, `warning` and `caution`.
    enum Style: Sendable {
        case note, tip, important, warning, caution

        /// The `class` attribute. A fixed string per case: nothing from the document is in it.
        var classAttribute: String {
            switch self {
            case .note: "callout callout-note"
            case .tip: "callout callout-tip"
            case .important: "callout callout-important"
            case .warning: "callout callout-warning"
            case .caution: "callout callout-caution"
            }
        }
    }

    /// What opens a callout or a spoiler.
    enum Opening {
        /// `title` is the author's, or nil for the default one the stylesheet draws.
        case callout(Style, title: String?, line: Int?)
        case spoiler(title: String, line: Int?)
    }

    /// A child of a block container, or the part of a paragraph between two markers.
    struct Block {
        let node: any Markup
        /// A paragraph's inline children, all of them.
        let inlines: [any Markup]
        /// The slice of `inlines` this block stands for, or nil for the whole node.
        let inline: Range<Int>?

        init(_ node: any Markup) {
            self.node = node
            inlines = node is Paragraph ? Array(node.children) : []
            inline = nil
        }

        init(paragraph: Paragraph, inlines: [any Markup], inline: Range<Int>) {
            node = paragraph
            self.inlines = inlines
            self.inline = inline
        }
    }

    /// Where a node starts: enough to tell paragraphs apart.
    struct Position: Hashable, Sendable {
        let line: Int
        let column: Int

        init?(_ markup: any Markup) {
            guard let start = markup.range?.lowerBound else { return nil }
            line = start.line
            column = start.column
        }
    }

    /// A list whose last paragraph ends with the closer line: the renderer keeps `keep` of that
    /// paragraph's inline children, which leaves the closer out.
    struct Trim: Sendable {
        let position: Position
        let keep: Int
    }

    /// What the renderer does, in document order.
    enum Event {
        case content(Block, trim: Trim?)
        case open(Opening)
        case close
    }

    // MARK: - Alerts

    struct Alert {
        let style: Style
        /// What the quote holds besides the marker line.
        let blocks: [Block]
    }

    /// The alert a block quote is, or nil for an ordinary quote.
    static func alert(in blockQuote: BlockQuote) -> Alert? {
        guard let first = blockQuote.child(at: 0) as? Paragraph,
              let head = first.child(at: 0) as? Text, head.string.utf8.first == UInt8(ascii: "[") else { return nil }
        let inlines = Array(first.children)
        let end = inlines.firstIndex(where: { $0 is SoftBreak || $0 is LineBreak }) ?? inlines.count
        guard let text = plainText(of: inlines[..<end]), let style = alertStyle(text) else { return nil }
        var blocks: [Block] = []
        if end + 1 < inlines.count {
            blocks.append(Block(paragraph: first, inlines: inlines, inline: (end + 1)..<inlines.count))
        }
        for index in 1..<max(blockQuote.childCount, 1) {
            if let child = blockQuote.child(at: index) { blocks.append(Block(child)) }
        }
        return Alert(style: style, blocks: blocks)
    }

    private static func alertStyle(_ line: String) -> Style? {
        let bytes = trimmed(Array(line.utf8)).map(lowercased)
        guard bytes.count >= 4, bytes.count <= 13, bytes.starts(with: Array("[!".utf8)), bytes.last == UInt8(ascii: "]") else { return nil }
        switch String(decoding: bytes, as: UTF8.self) {
        case "[!note]": return .note
        case "[!tip]": return .tip
        case "[!important]": return .important
        case "[!warning]": return .warning
        case "[!caution]": return .caution
        default: return nil
        }
    }

    // MARK: - Containers

    /// Whether `source` could hold a `:::` marker. A document without `:::` anywhere is never
    /// scanned for containers.
    static func mayContainContainers(_ source: String) -> Bool {
        var run = 0
        for byte in source.utf8 {
            if byte == UInt8(ascii: ":") {
                run += 1
                if run == 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private enum Marker {
        case opener(Opening)
        case closer
    }

    private struct Occurrence {
        let block: Int
        /// The marker line's inline children, `start..<end`; a list's closer has none.
        let start: Int
        let end: Int
        let marker: Marker
        let trim: Trim?
    }

    /// What a reader of the tree needs from the source to tell a marker from text that only
    /// decodes to one.
    struct Source {
        let bytes: SourceBytes
        /// Lines of `bytes` that hold math the page shows as math, in a source whose math has not
        /// been swapped for placeholders (the word counter's). The renderer parses a source that
        /// has been, and finds the placeholder instead.
        let mathLines: Set<Int>

        init(_ text: String, mathLines: Set<Int> = []) {
            bytes = SourceBytes(text)
            self.mathLines = mathLines
        }
    }

    /// `blocks` as a list of events with every paired marker applied, or nil when no opener has a
    /// closer (the blocks then render exactly as they would without this).
    static func events(for blocks: [Block], source: Source? = nil) -> [Event]? {
        var perBlock = [[Occurrence]](repeating: [], count: blocks.count)
        var openers = 0
        for (index, block) in blocks.enumerated() {
            guard block.node is Paragraph else { continue }
            let range = block.inline ?? 0..<block.inlines.count
            perBlock[index] = markers(in: block.inlines, range: range, block: index, source: source)
            openers += perBlock[index].reduce(0) { count, occurrence in
                if case .opener = occurrence.marker { count + 1 } else { count }
            }
        }
        guard openers > 0 else { return nil }
        // A closer that cmark folded into the end of a list is its last line.
        for (index, block) in blocks.enumerated() where block.node is UnorderedList || block.node is OrderedList {
            if let trim = tailCloser(of: block.node, source: source) {
                perBlock[index] = [Occurrence(block: index, start: 0, end: 0, marker: .closer, trim: trim)]
            }
        }

        let all = perBlock.flatMap { $0 }
        var partner = [Int](repeating: -1, count: all.count)
        var open: [Int] = []
        var literalDepth = 0
        var paired = false
        for (index, occurrence) in all.enumerated() {
            switch occurrence.marker {
            case .opener:
                if open.count < maxNesting { open.append(index) } else { literalDepth += 1 }
            case .closer:
                if literalDepth > 0 {
                    literalDepth -= 1
                } else if let opener = open.popLast() {
                    partner[opener] = index
                    partner[index] = opener
                    paired = true
                }
            }
        }
        guard paired else { return nil }

        var events: [Event] = []
        events.reserveCapacity(blocks.count + 2 * all.count)
        var next = 0
        for (index, block) in blocks.enumerated() {
            let count = perBlock[index].count
            defer { next += count }
            let matched = (next..<(next + count)).filter { partner[$0] >= 0 }
            guard !matched.isEmpty else {
                events.append(.content(block, trim: nil))
                continue
            }
            if block.node is Paragraph, let paragraph = block.node as? Paragraph {
                let range = block.inline ?? 0..<block.inlines.count
                var cursor = range.lowerBound
                for position in matched {
                    let occurrence = all[position]
                    if occurrence.start - 1 > cursor {
                        events.append(.content(Block(paragraph: paragraph, inlines: block.inlines, inline: cursor..<(occurrence.start - 1)), trim: nil))
                    }
                    switch occurrence.marker {
                    case .opener(let opening): events.append(.open(opening))
                    case .closer: events.append(.close)
                    }
                    cursor = min(occurrence.end + 1, range.upperBound)
                }
                if cursor < range.upperBound {
                    events.append(.content(Block(paragraph: paragraph, inlines: block.inlines, inline: cursor..<range.upperBound), trim: nil))
                }
            } else {
                // A list ending in its closer: the list, then the end of the container.
                events.append(.content(block, trim: all[matched[0]].trim))
                events.append(.close)
            }
        }
        return events
    }

    /// The marker lines of one paragraph's inline children `range`, in order.
    private static func markers(in inlines: [any Markup], range: Range<Int>, block: Int, source: Source?) -> [Occurrence] {
        var found: [Occurrence] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var end = start
            while end < range.upperBound, !(inlines[end] is SoftBreak || inlines[end] is LineBreak) { end += 1 }
            // Cheap test first: a marker line begins with a colon.
            if let head = inlines[start] as? Text, head.string.utf8.first == UInt8(ascii: ":"),
               !isEscaped(inlines[start], in: source),
               let text = plainText(of: inlines[start..<end]), let marker = parse(text, line: inlines[start].range?.lowerBound.line, source: source) {
                found.append(Occurrence(block: block, start: start, end: end, marker: marker, trim: nil))
            }
            start = end + 1
        }
        return found
    }

    /// `:::info`, `:::success`, `:::warning`, `:::danger` (each with an optional title), `:::spoiler
    /// Title` or `:::`, as a whole line of text.
    private static func parse(_ line: String, line sourceLine: Int?, source: Source?) -> Marker? {
        let bytes = trimmed(Array(line.utf8))
        let colon = UInt8(ascii: ":")
        guard bytes.count >= 3, bytes[0] == colon, bytes[1] == colon, bytes[2] == colon else { return nil }
        if bytes.count == 3 { return .closer }
        var end = 3
        while end < bytes.count, (0x61...0x7A).contains(bytes[end]) { end += 1 }
        guard end > 3, end == bytes.count || bytes[end] == 0x20 || bytes[end] == 0x09 else { return nil }
        let title = String(decoding: trimmed(Array(bytes[end...])), as: UTF8.self)
        // A placeholder of this render (math, footnote) is not a title.
        guard !title.unicodeScalars.contains(where: { $0 == "\u{E000}" || $0 == "\u{E001}" }) else { return nil }
        // The same for math the renderer's source has not had swapped out yet.
        if let sourceLine, source?.mathLines.contains(sourceLine) == true { return nil }
        let author = title.isEmpty ? nil : title
        switch String(decoding: bytes[3..<end], as: UTF8.self) {
        case "info": return .opener(.callout(.note, title: author, line: sourceLine))
        case "success": return .opener(.callout(.tip, title: author, line: sourceLine))
        case "warning": return .opener(.callout(.warning, title: author, line: sourceLine))
        case "danger": return .opener(.callout(.caution, title: author, line: sourceLine))
        case "spoiler":
            guard let author else { return nil }
            return .opener(.spoiler(title: author, line: sourceLine))
        default: return nil
        }
    }

    /// For a list whose last line is a closer: the paragraph that holds it and how much of it to
    /// keep. "Last line" means the final line of the final paragraph of the final item, at any
    /// depth of lists in lists; a closer anywhere else in a list is left literal.
    private static func tailCloser(of list: any Markup, source: Source?) -> Trim? {
        var node: any Markup = list
        while node.childCount > 0, let last = node.child(at: node.childCount - 1) {
            if let paragraph = last as? Paragraph {
                let inlines = Array(paragraph.children)
                var start = inlines.count
                while start > 0, !(inlines[start - 1] is SoftBreak || inlines[start - 1] is LineBreak) { start -= 1 }
                guard start > 0, start < inlines.count, let position = Position(paragraph),
                      !isEscaped(inlines[start], in: source),
                      let text = plainText(of: inlines[start...]),
                      case .closer? = parse(text, line: nil, source: source) else { return nil }
                return Trim(position: position, keep: start - 1)
            }
            guard last is ListItem || last is UnorderedList || last is OrderedList else { return nil }
            node = last
        }
        return nil
    }

    // MARK: - Helpers

    /// Whether the marker line that begins with `first` was written with an escape for a colon
    /// (`\:::info`, `&#58;&#58;&#58;info`): cmark decodes those to the same `Text` as the plain
    /// line, but HackMD matches the line as written and shows them as text. Judged from the
    /// source bytes at the start of the line; where the range is missing or points at anything
    /// else, the decoded text is believed, as cmark's ranges can be wrong.
    private static func isEscaped(_ first: any Markup, in source: Source?) -> Bool {
        guard let source, let start = first.range?.lowerBound,
              let bytes = source.bytes.prefix(at: start, count: 3), let head = bytes.first else { return false }
        let colon = UInt8(ascii: ":")
        if head == colon { return !bytes.allSatisfy { $0 == colon } }
        return head == UInt8(ascii: "\\") || head == UInt8(ascii: "&")
    }

    /// The text of `inlines` when every one is text or raw inline HTML (read as the characters
    /// written, so a title such as `"><img src=x onerror=…>` is text and reaches the page escaped),
    /// else nil. cmark splits text at characters it watches for (a colon, for autolinks), so one
    /// line is often several nodes.
    private static func plainText(of inlines: ArraySlice<any Markup>) -> String? {
        var text = ""
        for inline in inlines {
            if let node = inline as? Text {
                text += node.string
            } else if let node = inline as? InlineHTML {
                text += node.rawHTML
            } else {
                return nil
            }
        }
        return text
    }

    private static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        var start = 0
        var end = bytes.count
        while start < end, bytes[start] == 0x20 || bytes[start] == 0x09 { start += 1 }
        while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        return Array(bytes[start..<end])
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }
}
