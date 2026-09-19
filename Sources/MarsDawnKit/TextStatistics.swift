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

/// The text a page shows for raw HTML (#19, #57), read the way the escapers read untrusted input:
/// on bytes, in one forward pass, so no input makes it more than linear. Checked against what the
/// preview page's `innerText` shows (`CountMatchesPageTests`).
///
/// - A tag is `<` followed by a letter, `/` and a letter, `!` or `?`, up to the `>` that ends
///   it (one inside a quoted attribute value, `title="a>b"`, doesn't). It shows nothing; a
///   block-level tag (`p`, `div`, `li`, `br`, …) separates words as the page lays them out, an
///   inline one (`b`, `span`, …) doesn't. A tag with no `>` swallows the rest, as in the page.
/// - Any other `<` is shown as itself.
/// - A comment, `<!--` to `-->`, shows nothing.
/// - Never shown, up to the element's end, even when that is in a later piece of HTML:
///   `script`, `style` and `noscript` (the preview runs scripts) up to their first close tag;
///   `template`, `select` and any element with the `hidden` attribute up to their matching close
///   tag, counting the same element nested inside; and a `<details>` without `open`, after its
///   `</summary>`.
/// - Entities are decoded as the page decodes them: numeric ones, and the common named ones;
///   `&nbsp;` is a space. An unknown one is shown as written.
/// - `<textarea>` text is counted: the reader sees it in the box, although `innerText` leaves
///   form controls out.
/// - Nothing is evaluated.
struct VisibleHTMLText {
    private static func names(_ list: [String]) -> Set<[UInt8]> { Set(list.map { Array($0.utf8) }) }
    /// Their content is text up to the first close tag: nothing inside nests.
    private static let rawTextHidden = names(["script", "style", "noscript"])
    /// Hidden with everything inside, up to the matching close tag.
    private static let nestingHidden = names(["template", "select"])
    /// No content and no close tag: a `hidden` attribute on one hides nothing else.
    private static let voidElements = names(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"])
    private static let blockElements = names([
        "address", "article", "aside", "blockquote", "br", "dd", "details", "div", "dl", "dt", "figcaption",
        "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol",
        "p", "pre", "section", "summary", "table", "td", "th", "tr", "ul",
    ])
    /// Where this counter deliberately differs from the HTML table: a soft hyphen and the
    /// spacing entities read as nothing and as a plain space, so they never split a word or join
    /// two. Everything else comes from the full list (#69).
    private static let entityOverrides: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "bull": "•", "middot": "·", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±",
        "para": "¶", "sect": "§", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "laquo": "«",
        "raquo": "»", "iexcl": "¡", "iquest": "¿", "shy": "", "ensp": " ", "emsp": " ", "thinsp": " ",
    ]

    /// The hidden element the text is inside, lowercased: whether it nests, and how deep.
    private var hidden: (name: [UInt8], nests: Bool, depth: Int)?
    /// For each `<details>` the text is inside, whether it is collapsed.
    private var details: [Bool] = []

    var isHiding: Bool { hidden != nil }

