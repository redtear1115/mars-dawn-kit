import Foundation
import Testing
@testable import MarsDawnKit

/// Scalars that a `Character` comparison can't see past, generated from the running Swift
/// runtime's grapheme rules rather than written down.
enum JoinerScalars {
    /// Every Unicode scalar (surrogates are not scalars and are skipped).
    static let all: [Unicode.Scalar] = (0...0x10FFFF).compactMap { Unicode.Scalar(UInt32($0)) }

    /// Joins the character after it into one `Character` (Prepend): `"\(s)<".count == 1`.
    static let before: [Unicode.Scalar] = all.filter { "\($0)<".count == 1 }

    /// Joins onto the character before it (Extend, SpacingMark, ZWJ): `"<\(s)".count == 1`.
    static let after: [Unicode.Scalar] = all.filter { "<\($0)".count == 1 }

    /// Every scalar the vectors are built from: what this runtime clusters, plus the named seeds,
    /// so a seed is still exercised if the runtime's grapheme data doesn't join it.
    static let both: [Unicode.Scalar] = Array(
        Set(before).union(after).union((prependSeeds + extendSeeds).map { scalar($0) })
    ).sorted { $0.value < $1.value }

    static func range(_ values: ClosedRange<UInt32>) -> [UInt32] { Array(values) }

    // Lists of parts, not one long `+` chain: Xcode 26's type checker gives up on the chain.
    static let prependSeeds: [UInt32] = ([
        range(0x0600...0x0605), [0x06DD, 0x070F], range(0x0890...0x0891), [0x08E2, 0x0D4E, 0x110BD, 0x110CD],
        range(0x111C2...0x111C3), [0x1193F, 0x11941, 0x11A3A], range(0x11A84...0x11A89), [0x11D46, 0x11F02],
    ] as [[UInt32]]).flatMap { $0 }

    static let extendSeeds: [UInt32] = ([
        [0x0301, 0x0300, 0x036F, 0x0591, 0x064B, 0x093C, 0x20DD, 0x20E3, 0x0488],  // Mn and Me samples
        [0x0903, 0x093E, 0x0BBF],  // Mc samples
        [0x200D, 0x200C, 0xFF9E, 0xFF9F], range(0xFE00...0xFE0F), [0xE0100],
        range(0xE0020...0xE007F), range(0x1F3FB...0x1F3FF),
    ] as [[UInt32]]).flatMap { $0 }

    static func scalar(_ value: UInt32) -> Unicode.Scalar { Unicode.Scalar(value)! }

    /// The characters HTML treats specially.
    static let specials: [Character] = ["<", ">", "&", "\"", "'"]
}

struct JoinerScalarSetTests {
    /// The seeds are Prepend in Unicode's data, but Swift's own grapheme data decides how they
    /// cluster at run time. Any this runtime doesn't join are named here rather than passed over,
    /// and `JoinerScalars.both` runs them through the escapers either way.
    @Test func prependSeedsJoinTheFollowingCharacter() {
        let before = Set(JoinerScalars.before)
        let notJoining = JoinerScalars.prependSeeds.filter { "\(JoinerScalars.scalar($0))<".count != 1 }
        #expect(notJoining == [0x11A3A], "this runtime's Prepend data changed: \(notJoining.map { String($0, radix: 16) })")
        for value in JoinerScalars.prependSeeds where !notJoining.contains(value) {
            #expect(before.contains(JoinerScalars.scalar(value)), "U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    @Test func extendSeedsJoinThePrecedingCharacter() {
        let after = Set(JoinerScalars.after)
        for value in JoinerScalars.extendSeeds {
            let s = JoinerScalars.scalar(value)
            #expect(after.contains(s), "U+\(String(value, radix: 16, uppercase: true)) should extend")
            for special in JoinerScalars.specials {
                #expect("\(special)\(s)".count == 1)
            }
        }
    }

    @Test func negativeControlsDoNotJoin() {
        let before = Set(JoinerScalars.before)
        let after = Set(JoinerScalars.after)
        // Regional indicators, CR/LF and Hangul jamo only join their own kind.
        let controls: [UInt32] = [0x1F1E6, 0x1F1FF, 0x0D, 0x0A, 0x1100, 0x1161, 0x11A8, 0xAC00, 0x41, 0x3C]
        for value in controls {
            let s = JoinerScalars.scalar(value)
            #expect(!before.contains(s) && !after.contains(s), "U+\(String(value, radix: 16, uppercase: true))")
        }
        #expect("\r\n".count == 1)  // the CRLF rule itself still holds
        #expect("\u{1F1E6}\u{1F1FA}".count == 1)
        #expect("\u{1100}\u{1161}\u{11A8}".count == 1)
    }

    @Test func generatedSetsAreSubstantial() {
        #expect(JoinerScalars.before.count >= JoinerScalars.prependSeeds.count)
        #expect(JoinerScalars.after.count > 2000)
    }
}

// MARK: - Output checks

enum MarkupCheck {
    static let entities = ["&amp;", "&lt;", "&gt;", "&quot;", "&#39;"]

