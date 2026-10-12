import Foundation

/// Counts the `<details>` elements that a run of raw HTML blocks opens and closes (#414).
///
/// GitHub's `<details>` form has blank lines in it, and CommonMark ends an HTML block at a
/// blank line, so `<details><summary>…</summary>`, the Markdown in the middle and `</details>`
/// are three sibling nodes. The renderer wraps each HTML block in its own `div`, and a browser
/// closes the `<details>` at the first `</div>`. `MarkdownRenderer` uses this to put such a run
/// in one wrapper instead.
///
/// Read the way the HTML tokenizer reads it, on bytes, in one forward pass (so no input makes
/// it more than linear, and no state survives a raw-text element that never ends):
/// - A tag name ends at whitespace, `/` or `>`, and is compared in ASCII lower case: so
///   `<details-card>` is another element, and `</details foo>` and `</details/>` close one.
/// - Comments (`<!--` to `-->`, `--!>`, or the empty forms `<!-->` and `<!--->`), bogus comments
///   (`<!…>`, `<?…>`, `</` not followed by a letter) and the quoted values of attributes are
///   skipped, so a `<details>` written inside one is not counted.
/// - The content of `script`, `style`, `textarea`, `title`, `xmp`, `noembed`, `noframes` and
///   `noscript` is skipped up to the first matching close tag, and that of `plaintext` to the
///   end. `pre` is not skipped: a browser parses what is inside it as elements.
/// - A close with no opening is ignored: the depth never goes below zero.
enum DetailsScanner {
    /// The number of `<details>` still open after `html`, when `depth` were open before it.
    static func depth(after html: String, from depth: Int) -> Int {
        var html = html
        return html.withUTF8 { scan($0, depth) }
    }

    private static let rawTextNames: [[UInt8]] = [
        "script", "style", "textarea", "title", "xmp", "noembed", "noframes", "noscript",
    ].map { Array($0.utf8) }
    private static let plaintext = Array("plaintext".utf8)
    private static let details = Array("details".utf8)

    private static let lessThan = UInt8(ascii: "<"), greaterThan = UInt8(ascii: ">")
    private static let slash = UInt8(ascii: "/"), bang = UInt8(ascii: "!"), question = UInt8(ascii: "?")
    private static let dash = UInt8(ascii: "-"), equals = UInt8(ascii: "="), singleQuote = UInt8(ascii: "'")
    private static let doubleQuote = UInt8(ascii: "\"")

