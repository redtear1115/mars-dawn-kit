import Foundation
import Markdown

/// Word, character, line and reading-time counts for a piece of text.
///
/// Used by the app's status bar to summarize either a plain-text selection or an
/// entire Markdown document's readable content.
public struct TextStatistics: Sendable, Equatable {
    /// Total word count: each CJK ideograph, Hiragana/Katakana character or Hangul
    /// syllable counts as one word; each maximal run of other letters/digits (an
    /// apostrophe or hyphen inside a run doesn't split it) counts as one word.
    public let words: Int
    /// The subset of `words` that are CJK ideographs, Kana characters or Hangul syllables.
    public let cjkWordCount: Int
    /// The subset of `words` that are runs of non-CJK letters/digits.
    public let nonCJKWordCount: Int
    /// Grapheme clusters, excluding whitespace and newlines.
    public let characters: Int
    /// Grapheme clusters, excluding newlines only.
    public let charactersWithSpaces: Int
    /// Number of source lines. An empty string has 0 lines; a CRLF pair counts as one break.
    public let lines: Int
    /// Estimated reading time in whole minutes, rounded up (0 when there are no words).
    public let readingMinutes: Int

    /// Counts raw text exactly as given, for a selection or other plain-text span.
    public init(plainText: String) {
        self.init(readableText: plainText, sourceLines: plainText)
    }

    /// Parses Markdown and counts only the text a reader sees: prose, inline code and
    /// code-block contents, link text and image alt text. URLs, HTML tags and Markdown
    /// syntax markers (heading/list markers, emphasis, table pipes) are excluded.
    /// `lines` still counts the source lines of `markdownBody`.
    ///
    /// - Parameter markdownBody: The document body with its front matter already removed,
    ///   as `FrontMatter.split` returns it. Nothing is split off here, so a whole file
    ///   passed in counts its front matter as ordinary prose.
    ///
    /// The parse and the walk over its nodes run on a parsing worker
    /// (`MarkdownParsing.withDocument`), and this initializer blocks until they finish.
    /// A body the worker refuses to parse — `.tooDeep`, `.tooLarge` or `.tooComplex` —
    /// is counted as plain text instead, without parsing: the counts then include
    /// Markdown markers and URLs, an over-count, but they stay close to what the editor
    /// shows and are the only answer available without a tree. `lines` is the same either
    /// way, and nothing here can fail or return nothing.
    public init(markdownBody: String) {
        let readableText = MarkdownParsing.withDocument(markdownBody) { outcome -> String? in
            guard case .document(let document) = outcome else { return nil }
            var visitor = ReadableTextVisitor()
            visitor.visit(document)
            return visitor.output
        }
        self.init(readableText: readableText ?? markdownBody, sourceLines: markdownBody)
    }

    private init(readableText: String, sourceLines: String) {
        let counts = TextStatistics.countWords(in: readableText)
        cjkWordCount = counts.cjk
        nonCJKWordCount = counts.nonCJK
        words = counts.cjk + counts.nonCJK
        var characterCount = 0
        var characterWithSpacesCount = 0
        for character in readableText {
            if !character.isNewline { characterWithSpacesCount += 1 }
            if !character.isWhitespace { characterCount += 1 }
        }
        characters = characterCount
        charactersWithSpaces = characterWithSpacesCount
        lines = TextStatistics.countLines(in: sourceLines)
        readingMinutes = TextStatistics.readingMinutes(nonCJKWords: counts.nonCJK, cjkWords: counts.cjk)
    }

    // MARK: - Counting

    private static func countLines(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var newlineCount = 0
        for character in text where character.isNewline { newlineCount += 1 }
        return text.last!.isNewline ? newlineCount : newlineCount + 1
    }

    private static func readingMinutes(nonCJKWords: Int, cjkWords: Int) -> Int {
        guard nonCJKWords > 0 || cjkWords > 0 else { return 0 }
        let minutes = Double(nonCJKWords) / 250.0 + Double(cjkWords) / 400.0
        return max(1, Int(minutes.rounded(.up)))
    }