    /// Whether every '&' in `bytes` starts one of the renderer's entities.
    static func ampersandsAreEntities(_ bytes: [UInt8]) -> Bool {
        func byte(_ index: Int) -> UInt8 { index < bytes.count ? bytes[index] : 0 }
        func isEntity(at index: Int) -> Bool {
            switch byte(index + 1) {
            case UInt8(ascii: "a"):
                byte(index + 2) == UInt8(ascii: "m") && byte(index + 3) == UInt8(ascii: "p")
                    && byte(index + 4) == UInt8(ascii: ";")
            case UInt8(ascii: "l"), UInt8(ascii: "g"):
                byte(index + 2) == UInt8(ascii: "t") && byte(index + 3) == UInt8(ascii: ";")
            case UInt8(ascii: "q"):
                byte(index + 2) == UInt8(ascii: "u") && byte(index + 3) == UInt8(ascii: "o")
                    && byte(index + 4) == UInt8(ascii: "t") && byte(index + 5) == UInt8(ascii: ";")
            case UInt8(ascii: "#"):
                byte(index + 2) == UInt8(ascii: "3") && byte(index + 3) == UInt8(ascii: "9")
                    && byte(index + 4) == UInt8(ascii: ";")
            default:
                false
            }
        }
        for index in bytes.indices where bytes[index] == UInt8(ascii: "&") {
            guard isEntity(at: index) else { return false }
        }
        return true
    }

