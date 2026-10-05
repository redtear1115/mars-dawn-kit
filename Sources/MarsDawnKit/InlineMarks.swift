import Foundation
import Markdown

// HackMD's inline marks (#133): `==mark==`, `^sup^` and `~sub~`.
//
// cmark-gfm's strikethrough takes one tilde as well as two, and swift-markdown has no way to
// pass it `CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE` (its `ParseOptions` stop at block directives,
// symbol links, smart punctuation and source positions). So `~sub~` arrives as a `Strikethrough`
// node, and what tells it from `~~del~~` is the source: `SourceBytes.isSingleTilde`.
// cmark's own flanking rules already refuse `a ~ b ~ c` and a delimiter with space just inside.
//
// `==` and `^` are plain text to cmark, so they are found in `Text` nodes, which swift-markdown
// has already merged and unescaped (`\=` and `&amp;` are inside the same node as the text next to
// them). The escape is only visible in the source, so each text's delimiters are located there:
// the k-th `=` or `^` of the decoded string is the k-th of its source slice, escaped when a
// backslash stands before it. Code spans, code blocks, raw HTML, link destinations and math are
// never `Text` (math is a placeholder with no delimiter in it), so none of them is touched.
// A text whose source can't be read or whose delimiters don't line up is left as it is.
//
// Matching works on the children of one inline container, so a mark can enclose emphasis or
// links (`==a **b** c==`) but never reaches out of the container it began in, and the tags it
// writes always nest.

/// A document's source as bytes, to read what a node's range covers.
struct SourceBytes: Sendable {
    private let bytes: [UInt8]
    /// Byte offset of each line's first byte. cmark ends a line at LF, CR LF or a lone CR.
    private let lineStarts: [Int]

