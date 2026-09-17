import Foundation
import Markdown

/// Finds TeX math (`$…$`, `$$…$$`) in raw Markdown before swift-markdown parses it.
///
/// CommonMark would otherwise drop TeX backslashes, turn `*` into emphasis and `<…>`
/// into inline HTML. `extract(from:)` swaps each inline expression for an opaque
/// placeholder and turns top-level `$$` paragraphs into `math` code fences, keeping the
/// line count unchanged so `data-line` numbers still match the editor.
///
/// How it works:
/// 1. The body is parsed once. Math is looked for only inside paragraphs, headings and
///    table cells, and never inside code spans, inline HTML, images, link destinations
///    or titles (link text is scanned). Code blocks, HTML blocks and link reference
///    definitions are never scanned.
/// 2. Inside those regions, `$…$` and `$$…$$` must sit on one source line. Scanning runs
///    left to right: a `$` that opens math before a code span, HTML tag or link starts
///    wins, and the math may enclose those constructs completely (so `$x<y>z$` is math).
///    Math that would end inside one of them, or cut a link's text, is not extracted.
/// 3. A top-level paragraph that starts with `$$`, ends with `$$` and holds exactly one
///    display expression becomes a `math` fence with the same number of lines.
/// 4. The rewritten source is parsed again. Each paragraph, heading or cell whose
///    placeholders are not all in plain text, whose links, images, code spans, inline
///    HTML or emphasis changed (beyond what the math itself enclosed), or whose block
///    structure changed, is restored to its original source without math. This repeats
///    at most three times; after that the body is returned unchanged.
///
/// Every parse here, and every walk over its nodes, runs inside a
/// `MarkdownParsing.withDocument` body, on a parsing worker with a 64 MB stack; only
/// strings and counts come back. `extract` blocks the calling thread while that runs. The
/// first parse opens the worker, so the rewrite parses and the per-expression TeX parses
/// nested inside it run inline on the same worker.
///
/// Each round re-parses the body, so the cost is a few times one parse. Limits keep that
/// bounded, and a document over any of them shows its math as source text instead of
/// delaying every preview update by seconds:
/// - bodies over `maxBodyBytes` are not scanned at all;
/// - bodies whose first parse has more than `maxBlocks` block nodes (table cells
///   included: cmark-gfm pads short rows, so a narrow file can hold a huge table) are
///   returned unchanged after that parse;
/// - a body the parsing worker refuses outright — `.tooDeep`, `.tooLarge` or
///   `.tooComplex` under `ParseLimits` — is returned unchanged with no expressions, the
///   same answer as a body with no `$` in it. That is what the renderer needs: such a
///   body is shown as escaped source, where TeX belongs as written anyway. A rewrite
///   here could not be checked, because checking it means parsing it.
/// The same is true of a rewrite that the worker refuses although the body was accepted,
/// and of an expression whose own TeX cannot be parsed: that container keeps its source.
///
/// Flow for a renderer:
/// 1. `let extraction = MathExtractor.extract(from: body)`, where `body` is the document
///    with its front matter already removed, as `FrontMatter.split` returns it. Nothing
///    is split off here, and `extraction.markdown` has as many lines as `body`, so a
///    caller's `bodyLineOffset` still maps its `data-line` numbers onto the file.
/// 2. Parse `extraction.markdown` (through `MarkdownParsing.withDocument`).
/// 3. Replace each `Text` node's string with `extraction.segments(in:)`.
/// 4. For a `CodeBlock` where `isMathFence(language:)` is true, render
///    `extraction.tex(forMathFence:code:)` as display math.
///
/// The TeX returned here is raw source, and so is the `.text` around it. Both are
/// unescaped: `escapeHTML` before putting either in element content, and
/// `escapeAttribute` before putting either in a quoted attribute value (`escapeHTML`
/// leaves `"` and `'` alone, so it is not enough for an attribute).
public enum MathExtractor {
    /// Expressions longer than this many Unicode scalars stay as source text.
    public static let maxExpressionLength = 10_000
    /// Only the first this many expressions in a document are extracted.
    public static let maxExpressionCount = 2_000
    /// Bodies larger than this many UTF-8 bytes are not scanned for math.
    public static let maxBodyBytes = 256_000
    /// Bodies with more block nodes than this (including table cells) are not rewritten.
    public static let maxBlocks = 50_000

    /// A piece of a `Text` node after placeholder expansion. Neither case is HTML-escaped.
    public enum Segment: Equatable, Sendable {
        case text(String)
        case math(tex: String, display: Bool)
    }

    /// The rewritten Markdown plus the expressions its placeholders refer to.
    public struct Extraction: Sendable {
        /// Source to hand to `MarkdownParsing.withDocument`. Has the same number of lines
        /// as the input, so `data-line` numbers still address the original file.
        public let markdown: String
        /// Number of extracted expressions, including display blocks.
        public var expressionCount: Int { expressions.count }

        let nonce: String
        let expressions: [Expression]