    private static func countWords(in text: String) -> (cjk: Int, nonCJK: Int) {
        let characters = Array(text)
        var cjk = 0
        var nonCJK = 0
        var i = 0
        while i < characters.count {
            let character = characters[i]
            if isCJKCharacter(character) {
                cjk += 1
                i += 1
                continue
            }
            if isWordCharacter(character) {
                var j = i + 1
                while j < characters.count {
                    if isWordCharacter(characters[j]) {
                        j += 1
                    } else if isWordConnector(characters[j]), j + 1 < characters.count, isWordCharacter(characters[j + 1]) {
                        j += 2
                    } else {
                        break
                    }
                }
                nonCJK += 1
                i = j
                continue
            }
            i += 1
        }
        return (cjk, nonCJK)
    }

    /// A letter or digit that isn't already counted individually as a CJK character.
    private static func isWordCharacter(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber) && !isCJKCharacter(character)
    }

    /// An apostrophe or hyphen, allowed inside a word run without splitting it.
    private static func isWordConnector(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "-"
    }

    /// A CJK ideograph, Hiragana/Katakana character or Hangul syllable, each counted
    /// individually as one word.
    private static func isCJKCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x31F0...0x31FF, // Katakana Phonetic Extensions
             0x3400...0x4DBF, // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x20000...0x2A6DF, 0x2A700...0x2EBEF, // CJK Unified Ideographs Extension B–F
             0xAC00...0xD7A3: // Hangul Syllables
            return true
        default:
            return false
        }
    }
}

// MARK: - Readable-text visitor

/// Collects the text a reader would see from a Markdown document: prose, inline code
/// and code-block contents, link text and image alt text. URLs and HTML are skipped.
private struct ReadableTextVisitor: MarkupWalker {
    var output = ""
    /// Raw HTML, blocks and inline alike, read as a page shows it. It carries whether the
    /// document is inside a `script`, `style` or `template` from one piece of HTML to the next,
    /// so the text nodes between an inline `<script>` and its `</script>` aren't counted either.
    private var html = VisibleHTMLText()

    mutating func visitText(_ text: Text) {
        guard !html.isHiding else { return }
        output += text.string
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard !html.isHiding else { return }
        output += inlineCode.code
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        output += codeBlock.code
        output += "\n"
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

    mutating func visitHTMLBlock(_ block: HTMLBlock) {
        // The preview renders an HTML block, so its text is text a reader sees (#19).
        output += html.visibleText(of: block.rawHTML)
        output += " "
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        output += html.visibleText(of: inlineHTML.rawHTML)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        descendInto(paragraph)
        output += " "
    }

    mutating func visitHeading(_ heading: Heading) {
        descendInto(heading)
        output += " "
    }

    mutating func visitListItem(_ listItem: ListItem) {
        descendInto(listItem)
        output += " "
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        descendInto(blockQuote)
        output += " "
    }

    mutating func visitTableCell(_ cell: Table.Cell) {
        descendInto(cell)
        output += " "
    }
}

/// The text a page shows for raw HTML (#19), read the way the escapers read untrusted input: on
/// bytes, in one forward pass, so no input makes it more than linear.
///
/// - A tag is `<` followed by a letter, `/` and a letter, `!` or `?`, up to the `>` that ends
///   it (one inside a quoted attribute value, `title="a>b"`, doesn't). It
///   shows nothing; a block-level tag (`p`, `div`, `li`, `br`, …) separates words as the page
///   lays them out, an inline one (`b`, `span`, …) doesn't. A tag with no `>` swallows the rest,
///   as it would in the page.
/// - Any other `<` is shown as itself.
/// - A comment, `<!--` to `-->`, shows nothing.
/// - The content of `script`, `style` and `template` is never shown, up to the matching
///   close tag, even when that is in a later piece of HTML.
/// - Nothing is evaluated, and entities are left as written.
struct VisibleHTMLText {
    private static let hiddenElements: Set<[UInt8]> = ["script", "style", "template"].map { Array($0.utf8) }.reduce(into: []) { $0.insert($1) }
    private static let blockElements: Set<[UInt8]> = [
        "address", "article", "aside", "blockquote", "br", "dd", "details", "div", "dl", "dt", "figcaption",
        "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol",
        "p", "pre", "section", "summary", "table", "td", "th", "tr", "ul",
    ].map { Array($0.utf8) }.reduce(into: []) { $0.insert($1) }

