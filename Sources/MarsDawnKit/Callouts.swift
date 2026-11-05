import Foundation
import Markdown

/// Callouts (#135): GitHub alerts and HackMD containers, read from the parsed tree.
///
/// - **Alerts.** A block quote whose first paragraph's first line is exactly `[!NOTE]`, `[!TIP]`,
///   `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]` (any case, nothing else on that line) is a callout.
/// - **Foldable alerts (#300).** Obsidian's `[!note]-` (collapsed) and `[!tip]+` (expanded), for the
///   same five types, optionally followed by a space and a title: a `<details class="callout …">`.
/// - **Containers.** A line that is exactly `:::info`, `:::success`, `:::warning`, `:::danger` (each
///   with an optional title), `:::spoiler` (with an optional `{state="open"}` and title) or the
///   closer `:::` is a marker. A marker is a whole paragraph or a line inside one (the usual
///   HackMD form has no blank lines), and an opener with a matching closer makes a callout (or,
///   for `spoiler`, a `<details>`). As in markdown-it-container, an opener of N colons is closed
///   only by a closer of at least N, so `::::spoiler` can hold a `:::spoiler` (#300).
///
/// The reading happens on the tree: no source pre-pass, no recursion. Markers are found with one
/// forward scan over each paragraph's inline children, paired with a stack of at most
/// `maxNesting` entries, and handed to the renderer as a flat list of `Event`s. Everything that
/// does not pair stays what cmark made of it, so an unknown type or an unclosed `:::` renders
/// exactly as it did before callouts existed.
///
/// The type is only ever one of a fixed set, and each maps to a fixed class string: author text
/// reaches the page only as a title, rendered by the renderer's inline path with any raw HTML in
/// it escaped as text (`Title`).
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

    /// An author's title: `lead`, plain text, then `nodes`, the inline nodes that followed it on
    /// the marker line (emphasis, code, links). The renderer writes `lead` as text and `nodes`
    /// through its inline path, with raw HTML in them escaped as text: a title never carries
    /// more markup than a paragraph would, and never raw HTML.
    struct Title {
        let lead: String
        let nodes: [any Markup]

        /// The title of `lead` and `nodes`, or nil when both are empty.
        init?(lead: String, nodes: [any Markup]) {
            guard !lead.isEmpty || !nodes.isEmpty else { return nil }
            self.lead = lead
            self.nodes = nodes
        }
    }

    /// What opens a callout or a spoiler.
    enum Opening {
        /// `title` is the author's, or nil for the default one the stylesheet draws.
        case callout(Style, title: Title?, line: Int?)
        /// `title` nil: a `<details>` without a `<summary>`, as WebKit labels it. `open` only for
        /// `{state="open"}`.
        case spoiler(title: Title?, open: Bool, line: Int?)
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
        /// The closer's colons.
        let colons: Int
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
        /// Set for Obsidian's foldable form (`[!note]-`, `[!tip]+`), nil for GitHub's.
        var fold: Fold? = nil
    }

    /// A foldable alert (#300): open for `+`, closed for `-`, with the author's title if any.
    struct Fold {
        let open: Bool
        let title: Title?
    }

    /// The alert a block quote is, or nil for an ordinary quote.
    static func alert(in blockQuote: BlockQuote) -> Alert? {
        guard let first = blockQuote.child(at: 0) as? Paragraph,
              let head = first.child(at: 0) as? Text, head.string.utf8.first == UInt8(ascii: "[") else { return nil }
        let inlines = Array(first.children)
        let end = inlines.firstIndex(where: { $0 is SoftBreak || $0 is LineBreak }) ?? inlines.count
        var fold: Fold?
        let style: Style
        if let text = plainText(of: inlines[..<end]), let plain = alertStyle(text) {
            style = plain
        } else if let foldable = foldableAlert(inlines[..<end]) {
            style = foldable.style
            fold = foldable.fold
        } else {
            return nil
        }
        var blocks: [Block] = []
        if end + 1 < inlines.count {
            blocks.append(Block(paragraph: first, inlines: inlines, inline: (end + 1)..<inlines.count))
        }
        for index in 1..<max(blockQuote.childCount, 1) {
            if let child = blockQuote.child(at: index) { blocks.append(Block(child)) }
        }
        return Alert(style: style, blocks: blocks, fold: fold)
    }

    /// `[!type]-` or `[!type]+` (any case, one of the five types), then nothing or a space and a
    /// title, as the first line of a block quote.
    private static func foldableAlert(_ line: ArraySlice<any Markup>) -> (style: Style, fold: Fold)? {
        let (lead, rest) = leadingText(line)
        let bytes = Array(lead.utf8)
        guard let close = bytes.firstIndex(of: UInt8(ascii: "]")), close + 1 < bytes.count,
              let style = alertStyle(String(decoding: bytes[...close], as: UTF8.self)) else { return nil }
        let sign = bytes[close + 1]
        guard sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") else { return nil }
        let after = close + 2
        if after < bytes.count {
            guard bytes[after] == 0x20 || bytes[after] == 0x09 else { return nil }
        } else if !rest.isEmpty {
            return nil
        }
        let title = titleOf(Array(bytes[min(after, bytes.count)...]), nodes: rest)
        return (style, Fold(open: sign == UInt8(ascii: "+"), title: title))
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
        /// `colons`: how many the marker began with, three or more.
        case opener(Opening, colons: Int)
        case closer(colons: Int)

        var colons: Int {
            switch self {
            case .opener(_, let colons), .closer(let colons): colons
            }
        }
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
                perBlock[index] = [Occurrence(block: index, start: 0, end: 0, marker: .closer(colons: trim.colons), trim: trim)]
            }
        }

        let all = perBlock.flatMap { $0 }
        var partner = [Int](repeating: -1, count: all.count)
        // Every opener still open, innermost last: its index (-1 past the cap) and its colons.
        var open: [(index: Int, colons: Int)] = []
        var depth = 0
        var paired = false
        for (index, occurrence) in all.enumerated() {
            switch occurrence.marker {
            case .opener(_, let colons):
                // Past the cap an opener stays literal, and so does everything inside it.
                let literal = depth >= maxNesting || open.last?.index == -1
                open.append((literal ? -1 : index, colons))
                if !literal { depth += 1 }
            case .closer(let colons):
                // A closer shorter than the innermost opener is not its closer: it stays literal.
                guard let innermost = open.last, innermost.colons <= colons else { continue }
                open.removeLast()
                guard innermost.index >= 0 else { continue }
                depth -= 1
                partner[innermost.index] = index
                partner[index] = innermost.index
                paired = true
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
                    case .opener(let opening, _): events.append(.open(opening))
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
               let marker = marker(inlines[start..<end], line: inlines[start].range?.lowerBound.line, source: source) {
                found.append(Occurrence(block: block, start: start, end: end, marker: marker, trim: nil))
            }
            start = end + 1
        }
        return found
    }

    /// The scalars a placeholder of this render starts and ends with: math's U+E000/U+E001 and
    /// the footnote reference's U+E002/U+E003.
    private static func isPlaceholderScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == MathExtractor.placeholderStart || scalar == MathExtractor.placeholderEnd
            || scalar == FootnoteExtractor.placeholderStart || scalar == FootnoteExtractor.placeholderEnd
    }

    /// The marker a line's inline children are, if any. A line of text and raw HTML only is read
    /// as text, as it always was; a line with other inline nodes (a title with emphasis, code or
    /// a link) is read from its leading text, and the nodes after it are the rest of the title.
    private static func marker(_ line: ArraySlice<any Markup>, line sourceLine: Int?, source: Source?) -> Marker? {
        if let text = plainText(of: line) { return parse(text, nodes: [], line: sourceLine, source: source) }
        let (lead, rest) = leadingText(line)
        // A placeholder of this render (math, footnote) anywhere in the title: not a marker.
        guard !rest.contains(where: containsPlaceholder) else { return nil }
        return parse(lead, nodes: rest, line: sourceLine, source: source)
    }

    /// `:::info`, `:::success`, `:::warning`, `:::danger` (each with an optional title), `:::spoiler`
    /// (with an optional `{state="open"}` and title) or `:::`, each with three colons or more:
    /// `line` is the line's leading text and `nodes` the inline nodes after it.
    private static func parse(_ line: String, nodes: [any Markup], line sourceLine: Int?, source: Source?) -> Marker? {
        var bytes = Array(line.utf8)
        let colon = UInt8(ascii: ":")
        var start = 0
        while start < bytes.count, bytes[start] == 0x20 || bytes[start] == 0x09 { start += 1 }
        if nodes.isEmpty { bytes = trimmed(bytes); start = 0 }
        var colons = start
        while colons < bytes.count, bytes[colons] == colon { colons += 1 }
        let count = colons - start
        guard count >= 3 else { return nil }
        if colons == bytes.count { return nodes.isEmpty ? .closer(colons: count) : nil }
        var end = colons
        while end < bytes.count, (0x61...0x7A).contains(bytes[end]) { end += 1 }
        guard end > colons else { return nil }
        if end == bytes.count {
            guard nodes.isEmpty else { return nil }
        } else {
            guard bytes[end] == 0x20 || bytes[end] == 0x09 else { return nil }
        }
        var rest = Array(bytes[end...])
        // A placeholder of this render (math, footnote) is not a title.
        guard !String(decoding: rest, as: UTF8.self).unicodeScalars.contains(where: Self.isPlaceholderScalar) else { return nil }
        // The same for math the renderer's source has not had swapped out yet.
        if let sourceLine, source?.mathLines.contains(sourceLine) == true { return nil }
        let name = String(decoding: bytes[colons..<end], as: UTF8.self)
        var open = false
        if name == "spoiler", let attribute = stateOpenLength(rest), writtenStateOpen(line: sourceLine, source: source) {
            open = true
            rest.removeFirst(attribute)
        }
        let title = titleOf(rest, nodes: nodes)
        let opening: Opening
        switch name {
        case "info": opening = .callout(.note, title: title, line: sourceLine)
        case "success": opening = .callout(.tip, title: title, line: sourceLine)
        case "warning": opening = .callout(.warning, title: title, line: sourceLine)
        case "danger": opening = .callout(.caution, title: title, line: sourceLine)
        case "spoiler": opening = .spoiler(title: title, open: open, line: sourceLine)
        default: return nil
        }
        return .opener(opening, colons: count)
    }

    /// How many bytes of `rest` (what follows `spoiler`) are blanks and HackMD's `{state="open"}`
    /// (or `{state='open'}`) followed by a blank or the end, or nil when it does not start so.
    /// The parser's smart punctuation has curled the quotes by now, so the curled forms are read
    /// here and `writtenStateOpen` checks what the source line says.
    private static func stateOpenLength(_ rest: [UInt8]) -> Int? {
        var index = 0
        while index < rest.count, rest[index] == 0x20 || rest[index] == 0x09 { index += 1 }
        guard index > 0 else { return nil }
        for form in [#"{state="open"}"#, "{state='open'}", "{state=\u{201C}open\u{201D}}", "{state=\u{2018}open\u{2019}}"] {
            let attribute = Array(form.utf8)
            guard rest[index...].starts(with: attribute) else { continue }
            let end = index + attribute.count
            guard end == rest.count || rest[end] == 0x20 || rest[end] == 0x09 else { return nil }
            return end
        }
        return nil
    }

    /// Whether the source line of a spoiler holds `{state="open"}` or `{state='open'}` with straight
    /// quotes, as written: curly quotes typed by the author are title text. Without the source,
    /// the decoded text is believed.
    private static func writtenStateOpen(line: Int?, source: Source?) -> Bool {
        guard let line, let bytes = source?.bytes.line(line) else { return true }
        let text = Array(bytes)
        return [#"{state="open"}"#, "{state='open'}"].contains { form in
            let needle = Array(form.utf8)
            guard text.count >= needle.count else { return false }
            return (0...(text.count - needle.count)).contains { text[$0..<($0 + needle.count)].elementsEqual(needle) }
        }
    }

    /// The title of what follows a marker: `rest`, the leading text after the type (blanks around
    /// it dropped, though not a blank before `nodes`), then `nodes`.
    private static func titleOf(_ rest: [UInt8], nodes: [any Markup]) -> Title? {
        var start = 0
        var end = rest.count
        while start < end, rest[start] == 0x20 || rest[start] == 0x09 { start += 1 }
        if nodes.isEmpty {
            while end > start, rest[end - 1] == 0x20 || rest[end - 1] == 0x09 { end -= 1 }
        }
        return Title(lead: String(decoding: rest[start..<end], as: UTF8.self), nodes: nodes)
    }

    /// The text of the `Text` nodes that begin `line`, and the nodes after them.
    private static func leadingText(_ line: ArraySlice<any Markup>) -> (String, [any Markup]) {
        var lead = ""
        var index = line.startIndex
        while index < line.endIndex, let text = line[index] as? Text {
            lead += text.string
            index += 1
        }
        return (lead, Array(line[index...]))
    }

    /// Whether `node` or anything in it is text holding a placeholder scalar of this render.
    private static func containsPlaceholder(_ node: any Markup) -> Bool {
        var stack: [any Markup] = [node]
        while let next = stack.popLast() {
            if let text = next as? Text, text.string.unicodeScalars.contains(where: isPlaceholderScalar) { return true }
            if let code = next as? InlineCode, code.code.unicodeScalars.contains(where: isPlaceholderScalar) { return true }
            stack.append(contentsOf: next.children)
        }
        return false
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
                      case .closer(let colons)? = parse(text, nodes: [], line: nil, source: source) else { return nil }
                return Trim(position: position, keep: start - 1, colons: colons)
            }
            guard last is ListItem || last is UnorderedList || last is OrderedList else { return nil }
            node = last
        }
        return nil
    }

    // MARK: - Helpers

    /// Whether the marker line that begins with `first` was written with an escape for a colon
    /// (`\:::info`, `&#58;&#58;&#58;info`): cmark decodes those to the same `Text` as the plain
    /// line, but HackMD matches the line as written and shows them as text.
    ///
    /// Judged from the source line: past the indent and any `>` of a block quote, a marker is
    /// three colons. cmark's column is not used first, because a line a list item took lazily
    /// (`:::` closing a list) is given the item's column, not its own. Behind a list marker the
    /// column is right, and is read instead. Where nothing says otherwise the decoded text is
    /// believed.
    private static func isEscaped(_ first: any Markup, in source: Source?) -> Bool {
        guard let source, let start = first.range?.lowerBound else { return false }
        let colon = UInt8(ascii: ":")
        func escapes(_ bytes: ArraySlice<UInt8>) -> Bool? {
            guard let head = bytes.first else { return nil }
            if head == colon { return !bytes.prefix(3).elementsEqual([colon, colon, colon]) }
            return head == UInt8(ascii: "\\") || head == UInt8(ascii: "&") ? true : nil
        }
        if var line = source.bytes.line(start.line) {
            while let head = line.first, head == 0x20 || head == 0x09 || head == UInt8(ascii: ">") { line = line.dropFirst() }
            if let answer = escapes(line) { return answer }
        }
        guard let bytes = source.bytes.prefix(at: start, count: 3) else { return false }
        return escapes(bytes) ?? false
    }

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