        /// Splits a `Text` node's string into plain text and math.
        ///
        /// Only placeholders made by this extraction (matching nonce, valid index) are
        /// expanded. Any other U+E000…U+E001 sequence is returned as `.text`, unchanged.
        public func segments(in text: String) -> [Segment] {
            let scalars = Array(text.unicodeScalars)
            var segments: [Segment] = []
            var plain = String.UnicodeScalarView()
            var index = 0
            while index < scalars.count {
                if scalars[index] == MathExtractor.placeholderStart,
                   let (expression, end) = inlineExpression(in: scalars, at: index) {
                    if !plain.isEmpty {
                        segments.append(.text(String(plain)))
                        plain = String.UnicodeScalarView()
                    }
                    segments.append(.math(tex: expression.tex, display: expression.display))
                    index = end
                } else {
                    plain.append(scalars[index])
                    index += 1
                }
            }
            if !plain.isEmpty { segments.append(.text(String(plain))) }
            return segments
        }

        /// The TeX for a code block whose info string passes `isMathFence(language:)`.
        ///
        /// For a fence this extraction made from a `$$` paragraph, returns the verbatim
        /// source between the `$$` delimiters (including any TeX on the delimiter lines).
        /// For a `math` fence the author wrote, returns `code` without its final line
        /// ending. Either way the result is raw TeX: escape it before it reaches a page.
        public func tex(forMathFence language: String?, code: String) -> String {
            if let language, let index = MathExtractor.blockPlaceholderIndex(info: language, nonce: nonce),
               index < expressions.count, expressions[index].isBlock {
                return expressions[index].tex
            }
            // On bytes, not `Character`s: the last grapheme of code ending in CR LF is the
            // pair, so `hasSuffix("\n")` misses it and `dropLast()` would drop both.
            let utf8 = code.utf8
            guard utf8.last == Byte.newline else { return code }
            var end = utf8.index(before: utf8.endIndex)
            if end > utf8.startIndex, utf8[utf8.index(before: end)] == Byte.carriageReturn {
                end = utf8.index(before: end)
            }
            return String(decoding: utf8[..<end], as: UTF8.self)
        }

        private func inlineExpression(in scalars: [Unicode.Scalar], at start: Int) -> (Expression, Int)? {
            guard let (index, end) = MathExtractor.parsePlaceholder(scalars, at: start, nonce: nonce),
                  index < expressions.count, !expressions[index].isBlock else { return nil }
            return (expressions[index], end)
        }
    }

    struct Expression: Equatable, Sendable {
        let tex: String
        let display: Bool
        /// True for a `$$` paragraph rewritten into a fence; those are never expanded from text.
        let isBlock: Bool
    }

    /// Extracts math using a fresh 64-bit nonce from `SystemRandomNumberGenerator`.
    public static func extract(from body: String) -> Extraction {
        var generator = SystemRandomNumberGenerator()
        return extract(from: body, using: &generator)
    }

    /// Extracts math, drawing the placeholder nonce from `generator` (for tests).
    public static func extract(from body: String, using generator: inout some RandomNumberGenerator) -> Extraction {
        let hex = String(generator.next() as UInt64, radix: 16)
        let nonce = String(repeating: "0", count: 16 - hex.count) + hex
        guard body.utf8.count <= maxBodyBytes, body.utf8.contains(Byte.dollar) else {
            return Extraction(markdown: body, nonce: nonce, expressions: [])
        }
        // The whole run happens inside one worker body: the document and every node stay
        // there, and only the rewritten source and the expressions come back.
        let rewritten = MarkdownParsing.withDocument(body) { outcome -> (String, [Expression]) in
            guard case .document(let document) = outcome else { return (body, []) }
            var engine = Engine(body: body, nonce: nonce)
            return engine.run(document)
        }
        return Extraction(markdown: rewritten.0, nonce: nonce, expressions: rewritten.1)
    }

    /// True when a code block's info string names the `math` language (first word, any
    /// ASCII case).
    public static func isMathFence(language: String?) -> Bool {
        guard let language, let first = infoWords(language).first else { return false }
        return asciiCaseInsensitiveEquals(first, "math")
    }

    /// An info string's ASCII space- and tab-delimited words, as UTF-8 slices, the way
    /// cmark-gfm reads the language out of one.
    ///
    /// Split on bytes, not `Character`s: a space carrying a combining mark is a single
    /// grapheme that compares unequal to `" "`, so a `Character` split would run the
    /// language together with what follows it and miss the language entirely. The split
    /// points are ASCII, which never occur inside a multi-byte sequence, so each slice is
    /// whole UTF-8.
    static func infoWords(_ info: String) -> [ArraySlice<UInt8>] {
        let bytes = Array(info.utf8)
        var words: [ArraySlice<UInt8>] = []
        var index = 0
        while index < bytes.count {
            while index < bytes.count, Byte.isSpaceOrTab(bytes[index]) { index += 1 }
            let start = index
            while index < bytes.count, !Byte.isSpaceOrTab(bytes[index]) { index += 1 }
            if start < index { words.append(bytes[start..<index]) }
        }
        return words
    }

    // MARK: Placeholders

    static let placeholderStart: Unicode.Scalar = "\u{E000}"
    static let placeholderEnd: Unicode.Scalar = "\u{E001}"

    static func placeholder(index: Int, nonce: [UInt8]) -> [UInt8] {
        Array("\u{E000}\(index):".utf8) + nonce + Array("\u{E001}".utf8)
    }

