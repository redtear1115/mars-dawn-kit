import Foundation

/// Tags that raw HTML may not create for real; they are renamed with an `x-md-` prefix.
///
/// - `link`: `rel=dns-prefetch` or `rel=preconnect` opens a connection that the page's CSP
///   doesn't stop.
/// - `iframe`, `frame`, `object`, `embed`, `portal`, `fencedframe`: they create nested documents
///   (an `<iframe srcdoc>` can hold an entity-encoded `<link>` that this rename can't see).
///
/// The content rule lists block these connections too; this is a second layer.
let neutralizedRawHTMLTags = ["link", "iframe", "frame", "object", "embed", "portal", "fencedframe"]

/// Renames the start and end tags in `neutralizedRawHTMLTags` in raw HTML, e.g. `<iframe` to
/// `<x-md-iframe` and `</LINK` to `</x-md-link`.
///
/// The match is on the tag name as the HTML tokenizer ends it (whitespace, `/` or `>`), in any
/// case, so longer names such as `<frameset>` or `<objective>` are left alone. Attributes are not
/// parsed and other HTML is left alone. (The name predates the tags other than `link`.)
func neutralizingLinkTags(_ html: String) -> String {
    guard neutralizedTagHints.contains(where: { html.range(of: $0, options: .caseInsensitive) != nil }) else {
        return html
    }
    let source = html as NSString
    var result = ""
    var copied = 0
    for match in neutralizedTagPattern.matches(in: html, range: NSRange(location: 0, length: source.length)) {
        let slash = source.substring(with: match.range(at: 1))
        let name = source.substring(with: match.range(at: 2)).lowercased()
        result += source.substring(with: NSRange(location: copied, length: match.range.location - copied))
        result += "<\(slash)x-md-\(name)"
        copied = match.range.location + match.range.length
    }
    result += source.substring(from: copied)
    return result
}

/// Every neutralized tag name contains one of these, for a quick skip.
private let neutralizedTagHints = ["link", "frame", "object", "embed", "portal"]

// Tag names end at tab, line feed, form feed, carriage return (normalised to a line feed), space, '/' or '>'.
private let neutralizedTagPattern = try! NSRegularExpression(
    pattern: #"<(/?)("# + neutralizedRawHTMLTags.joined(separator: "|") + #")(?=[\t\n\f\r />])"#,
    options: [.caseInsensitive]
)

// MARK: HTML documents

/// Renames the tags in `neutralizedRawHTMLTags` in a whole HTML document, like
/// `neutralizingLinkTags`, except that a `<link` start tag is kept when it has exactly one `rel`
/// attribute whose value is exactly `stylesheet` (HTML whitespace trimmed, ASCII case ignored).
///
/// The attributes are read in one forward pass with the HTML tokenizer's rules (an unquoted
/// value ends at whitespace or `>` and includes `/`; a name may start with `=`, `"` or `'`; a
/// quoted value may contain `>`). Values are compared as bytes; character references aren't
/// decoded, so an encoded `rel` isn't `stylesheet`.
///
/// Fails closed: an unterminated tag, a duplicate `rel`, or any `<` inside the tag renames it.
/// The scan doesn't know whether the tag sits in a comment or a raw-text element, so a kept
/// tag must not be able to hide markup; refusing `<` inside it ensures that, and keeps the pass
/// linear, because a tag's scan never goes past the next `<`.
func neutralizingHTMLDocumentTags(_ html: String) -> String {
    let input = Array(html.utf8)
    let lessThan = UInt8(ascii: "<"), slash = UInt8(ascii: "/")
    let names = neutralizedRawHTMLTags.map { Array($0.utf8) }
    var output: [UInt8] = []
    output.reserveCapacity(input.count + 64)
    var copied = 0
    var index = 0
    while index < input.count {
        guard input[index] == lessThan else {
            index += 1
            continue
        }
        let tagStart = index
        var nameStart = index + 1
        let isEndTag = nameStart < input.count && input[nameStart] == slash
        if isEndTag { nameStart += 1 }
        guard let name = names.first(where: { htmlTagName($0, matches: input, at: nameStart) }) else {
            index += 1
            continue
        }
        let nameEnd = nameStart + name.count
        if !isEndTag, name == Array("link".utf8), let tagEnd = endOfKeptStylesheetLink(input, from: nameEnd) {
            index = tagEnd
            continue
        }
        output.append(contentsOf: input[copied..<tagStart])
        output.append(lessThan)
        if isEndTag { output.append(slash) }
        output.append(contentsOf: Array("x-md-".utf8))
        output.append(contentsOf: name)
        copied = nameEnd
        index = nameEnd
    }
    output.append(contentsOf: input[copied...])
    return String(decoding: output, as: UTF8.self)
}