    private static func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }
    private static func lower(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }

    private static func scan(_ b: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
        var depth = start
        let n = b.count
        var i = 0
        while i < n {
            guard b[i] == lessThan else {
                i += 1
                continue
            }
            let next = i + 1
            guard next < n else { break }
            let c = b[next]
            if c == bang {
                if next + 2 < n, b[next + 1] == dash, b[next + 2] == dash {
                    i = endOfComment(b, from: next + 3)
                } else {
                    i = afterGreaterThan(b, from: next + 1)
                }
            } else if c == question {
                i = afterGreaterThan(b, from: next + 1)
            } else if c == slash {
                let nameStart = next + 1
                guard nameStart < n, isLetter(b[nameStart]) else {
                    i = afterGreaterThan(b, from: nameStart)
                    continue
                }
                let nameEnd = endOfName(b, from: nameStart)
                if nameEquals(b, nameStart, nameEnd, details), depth > 0 { depth -= 1 }
                i = endOfTag(b, from: nameEnd)
            } else if isLetter(c) {
                let nameEnd = endOfName(b, from: next)
                let tagEnd = endOfTag(b, from: nameEnd)
                if nameEquals(b, next, nameEnd, details) {
                    depth += 1
                    i = tagEnd
                } else if nameEquals(b, next, nameEnd, plaintext) {
                    break
                } else if let raw = rawTextNames.first(where: { nameEquals(b, next, nameEnd, $0) }) {
                    i = endOfRawText(b, from: tagEnd, name: raw)
                } else {
                    i = tagEnd
                }
            } else {
                i = next
            }
        }
        return depth
    }

    private static func endOfName(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var j = start
        while j < b.count, !isSpace(b[j]), b[j] != slash, b[j] != greaterThan { j += 1 }
        return j
    }

    private static func nameEquals(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ name: [UInt8]) -> Bool {
        guard end - start == name.count else { return false }
        for offset in 0..<name.count where lower(b[start + offset]) != name[offset] { return false }
        return true
    }

    /// The index after the next `>` at or after `start`, or the end.
    private static func afterGreaterThan(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var j = start
        while j < b.count {
            if b[j] == greaterThan { return j + 1 }
            j += 1
        }
        return b.count
    }

    /// The index after a comment whose `<!--` ends just before `start`.
    private static func endOfComment(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let n = b.count
        if start < n, b[start] == greaterThan { return start + 1 }
        if start + 1 < n, b[start] == dash, b[start + 1] == greaterThan { return start + 2 }
        var j = start
        while j + 2 < n {
            if b[j] == dash, b[j + 1] == dash {
                if b[j + 2] == greaterThan { return j + 3 }
                if b[j + 2] == bang, j + 3 < n, b[j + 3] == greaterThan { return j + 4 }
            }
            j += 1
        }
        return n
    }

    /// The index after the `>` that ends a start or end tag whose name ends just before `start`.
    /// A quoted attribute value may hold a `>`; a tag with no `>` swallows the rest.
    private static func endOfTag(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let n = b.count
        var j = start
        while j < n {
            let ch = b[j]
            if ch == greaterThan { return j + 1 }
            if isSpace(ch) || ch == slash {
                j += 1
                continue
            }
            // An attribute name; the first byte may be `=` or a quote.
            j += 1
            while j < n, !isSpace(b[j]), b[j] != slash, b[j] != greaterThan, b[j] != equals { j += 1 }
            var k = j
            while k < n, isSpace(b[k]) { k += 1 }
            guard k < n, b[k] == equals else { continue }
            k += 1
            while k < n, isSpace(b[k]) { k += 1 }
            guard k < n else { return n }
            if b[k] == doubleQuote || b[k] == singleQuote {
                let quote = b[k]
                k += 1
                while k < n, b[k] != quote { k += 1 }
                guard k < n else { return n }
                j = k + 1
            } else {
                while k < n, !isSpace(b[k]), b[k] != greaterThan { k += 1 }
                j = k
            }
        }
        return n
    }

    /// The index of the `<` of the first `</name` at or after `start` that ends like a tag name,
    /// or the end.
    private static func endOfRawText(_ b: UnsafeBufferPointer<UInt8>, from start: Int, name: [UInt8]) -> Int {
        let n = b.count
        var j = start
        while j + 1 < n {
            if b[j] == lessThan, b[j + 1] == slash {
                let nameStart = j + 2
                let nameEnd = nameStart + name.count
                if nameEnd < n, nameEquals(b, nameStart, nameEnd, name),
                   isSpace(b[nameEnd]) || b[nameEnd] == slash || b[nameEnd] == greaterThan {
                    return j
                }
            }
            j += 1
        }
        return n
    }
}

/// Where the groups of a container's children are (see `MarkdownRenderer`).
enum DetailsGrouping {
    /// The index ranges of the children that make up one group each, in order.
    ///
    /// `depths[i]` is how many `<details>` are open after child `i`: it changes only at an HTML
    /// block. A group is a maximal run `s…e` where none is open before `s` and all are closed
    /// after `e`, and some are open after every child in between. A run still open at the end of
    /// the container is not a group.
    static func groups(depthAfter depths: [Int]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var before = 0
        var start: Int?
        for (index, after) in depths.enumerated() {
            if before == 0, after > 0 { start = index }
            if after == 0, let s = start {
                result.append(s...index)
                start = nil
            }
            before = after
        }
        return result
    }
}