    /// Turns the renderer's five entities back into their characters, on bytes.
    static func unescape(_ string: String) -> String {
        let bytes = Array(string.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        let table: [(String, UInt8)] = [
            ("&amp;", UInt8(ascii: "&")), ("&lt;", UInt8(ascii: "<")), ("&gt;", UInt8(ascii: ">")),
            ("&quot;", UInt8(ascii: "\"")), ("&#39;", UInt8(ascii: "'")),
        ]
        outer: while index < bytes.count {
            if bytes[index] == UInt8(ascii: "&") {
                for (entity, byte) in table where bytes[index...].starts(with: entity.utf8) {
                    out.append(byte)
                    index += entity.utf8.count
                    continue outer
                }
            }
            out.append(bytes[index])
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Tags and attributes the renderer writes itself.
    static let allowedTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "blockquote", "pre", "code", "div", "ul", "ol", "li",
        "input", "table", "thead", "tbody", "tr", "th", "td", "em", "strong", "del", "br", "a", "img",
    ]
    static let allowedAttributes: Set<String> = [
        "data-line", "id", "class", "start", "type", "disabled", "checked", "style", "href", "title", "src", "alt",
    ]

    /// Nil if `html` consists only of renderer-owned tags with well-formed, fully escaped
    /// attribute values, and text with no '>' and only known entities; else what went wrong.
    static func problem(in html: String) -> String? {
        let bytes = Array(html.utf8)
        guard ampersandsAreEntities(bytes) else { return "unknown entity" }
        var i = 0
        func isNameByte(_ b: UInt8) -> Bool {
            (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == UInt8(ascii: "-")
        }
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: ">"):
                // Text escaping leaves quotes alone (harmless outside a tag), but not '>'.
                return "stray '>' at byte \(i)"
            case UInt8(ascii: "<"):
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "/") { i += 1 }
                let nameStart = i
                while i < bytes.count, isNameByte(bytes[i]) { i += 1 }
                let name = String(decoding: bytes[nameStart..<i], as: UTF8.self)
                guard allowedTags.contains(name) else { return "tag <\(name)> at byte \(nameStart)" }
                // Attributes: ( ' ' name ( '="' value '"' )? )* '>'
                while true {
                    guard i < bytes.count else { return "unterminated tag <\(name)>" }
                    if bytes[i] == UInt8(ascii: ">") { i += 1; break }
                    guard bytes[i] == UInt8(ascii: " ") else { return "unexpected byte \(bytes[i]) in <\(name)>" }
                    i += 1
                    let attributeStart = i
                    while i < bytes.count, isNameByte(bytes[i]) { i += 1 }
                    let attribute = String(decoding: bytes[attributeStart..<i], as: UTF8.self)
                    guard allowedAttributes.contains(attribute) else { return "attribute \(attribute) in <\(name)>" }
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "=") else { continue }
                    i += 1
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { return "unquoted \(attribute)" }
                    i += 1
                    while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                        if bytes[i] == UInt8(ascii: "<") || bytes[i] == UInt8(ascii: ">") || bytes[i] == UInt8(ascii: "'") {
                            return "raw byte \(bytes[i]) in \(attribute)"
                        }
                        i += 1
                    }
                    guard i < bytes.count else { return "unterminated \(attribute)" }
                    i += 1
                }
            default:
                i += 1
            }
        }
        return nil
    }
}

// MARK: - Escapers

struct ScalarEscaperTests {
    /// What is wrong with the escaped forms of `input`, or nil. `roundTrip` also unescapes the
    /// results and compares them with the input; the batched sweep leaves that to the other tests.
    private func problem(escaping input: String, roundTrip: Bool = true) -> String? {
        let text = escapeHTML(input)
        let textBytes = Array(text.utf8)
        if textBytes.contains(0x3C) || textBytes.contains(0x3E) { return "raw '<' or '>' from escapeHTML" }
        if !MarkupCheck.ampersandsAreEntities(textBytes) { return "unknown entity from escapeHTML" }
        if roundTrip, MarkupCheck.unescape(text) != input { return "escapeHTML changed the text" }

        let attribute = escapeAttribute(input)
        let attributeBytes = Array(attribute.utf8)
        if attributeBytes.contains(0x3C) || attributeBytes.contains(0x3E) { return "raw '<' or '>' from escapeAttribute" }
        if attributeBytes.contains(0x22) || attributeBytes.contains(0x27) { return "raw quote from escapeAttribute" }
        if !MarkupCheck.ampersandsAreEntities(attributeBytes) { return "unknown entity from escapeAttribute" }
        if roundTrip, MarkupCheck.unescape(attribute) != input { return "escapeAttribute changed the text" }
        return nil
    }

    /// Each joining scalar, on its own, before and after each special character.
    @Test func joinersNeverHideASpecialCharacter() {
        for s in JoinerScalars.both {
            for c in JoinerScalars.specials {
                for input in ["\(s)\(c)x", "\(c)\(s)"] {
                    if let problem = problem(escaping: input) {
                        Issue.record("U+\(String(s.value, radix: 16, uppercase: true)) with \(c): \(problem)")
                    }
                }
            }
        }
    }

