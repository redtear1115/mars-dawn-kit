import Foundation

/// A metadata block at the very top of a Markdown document, delimited by `---` lines
/// (YAML front matter as used by Jekyll, Hugo, Pandoc and others).
///
/// Detection is deliberately narrow:
/// - Line 1 must be exactly `---`: no leading or trailing spaces, nothing else on the line.
///   A single leading byte order mark (U+FEFF) is skipped: it is how some editors start a
///   UTF-8 file, not part of the delimiter. It stays in the text and in line 1; the block's
///   `range` starts after it.
/// - The block closes at the next line that is exactly `---` or `...`.
/// - If no such line follows, the document has no front matter at all.
/// - Lines end with LF, CRLF or a lone CR, as in CommonMark, so line numbers agree with the
///   Markdown parser's.
///
/// The block is not parsed as YAML and nothing in it is evaluated. `pairs` only recognises
/// flat `key: value` lines, and every value is kept as written.
public struct FrontMatter: Sendable {
    /// Source lines covered by the block, 1-based and inclusive, both delimiters included.
    /// Always starts at 1.
    public let lineRange: ClosedRange<Int>
    /// The block's range in the string passed to `split`, from the start of the opening
    /// delimiter to the end of the closing delimiter's line ending (the start of the body).
    /// Valid only for that string.
    public let range: Range<String.Index>
    /// The text between the two delimiter lines, exactly as written, including each inner
    /// line's line ending. Empty when the delimiters are adjacent.
    public let rawText: String
    /// The lines between the delimiters, without their line endings.
    public let lines: [String]

    private let parsedPairs: [Pair]?

    private struct Pair: Sendable {
        let key: String
        let value: String
    }

    /// The block as `key: value` pairs, in source order, or `nil` when the block isn't that
    /// simple. Non-nil only when the block has at least one non-blank line and every
    /// non-blank line is a `key: value` line (see `keyValue(in:)` for the exact rule).
    /// Blank lines are skipped. Duplicate keys are kept.
    public var pairs: [(key: String, value: String)]? {
        parsedPairs?.map { ($0.key, $0.value) }
    }

    /// Splits `text` into its front matter, if any, and the Markdown body after it.
    ///
    /// - Returns: the front matter (or `nil`), the body (a slice of `text`; all of `text`
    ///   when there is no front matter), and `bodyLineOffset`, the number of source lines
    ///   before the body. A body line `n` (1-based) is file line `n + bodyLineOffset`.
    ///
    /// Runs in time linear in the length of `text`. It works on UTF-8 bytes and Unicode
    /// scalars, never on `Character`s: comparing or classifying a grapheme normalises it,
    /// which is quadratic in its length, and one grapheme can hold a whole line of combining
    /// marks. Every index it returns sits at a line boundary, which is also a `Character`
    /// boundary.
    public static func split(_ text: String) -> (frontMatter: FrontMatter?, body: Substring, bodyLineOffset: Int) {
        let result = search(text)
        return (result.frontMatter, result.body, result.bodyLineOffset)
    }

    /// Front matter that hasn't closed within this many lines of the opening delimiter isn't
    /// front matter: `search` gives up rather than scanning on to the end of the document. Real
    /// front matter (Jekyll, Hugo, Pandoc) is a short metadata block, well under this; what this
    /// guards against is an editor mid-retype of the closing line in a large document, where
    /// every keystroke otherwise costs a full-document scan (#97).
    static let maxUnclosedSearchLines = 1000

    /// `split`'s search, plus how many lines the loop examined. A separate function, returning
    /// the count as an ordinary value rather than through shared mutable state, so a test can
    /// read it without racing every other test's concurrent calls into `split` (#97).
    static func search(
        _ text: String
    ) -> (frontMatter: FrontMatter?, body: Substring, bodyLineOffset: Int, linesScanned: Int) {
        let noFrontMatter = (frontMatter: FrontMatter?.none, body: text[...], bodyLineOffset: 0, linesScanned: 0)
        let utf8 = text.utf8
        var lines = LineScanner(utf8)
        guard let opening = lines.next() else { return noFrontMatter }
        // One leading byte order mark (EF BB BF) comes before the delimiter, not in it (#27).
        var delimiter = opening.content
        if utf8[delimiter].starts(with: [0xEF, 0xBB, 0xBF]) {
            delimiter = utf8.index(delimiter.lowerBound, offsetBy: 3)..<delimiter.upperBound
        }
        guard utf8[delimiter].elementsEqual("---".utf8) else { return noFrontMatter }

        var inner: [Range<String.Index>] = []
        var scanned = 0
        while let line = lines.next() {
            scanned += 1
            let content = utf8[line.content]
            if content.elementsEqual("---".utf8) || content.elementsEqual("...".utf8) {
                // A block with nothing but blank lines carries no information, so it stays
                // ordinary Markdown (`---\n---` is two thematic breaks, as it always was)
                // rather than becoming an empty Document info block.
                guard inner.contains(where: { !utf8[$0].allSatisfy(Self.isBlank) }) else {
                    return noFrontMatter
                }
                let closingLine = inner.count + 2
                // The bounds are next to ASCII line endings, so the bytes are whole scalars.
                let innerLines = inner.map { String(decoding: utf8[$0], as: UTF8.self) }
                let frontMatter = FrontMatter(
                    lineRange: 1...closingLine,
                    range: delimiter.lowerBound..<line.end,
                    rawText: String(decoding: utf8[opening.end..<line.content.lowerBound], as: UTF8.self),
                    lines: innerLines,
                    parsedPairs: parsePairs(innerLines)
                )
                return (frontMatter, text[line.end...], closingLine, scanned)
            }
            inner.append(line.content)
            if inner.count >= maxUnclosedSearchLines {
                return (nil, text[...], 0, scanned)
            }
        }
        return (nil, text[...], 0, scanned)
    }

