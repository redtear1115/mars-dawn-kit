import Foundation
import Markdown

// HackMD's image size suffix (#131): `![alt](url =WxH)`, and `=W`, `=Wx`, `=xH`.
//
// cmark doesn't read these as images (a space ends the destination), so `![alt](url =WxH)`
// reaches the renderer as plain text, inside one `Text` node: swift-markdown merges a run of
// text into one. It is found there and nowhere else. Link destinations and titles, code spans,
// raw HTML, code blocks and image alt text are never `Text`, so text that cmark reads as
// anything but text is never touched, and nothing is rewritten before parsing. The search is
// one forward pass over each text.
//
// A `Text` node's string is already unescaped and entity-decoded, so `\![a](u =1)` and
// `&#33;[a](u =1)` would look like the real thing. A text is only searched when its source
// says the same bytes as its string (see `isVerbatim`); any other text is left as text, which
// is how it renders without the feature.

/// Finds HackMD-sized images in a text.
enum ImageSizes {
    /// One `![alt](source =WxH)` in a string, by UTF-8 offsets into it.
    struct Match: Equatable {
        let range: Range<Int>
        let alt: String
        let source: String
        let width: Int?
        let height: Int?
    }

    /// The largest width or height written out; a larger one is clamped to it.
    static let maxSide = 4096
    /// More digits than this is not a size, and the text stays as written.
    static let maxDigits = 6

    /// Cheap test, so a text without a candidate costs one scan for two bytes.
    static func mayHaveMatch(_ string: String) -> Bool {
        var previous: UInt8 = 0
        var sawImageStart = false
        for byte in string.utf8 {
            if previous == UInt8(ascii: "!"), byte == UInt8(ascii: "[") { sawImageStart = true }
            if sawImageStart, previous == UInt8(ascii: " "), byte == UInt8(ascii: "=") { return true }
            previous = byte
        }
        return false
    }

    /// Whether `text`'s source says what its string says: no backslash escape or entity changed
    /// it. Smart punctuation is allowed for (the renderer turns `"`, `'`, `--`, `---` and `...`
    /// into typographic characters), and so are the trailing spaces and tabs the source has
    /// before a line break, which cmark drops from the text. A range that points at the wrong
    /// line (see `SourceBytes.isSingleTilde`) has different bytes, so it is refused too.
    static func isVerbatim(_ text: Text, source: SourceBytes) -> Bool {
        guard let slice = source.slice(text.range) else { return false }
        return canonical(String(decoding: slice, as: UTF8.self)) == canonical(text.string)
    }

    /// The string with smart punctuation spelled the ASCII way and trailing blanks dropped.
    private static func canonical(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
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
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    /// Every sized image in `string`, in order. Linear: a failed candidate's scan stops at the
    /// first byte that could begin the next one, and the search resumes there.
    static func matches(in string: String) -> [Match] {
        let bytes = Array(string.utf8)
        let count = bytes.count
        var found: [Match] = []
        var index = 0
        while index + 1 < count {
            guard bytes[index] == UInt8(ascii: "!"), bytes[index + 1] == UInt8(ascii: "[") else {
                index += 1
                continue
            }
            switch candidate(bytes, at: index) {
            case .match(let match):
                found.append(match)
                index = match.range.upperBound
            case .resume(let next):
                index = max(index + 1, next)
            }
        }
        return found
    }

    private enum Outcome {
        case match(Match)
        /// No image starts here; the next one can't start before this offset.
        case resume(Int)
    }

    /// Reads `![alt](source =size)` at `start`, which holds `![`. The alt text has no brackets
    /// and no line break; the source has no whitespace, parentheses, angle or square brackets.
    private static func candidate(_ bytes: [UInt8], at start: Int) -> Outcome {
        let count = bytes.count
        var index = start + 2
        while index < count, !isAltStop(bytes[index]) { index += 1 }
        // A `[` here may itself open an image as `![`: resume on the `!` before it.
        guard index < count, bytes[index] == UInt8(ascii: "]") else { return .resume(index - 1) }
        let altEnd = index
        index += 1
        guard index < count, bytes[index] == UInt8(ascii: "(") else { return .resume(index) }
        index += 1
        let sourceStart = index
        while index < count, !isSourceStop(bytes[index]) { index += 1 }
        let sourceEnd = index
        guard sourceEnd > sourceStart, index < count, bytes[index] == UInt8(ascii: " ") else { return .resume(index - 1) }
        while index < count, bytes[index] == UInt8(ascii: " ") { index += 1 }
        guard index < count, bytes[index] == UInt8(ascii: "=") else { return .resume(index) }
        index += 1
        let widthStart = index
        while index < count, isDigit(bytes[index]) { index += 1 }
        let widthDigits = bytes[widthStart..<index]
        var heightDigits = bytes[index..<index]
        if index < count, bytes[index] == UInt8(ascii: "x") {
            index += 1
            let heightStart = index
            while index < count, isDigit(bytes[index]) { index += 1 }
            heightDigits = bytes[heightStart..<index]
        }
        guard index < count, bytes[index] == UInt8(ascii: ")"),
              !(widthDigits.isEmpty && heightDigits.isEmpty),
              widthDigits.count <= maxDigits, heightDigits.count <= maxDigits
        else { return .resume(index) }
        let alt = String(decoding: bytes[(start + 2)..<altEnd], as: UTF8.self)
        let source = String(decoding: bytes[sourceStart..<sourceEnd], as: UTF8.self)
        // Math and footnote placeholders are private-use characters; neither belongs in an image.
        // A source with smart punctuation in it is not the URL that was written, and a backslash
        // that is not an escape (`b\ =1`) is left to read as the text it is.
        guard !(alt + source).unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) }),
              !source.unicodeScalars.contains(where: { smartPunctuation.contains($0) }),
              !(alt + source).utf8.contains(UInt8(ascii: "\\"))
        else { return .resume(index) }
        return .match(Match(range: start..<(index + 1), alt: alt, source: source,
                            width: side(widthDigits), height: side(heightDigits)))
    }

    private static func side(_ digits: ArraySlice<UInt8>) -> Int? {
        guard !digits.isEmpty, let value = Int(String(decoding: digits, as: UTF8.self)), value > 0 else { return nil }
        return min(value, maxSide)
    }

    private static let smartPunctuation: Set<Unicode.Scalar> = [
        "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{2013}", "\u{2014}", "\u{2026}",
    ]

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func isAltStop(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "]") || byte == UInt8(ascii: "[") || byte == 0x0A || byte == 0x0D
    }

    private static func isSourceStop(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), 0x0A, 0x0D,
             UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"):
            true
        default:
            false
        }
    }
}
