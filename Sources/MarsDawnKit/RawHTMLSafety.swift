import Foundation

/// Tags that raw HTML may not create for real; they are renamed with an `x-md-` prefix.
///
/// - `link`: `rel=dns-prefetch` or `rel=preconnect` opens a connection that the page's CSP
///   doesn't stop.
/// - `iframe`, `frame`, `object`, `embed`, `portal`, `fencedframe`: they create nested documents
///   (an `<iframe srcdoc>` can hold an entity-encoded `<link>` that this rename can't see).
///
/// The content rule lists stop a preconnect too; for dns-prefetch that is unverified (see
/// `PreviewContentRules`), so this rename, with preview.js's element filter behind it, is the
/// guard for that case rather than a second layer.
let neutralizedRawHTMLTags = ["link", "iframe", "frame", "object", "embed", "portal", "fencedframe"]

/// Renames the start and end tags in `neutralizedRawHTMLTags` in raw HTML, e.g. `<iframe` to
/// `<x-md-iframe` and `</LINK` to `</x-md-link`.
///
/// The match is on the tag name as the HTML tokenizer ends it (whitespace, `/` or `>`), in any
/// case, so longer names such as `<frameset>` or `<objective>` are left alone. Attributes are not
/// parsed and other HTML is left alone. (The name predates the tags other than `link`.)
func neutralizingLinkTags(_ html: String) -> String {
    // Quick skip on bytes: every match starts with '<'. (A String search here would be
    // grapheme-aware and could miss a tag name that a combining mark has joined to its
    // neighbour.) The pattern itself matches UTF-16 code units, not graphemes.
    guard html.utf8.contains(UInt8(ascii: "<")) else { return html }
    let source = html as NSString
    let matches = neutralizedTagPattern.matches(in: html, range: NSRange(location: 0, length: source.length))
    guard !matches.isEmpty else { return html }
    var result = ""
    var copied = 0
    for match in matches {
        let slash = source.substring(with: match.range(at: 1))
        let name = source.substring(with: match.range(at: 2)).lowercased()
        result += source.substring(with: NSRange(location: copied, length: match.range.location - copied))
        result += "<\(slash)x-md-\(name)"
        copied = match.range.location + match.range.length
    }
    result += source.substring(from: copied)
    return result
}

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


// MARK: Remote references

/// Whether an HTML document references content on the web (`http:`, `https:`, `ws:`, `wss:` or
/// protocol-relative URLs) in URL attributes or CSS. For the remote-content banner only; the
/// CSP and the content rule lists are the controls.
///
/// Whether the document might run something: a `<script` element, or an inline event-handler
/// attribute (`onclick=`, `onload=`, …).
///
/// **For the affordance and the copy only. Never a control.** The CSP, the content rule list and
/// the page sandbox decide what a document may do, and none of them consults this. A false
/// negative costs a reader the offer to run a document, which then stays static — no security
/// consequence. A false positive shows a bar that needn't have been there.
///
/// Like `referencesRemoteContent` before it, this over-reports rather than under-reports: it
/// doesn't track quoting or comments, so `<script` inside a comment or a string counts.
func mightRunScript(_ html: String) -> Bool {
    let bytes = Array(html.utf8)
    var index = 0
    while index < bytes.count {
        if bytes[index] == UInt8(ascii: "<"), htmlTagName(scriptTagName, matches: bytes, at: index + 1) {
            return true
        }
        // An event-handler attribute: `on` + letters + `=`, not part of a longer word.
        if asciiLowercased(bytes[index]) == UInt8(ascii: "o"), isEventHandlerAttribute(bytes, at: index) {
            return true
        }
        index += 1
    }
    return false
}

