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
// has already merged and unescaped (`\=` and `&#61;` are inside the same node as the text next
// to them). Which of a text's `=` and `^` were escaped is read from a second parse in which
// they are stand-ins (`EscapeMap`), not from source positions, which cmark gets wrong after a
// hard break and inside containers. Code spans, code blocks, raw HTML, link destinations and
// math are never `Text` (math is a placeholder with no delimiter in it), so none of them is
// touched. A text whose escapes can't be read is left as it is.
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
    static func smartPunctuationSpelledOut(_ string: String) -> String {
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

/// Which `=` and `^` of each text the author escaped (`\=`, `\^`) or wrote as an entity
/// (`&#61;`, `&Hat;`), so they never act as delimiters.
///
/// A text's string comes unescaped, and source positions can't say where it came from (cmark
/// reports the inlines after a hard break on the paragraph's first line, with the container
/// prefixes it stripped not counted), so the document is parsed a second time with every
/// escaped or entity `=` and `^` swapped for a private-use stand-in. Neither character is
/// CommonMark syntax, so the second tree has the first one's shape, and each text's escapes are
/// read from the text at the same path in it. Only a document that has such an escape is
/// parsed twice.
struct EscapeMap: Sendable {
    /// Punctuation, as `=` and `^` are, so emphasis flanking next to a stand-in reads as it does
    /// next to the character it replaces (a private-use character is not punctuation, and `a*\=b*`
    /// would open emphasis in the second tree only). Rare enough that a document's own use of
    /// one only costs that text its marks: the counts below then disagree.
    static let escapedEquals: Unicode.Scalar = "\u{2E40}"
    static let escapedCaret: Unicode.Scalar = "\u{2E41}"

    /// False when the document has no escaped or entity `=` or `^`: every one is a delimiter.
    private let hasEscapes: Bool
    /// The escape flags of each text that has a `=`, `^` or stand-in, by path; nil if the second
    /// parse was refused, and then no text with a delimiter is read.
    private let flagsByPath: [[Int]: [Bool]]?

    static let none = EscapeMap(hasEscapes: false, flagsByPath: [:])

    private init(hasEscapes: Bool, flagsByPath: [[Int]: [Bool]]?) {
        self.hasEscapes = hasEscapes
        self.flagsByPath = flagsByPath
    }

    /// For `document`, parsed from `source`. Parses again on the current worker when `source`
    /// holds an escape; call it from inside a `MarkdownParsing.withDocument` body.
    ///
    /// The second tree is only trusted when it is the first one node for node: same types, same
    /// child counts, same text once the stand-ins read as `=` and `^` again. Swapping a character
    /// can change how cmark reads its surroundings (`<a b=\=>` is not a tag but `<a b=⹀>` is;
    /// `[a&#61;b]` and `[a\=b]` become one label), and then no text's escapes can be read from
    /// it: every text with a delimiter gets no marks rather than another text's escapes.
    init(source: String, document: Document, limits: ParseLimits) {
        guard let standIns = Self.standIns(source) else {
            self = .none
            return
        }
        hasEscapes = true
        let expected = Self.signature(of: document, restoringStandIns: false)
        // The stand-ins can make the text longer, never the tree bigger: lift only the byte cap.
        let relaxed = ParseLimits(maxDepth: limits.maxDepth, maxBytes: nil, maxNodes: limits.maxNodes)
        flagsByPath = MarkdownParsing.withDocument(standIns, options: relaxed) { outcome -> [[Int]: [Bool]]? in
            guard case .document(let second) = outcome,
                  Self.signature(of: second, restoringStandIns: true) == expected
            else { return nil }
            var flags: [[Int]: [Bool]] = [:]
            var stack: [(node: any Markup, path: [Int])] = [(second, [])]
            while let (node, path) = stack.popLast() {
                if let text = node as? Text {
                    var textFlags: [Bool] = []
                    for scalar in text.string.unicodeScalars {
                        if scalar == "=" || scalar == "^" {
                            textFlags.append(false)
                        } else if scalar == EscapeMap.escapedEquals || scalar == EscapeMap.escapedCaret {
                            textFlags.append(true)
                        }
                    }
                    if !textFlags.isEmpty { flags[path] = textFlags }
                    continue
                }
                for (index, child) in node.children.enumerated() { stack.append((child, path + [index])) }
            }
            return flags
        }
    }

    /// Every node in depth-first order: its type and child count, and a text's string (the
    /// stand-ins read back as `=` and `^` when `restoringStandIns`).
    private static func signature(of document: Document, restoringStandIns: Bool) -> [String] {
        var result: [String] = []
        var stack: [any Markup] = [document]
        while let node = stack.popLast() {
            var entry = "\(type(of: node))/\(node.childCount)"
            if let text = node as? Text {
                var string = String.UnicodeScalarView()
                for scalar in text.string.unicodeScalars {
                    switch scalar {
                    case escapedEquals where restoringStandIns: string.append("=")
                    case escapedCaret where restoringStandIns: string.append("^")
                    default: string.append(scalar)
                    }
                }
                entry += "|" + String(string)
            }
            result.append(entry)
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }

    /// For each `=` or `^` of `text` in order, whether it was escaped; nil when that can't be
    /// read, and then the text has no delimiters.
    func flags(for text: Text, delimiterCount: Int) -> [Bool]? {
        guard hasEscapes else { return Array(repeating: false, count: delimiterCount) }
        guard let flagsByPath else { return nil }
        // Every text with a delimiter was recorded; a missing one, or a count that differs, means
        // the trees didn't line up there, and the text is left without marks.
        guard let flags = flagsByPath[Self.path(of: text)], flags.count == delimiterCount else { return nil }
        return flags
    }

    private static func path(of node: any Markup) -> [Int] {
        var path: [Int] = []
        var current: any Markup = node
        while let parent = current.parent {
            path.append(current.indexInParent)
            current = parent
        }
        return path.reversed()
    }

    /// `source` with each escaped or entity `=` and `^` swapped for its stand-in, or nil if it
    /// has none. A backslash escape is a backslash before ASCII punctuation, as cmark reads it.
    static func standIns(_ source: String) -> String? {
        let bytes = Array(source.utf8)
        guard bytes.contains(UInt8(ascii: "\\")) || bytes.contains(UInt8(ascii: "&")) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 16)
        var changed = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count, isASCIIPunctuation(bytes[index + 1]) {
                let next = bytes[index + 1]
                if next == UInt8(ascii: "=") || next == UInt8(ascii: "^") {
                    out.append(contentsOf: String(next == UInt8(ascii: "=") ? escapedEquals : escapedCaret).utf8)
                    changed = true
                } else {
                    out.append(byte)
                    out.append(next)
                }
                index += 2
                continue
            }
            if byte == UInt8(ascii: "&"), let (decoded, length) = VisibleHTMLText.entity(bytes, at: index),
               decoded == [UInt8(ascii: "=")] || decoded == [UInt8(ascii: "^")] {
                out.append(contentsOf: String(decoded == [UInt8(ascii: "=")] ? escapedEquals : escapedCaret).utf8)
                changed = true
                index += length
                continue
            }
            out.append(byte)
            index += 1
        }
        return changed ? String(decoding: out, as: UTF8.self) : nil
    }

    private static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte) || (0x5B...0x60).contains(byte) || (0x7B...0x7E).contains(byte)
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
    static func pieces(of children: [any Markup], escapes: EscapeMap, scanText: Bool = true) -> [Piece]? {
        guard scanText, children.contains(where: { ($0 as? Text).map { mayHaveDelimiter($0.string) } ?? false }) else { return nil }
        var atoms: [Atom] = []
        for (index, child) in children.enumerated() {
            switch child {
            case let text as Text:
                append(text, child: index, escapes: escapes, to: &atoms)
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
    private static func append(_ text: Text, child: Int, escapes: EscapeMap, to atoms: inout [Atom]) {
        let scalars = Array(text.string.unicodeScalars)
        let escaped = escapes.flags(for: text, delimiterCount: scalars.reduce(0) { $0 + ($1 == "=" || $1 == "^" ? 1 : 0) })
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
        // One stack of open delimiters per kind, by atom index. Closing a pair drops whatever of
        // the other kind opened inside it, which sits on top of that stack; whitespace drops
        // every open `^`. Each delimiter is pushed and dropped once, so this is linear (#155
        // review: one shared stack swept on every space was quadratic).
        var openMarks: [Int] = []
        var openSups: [Int] = []
        for (index, atom) in atoms.enumerated() {
            switch atom {
            case .space:
                // `^sup^` can't hold whitespace, so a `^` open before it never closes.
                openSups.removeAll(keepingCapacity: true)
            case .scalar(let scalar, _) where scalar.properties.isWhitespace:
                openSups.removeAll(keepingCapacity: true)
            case .delimiter(let kind, _, let canOpen, let canClose):
                if canClose, let opener = (kind == .mark ? openMarks : openSups).last {
                    matches[opener] = index
                    if kind == .mark {
                        openMarks.removeLast()
                        while let last = openSups.last, last > opener { openSups.removeLast() }
                    } else {
                        openSups.removeLast()
                        while let last = openMarks.last, last > opener { openMarks.removeLast() }
                    }
                } else if canOpen {
                    if kind == .mark { openMarks.append(index) } else { openSups.append(index) }
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