/// HTML whitespace: tab, line feed, form feed, carriage return and space.
private func isHTMLWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
}

/// Whether `input` has the lowercase tag `name` at `start` (ASCII case ignored), ended the way
/// the tokenizer ends a tag name (whitespace, `/` or `>`).
private func htmlTagName(_ name: [UInt8], matches input: [UInt8], at start: Int) -> Bool {
    let end = start + name.count
    guard end < input.count else { return false }
    for offset in 0..<name.count {
        var byte = input[start + offset]
        if (0x41...0x5A).contains(byte) { byte += 0x20 }
        guard byte == name[offset] else { return false }
    }
    let next = input[end]
    return isHTMLWhitespace(next) || next == UInt8(ascii: "/") || next == UInt8(ascii: ">")
}

/// Reads a `<link` tag's attributes from just after its name. Returns the index after its `>`
/// if the tag is kept (exactly one `rel`, equal to `stylesheet`), or nil to rename it.
private func endOfKeptStylesheetLink(_ input: [UInt8], from start: Int) -> Int? {
    enum State {
        case beforeName, name, afterName, beforeValue, doubleQuoted, singleQuoted, unquoted, afterQuoted, selfClosing
    }
    let equals = UInt8(ascii: "="), slash = UInt8(ascii: "/"), greaterThan = UInt8(ascii: ">")
    let doubleQuote = UInt8(ascii: "\""), singleQuote = UInt8(ascii: "'")
    let rel = Array("rel".utf8), stylesheet = Array("stylesheet".utf8)

    var state = State.beforeName
    var name: [UInt8] = []
    var value: [UInt8] = []
    var hasAttribute = false
    var relCount = 0
    var relIsStylesheet = false

    func finishAttribute() {
        guard hasAttribute else { return }
        if name == rel {
            relCount += 1
            var trimmed = value[...]
            while let first = trimmed.first, isHTMLWhitespace(first) { trimmed.removeFirst() }
            while let last = trimmed.last, isHTMLWhitespace(last) { trimmed.removeLast() }
            relIsStylesheet = trimmed.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 } == stylesheet
        }
        hasAttribute = false
        name = []
        value = []
    }

    func startAttribute() {
        finishAttribute()
        hasAttribute = true
    }

    var index = start
    while index < input.count {
        let byte = input[index]
        // Doubt: this tag might not be a tag at all (comment, raw text), and a `<` could start one.
        guard byte != UInt8(ascii: "<") else { return nil }
        var consumed = true
        switch state {
        case .beforeName:
            if isHTMLWhitespace(byte) {
            } else if byte == slash {
                state = .selfClosing
            } else if byte == greaterThan {
                finishAttribute()
                return relCount == 1 && relIsStylesheet ? index + 1 : nil
            } else if byte == equals {
                startAttribute()
                name = [equals]
                state = .name
            } else {
                startAttribute()
                state = .name
                consumed = false
            }
        case .name:
            if isHTMLWhitespace(byte) || byte == slash || byte == greaterThan {
                state = .afterName
                consumed = false
            } else if byte == equals {
                state = .beforeValue
            } else {
                name.append((0x41...0x5A).contains(byte) ? byte + 0x20 : byte)
            }
        case .afterName:
            if isHTMLWhitespace(byte) {
            } else if byte == slash {
                finishAttribute()
                state = .selfClosing
            } else if byte == equals {
                state = .beforeValue
            } else if byte == greaterThan {
                finishAttribute()
                return relCount == 1 && relIsStylesheet ? index + 1 : nil
            } else {
                startAttribute()
                state = .name
                consumed = false
            }
        case .beforeValue:
            if isHTMLWhitespace(byte) {
            } else if byte == doubleQuote {
                state = .doubleQuoted
            } else if byte == singleQuote {
                state = .singleQuoted
            } else if byte == greaterThan {
                finishAttribute()
                return relCount == 1 && relIsStylesheet ? index + 1 : nil
            } else {
                state = .unquoted
                consumed = false
            }
        case .doubleQuoted, .singleQuoted:
            if byte == (state == .doubleQuoted ? doubleQuote : singleQuote) {
                finishAttribute()
                state = .afterQuoted
            } else {
                value.append(byte)
            }
        case .unquoted:
            if isHTMLWhitespace(byte) {
                finishAttribute()
                state = .beforeName
            } else if byte == greaterThan {
                finishAttribute()
                return relCount == 1 && relIsStylesheet ? index + 1 : nil
            } else {
                value.append(byte)
            }
        case .afterQuoted:
            if isHTMLWhitespace(byte) {
                state = .beforeName
            } else if byte == slash {
                state = .selfClosing
            } else if byte == greaterThan {
                return relCount == 1 && relIsStylesheet ? index + 1 : nil
            } else {
                state = .beforeName
                consumed = false
            }
        case .selfClosing:
            if byte == greaterThan {
                finishAttribute()
                return relCount == 1 && relIsStylesheet ? index + 1 : nil
            }
            state = .beforeName
            consumed = false
        }
        if consumed { index += 1 }
    }
    // Unterminated: the tokenizer drops the tag and everything after it is inside it.
    return nil
}