    /// Parses `U+E000 <index>:<nonce> U+E001` at `start`; returns the index and the end offset.
    static func parsePlaceholder(_ scalars: [Unicode.Scalar], at start: Int, nonce: String) -> (Int, Int)? {
        var position = start
        guard position < scalars.count, scalars[position] == placeholderStart else { return nil }
        position += 1
        let digitsStart = position
        var index = 0
        while position < scalars.count, position - digitsStart < 10, let digit = asciiDigit(scalars[position]) {
            index = index * 10 + digit
            position += 1
        }
        let digitCount = position - digitsStart
        // 1–9 digits, no leading zeros.
        guard (1...9).contains(digitCount),
              digitCount == 1 || scalars[digitsStart] != "0",
              position < scalars.count, scalars[position] == ":" else { return nil }
        position += 1
        for expected in nonce.unicodeScalars {
            guard position < scalars.count, scalars[position] == expected else { return nil }
            position += 1
        }
        guard position < scalars.count, scalars[position] == placeholderEnd else { return nil }
        return (index, position + 1)
    }

    /// Every well-formed placeholder with this nonce in `string`, in order.
    static func placeholderIndices(in string: String, nonce: String) -> [Int] {
        guard string.unicodeScalars.contains(placeholderStart) else { return [] }
        let scalars = Array(string.unicodeScalars)
        var indices: [Int] = []
        var position = 0
        while position < scalars.count {
            if let (index, end) = parsePlaceholder(scalars, at: position, nonce: nonce) {
                indices.append(index)
                position = end
            } else {
                position += 1
            }
        }
        return indices
    }

    /// The index in an info string of exactly the form `math <placeholder>`.
    ///
    /// Lower case only, because this reads back an info string the extractor wrote itself;
    /// the nonce is what actually keeps an authored fence out.
    static func blockPlaceholderIndex(info: String, nonce: String) -> Int? {
        let words = infoWords(info)
        guard words.count == 2, words[0].elementsEqual("math".utf8) else { return nil }
        let scalars = Array(String(decoding: words[1], as: UTF8.self).unicodeScalars)
        guard let (index, end) = parsePlaceholder(scalars, at: 0, nonce: nonce), end == scalars.count else { return nil }
        return index
    }

    private static func asciiDigit(_ scalar: Unicode.Scalar) -> Int? {
        ("0"..."9").contains(scalar) ? Int(scalar.value - 48) : nil
    }
}

// MARK: - Byte helpers

private enum Byte {
    static let tab: UInt8 = 0x09, newline: UInt8 = 0x0A, carriageReturn: UInt8 = 0x0D, space: UInt8 = 0x20
    static let dollar = UInt8(ascii: "$"), backslash = UInt8(ascii: "\\"), backtick = UInt8(ascii: "`")
    static let less = UInt8(ascii: "<"), greater = UInt8(ascii: ">"), bang = UInt8(ascii: "!")
    static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]"), closeParen = UInt8(ascii: ")")

    static func isSpaceOrTab(_ b: UInt8) -> Bool { b == space || b == tab }
    /// ASCII whitespace: space, tab, LF, VT, FF, CR.
    static func isWhitespace(_ b: UInt8) -> Bool { b == space || (0x09...0x0D).contains(b) }
    static func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }
    static func isASCIIPunctuation(_ b: UInt8) -> Bool {
        (0x21...0x2F).contains(b) || (0x3A...0x40).contains(b) || (0x5B...0x60).contains(b) || (0x7B...0x7E).contains(b)
    }
    /// Characters that can start a construct whose count the structural check compares.
    static let structural: Set<UInt8> = Set("`<[]!*_".utf8)
}

/// Answers "is s[a..<b] longer than the limit (in Unicode scalars)?" in amortised linear time
/// when many ranges share the same end.
private struct LengthChecker {
    private var memoEnd = -1
    private var memoStart = 0
    private var memoCount = 0

    mutating func exceedsLimit(_ s: [UInt8], _ start: Int, _ end: Int) -> Bool {
        let limit = MathExtractor.maxExpressionLength
        let bytes = end - start
        if bytes <= limit { return false }
        if bytes > limit * 4 { return true }
        let count: Int
        if memoEnd == end, memoStart <= start {
            count = memoCount - Self.scalars(s, memoStart, start)
        } else {
            count = Self.scalars(s, start, end)
        }
        memoEnd = end
        memoStart = start
        memoCount = count
        return count > limit
    }

    private static func scalars(_ s: [UInt8], _ start: Int, _ end: Int) -> Int {
        var count = 0
        for position in start..<end where s[position] & 0xC0 != 0x80 { count += 1 }
        return count
    }
}

// MARK: - Tree helpers

/// Identifies a paragraph, heading or table cell by its first source line and its
/// position among containers starting on that line. Stable across the two parses because
/// rewriting never changes line counts.
private struct ContainerKey: Hashable {
    let line: Int
    let ordinal: Int
}

private func isInlineContainer(_ node: any Markup) -> Bool {
    node is Paragraph || node is Heading || node is Table.Cell
}

/// Visits block-level nodes in document order, calling `visit` with the number of
/// enclosing block quotes. Returning false skips the node's children.
private func walkBlocks(_ document: Document, _ visit: (any Markup, Int) -> Bool) {
    var stack: [(any Markup, Int)] = [(document, 0)]
    while let (node, quoteDepth) = stack.popLast() {
        guard node is Document || visit(node, quoteDepth) else { continue }
        let childDepth = quoteDepth + (node is BlockQuote ? 1 : 0)
        for child in Array(node.children).reversed() where !(child is InlineMarkup) {
            stack.append((child, childDepth))
        }
    }
}