/// Whether the document asks for code from the web: a `<script` element whose `src` is a remote
/// URL. **Copy only, never a control** — the CSP refuses remote script whatever this says. It is
/// what lets the bar explain a refusal instead of leaving a page silently half-working (D-1c).
///
/// Its blind spot is stated rather than discovered: script added at run time that fetches further
/// script is refused by the CSP and produces no line here, because nothing scanned it. The
/// refusal still happens; only the explanation is missing.
func asksForRemoteScript(_ html: String) -> Bool {
    let bytes = Array(html.utf8)
    var index = 0
    while index < bytes.count {
        guard bytes[index] == UInt8(ascii: "<"), htmlTagName(scriptTagName, matches: bytes, at: index + 1) else {
            index += 1
            continue
        }
        // Inside this tag, up to the closing `>`: an `src` attribute with a remote value.
        var cursor = index + 1 + scriptTagName.count
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: ">") {
            if asciiLowercased(bytes[cursor]) == UInt8(ascii: "s"),
               isSourceAttribute(bytes, at: cursor),
               let value = attributeValueStart(bytes, after: cursor + srcAttributeName.count),
               isRemoteURL(bytes, at: value, afterOptionalQuote: true) {
                return true
            }
            cursor += 1
        }
        index = cursor
    }
    return false
}

private let scriptTagName = Array("script".utf8)
private let srcAttributeName = Array("src".utf8)
private let eventHandlerPrefix = Array("on".utf8)

/// `on` + at least one ASCII letter + `=`, with a non-word byte before it so `button-onclick=`
/// isn't one.
private func isEventHandlerAttribute(_ bytes: [UInt8], at start: Int) -> Bool {
    guard matchesLiteral(bytes, at: start, eventHandlerPrefix) else { return false }
    if start > 0, isRemoteScanWordByte(bytes[start - 1]) { return false }
    var index = start + eventHandlerPrefix.count
    var letters = 0
    while index < bytes.count, asciiLowercased(bytes[index]) >= UInt8(ascii: "a"),
          asciiLowercased(bytes[index]) <= UInt8(ascii: "z") {
        letters += 1
        index += 1
    }
    guard letters > 0 else { return false }
    index = skipRemoteScanWhitespace(bytes, from: index)
    return index < bytes.count && bytes[index] == UInt8(ascii: "=")
}

/// A whole `src` attribute name, not the tail of a longer one.
private func isSourceAttribute(_ bytes: [UInt8], at start: Int) -> Bool {
    guard matchesLiteral(bytes, at: start, srcAttributeName) else { return false }
    if start > 0, isRemoteScanWordByte(bytes[start - 1]) { return false }
    let after = skipRemoteScanWhitespace(bytes, from: start + srcAttributeName.count)
    return after < bytes.count && bytes[after] == UInt8(ascii: "=")
}

/// The first byte of an attribute's value, given the position just past its name.
private func attributeValueStart(_ bytes: [UInt8], after nameEnd: Int) -> Int? {
    var index = skipRemoteScanWhitespace(bytes, from: nameEnd)
    guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { return nil }
    index = skipRemoteScanWhitespace(bytes, from: index + 1)
    return index < bytes.count ? index : nil
}


/// The attributes whose value is a URL (or a list of them).
private let remoteURLAttributeNames: [[UInt8]] = [
    "src", "srcset", "href", "poster", "data", "background", "action", "ping", "imagesrcset",
].map { Array($0.utf8) }

private let urlLiteral = Array("url".utf8)
private let imageSetLiteral = Array("image-set".utf8)
private let importLiteral = Array("import".utf8)
private let urlOpenLiteral = Array("url(".utf8)
private let httpLiteral = Array("http".utf8)
private let wsLiteral = Array("ws".utf8)

/// `[A-Za-z0-9_-]`: what the pattern this replaced wouldn't let an attribute name follow, so
/// `data-src` isn't `data` and `imagesrc` isn't `src`. Bytes over 0x7F are not word bytes.
private func isRemoteScanWordByte(_ byte: UInt8) -> Bool {
    (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
        || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
}

/// `\s`: space, tab, line feed, vertical tab, form feed and carriage return.
private func isRemoteScanWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || (0x09...0x0D).contains(byte)
}