    /// Every scalar, in batches. Each pair is followed by "x", so a joiner can only join the
    /// special character it is paired with, as it would on its own.
    @Test func everyScalarNextToEverySpecialCharacterIsEscaped() {
        let specials = JoinerScalars.specials.map { Array($0.utf8)[0] }
        let x = UInt8(ascii: "x")
        let batchSize = 8192
        var index = 0
        var payload: [UInt8] = []
        while index < JoinerScalars.all.count {
            payload.removeAll(keepingCapacity: true)
            for s in JoinerScalars.all[index..<min(index + batchSize, JoinerScalars.all.count)] {
                var bytes: [UInt8] = []
                UTF8.encode(s) { bytes.append($0) }
                for c in specials {
                    payload += bytes
                    payload += [c, x, c]
                    payload += bytes
                    payload.append(x)
                }
            }
            if let problem = problem(escaping: String(decoding: payload, as: UTF8.self), roundTrip: false) {
                Issue.record("batch from U+\(String(JoinerScalars.all[index].value, radix: 16)): \(problem)")
            }
            index += batchSize
        }
    }

    @Test func entitySpellingsAreUnchanged() {
        #expect(escapeHTML(#"a&b<c>d"e'f"#) == #"a&amp;b&lt;c&gt;d"e'f"#)
        #expect(escapeAttribute(#"a&b<c>d"e'f"#) == "a&amp;b&lt;c&gt;d&quot;e&#39;f")
        #expect(escapeHTML("\u{600}<") == "\u{600}&lt;")
        #expect(escapeHTML(">\u{301}") == "&gt;\u{301}")
        #expect(escapeAttribute("\"\u{301}") == "&quot;\u{301}")
        #expect(escapeAttribute("'\u{200D}") == "&#39;\u{200D}")
        let plain = "Plain text, ünïcödé and 日本語 😀"
        #expect(escapeHTML(plain) == plain)
        #expect(escapeAttribute(plain) == plain)
    }
}

// MARK: - Renderer

struct ScalarRendererTests {
    /// Markdown for each sink, with `s` beside the special characters. No raw HTML.
    static func vectors(_ s: Unicode.Scalar) -> [String] {
        [
            // Text, where the special characters arrive as entities or can't start a tag.
            "\(s)&lt;link rel=dns-prefetch href=//x.tld&gt; &quot;\(s) &lt;\(s)b&gt;\(s) &amp;\(s)\n",
            "a \(s)< b <\(s)x> \(s)>\(s) \"\(s) '\(s)\n",
            // Code span, fence, mermaid.
            "`\(s)<link rel=dns-prefetch href=//x.tld>` `<\(s)b>\(s)` `>\(s)`\n",
            "```\n\(s)<link rel=dns-prefetch href=//x.tld>\n<\(s)b>\(s)\n```\n",
            "```mermaid\ngraph TD\n\(s)<b>\(s) --> B\n```\n",
            // Link titles and destinations.
            "[a](/u '\"\(s) onmouseover=x \(s)>') [b](/u \"'\(s)<\(s)\") [c](/u (\(s)\"\(s)>))\n",
            "[d](/x\(s)\"\(s)>) [e](<javascript:\(s)alert(1)>) [f](java\(s)script:x)\n",
            // Image alt and title.
            "![\(s)\"<\(s)>\(s)'](/i.png '\"\(s)>\(s)<')\n",
            "![&quot;\(s)&gt;\(s)](data:image/svg\(s)+xml,x)\n",
            // Heading ids.
            "# \(s)\"<\(s)>\(s)&'\(s)\n",
            "## a\(s)\"b\(s)>c <\(s)d\n",
            // Code-fence language (class attribute).
            "```c\(s)\"><\(s)'x\n\(s)\n```\n",
            "```\(s)\"\(s)>\n\n```\n",
            // Symbol-link syntax (a code span unless symbol links are parsed).
            "``x\(s)<y\(s)>``\n",
            // Tables and lists.
            "| \(s)&lt;\(s) | `<\(s)` |\n|--|--|\n| \(s)\" | >\(s) |\n\n- [x] \(s)&lt;\n",
        ]
    }

    private func check(_ markdown: String, _ label: @autoclosure () -> String) {
        let html = MarkdownRenderer.render(markdown)
        if let problem = MarkupCheck.problem(in: html) {
            Issue.record("\(label()): \(problem)\n\(html)")
        }
    }

    @Test func joinersDoNotBreakOutOfAnySink() {
        for s in JoinerScalars.both {
            for (index, markdown) in Self.vectors(s).enumerated() {
                check(markdown, "U+\(String(s.value, radix: 16, uppercase: true)) vector \(index)")
            }
        }
    }