/// Calls `visit` for every descendant of `node` in document order. Returning false skips
/// that descendant's children.
private func walkDescendants(_ node: any Markup, _ visit: (any Markup) -> Bool) {
    var stack: [any Markup] = Array(node.children).reversed()
    while let current = stack.popLast() {
        guard visit(current), current.childCount > 0 else { continue }
        stack.append(contentsOf: Array(current.children).reversed())
    }
}

/// Links, images, code spans, inline HTML, emphasis and strong emphasis under `node`,
/// keyed by kind and content.
private func inlineSignature(_ node: any Markup) -> [String: Int] {
    var signature: [String: Int] = [:]
    walkDescendants(node) { child in
        let key: String? = switch child {
        case let link as Link: "L" + (link.destination ?? "") + "\u{0}" + (link.title ?? "")
        case let image as Image: "I" + (image.source ?? "") + "\u{0}" + (image.title ?? "")
        case let code as InlineCode: "C" + code.code
        case let html as InlineHTML: "H" + html.rawHTML
        case is Emphasis: "E"
        case is Strong: "S"
        default: nil
        }
        if let key { signature[key, default: 0] += 1 }
        return true
    }
    return signature
}

// MARK: - Engine

private struct Engine {
    struct Container {
        let key: ContainerKey
        let firstLine: Int
        let lastLine: Int
        let isDisplay: Bool
        /// Signature expected after rewriting; nil when the math enclosed something the
        /// container does not have (the container is never rewritten then).
        let expectedSignature: [String: Int]?
    }

    struct FenceRewrite {
        let openingLine: Range<Int>
        let closingLine: Range<Int>
        let fence: [UInt8]
    }

    struct Candidate {
        let container: Int
        let range: Range<Int>
        let tex: String
        let display: Bool
        let fence: FenceRewrite?
    }

    struct BlockEntry {
        let kind: ObjectIdentifier
        let firstLine: Int
        let lastLine: Int
        /// A paragraph whose parent is the document: the only shape a `$$` rewrite turns
        /// into a fence. Recorded so the original document's entries can be compared
        /// against any round's display lines without keeping the document itself.
        let isTopLevelParagraph: Bool

        /// The same entry as the rewrite would leave it: a top-level paragraph whose first
        /// line is a rewritten `$$` paragraph reads as a code block.
        func substituting(displayLines: Set<Int>) -> BlockEntry {
            guard isTopLevelParagraph, displayLines.contains(firstLine) else { return self }
            return BlockEntry(kind: ObjectIdentifier(CodeBlock.self), firstLine: firstLine,
                              lastLine: lastLine, isTopLevelParagraph: isTopLevelParagraph)
        }
    }

    static let maxRounds = 3

    let body: String
    let s: [UInt8]
    let nonce: String
    let nonceBytes: [UInt8]
    private var lineStarts: [Int] = []
    private var lineEnds: [Int] = []
    private var mask: [UInt8] = []
    private var containers: [Container] = []
    private var candidates: [Candidate] = []
    private var lengthChecker = LengthChecker()
    private var nextLinkZone = 0

    init(body: String, nonce: String) {
        self.body = body
        s = Array(body.utf8)
        self.nonce = nonce
        nonceBytes = Array(nonce.utf8)
        // Line endings as CommonMark counts them: LF, CR LF or a lone CR.
        var start = 0
        var position = 0
        while position < s.count {
            switch s[position] {
            case Byte.newline:
                lineStarts.append(start)
                lineEnds.append(position)
                position += 1
                start = position
            case Byte.carriageReturn:
                lineStarts.append(start)
                lineEnds.append(position)
                position += position + 1 < s.count && s[position + 1] == Byte.newline ? 2 : 1
                start = position
            default:
                position += 1
            }
        }
        lineStarts.append(start)
        lineEnds.append(s.count)
    }

    /// Runs both passes. `original` is the parse of `body`, made by the caller inside a
    /// `MarkdownParsing.withDocument` body; it never leaves that body, and neither does
    /// any parse made here.
    mutating func run(_ original: Document) -> (String, [MathExtractor.Expression]) {
        // Block nodes in document order. cmark-gfm sometimes reports an end past the next
        // block (a setext heading before a lone CR, for one), so each container is also
        // cut off where the next block starts.
        var blocks: [(node: any Markup, start: Int, quoteDepth: Int)] = []
        var visited = 0
        walkBlocks(original) { node, quoteDepth in
            // Past the limit, stop descending; the body is returned unchanged below.
            visited += 1
            guard visited <= MathExtractor.maxBlocks else { return false }
            if let range = node.range { blocks.append((node, offset(range.lowerBound), quoteDepth)) }
            return !isInlineContainer(node)
        }
        guard visited <= MathExtractor.maxBlocks else { return (body, []) }
        mask = [UInt8](repeating: 0, count: s.count)
        var ordinals: [Int: Int] = [:]
        for (index, block) in blocks.enumerated() where isInlineContainer(block.node) {
            guard let range = block.node.range else { continue }
            let line = range.lowerBound.line
            let ordinal = ordinals[line, default: 0]
            ordinals[line] = ordinal + 1
            guard candidates.count < MathExtractor.maxExpressionCount else { continue }
            let limit = blocks[(index + 1)...].first { $0.start > block.start }?.start ?? s.count
            collect(block.node, range: range, limit: limit,
                    key: ContainerKey(line: line, ordinal: ordinal), quoteDepth: block.quoteDepth)
        }
        mask = []
        guard !candidates.isEmpty else { return (body, []) }

        let originalBlocks = blockEntries(original)
        // Pass 1 is done, so the state the check reads never changes again. A copy of it
        // is what the nested worker bodies capture; the document itself is not captured,
        // because it is not `Sendable` and must not escape its own body.
        let checker = self
        var active = Set(containers.indices.filter { containers[$0].expectedSignature != nil })
        for _ in 0..<Self.maxRounds {
            guard !active.isEmpty else { break }
            let (markdown, expressions, order) = build(active)
            let round = active
            // Nested: already on the worker, so this parse runs inline there.
            let failed = MarkdownParsing.withDocument(markdown) { outcome -> Set<Int>? in
                guard case .document(let rewritten) = outcome else { return nil }
                return checker.check(rewritten, active: round, order: order, originalBlocks: originalBlocks)
            }
            // A rewrite the worker refuses can't be checked, so it is never used.
            guard let failed else { return (body, []) }
            if failed.isEmpty { return (markdown, expressions) }
            active.subtract(failed)
        }
        return (body, [])
    }