    init(_ source: String) {
        bytes = Array(source.utf8)
        var starts = [0]
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                starts.append(index + 1)
            } else if bytes[index] == 0x0D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
                starts.append(index + 1)
            }
            index += 1
        }
        lineStarts = starts
    }

    private func offset(of location: SourceLocation) -> Int? {
        guard location.line >= 1, location.line <= lineStarts.count, location.column >= 1 else { return nil }
        let offset = lineStarts[location.line - 1] + location.column - 1
        return offset <= bytes.count ? offset : nil
    }

    /// Whether the node's source starts with `<`, as an autolink's does.
    func startsWithAngleBracket(_ node: any Markup) -> Bool {
        guard let start = node.range?.lowerBound, let offset = offset(of: start), offset < bytes.count else { return false }
        return bytes[offset] == UInt8(ascii: "<")
    }

    /// The bytes a one-line range covers (its end column is exclusive), or nil.
    func slice(_ range: SourceRange?) -> ArraySlice<UInt8>? {
        guard let range, range.lowerBound.line == range.upperBound.line,
              let start = offset(of: range.lowerBound), let end = offset(of: range.upperBound), start <= end
        else { return nil }
        return bytes[start..<end]
    }

    /// Whether a strikethrough was written with one tilde (`~sub~`), judged from its source.
    ///
    /// cmark-gfm gives the first line of a paragraph the line number the paragraph began on, even
    /// when link reference definitions took its first lines, so a node's range can point at the
    /// wrong line. A single tilde is only believed when the source has one at both ends of the
    /// range; anything else, a misplaced range included, is a `~~del~~` as before.
    ///
    /// A subscript has no whitespace inside (#133, as markdown-it-sub has it), so `~a b~` and
    /// `This ~is struck~ text` stay the single-tilde strikethrough GFM gives them.
    func isSingleTilde(_ node: any Markup) -> Bool {
        guard let range = node.range, let start = offset(of: range.lowerBound), let end = offset(of: range.upperBound),
              start + 1 < end, end <= bytes.count
        else { return false }
        let tilde = UInt8(ascii: "~")
        guard bytes[start] == tilde && bytes[start + 1] != tilde && bytes[end - 1] == tilde && bytes[end - 2] != tilde
        else { return false }
        let inner = String(decoding: bytes[(start + 1)..<(end - 1)], as: UTF8.self)
        // The bytes between the tildes must say what the node shows. After a hard break cmark
        // reports later inlines on the paragraph's first line, so the range can land on other
        // text that happens to sit between single tildes; then it is a `~~del~~` as before.
        // Markup or escapes inside (`~*a*~`, `~\~a~`) fail this too and stay `<del>`.
        let shown = node.children.map { ($0 as? any PlainTextConvertibleMarkup)?.plainText ?? "\u{FFFC}" }.joined()
        guard Self.smartPunctuationSpelledOut(inner) == Self.smartPunctuationSpelledOut(shown) else { return false }
        return !inner.unicodeScalars.contains { $0.properties.isWhitespace }
    }

    /// `string` with the renderer's smart punctuation spelled the ASCII way it was written.
    private static func smartPunctuationSpelledOut(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\u{201C}", "\u{201D}": result += "\""
            case "\u{2018}", "\u{2019}": result += "'"
            case "\u{2013}": result += "--"
            case "\u{2014}": result += "---"
            case "\u{2026}": result += "..."
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// Where `==` and `^` open and close a mark among the children of one inline container.
enum InlineMarks {
    enum Kind { case mark, sup }

    /// What a child's text becomes: ordinary characters, with the delimiters that pair up.
    enum Piece {
        /// Text of child `child`, to be escaped and rendered as that child's text would be.
        case text(String, child: Int)
        case open(Kind)
        case close(Kind)
        /// A child that is not text, rendered as it would be on its own.
        case node(child: Int)
    }

    /// Cheap test for whether any text can hold a delimiter, so a container without one is
    /// rendered exactly as it was before.
    static func mayHaveDelimiter(_ text: String) -> Bool {
        var previousEquals = false
        for byte in text.utf8 {
            if byte == UInt8(ascii: "^") { return true }
            if byte == UInt8(ascii: "=") {
                if previousEquals { return true }
                previousEquals = true
            } else {
                previousEquals = false
            }
        }
        return false
    }

    private enum Atom {
        case scalar(Unicode.Scalar, child: Int)
        /// A whole `==` or `^`.
        case delimiter(Kind, child: Int, canOpen: Bool, canClose: Bool)
        case node(child: Int)
        /// A soft or hard break: whitespace to the delimiter rules.
        case space(child: Int)
    }

    /// The pieces of `children`, or nil if none of them holds a delimiter that pairs up.
    /// `scanText` is false inside an autolink, whose text is the URL.
    static func pieces(of children: [any Markup], source: SourceBytes, scanText: Bool = true) -> [Piece]? {
        guard scanText, children.contains(where: { ($0 as? Text).map { mayHaveDelimiter($0.string) } ?? false }) else { return nil }
        var atoms: [Atom] = []
        for (index, child) in children.enumerated() {
            switch child {
            case let text as Text:
                append(text, child: index, source: source, to: &atoms)
            case is SoftBreak, is LineBreak:
                atoms.append(.space(child: index))
            default:
                atoms.append(.node(child: index))
            }
        }
        classify(&atoms)
        let matches = match(atoms)
        guard !matches.isEmpty else { return nil }
        return output(atoms, matches: matches)
    }

    /// Splits one text into scalars and delimiter runs.
    private static func append(_ text: Text, child: Int, source: SourceBytes, to atoms: inout [Atom]) {
        let scalars = Array(text.string.unicodeScalars)
        let escaped = escapedDelimiters(in: scalars, source: source.slice(text.range))
        var index = 0
        var delimiterNumber = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let isDelimiterCharacter = scalar == "=" || scalar == "^"
            guard isDelimiterCharacter, let escaped else {
                atoms.append(.scalar(scalar, child: child))
                index += 1
                continue
            }
            if escaped[delimiterNumber] {
                atoms.append(.scalar(scalar, child: child))
                index += 1
                delimiterNumber += 1
                continue
            }
            var end = index
            var endNumber = delimiterNumber
            while end < scalars.count, scalars[end] == scalar, !escaped[endNumber] {
                end += 1
                endNumber += 1
            }
            let length = end - index
            // `==` exactly, and a single `^` not opening a footnote reference (`[^1]`).
            let isDelimiter = scalar == "=" ? length == 2 : (length == 1 && !(index > 0 && scalars[index - 1] == "["))
            if isDelimiter {
                atoms.append(.delimiter(scalar == "=" ? .mark : .sup, child: child, canOpen: false, canClose: false))
            } else {
                for position in index..<end { atoms.append(.scalar(scalars[position], child: child)) }
            }
            index = end
            delimiterNumber = endNumber
        }
    }

    /// For each `=` or `^` of the decoded text in order, whether the source escapes it with a
    /// backslash; nil when the source is unknown or has a different number of them (an entity
    /// such as `&equals;` made one), so the text is left alone.
    private static func escapedDelimiters(in scalars: [Unicode.Scalar], source: ArraySlice<UInt8>?) -> [Bool]? {
        guard let source, plausible(source, for: scalars) else { return nil }
        var escaped: [Bool] = []
        var index = source.startIndex
        while index < source.endIndex {
            let byte = source[index]
            if byte == UInt8(ascii: "\\"), index + 1 < source.endIndex, isASCIIPunctuation(source[index + 1]) {
                let next = source[index + 1]
                if next == UInt8(ascii: "=") || next == UInt8(ascii: "^") { escaped.append(true) }
                index += 2
                continue
            }
            if byte == UInt8(ascii: "=") || byte == UInt8(ascii: "^") { escaped.append(false) }
            index += 1
        }
        let count = scalars.reduce(0) { $0 + ($1 == "=" || $1 == "^" ? 1 : 0) }
        return escaped.count == count ? escaped : nil
    }

    /// Whether `source` can be where `scalars` came from: its ASCII letters and digits hold the
    /// string's, in order. Catches a range that points at the wrong line (see `isSingleTilde`);
    /// the source has more of them where an entity was written (`&amp;`), never fewer.
    private static func plausible(_ source: ArraySlice<UInt8>, for scalars: [Unicode.Scalar]) -> Bool {
        var index = source.startIndex
        for scalar in scalars where scalar.isASCII && scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
            let byte = UInt8(ascii: scalar)
            while index < source.endIndex, source[index] != byte { index += 1 }
            guard index < source.endIndex else { return false }
            index += 1
        }
        return true
    }

    private static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte) || (0x5B...0x60).contains(byte) || (0x7B...0x7E).contains(byte)
    }

    /// Sets each delimiter's `canOpen` (something that isn't whitespace follows) and `canClose`
    /// (something that isn't whitespace precedes), as for emphasis. A container's edges and a
    /// break are whitespace; any other child counts as a character.
    private static func classify(_ atoms: inout [Atom]) {
        func isSpace(_ atom: Atom?) -> Bool {
            switch atom {
            case nil, .space: true
            case .scalar(let scalar, _): scalar.properties.isWhitespace
            case .delimiter, .node: false
            }
        }
        for index in atoms.indices {
            guard case .delimiter(let kind, let child, _, _) = atoms[index] else { continue }
            let before = index > 0 ? atoms[index - 1] : nil
            let after = index + 1 < atoms.count ? atoms[index + 1] : nil
            atoms[index] = .delimiter(kind, child: child, canOpen: !isSpace(after), canClose: !isSpace(before))
        }
    }

    /// Opening atom index to closing atom index, for the pairs that close.
    private static func match(_ atoms: [Atom]) -> [Int: Int] {
        var matches: [Int: Int] = [:]
        var open: [(kind: Kind, index: Int)] = []
        for (index, atom) in atoms.enumerated() {
            switch atom {
            case .space:
                // `^sup^` can't hold whitespace, so a `^` open before it never closes.
                open.removeAll { $0.kind == .sup }
            case .scalar(let scalar, _) where scalar.properties.isWhitespace:
                open.removeAll { $0.kind == .sup }
            case .delimiter(let kind, _, let canOpen, let canClose):
                if canClose, let position = open.lastIndex(where: { $0.kind == kind }) {
                    matches[open[position].index] = index
                    // Anything opened inside the pair has no partner left.
                    open.removeSubrange(position...)
                } else if canOpen {
                    open.append((kind, index))
                }
            default:
                break
            }
        }
        return matches
    }

    private static func output(_ atoms: [Atom], matches: [Int: Int]) -> [Piece] {
        let closers = Set(matches.values)
        var pieces: [Piece] = []
        // Scalars collect in an array and become a String once per run: appending scalar by
        // scalar to a String.UnicodeScalarView took quadratic time on a long text.
        var run: [Unicode.Scalar] = []
        var runChild = -1
        func flush() {
            if !run.isEmpty {
                var text = String.UnicodeScalarView()
                text.append(contentsOf: run)
                pieces.append(.text(String(text), child: runChild))
            }
            run.removeAll(keepingCapacity: true)
        }
        func add(_ scalars: [Unicode.Scalar], child: Int) {
            if child != runChild { flush(); runChild = child }
            run.append(contentsOf: scalars)
        }
        for (index, atom) in atoms.enumerated() {
            switch atom {
            case .scalar(let scalar, let child):
                add([scalar], child: child)
            case .delimiter(let kind, let child, _, _):
                if matches[index] != nil {
                    flush()
                    pieces.append(.open(kind))
                } else if closers.contains(index) {
                    flush()
                    pieces.append(.close(kind))
                } else {
                    add(Array(repeating: kind == .mark ? "=" : "^", count: kind == .mark ? 2 : 1), child: child)
                }
            case .node(let child), .space(let child):
                flush()
                runChild = -1
                pieces.append(.node(child: child))
            }
        }
        flush()
        return pieces
    }
}