/// Whether an HTML document references content on the web (`http:`, `https:`, `ws:`, `wss:` or
/// protocol-relative URLs) in URL attributes or CSS. For the remote-content banner only; the
/// CSP and the content rule lists are the controls.
func referencesRemoteContent(_ html: String) -> Bool {
    let range = NSRange(location: 0, length: (html as NSString).length)
    for match in remoteAttributePattern.matches(in: html, range: range) {
        for group in 1...3 {
            let valueRange = match.range(at: group)
            guard valueRange.location != NSNotFound else { continue }
            let value = (html as NSString).substring(with: valueRange)
            if remoteURLInValuePattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil {
                return true
            }
        }
    }
    return remoteCSSPattern.firstMatch(in: html, range: range) != nil
}

private let remoteURLStart = #"(?:https?:|wss?:|[\\/]{2})"#

private let remoteAttributePattern = try! NSRegularExpression(
    pattern: #"(?<![\w-])(?:src|srcset|href|poster|data|background|action|ping|imagesrcset)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#,
    options: [.caseInsensitive]
)

/// A URL at the start of a value or after a space or comma (srcset, ping).
private let remoteURLInValuePattern = try! NSRegularExpression(
    pattern: #"(?:^|[\s,])\s*"# + remoteURLStart,
    options: [.caseInsensitive]
)

private let remoteCSSPattern = try! NSRegularExpression(
    pattern: #"(?:url\(\s*["']?\s*"# + remoteURLStart + #"|image-set\([^;{}]*?["'(]\s*"# + remoteURLStart
        + #"|@import\s+(?:url\(\s*)?["']?\s*"# + remoteURLStart + ")",
    options: [.caseInsensitive]
)