    mutating func visibleText(of html: String) -> String {
        let b = Array(html.utf8)
        let n = b.count
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var i = 0
        func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
        func isNameByte(_ byte: UInt8) -> Bool { isLetter(byte) || (0x30...0x39).contains(byte) || byte == UInt8(ascii: "-") }
        func lower(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }
        /// Whether `b[at...]` is `<name` or `</name` (per `closing`) followed by a non-name byte.
        func tagNamed(_ name: [UInt8], at j: Int, closing: Bool) -> Bool {
            let start = j + (closing ? 2 : 1)
            guard b[j] == UInt8(ascii: "<"), !closing || (j + 1 < n && b[j + 1] == UInt8(ascii: "/")),
                  start + name.count <= n,
                  (0..<name.count).allSatisfy({ lower(b[start + $0]) == name[$0] }) else { return false }
            return start + name.count == n || !isNameByte(b[start + name.count])
        }
        while i < n {
            if let current = hidden {
                // Skip to the close tag that ends it; the tag itself is read below.
                var j = i
                var depth = current.depth
                var found = false
                while j < n {
                    if b[j] == UInt8(ascii: "<") {
                        if tagNamed(current.name, at: j, closing: true) {
                            depth -= 1
                            if !current.nests || depth == 0 { found = true; break }
                        } else if current.nests, tagNamed(current.name, at: j, closing: false) {
                            depth += 1
                        }
                    }
                    j += 1
                }
                guard found else {
                    hidden = (current.name, current.nests, depth)
                    return String(decoding: out, as: UTF8.self)
                }
                hidden = nil
                i = j
                continue
            }
            let byte = b[i]
            if byte == UInt8(ascii: "&"), let (decoded, length) = Self.entity(b, at: i) {
                out.append(contentsOf: decoded)
                i += length
                continue
            }
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
            // To the `>` that ends the tag: one inside a quoted attribute value doesn't. Attribute
            // names outside quotes are collected on the way.
            var end = i + 1
            var quote: UInt8?
            var afterEquals = false
            var inUnquotedValue = false
            var attributes: [[UInt8]] = []
            var attribute: [UInt8] = []
            var inName = false
            var closed = false
            func isSpace(_ c: UInt8) -> Bool { c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r") }
            while end < n {
                let c = b[end]
                defer { end += 1 }
                if let open = quote {
                    if c == open { quote = nil }
                    continue
                }
                if c == UInt8(ascii: ">") { closed = true; break }
                if inUnquotedValue {
                    if isSpace(c) { inUnquotedValue = false }
                    continue
                }
                if afterEquals {
                    if isSpace(c) { continue }
                    afterEquals = false
                    if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { quote = c } else { inUnquotedValue = true }
                    continue
                }
                if c == UInt8(ascii: "=") {
                    if inName { attributes.append(attribute); inName = false }
                    afterEquals = true
                } else if isNameByte(c) {
                    if !inName { attribute = []; inName = true }
                    attribute.append(lower(c))
                } else if inName {
                    attributes.append(attribute)
                    inName = false
                }
            }
            end = closed ? end - 1 : n  // the defer stepped past the `>`; no `>` at all swallows the rest
            if inName { attributes.append(attribute) }
            var nameEnd = i + (closing ? 2 : 1)
            let nameStart = nameEnd
            while nameEnd < end, isNameByte(b[nameEnd]) { nameEnd += 1 }
            let name = b[nameStart..<nameEnd].map(lower)
            // The first "attribute" collected is the element's own name.
            let attributeNames = Set(attributes.dropFirst())
            if Self.blockElements.contains(name) { out.append(UInt8(ascii: " ")) }
            i = end + 1
            let selfClosing = end > 0 && b[end - 1] == UInt8(ascii: "/")
            if closing {
                if name == Array("details".utf8), !details.isEmpty { details.removeLast() }
                if name == Array("summary".utf8), details.last == true {
                    // The rest of a collapsed <details> is hidden, up to its own </details>.
                    hidden = (Array("details".utf8), true, 1)
                }
                continue
            }
            if name == Array("details".utf8) { details.append(!attributeNames.contains(Array("open".utf8))) }
            if Self.rawTextHidden.contains(name) {
                hidden = (name, false, 1)
            } else if Self.nestingHidden.contains(name) || (attributeNames.contains(Array("hidden".utf8))
                        && !Self.voidElements.contains(name) && !selfClosing) {
                hidden = (name, true, 1)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The UTF-8 an entity at `b[at]` stands for and its length, or nil to show `&` as written.
    private static func entity(_ b: [UInt8], at start: Int) -> ([UInt8], Int)? {
        var end = start + 1
        while end < b.count, end - start <= 32, b[end] != UInt8(ascii: ";") {
            let c = b[end]
            guard (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == UInt8(ascii: "#") else { return nil }
            end += 1
        }
        guard end < b.count, b[end] == UInt8(ascii: ";"), end > start + 1 else { return nil }
        let body = String(decoding: b[(start + 1)..<end], as: UTF8.self)
        let length = end - start + 1
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return (Array(String(scalar).utf8), length)
        }
        guard let text = entityOverrides[body] ?? HTMLNamedEntities.table[body] else { return nil }
        return (Array(text.utf8), length)
    }
}