    @Test func sampleOfAllScalarsDoesNotBreakOut() {
        // Every 97th scalar, so each block and plane is visited without rendering 1.1M documents.
        for s in stride(from: 0, to: JoinerScalars.all.count, by: 97).map({ JoinerScalars.all[$0] })
        where !CharacterSet.controlCharacters.contains(s) && s.value > 0x7F {
            for (index, markdown) in Self.vectors(s).enumerated() {
                check(markdown, "U+\(String(s.value, radix: 16, uppercase: true)) vector \(index)")
            }
        }
    }

    /// The confirmed report: a Prepend scalar hid `<` in a code span.
    @Test func prependBeforeLessThanInCodeSpanIsEscaped() {
        let html = MarkdownRenderer.render("`\u{0600}<link rel=dns-prefetch href=//x.tld>`")
        #expect(html == "<p data-line=\"1\"><code>\u{0600}&lt;link rel=dns-prefetch href=//x.tld&gt;</code></p>\n")
    }

    @Test func combiningMarkAfterQuoteCantLeaveTheTitle() {
        let html = MarkdownRenderer.render("[a](/u '\"\u{301} onmouseover=alert(1) x=\u{301}>')")
        #expect(html == "<p data-line=\"1\"><a href=\"/u\" title=\"&quot;\u{301} onmouseover=alert(1) x=\u{301}&gt;\">a</a></p>\n")
    }

    /// U+0D4E is a letter, so `slugify` and the code-language filter (both still `Character`-based,
    /// see the P4 note in the hotfix) keep its cluster — quote and all — in an attribute value.
    @Test func prependLetterInHeadingIdAndFenceLanguageIsEscaped() {
        // In headings the quote is smart punctuation by the time it reaches the slug, but '<'
        // and '>' are not, and the id must still be a well-formed attribute value.
        let heading = MarkdownRenderer.render("# a\u{0D4E}\"><b\n")
        #expect(heading == "<h1 id=\"a\u{0D4E}\u{201D}b\" data-line=\"1\">a\u{0D4E}\u{201D}&gt;&lt;b</h1>\n", "\(heading)")
        #expect(MarkupCheck.problem(in: heading) == nil)

        // An info string is literal, so the quote reaches the class attribute as a quote.
        let fence = MarkdownRenderer.render("```c\u{0D4E}\"x\nbody\n```\n")
        #expect(fence.contains("<code class=\"language-c\u{0D4E}&quot;x\">"), "\(fence)")
        #expect(MarkupCheck.problem(in: fence) == nil)
    }

    @Test func entityInTextStaysEscapedWithAJoiner() {
        let html = MarkdownRenderer.render("\u{0600}&lt;img src=x onerror=alert(1)&gt;")
        #expect(html == "<p data-line=\"1\">\u{0600}&lt;img src=x onerror=alert(1)&gt;</p>\n")
    }

