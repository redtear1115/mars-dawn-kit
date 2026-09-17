import Foundation

/// A metadata block at the very top of a Markdown document, delimited by `---` lines
/// (YAML front matter as used by Jekyll, Hugo, Pandoc and others).
///
/// Detection is deliberately narrow:
/// - Line 1 must be exactly `---`: no leading or trailing spaces, nothing else on the line.
///   A leading byte order mark (U+FEFF) is not skipped, so strip it before calling `split`.
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
    public static func split(_ text: String) -> (frontMatter: FrontMatter?, body: Substring, bodyLineOffset: Int) {
        let noFrontMatter = (frontMatter: FrontMatter?.none, body: text[...], bodyLineOffset: 0)
        var lines = LineScanner(text)
        guard let opening = lines.next(), text[opening.content] == "---" else { return noFrontMatter }

        var inner: [Range<String.Index>] = []
        while let line = lines.next() {
            let content = text[line.content]
            if content == "---" || content == "..." {
                let closingLine = inner.count + 2
                let innerText = text[opening.end..<line.content.lowerBound]
                let innerLines = inner.map { String(text[$0]) }
                let frontMatter = FrontMatter(
                    lineRange: 1...closingLine,
                    range: text.startIndex..<line.end,
                    rawText: String(innerText),
                    lines: innerLines,
                    parsedPairs: parsePairs(innerLines)
                )
                return (frontMatter, text[line.end...], closingLine)
            }
            inner.append(line.content)
        }
        return noFrontMatter
    }

    /// Parses one `key: value` line, or returns `nil`.
    ///
    /// The rule:
    /// - The key starts the line (no indentation) with a letter, a digit or `_`.
    /// - The key continues with letters, digits, `_`, `-`, `.` or single spaces, and doesn't
    ///   end with a space. Letters and digits may be any Unicode letters and digits.
    /// - The key is followed directly by `:`, then either the end of the line or a space or
    ///   tab.
    /// - The value is the rest of the line with surrounding spaces and tabs trimmed. It may be
    ///   empty and may contain anything, including more colons; quotes are kept as written.
    ///
    /// So comments (`# …`), list items (`- …`), indented (nested) lines, flow collections,
    /// and keys that are quoted or contain `:` all make the block non-simple.
    static func keyValue(in line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        let rest = line[line.index(after: colon)...]
        guard let first = key.first, first.isLetter || first.isNumber || first == "_",
              key.last != " ",
              !key.contains("  "),
              key.allSatisfy({ $0.isLetter || $0.isNumber || "_-. ".contains($0) })
        else { return nil }
        if let next = rest.first, next != " ", next != "\t" { return nil }
        let value = rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return (String(key), value)
    }

    private static func parsePairs(_ lines: [String]) -> [Pair]? {
        var pairs: [Pair] = []
        for line in lines where !line.allSatisfy({ $0 == " " || $0 == "\t" }) {
            guard let pair = keyValue(in: line) else { return nil }
            pairs.append(Pair(key: pair.key, value: pair.value))
        }
        return pairs.isEmpty ? nil : pairs
    }
}

/// Splits a string into lines at LF, CRLF or a lone CR.
private struct LineScanner {
    struct Line {
        /// The line without its ending.
        let content: Range<String.Index>
        /// Where the next line starts (after the ending, or the end of the text).
        let end: String.Index
    }

    private let text: String
    private var position: String.Index
    private var finished = false

    init(_ text: String) {
        self.text = text
        position = text.startIndex
    }

    mutating func next() -> Line? {
        guard !finished else { return nil }
        let utf8 = text.utf8
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