    // MARK: Pass 1

    private func offset(_ location: SourceLocation) -> Int {
        let line = min(max(location.line, 1), lineStarts.count) - 1
        return min(max(lineStarts[line] + location.column - 1, lineStarts[line]), lineEnds[line])
    }

    /// Where cmark-gfm's column count starts on a continuation line: after the block-quote
    /// markers and all leading whitespace.
    private func contentStart(line: Int, quoteDepth: Int) -> Int {
        var position = lineStarts[line - 1]
        let end = lineEnds[line - 1]
        var remaining = quoteDepth
        while remaining > 0 {
            while position < end, Byte.isSpaceOrTab(s[position]) { position += 1 }
            guard position < end, s[position] == Byte.greater else { break }
            position += 1
            remaining -= 1
        }
        while position < end, Byte.isSpaceOrTab(s[position]) { position += 1 }
        return position
    }

    /// 1-based line containing a byte offset.
    private func line(containing position: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= position { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    private mutating func collect(_ node: any Markup, range: SourceRange, limit: Int, key: ContainerKey, quoteDepth: Int) {
        let start = offset(range.lowerBound)
        let firstLine = range.lowerBound.line
        guard firstLine <= lineStarts.count, start < limit else { return }
        var end = max(start, offset(range.upperBound))
        var lastLine = max(firstLine, min(range.upperBound.line, lineStarts.count))
        if end > limit {
            end = limit
            lastLine = max(firstLine, line(containing: end - 1))
            end = min(end, lineEnds[lastLine - 1])
        }
        guard contains(Byte.dollar, in: start..<end) else { return }

        if node is Paragraph, node.parent is Document, lastLine > firstLine {
            if let display = displayRewrite(start: start, end: end, firstLine: firstLine, lastLine: lastLine) {
                let previousEnd = candidates.last.map { $0.fence?.closingLine.upperBound ?? $0.range.upperBound } ?? 0
                if let display, display.fence.openingLine.lowerBound >= previousEnd {
                    containers.append(Container(key: key, firstLine: firstLine, lastLine: lastLine,
                                                isDisplay: true, expectedSignature: [:]))
                    candidates.append(Candidate(container: containers.count - 1, range: display.range,
                                                tex: display.tex, display: true, fence: display.fence))
                }
                return
            }
        }

        // Positions of inline nodes. cmark-gfm reports columns on continuation lines as if
        // the line started at the container's first column, so map them back.
        let startColumn = range.lowerBound.column
        func map(_ location: SourceLocation) -> Int? {
            let line = location.line
            guard line >= firstLine, line <= lastLine else { return nil }
            let base = line == firstLine ? lineStarts[line - 1] : contentStart(line: line, quoteDepth: quoteDepth)
            let column = line == firstLine ? location.column - 1 : location.column - startColumn
            guard column >= 0, base + column <= lineEnds[line - 1] else { return nil }
            return base + column
        }
        func mapped(_ markup: any Markup) -> Range<Int>? {
            guard let range = markup.range, let lower = map(range.lowerBound), let upper = map(range.upperBound),
                  lower < upper else { return nil }
            return lower..<upper
        }
        func matches(_ range: Range<Int>, first: Set<UInt8>, last: Set<UInt8>) -> Bool {
            first.contains(s[range.lowerBound]) && last.contains(s[range.upperBound - 1])
        }

        var links: [Range<Int>] = []
        var linkTexts: [Range<Int>] = []
        var opaque: [Range<Int>] = []
        var reliable = true
        walkDescendants(node) { child in
            guard reliable else { return false }
            switch child {
            case let link as Link:
                guard let whole = mapped(link), matches(whole, first: [Byte.openBracket, Byte.less],
                                                         last: [Byte.closeParen, Byte.closeBracket, Byte.greater]) else {
                    reliable = false
                    return false
                }
                links.append(whole)
                if s[whole.lowerBound] == Byte.less { return false }  // autolink: all opaque
                let positioned = link.children.filter { $0.range != nil }
                if let first = positioned.first, let last = positioned.last {
                    guard let textStart = mapped(first)?.lowerBound, let textEnd = mapped(last)?.upperBound,
                          textStart == whole.lowerBound + 1, textEnd < whole.upperBound,
                          s[textEnd] == Byte.closeBracket else {
                        reliable = false
                        return false
                    }
                    linkTexts.append(textStart..<textEnd)
                }
                return true
            case let image as Image:
                guard let whole = mapped(image),
                      matches(whole, first: [Byte.bang], last: [Byte.closeParen, Byte.closeBracket]) else {
                    reliable = false
                    return false
                }
                opaque.append(whole)
                return false
            case let code as InlineCode:
                guard let whole = mapped(code), matches(whole, first: [Byte.backtick], last: [Byte.backtick]) else {
                    reliable = false
                    return false
                }
                opaque.append(whole)
                return false
            case let html as InlineHTML:
                guard let whole = mapped(html), matches(whole, first: [Byte.less], last: [Byte.greater]),
                      html.rawHTML.contains(where: \.isNewline)
                        || s[whole].elementsEqual(html.rawHTML.utf8) else {
                    reliable = false
                    return false
                }
                opaque.append(whole)
                return false
            default:
                return true
            }
        }
        guard reliable else { return }

        // Zones: 1 = scannable, 2 = opaque, 3... = the text of one link.
        fillMask(start..<end, 1)
        for range in links { fillMask(range, 2) }
        for range in linkTexts {
            fillMask(range, UInt8(3 + nextLinkZone % 253))
            nextLinkZone += 1
        }
        for range in opaque { fillMask(range, 2) }

        let firstCandidate = candidates.count
        let containerIndex = containers.count
        for line in firstLine...lastLine {
            let segmentStart = line == firstLine ? start : lineStarts[line - 1]
            let segmentEnd = line == lastLine ? end : lineEnds[line - 1]
            if segmentStart < segmentEnd {
                scanSegment(segmentStart..<segmentEnd, container: containerIndex)
            }
        }
        fillMask(start..<end, 0)
        guard candidates.count > firstCandidate else { return }

        // What the rewritten container should still contain: everything except what the
        // math enclosed (estimated by parsing each expression on its own). Nested: this
        // runs inline on the worker the body's parse already opened.
        var expected: [String: Int]? = inlineSignature(node)
        for candidate in candidates[firstCandidate...]
        where candidate.tex.utf8.contains(where: { Byte.structural.contains($0) }) {
            let tex = candidate.tex
            let signature = MarkdownParsing.withDocument(tex) { outcome -> [String: Int]? in
                guard case .document(let document) = outcome else { return nil }
                return inlineSignature(document)
            }
            // TeX the worker refuses leaves no way to tell what the math encloses, so the
            // container is never rewritten and its math stays as source. Defensive: the
            // TeX is a run of bytes from one line of a body the worker already accepted,
            // so its tree is a sub-tree of that body's and can't be over a budget
            // (`texIsNeverDeeperThanTheBodyItCameFrom`).
            guard let signature else { expected = nil; break }
            for (key, count) in signature {
                let remaining = (expected?[key] ?? 0) - count
                if remaining < 0 { expected = nil; break }
                expected?[key] = remaining == 0 ? nil : remaining
            }
            if expected == nil { break }
        }
        containers.append(Container(key: key, firstLine: firstLine, lastLine: lastLine,
                                    isDisplay: false, expectedSignature: expected))
    }

    /// For a multi-line top-level paragraph: nil if it is not a `$$` paragraph, `.some(nil)`
    /// if it is but cannot be extracted (too long), otherwise the rewrite.
    private mutating func displayRewrite(start: Int, end: Int, firstLine: Int, lastLine: Int)
        -> (range: Range<Int>, tex: String, fence: FenceRewrite)?? {
        var e = end
        while e > start, Byte.isWhitespace(s[e - 1]) { e -= 1 }
        guard e - start >= 4, s[start] == Byte.dollar, s[start + 1] == Byte.dollar,
              s[e - 1] == Byte.dollar, s[e - 2] == Byte.dollar else { return nil }
        let texRange = (start + 2)..<(e - 2)
        // Exactly one display expression: no other unescaped `$$` inside, closer unescaped.
        var backslashes = 0
        for position in texRange {
            let byte = s[position]
            if byte == Byte.dollar, backslashes % 2 == 0, s[position + 1] == Byte.dollar { return nil }
            backslashes = byte == Byte.backslash ? backslashes + 1 : 0
        }
        guard backslashes % 2 == 0 else { return nil }  // the closing `$$` is escaped
        if lengthChecker.exceedsLimit(s, texRange.lowerBound, texRange.upperBound) { return .some(nil) }

        var longestRun = 0, run = 0
        for position in lineStarts[firstLine - 1]..<lineEnds[lastLine - 1] {
            run = s[position] == Byte.backtick ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = FenceRewrite(
            openingLine: lineStarts[firstLine - 1]..<lineEnds[firstLine - 1],
            closingLine: lineStarts[lastLine - 1]..<lineEnds[lastLine - 1],
            fence: [UInt8](repeating: Byte.backtick, count: max(3, longestRun + 1))
        )
        return (texRange, String(decoding: s[texRange], as: UTF8.self), fence)
    }

    private mutating func fillMask(_ range: Range<Int>, _ value: UInt8) {
        guard !range.isEmpty else { return }
        mask.withUnsafeMutableBufferPointer { buffer in
            UnsafeMutableBufferPointer(rebasing: buffer[range]).update(repeating: value)
        }
    }

    private func contains(_ byte: UInt8, in range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        return s.withUnsafeBufferPointer { buffer in
            memchr(buffer.baseAddress! + range.lowerBound, Int32(byte), range.count) != nil
        }
    }

    /// Closer candidates of one kind, per zone, with forward-only cursors.
    private struct Closers {
        private var top: [Int] = []  // zone 1, the common case
        private var topCursor = 0
        private var links: [UInt8: [Int]] = [:]
        private var linkCursors: [UInt8: Int] = [:]

        var isEmpty: Bool { top.isEmpty && links.isEmpty }

        mutating func append(_ position: Int, zone: UInt8) {
            if zone == 1 { top.append(position) } else { links[zone, default: []].append(position) }
        }

        mutating func next(zone: UInt8, from start: Int) -> Int? {
            if zone == 1 {
                while topCursor < top.count, top[topCursor] < start { topCursor += 1 }
                return topCursor < top.count ? top[topCursor] : nil
            }
            guard let list = links[zone] else { return nil }
            var cursor = linkCursors[zone, default: 0]
            while cursor < list.count, list[cursor] < start { cursor += 1 }
            linkCursors[zone] = cursor
            return cursor < list.count ? list[cursor] : nil
        }
    }

    /// Finds `$…$` and `$$…$$` within one source line, left to right.
    private mutating func scanSegment(_ segment: Range<Int>, container: Int) {
        guard contains(Byte.dollar, in: segment) else { return }
        // Closer candidates: unescaped, and for `$` not after whitespace nor before a digit.
        var singles = Closers()
        var doubles = Closers()
        var backslashes = 0
        for position in segment {
            let byte = s[position]
            if byte == Byte.dollar, backslashes % 2 == 0 {
                let zone = mask[position]
                if zone == 1 || zone >= 3 {
                    if position + 1 < segment.upperBound, s[position + 1] == Byte.dollar, mask[position + 1] == zone {
                        doubles.append(position, zone: zone)
                    }
                    if position > segment.lowerBound, !Byte.isWhitespace(s[position - 1]),
                       !(position + 1 < segment.upperBound && Byte.isDigit(s[position + 1])) {
                        singles.append(position, zone: zone)
                    }
                }
            }
            backslashes = byte == Byte.backslash ? backslashes + 1 : 0
        }
        guard !singles.isEmpty || !doubles.isEmpty else { return }

        let end = segment.upperBound
        var i = segment.lowerBound
        while i < end {
            guard candidates.count < MathExtractor.maxExpressionCount else { return }
            let zone = mask[i]
            guard zone == 1 || zone >= 3 else { i += 1; continue }
            switch s[i] {
            case Byte.backslash:
                i += i + 1 < end && Byte.isASCIIPunctuation(s[i + 1]) && mask[i + 1] == zone ? 2 : 1
            case Byte.dollar:
                var runEnd = i
                while runEnd < end, s[runEnd] == Byte.dollar, mask[runEnd] == zone { runEnd += 1 }
                let run = runEnd - i
                if run == 2, let close = doubles.next(zone: zone, from: i + 2),
                   s[(i + 2)..<close].contains(where: { !Byte.isWhitespace($0) }),
                   !lengthChecker.exceedsLimit(s, i + 2, close) {
                    add(i..<(close + 2), tex: (i + 2)..<close, display: true, container: container)
                    i = close + 2
                } else if run == 1, i + 1 < end, !Byte.isWhitespace(s[i + 1]),
                          let close = singles.next(zone: zone, from: i + 2),
                          !lengthChecker.exceedsLimit(s, i + 1, close) {
                    add(i..<(close + 1), tex: (i + 1)..<close, display: false, container: container)
                    i = close + 1
                } else {
                    i = runEnd  // `$$` without a closer, or a longer run, stays literal as a whole
                }
            default:
                i += 1
            }
        }
    }

    private mutating func add(_ range: Range<Int>, tex: Range<Int>, display: Bool, container: Int) {
        // Never overlap an earlier expression, whatever positions the parser reported.
        if let previous = candidates.last, range.lowerBound < (previous.fence?.closingLine.upperBound ?? previous.range.upperBound) {
            return
        }
        candidates.append(Candidate(container: container, range: range,
                                    tex: String(decoding: s[tex], as: UTF8.self), display: display, fence: nil))
    }

    // MARK: Rewriting

    /// Rewrites the active containers. Returns the markdown, the expressions and, for each
    /// expression index, the candidate it came from.
    private func build(_ active: Set<Int>) -> (String, [MathExtractor.Expression], [Int]) {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var expressions: [MathExtractor.Expression] = []
        var order: [Int] = []
        var position = 0
        func replace(_ range: Range<Int>, with bytes: [UInt8]) {
            out += s[position..<range.lowerBound]
            out += bytes
            position = range.upperBound
        }
        for (index, candidate) in candidates.enumerated() where active.contains(candidate.container) {
            let placeholder = MathExtractor.placeholder(index: expressions.count, nonce: nonceBytes)
            expressions.append(.init(tex: candidate.tex, display: candidate.display, isBlock: candidate.fence != nil))
            order.append(index)
            if let fence = candidate.fence {
                replace(fence.openingLine, with: fence.fence + Array("math ".utf8) + placeholder)
                replace(fence.closingLine, with: fence.fence)
            } else {
                replace(candidate.range, with: placeholder)
            }
        }
        out += s[position...]
        return (String(decoding: out, as: UTF8.self), expressions, order)
    }

    // MARK: Pass 2

    /// The document's block structure as plain values. Which top-level paragraphs a round
    /// turns into fences is recorded per entry rather than applied here, so the original
    /// document's entries are taken once and then compared against any round's display
    /// lines with `BlockEntry.substituting(displayLines:)`, without keeping the document.
    private func blockEntries(_ document: Document) -> [BlockEntry] {
        var entries: [BlockEntry] = []
        walkBlocks(document) { node, _ in
            let first = node.range?.lowerBound.line ?? 0
            entries.append(BlockEntry(kind: ObjectIdentifier(type(of: node)), firstLine: first,
                                      lastLine: node.range?.upperBound.line ?? first,
                                      isTopLevelParagraph: node is Paragraph && node.parent is Document))
            return true
        }
        return entries
    }

    /// Returns the active containers that failed the structural check.
    private func check(_ document: Document, active: Set<Int>, order: [Int],
                       originalBlocks: [BlockEntry]) -> Set<Int> {
        var failed = Set<Int>()
        var found = [Int](repeating: 0, count: order.count)
        func container(of index: Int) -> Int? {
            index < order.count ? candidates[order[index]].container : nil
        }
        func reject(_ indices: [Int]) {
            for index in indices { if let owner = container(of: index) { failed.insert(owner) } }
        }

        // Where the rewritten containers ended up.
        var keyToContainer: [ContainerKey: Int] = [:]
        for index in active where !containers[index].isDisplay { keyToContainer[containers[index].key] = index }
        var seen = Set<Int>()
        var ordinals: [Int: Int] = [:]
        walkBlocks(document) { node, _ in
            if let code = node as? CodeBlock {
                reject(MathExtractor.placeholderIndices(in: code.code, nonce: nonce))
                let info = code.language ?? ""
                var infoIndices = MathExtractor.placeholderIndices(in: info, nonce: nonce)
                if let index = MathExtractor.blockPlaceholderIndex(info: info, nonce: nonce),
                   let owner = container(of: index), containers[owner].isDisplay, code.parent is Document,
                   code.range?.lowerBound.line == containers[owner].firstLine {
                    found[index] += 1
                    infoIndices.removeAll { $0 == index }
                }
                reject(infoIndices)
                return false
            }
            if let html = node as? HTMLBlock {
                reject(MathExtractor.placeholderIndices(in: html.rawHTML, nonce: nonce))
                return false
            }
            guard isInlineContainer(node) else { return true }
            // cmark-gfm gives some containers no range (a paragraph split off before a
            // table, for one). They own nothing, so any placeholder in them is rejected.
            var owner: Int?
            if let range = node.range {
                let line = range.lowerBound.line
                let key = ContainerKey(line: line, ordinal: ordinals[line, default: 0])
                ordinals[line] = key.ordinal + 1
                owner = keyToContainer[key]
            }
            if let owner {
                seen.insert(owner)
                if inlineSignature(node) != containers[owner].expectedSignature { failed.insert(owner) }
            }
            // Placeholders count only in plain text of their own container, outside images.
            walkDescendants(node) { child in
                switch child {
                case let text as Text:
                    for index in MathExtractor.placeholderIndices(in: text.string, nonce: nonce) {
                        guard let expected = container(of: index) else { continue }
                        // A display placeholder in text is never expanded; its fence is checked above.
                        if containers[expected].isDisplay { continue }
                        if expected == owner { found[index] += 1 } else { reject([index]) }
                    }
                    return false
                case let link as Link:
                    reject(MathExtractor.placeholderIndices(in: (link.destination ?? "") + (link.title ?? ""), nonce: nonce))
                    return true
                case let image as Image:
                    let strings = [image.source ?? "", image.title ?? "", image.plainText]
                    reject(strings.flatMap { MathExtractor.placeholderIndices(in: $0, nonce: nonce) })
                    return false
                case let code as InlineCode:
                    reject(MathExtractor.placeholderIndices(in: code.code, nonce: nonce))
                    return false
                case let html as InlineHTML:
                    reject(MathExtractor.placeholderIndices(in: html.rawHTML, nonce: nonce))
                    return false
                default:
                    return true
                }
            }
            return false
        }
        for index in active where !containers[index].isDisplay && !seen.contains(index) { failed.insert(index) }
        for (index, count) in found.enumerated() where count != 1 { reject([index]) }

        // Block structure must be unchanged, except rewritten `$$` paragraphs. A structural
        // change also disturbs the containers after it, so only the blamed containers are
        // reverted this round; the next round checks the rest again.
        let displayLines = Set(active.filter { containers[$0].isDisplay }.map { containers[$0].firstLine })
        let before = displayLines.isEmpty ? originalBlocks : originalBlocks.map { $0.substituting(displayLines: displayLines) }
        let after = blockEntries(document)
        let differs = before.indices.first { index in
            index >= after.count || before[index].kind != after[index].kind
                || before[index].firstLine != after[index].firstLine
        }
        if let mismatch = differs ?? (before.count < after.count ? before.count : nil) {
            // Blame the containers within the original block first, then the new one, then all.
            func touching(_ entry: BlockEntry?) -> Set<Int> {
                guard let entry else { return [] }
                return active.filter { containers[$0].firstLine <= entry.lastLine && containers[$0].lastLine >= entry.firstLine }
            }
            var touched = touching(mismatch < before.count ? before[mismatch] : nil)
            if touched.isEmpty { touched = touching(mismatch < after.count ? after[mismatch] : nil) }
            return touched.isEmpty ? active : touched
        }
        return failed
    }
}