    // MARK: Fuzz

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Markdown pieces that can't form raw HTML: every '<' is followed by a space or a
    /// non-ASCII joiner, and there is no '!', '?' or '/' after one.
    static func fuzzDocument(_ rng: inout SplitMix64) -> String {
        let joiners = JoinerScalars.both
        let pieces = [
            "# ", "## ", "\n", "\n\n", " ", "a", "Z9", "é", "日", "😀", "\"", "'", ">", "&", "&lt;", "&gt;",
            "&quot;", "&amp;", "&#39;", "&#60;", "`", "``", "\n```\n", "\n```c", "\n```mermaid\n", "[", "](", ")",
            "![", " '", " \"", "*", "_", "~~", "- ", "1. ", "> ", "|", "\n|-|-|\n", "- [x] ", "\\", "(", "=",
            ":", "javascript:", "data:image/svg", "http:", "#", "\t",
        ]
        var document = ""
        for _ in 0..<Int.random(in: 1...60, using: &rng) {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...2: document.unicodeScalars.append(joiners.randomElement(using: &rng)!)
            case 3: document += Bool.random(using: &rng) ? "< " : "<"; document.unicodeScalars.append(joiners.randomElement(using: &rng)!)
            default: document += pieces.randomElement(using: &rng)!
            }
        }
        return document
    }

    @Test(arguments: [UInt64(0x5EED), UInt64.random(in: 1...UInt64.max)])
    func fuzzedDocumentsStayWellFormed(seed: UInt64) {
        var rng = SplitMix64(state: seed)
        for iteration in 0..<3000 {
            let markdown = Self.fuzzDocument(&rng)
            // '<' plus a joiner can still be the start of a line that cmark reads as HTML only if
            // an ASCII letter follows '<', which the generator never writes.
            check(markdown, "seed \(seed) iteration \(iteration): \(markdown.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }
}

// MARK: - URLs

struct ScalarURLTests {
    @Test func javascriptFollowedByAJoinerIsBlocked() {
        for s in JoinerScalars.both {
            let label = "U+\(String(s.value, radix: 16, uppercase: true))"
            #expect(sanitizedURL("javascript:\(s)alert(1)", allowData: false) == "#", "\(label)")
            #expect(sanitizedURL("javascript:\(s)alert(1)", allowData: true) == "#", "\(label)")
            #expect(sanitizedURL("JavaScript\(s):alert(1)", allowData: false) == "#", "\(label)")
            #expect(sanitizedURL("java\(s)script:alert(1)", allowData: false) == "#", "\(label)")
            #expect(sanitizedURL("\(s)javascript:alert(1)", allowData: false) == "#", "\(label)")
            #expect(sanitizedURL("data:image/svg\(s)+xml,<svg>", allowData: true) == "#", "\(label)")
            #expect(sanitizedURL("data:\(s)text/html,x", allowData: true) == "#", "\(label)")
            // The asset mapping sees the same scheme and leaves the source to the sanitizer.
            #expect(DocumentAssetSchemeHandler.previewURL(forImageSource: "javascript:\(s)x", hasBaseDirectory: true) == nil, "\(label)")
        }
    }

    @Test func joinerAfterAPathCharacterIsStillRelative() {
        #expect(sanitizedURL("docs/\u{301}a:b.md", allowData: false) == "docs/\u{301}a:b.md")
        #expect(sanitizedURL("?\u{301}q=a:b", allowData: false) == "?\u{301}q=a:b")
    }

    /// The decisions from before this change, for every case the existing tests cover.
    @Test func existingDecisionsAreUnchanged() {
        let cases: [(String, Bool, String)] = [
            ("javascript:alert(1)", false, "#"),
            ("java\tscript:alert(1)", false, "#"),
            ("JAVA\nSCRIPT:alert(1)", false, "#"),
            ("file:///etc/passwd", true, "#"),
            ("x-custom:thing", false, "#"),
            ("mailto:a@b.c", false, "mailto:a@b.c"),
            ("#heading", false, "#heading"),
            ("docs/a:b.md", false, "docs/a:b.md"),
            ("data:image/svg+xml,abc", true, "#"),
            ("DATA:IMAGE/SVG+XML,abc", true, "#"),
            ("data:image/png;base64,AA", true, "data:image/png;base64,AA"),
            ("Data:Image/PNG;base64,AA", true, "Data:Image/PNG;base64,AA"),
            ("data:image/png;base64,AA", false, "#"),
            ("data:text/html,x", true, "#"),
            ("https://example.com", false, "https://example.com"),
            ("HTTP://example.com", false, "HTTP://example.com"),
            ("  https://example.com  ", false, "https://example.com"),
            ("marsdawn-asset://doc/a.png", true, "marsdawn-asset://doc/a.png"),
            ("img/a.png", true, "img/a.png"),
            (":nothing", false, "#"),
            ("1http:x", false, "#"),
            ("ht tp:x", false, "#"),
            ("é:x", false, "#"),
            ("", false, ""),
        ]
        for (input, allowData, expected) in cases {
            #expect(sanitizedURL(input, allowData: allowData) == expected, "\(input)")
        }
    }
}

