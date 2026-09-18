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

    mutating func visitText(_ text: Text) {
        output += text.string
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
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

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // HTML markup isn't readable text.
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        // HTML tags aren't readable text.
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
