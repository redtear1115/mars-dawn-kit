import Foundation

/// Which language a document is written in, as far as the preview's fonts need to know (kit #164).
///
/// Han characters are shared by Chinese and Japanese, and a font chosen for one draws the other's
/// characters with the wrong shapes (骨, 直, 次). The page picks the system's CJK font from the
/// process language unless the content says otherwise, so a Japanese document read on a Chinese
/// Mac got Chinese shapes. The renderer tells the page "this is Japanese", and only that: it never
/// names another language, and a document it can't tell about renders exactly as before.
///
/// The answer reaches the page as one marker element at the very start of the rendered HTML
/// (`markerHTML`), which `preview.js` takes out before anything else reads the fragment and turns
/// into `#content.lang`.
package enum ContentLanguage {
    /// The element name of the marker. The renderer writes no other element with this name, and
    /// `preview.js` recognises it only as the fragment's very first node.
    package static let markerElement = "md-content-lang"

    /// The longest tag accepted, in bytes.
    package static let maxTagBytes = 35

    /// `"ja"`, a `ja-…` tag, or `nil`. Never another language.
    ///
    /// - A front-matter `lang:` line decides first: a valid tag (`isValidTag`) whose primary
    ///   subtag is `ja` (any case) is returned as written; any other valid tag means the author
    ///   declared a language that isn't Japanese, and the answer is `nil` with no further look.
    ///   An invalid or empty value is ignored, as if the line weren't there.
    /// - Otherwise the document is Japanese when it has kana letters and they are at least 10% of
    ///   its Han and kana letters together (`isMostlyKana`). Every character counts, including
    ///   those in code blocks, inline code, math and the front matter itself: a code block of
    ///   Japanese strings is still Japanese text, and skipping them would mean parsing first.
    ///
    /// Linear in the length of `markdown`: one pass over its Unicode scalars with fixed ranges,
    /// after `FrontMatter.split`, which is linear itself.
    package static func detect(markdown: String) -> String? {
        switch declaredTag(in: markdown) {
        case .japanese(let tag): return tag
        case .otherLanguage: return nil
        case .none: return isMostlyKana(markdown) ? "ja" : nil
        }
    }

    enum Declaration: Equatable {
        case japanese(String)
        case otherLanguage
        case none
    }

    /// What the front matter's `lang:` says. Read with the front-matter table's own line rule
    /// (`FrontMatter.keyValue(in:)`): the key is exactly `lang`, case-sensitive, and the first such
    /// line wins. Each line is read on its own, so a block that isn't simple enough for the table
    /// (a list elsewhere in it, say) still has its top-level `lang:` read.
    static func declaredTag(in markdown: String) -> Declaration {
        guard let frontMatter = FrontMatter.split(markdown).frontMatter else { return .none }
        for line in frontMatter.lines {
            guard let pair = FrontMatter.keyValue(in: line), pair.key == "lang" else { continue }
            guard let tag = tagValue(pair.value) else { return .none }
            return isJapanese(tag) ? .japanese(tag) : .otherLanguage
        }
        return .none
    }

    /// The value with exactly one matching pair of surrounding quotes taken off and spaces and tabs
    /// trimmed, if it is then a valid tag; `nil` when it is empty or invalid.
    static func tagValue(_ value: String) -> String? {
        var bytes = Array(value.utf8)
        if bytes.count >= 2, let first = bytes.first, first == UInt8(ascii: "\"") || first == UInt8(ascii: "'"),
           bytes.last == first {
            bytes = Array(bytes[1..<(bytes.count - 1)])
        }
        while let first = bytes.first, FrontMatter.isBlank(first) { bytes.removeFirst() }
        while let last = bytes.last, FrontMatter.isBlank(last) { bytes.removeLast() }
        guard isValidTag(bytes) else { return nil }
        // Every byte is ASCII, so this is the same text.
        return String(decoding: bytes, as: UTF8.self)
    }

    /// An ASCII-only BCP 47 shape, checked on bytes: two or three ASCII letters, then any number
    /// of `-` and one to eight ASCII letters or digits, at most `maxTagBytes` bytes in all. Not a
    /// registry check; only a shape that can't carry markup, quotes or anything but a tag.
    /// `preview.js` checks the same pattern again.
    package static func isValidTag<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        guard !bytes.isEmpty, bytes.count <= maxTagBytes else { return false }
        func isLetter(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
        func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }
        var subtags: [[UInt8]] = [[]]
        for byte in bytes {
            if byte == UInt8(ascii: "-") { subtags.append([]) } else { subtags[subtags.count - 1].append(byte) }
        }
        let primary = subtags[0]
        guard (2...3).contains(primary.count), primary.allSatisfy(isLetter) else { return false }
        for subtag in subtags.dropFirst() {
            guard (1...8).contains(subtag.count), subtag.allSatisfy({ isLetter($0) || isDigit($0) }) else { return false }
        }
        return true
    }

    /// Whether a valid tag's primary subtag is `ja`, ignoring ASCII case.
    static func isJapanese(_ tag: String) -> Bool {
        let primary = tag.utf8.prefix { $0 != UInt8(ascii: "-") }
        return primary.count == 2 && primary.map { $0 | 0x20 } == [UInt8(ascii: "j"), UInt8(ascii: "a")]
    }

    /// Kana letters are at least one, and at least 10% of Han and kana letters together.
    static func isMostlyKana(_ text: String) -> Bool {
        let (kana, han) = counts(text)
        return kana >= 1 && kana * 10 >= kana + han
    }

    /// Kana letters and Han ideographs in `text`, one pass over its scalars.
    ///
    /// Kana letters: Hiragana U+3041–U+3096 and U+309D–U+309F; Katakana U+30A1–U+30FA,
    /// U+30FD–U+30FF, U+31F0–U+31FF, and the halfwidth U+FF66–U+FF6F and U+FF71–U+FF9D. Left out,
    /// because Chinese text uses them too or they belong to no script: the middle dot U+30FB
    /// (「哈利・波特」), U+30A0, the prolonged sound mark U+30FC and its halfwidth U+FF70, the
    /// combining and spacing (semi-)voiced sound marks U+3099–U+309C and U+FF9E–U+FF9F, and the
    /// halfwidth middle dot U+FF65.
    ///
    /// Han: U+3400–U+4DBF, U+4E00–U+9FFF, U+F900–U+FAFF and U+20000–U+2FA1F.
    static func counts(_ text: String) -> (kana: Int, han: Int) {
        var kana = 0, han = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Everything below U+3041 is neither, and that is nearly all of a Latin document.
            if v < 0x3041 { continue }
            switch v {
            case 0x3041...0x3096, 0x309D...0x309F,
                 0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF,
                 0xFF66...0xFF6F, 0xFF71...0xFF9D:
                kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                han += 1
            default:
                break
            }
        }
        return (kana, han)
    }

    /// The marker for `tag`: `<md-content-lang data-lang="…"></md-content-lang>`. Exactly one
    /// attribute, no content, an explicit end tag. `tag` must be one `detect` returned; it is
    /// checked again and escaped anyway, and anything else gives no marker.
    static func markerHTML(_ tag: String) -> String {
        guard isValidTag(tag.utf8), isJapanese(tag) else { return "" }
        return "<\(markerElement) data-lang=\"\(escapeAttribute(tag))\"></\(markerElement)>"
    }
}