private func skipRemoteScanWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
    var index = start
    while index < bytes.count, isRemoteScanWhitespace(bytes[index]) { index += 1 }
    return index
}

/// Whether `bytes` holds the lowercase `literal` at `start`, ASCII case ignored. A start outside
/// the input is no match rather than an error.
private func matchesLiteral(_ bytes: [UInt8], at start: Int, _ literal: [UInt8]) -> Bool {
    guard start >= 0, start + literal.count <= bytes.count else { return false }
    for offset in 0..<literal.count where asciiLowercased(bytes[start + offset]) != literal[offset] {
        return false
    }
    return true
}

private func isRemoteURLAttributeName(_ bytes: [UInt8], from start: Int, to end: Int) -> Bool {
    for name in remoteURLAttributeNames where name.count == end - start {
        if matchesLiteral(bytes, at: start, name) { return true }
    }
    return false
}

/// `https?:`, `wss?:`, or two bytes each of which is `/` or `\` (a protocol-relative URL, and
/// the backslash spelling a browser normalises to one).
///
/// This runs for most bytes of an attribute value, so it rejects on the first one.
private func isRemoteURLStart(_ bytes: [UInt8], at index: Int) -> Bool {
    guard index >= 0, index < bytes.count else { return false }
    switch asciiLowercased(bytes[index]) {
    case UInt8(ascii: "/"), UInt8(ascii: "\\"):
        guard index + 1 < bytes.count else { return false }
        let next = bytes[index + 1]
        return next == UInt8(ascii: "/") || next == UInt8(ascii: "\\")
    case UInt8(ascii: "h"):
        return isRemoteURLScheme(bytes, at: index, httpLiteral)
    case UInt8(ascii: "w"):
        return isRemoteURLScheme(bytes, at: index, wsLiteral)
    default:
        return false
    }
}

/// `scheme` then an optional `s` then `:`.
private func isRemoteURLScheme(_ bytes: [UInt8], at index: Int, _ scheme: [UInt8]) -> Bool {
    guard matchesLiteral(bytes, at: index, scheme) else { return false }
    var end = index + scheme.count
    if end < bytes.count, asciiLowercased(bytes[end]) == UInt8(ascii: "s") { end += 1 }
    return end < bytes.count && bytes[end] == UInt8(ascii: ":")
}

/// `\s*`, then at most one quote and `\s*` when `afterOptionalQuote`, then a remote URL.
///
/// Each whitespace run it walks starts right after the byte it was called for, and a run has one
/// such byte, so the walks over a document add up to its length.
private func isRemoteURL(_ bytes: [UInt8], at start: Int, afterOptionalQuote: Bool) -> Bool {
    var index = skipRemoteScanWhitespace(bytes, from: start)
    if afterOptionalQuote, index < bytes.count,
       bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
        index = skipRemoteScanWhitespace(bytes, from: index + 1)
    }
    return isRemoteURLStart(bytes, at: index)
}

/// `@import`, whitespace, an optional `url(` and whitespace, then a remote URL. `index` is the `@`.
private func isRemoteImport(_ bytes: [UInt8], at index: Int) -> Bool {
    guard matchesLiteral(bytes, at: index + 1, importLiteral) else { return false }
    var cursor = index + 1 + importLiteral.count
    guard cursor < bytes.count, isRemoteScanWhitespace(bytes[cursor]) else { return false }
    cursor = skipRemoteScanWhitespace(bytes, from: cursor)
    if matchesLiteral(bytes, at: cursor, urlOpenLiteral) {
        cursor = skipRemoteScanWhitespace(bytes, from: cursor + urlOpenLiteral.count)
    }
    return isRemoteURL(bytes, at: cursor, afterOptionalQuote: true)
}
