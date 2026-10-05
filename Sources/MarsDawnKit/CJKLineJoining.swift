import Foundation
import Markdown

/// Whether a soft break between two lines of CJK text should vanish (#129).
///
/// A newline inside a paragraph is a soft break, which a browser shows as a space. Chinese and
/// Japanese don't put spaces between words, so a note written a line at a time (`第一行中文` then
/// `第二行中文`) must read as one run of text, not `第一行中文 第二行中文`. Hangul is not counted,
/// although #129 listed it: Korean spaces its words, so a Korean line that ends at a word boundary
/// would lose the space it needs. A break between Korean lines stays a space, as CommonMark has it.
///
/// The rule is on the two characters either side of the break, nothing else:
/// - both CJK (`isCJK`): the break renders as nothing at all. A literal newline would still be
///   a space to the browser, so the renderer emits no whitespace;
/// - Latin and Latin: unchanged, as CommonMark has it;
/// - CJK and Latin (`日本語\nabc`): unchanged. There the space is wanted more often than not
///   (a Latin word or number next to a Chinese sentence), and a reader can't tell from the break
///   which the author meant.
enum CJKLineJoining {
    /// Han, kana, and CJK punctuation and fullwidth forms. Not U+3000, the ideographic
    /// space: it is a space, and a break next to one stays as it was.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FDF,               // CJK Radicals Supplement, Kangxi Radicals
             0x3001...0x303F,               // CJK Symbols and Punctuation (3000, the space, is out)
             0x3040...0x30FF,               // Hiragana, Katakana
             0x3100...0x312F,               // Bopomofo
             0x3190...0x31FF,               // Kanbun, Bopomofo Extended, CJK Strokes, Katakana Extensions
             0x3200...0x33FF,               // Enclosed CJK Letters and Months, CJK Compatibility
             0x3400...0x4DBF,               // CJK Extension A
             0x4E00...0x9FFF,               // CJK Unified Ideographs
             0xF900...0xFAFF,               // CJK Compatibility Ideographs
             0xFE10...0xFE19,               // Vertical Forms
             0xFE30...0xFE6F,               // CJK Compatibility Forms, Small Form Variants
             0xFF01...0xFF9F,               // Fullwidth forms and halfwidth Katakana
             0xFFE0...0xFFEE,               // Fullwidth signs and halfwidth symbols (FFA0-FFDF, halfwidth Hangul, is out)
             0x20000...0x323AF,             // CJK Extensions B to H, and the compatibility supplement
             0x1B000...0x1B16F:             // Kana Supplement, Kana Extended-A, Small Kana Extension
            true
        default:
            false
        }
    }

    /// Whether a soft break between the siblings `before` and `after` stands between two CJK
    /// characters. Either may be a container (`**中文**\n中文`), whose edge character counts.
    static func joins(before: (any Markup)?, after: (any Markup)?) -> Bool {
        guard let before = scalar(of: before, last: true), let after = scalar(of: after, last: false) else { return false }
        return isCJK(before) && isCJK(after)
    }

    /// The last (`last` true) or first visible character of a node, or nil if it has none there
    /// (an image, a break). Walks down the edge that touches the break, without recursion
    /// (nesting can be deep): the last child when looking back, the first when looking ahead.
    private static func scalar(of node: (any Markup)?, last: Bool) -> Unicode.Scalar? {
        var current = node
        while let node = current {
            switch node {
            case let text as Text:
                return last ? text.string.unicodeScalars.last : text.string.unicodeScalars.first
            case let code as InlineCode:
                return last ? code.code.unicodeScalars.last : code.code.unicodeScalars.first
            case is Image, is SoftBreak, is LineBreak, is InlineHTML, is SymbolLink:
                return nil
            default:
                guard node.childCount > 0 else { return nil }
                current = node.child(at: last ? node.childCount - 1 : 0)
            }
        }
        return nil
    }
}