    /// Parses one `key: value` line, or returns `nil`.
    ///
    /// The rule, applied to Unicode scalars:
    /// - The key starts the line (no indentation) with a letter, a digit or `_`. Letters and
    ///   digits are any Unicode scalars that are alphabetic or numeric, the same test
    ///   `Character.isLetter` and `Character.isNumber` apply to a character's first scalar.
    /// - The key continues with letters, digits, `_`, `-`, `.` or single spaces, and doesn't
    ///   end with a space.
    /// - A letter or digit may carry combining marks (grapheme extenders, spacing marks and
    ///   U+200D), so a decomposed `e` + U+0301 counts as a letter, as it does as a
    ///   `Character`. A mark after anything else (`_`, `-`, `.`, a space, or the start of the
    ///   line) makes the line non-simple, again as with `Character`s, where such a pair is
    ///   neither a letter nor one of the listed punctuation characters.
    /// - The key is followed directly by `:` (the first U+003A on the line), then either the
    ///   end of the line or a space or tab.
    /// - The value is the rest of the line with surrounding spaces and tabs trimmed. It may be
    ///   empty and may contain anything, including more colons and combining marks (even
    ///   right after the separating space); quotes are kept as written.
    ///
    /// So comments (`# …`), list items (`- …`), indented (nested) lines, flow collections,
    /// and keys that are quoted or contain `:` all make the block non-simple.
    static func keyValue(in line: String) -> (key: String, value: String)? {
        let utf8 = line.utf8
        // ASCII bytes are never part of a multi-byte sequence, so byte positions of ":",
        // space and tab are scalar boundaries.
        guard let colon = utf8.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        // The key's bytes end right before an ASCII ":", so they decode to whole scalars.
        let keyBytes = utf8[..<colon]
        var rest = utf8[utf8.index(after: colon)...]
        if let next = rest.first, next != UInt8(ascii: " "), next != UInt8(ascii: "\t") { return nil }
        // A fresh String, not a Substring of `line`: a Substring would round its bounds down
        // to Character boundaries, and a key ending in a Prepend scalar has none before ":".
        let key = String(decoding: keyBytes, as: UTF8.self)
        guard isSimpleKey(key) else { return nil }
        while let first = rest.first, first == UInt8(ascii: " ") || first == UInt8(ascii: "\t") {
            rest = rest.dropFirst()
        }
        while let last = rest.last, last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") {
            rest = rest.dropLast()
        }
        return (key, String(decoding: rest, as: UTF8.self))
    }

    private static func isSimpleKey(_ key: String) -> Bool {
        var previous: Unicode.Scalar?
        // Whether a combining mark may follow: the last non-mark scalar was a letter or digit.
        var canCarryMarks = false
        for scalar in key.unicodeScalars {
            let properties = scalar.properties
            if properties.isAlphabetic || properties.numericType != nil {
                canCarryMarks = true
            } else if properties.isGraphemeExtend || properties.generalCategory == .spacingMark
                        || scalar == "\u{200D}" {
                guard canCarryMarks, previous != nil else { return false }
            } else if scalar == "_" || scalar == "-" || scalar == "." {
                guard previous != nil || scalar == "_" else { return false }
                canCarryMarks = false
            } else if scalar == " " {
                guard let previous, previous != " " else { return false }
                canCarryMarks = false
            } else {
                return false
            }
            previous = scalar
        }
        return previous != nil && previous != " "
    }

    /// A byte that makes a line blank: spaces and tabs only, matching CommonMark.
    static func isBlank(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }

    private static func parsePairs(_ lines: [String]) -> [Pair]? {
        var pairs: [Pair] = []
        for line in lines where !line.utf8.allSatisfy(isBlank) {
            guard let pair = keyValue(in: line) else { return nil }
            pairs.append(Pair(key: pair.key, value: pair.value))
        }
        return pairs.isEmpty ? nil : pairs
    }
}

/// Splits a string into lines at LF, CRLF or a lone CR, by bytes. Line boundaries are
/// `Character` boundaries too: graphemes always break before and after CR and LF, and CRLF is
/// never split.
private struct LineScanner {
    struct Line {
        /// The line without its ending.
        let content: Range<String.Index>
        /// Where the next line starts (after the ending, or the end of the text).
        let end: String.Index
    }

    private let utf8: String.UTF8View
    private var position: String.Index
    private var finished = false

    init(_ utf8: String.UTF8View) {
        self.utf8 = utf8
        position = utf8.startIndex
    }

    mutating func next() -> Line? {
        guard !finished else { return nil }
        let start = position
        var index = start
        while index < utf8.endIndex, utf8[index] != 0x0A, utf8[index] != 0x0D {
            index = utf8.index(after: index)
        }
        var end = index
        if index < utf8.endIndex {
            end = utf8.index(after: index)
            if utf8[index] == 0x0D, end < utf8.endIndex, utf8[end] == 0x0A {
                end = utf8.index(after: end)
            }
        }
        // The last line is the one reaching the end of the text; a final line ending
        // doesn't start another, empty line.
        finished = end == utf8.endIndex
        position = end
        return Line(content: start..<index, end: end)
    }
}