    /// The hidden element the text is inside, lowercased, or nil.
    private var hiddenElement: [UInt8]?

    var isHiding: Bool { hiddenElement != nil }

    mutating func visibleText(of html: String) -> String {
        let b = Array(html.utf8)
        let n = b.count
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var i = 0
        func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
        func lower(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }
        while i < n {
            if let hidden = hiddenElement {
                // Up to `</name`, any case; the tag itself is read below.
                var j = i
                var found = false
                while j + 1 + hidden.count < n {
                    if b[j] == UInt8(ascii: "<"), b[j + 1] == UInt8(ascii: "/"),
                       (0..<hidden.count).allSatisfy({ lower(b[j + 2 + $0]) == hidden[$0] }) {
                        found = true
                        break
                    }
                    j += 1
                }
                guard found else { return String(decoding: out, as: UTF8.self) }
                hiddenElement = nil
                i = j
                continue
            }
            let byte = b[i]
            guard byte == UInt8(ascii: "<") else {
                out.append(byte)
                i += 1
                continue
            }
            if i + 3 < n, b[i + 1] == UInt8(ascii: "!"), b[i + 2] == UInt8(ascii: "-"), b[i + 3] == UInt8(ascii: "-") {
                var j = i + 4
                while j + 2 < n, !(b[j] == UInt8(ascii: "-") && b[j + 1] == UInt8(ascii: "-") && b[j + 2] == UInt8(ascii: ">")) { j += 1 }
                guard j + 2 < n else { return String(decoding: out, as: UTF8.self) }
                i = j + 3
                continue
            }
            let next: UInt8? = i + 1 < n ? b[i + 1] : nil
            let closing = next == UInt8(ascii: "/")
            let startsTag = next.map { isLetter($0) || $0 == UInt8(ascii: "!") || $0 == UInt8(ascii: "?") } ?? false
                || (closing && i + 2 < n && isLetter(b[i + 2]))
            guard startsTag else {
                out.append(byte)
                i += 1
                continue
            }
            // To the `>` that ends the tag: one inside a quoted attribute value doesn't.
            var end = i + 1
            var quote: UInt8?
            var afterEquals = false
            while end < n {
                let c = b[end]
                if let open = quote {
                    if c == open { quote = nil }
                } else if c == UInt8(ascii: ">") {
                    break
                } else if afterEquals, c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                    quote = c
                }
                if c == UInt8(ascii: "=") { afterEquals = quote == nil } else if c != UInt8(ascii: " "), c != UInt8(ascii: "\t"), c != UInt8(ascii: "\n") { afterEquals = false }
                end += 1
            }
            guard end < n else { return String(decoding: out, as: UTF8.self) }
            var nameEnd = i + (closing ? 2 : 1)
            let nameStart = nameEnd
            while nameEnd < end, isLetter(b[nameEnd]) || (0x30...0x39).contains(b[nameEnd]) || b[nameEnd] == UInt8(ascii: "-") { nameEnd += 1 }
            let name = b[nameStart..<nameEnd].map(lower)
            if Self.blockElements.contains(name) { out.append(UInt8(ascii: " ")) }
            if !closing, Self.hiddenElements.contains(name) { hiddenElement = name }
            i = end + 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
