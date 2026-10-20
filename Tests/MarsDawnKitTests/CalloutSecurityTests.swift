import Foundation
import Testing
@testable import MarsDawnKit

/// Kit #135: what an author can put in a callout reaches the page as escaped text and
/// nowhere else; the work grows linearly; nesting is capped.
struct CalloutSecurityTests {
    struct Element: Equatable {
        let name: String
        let attributes: [String: String]
    }

    /// Every start tag of `html`, read strictly: a `<` that does not begin a well-formed tag is a
    /// failure, so text that should have been escaped cannot hide as "not a tag".
    static func elements(_ html: String) throws -> [Element] {
        let bytes = Array(html.utf8)
        var found: [Element] = []
        var index = 0
        let tag = try Regex(#"^<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:\s+[a-zA-Z-]+="[^"<>]*")*)\s*>"#)
        let attribute = try Regex(#"([a-zA-Z-]+)="([^"]*)""#)
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            let rest = String(decoding: bytes[index...].prefix(400), as: UTF8.self)
            guard let match = rest.firstMatch(of: tag) else {
                throw MalformedTag(near: String(rest.prefix(80)))
            }
            if match.output[1].substring?.isEmpty ?? true {
                var attributes: [String: String] = [:]
                let text = String(match.output[3].substring ?? "")
                for pair in text.matches(of: attribute) {
                    attributes[String(pair.output[1].substring ?? "")] = String(pair.output[2].substring ?? "")
                }
                found.append(Element(name: String(match.output[2].substring ?? ""), attributes: attributes))
            }
            index += match.output[0].substring?.utf8.count ?? 1
        }
        return found
    }

    struct MalformedTag: Error, CustomStringConvertible {
        let near: String
        var description: String { "a `<` that is not a well-formed tag: \(near.debugDescription)" }
    }

    static let hostileTitles = [
        #"">< img src=x onerror=alert(1)>"#.replacingOccurrences(of: "< img", with: "<img"),
        "</p><script>alert(1)</script>",
        #"" onmouseover="alert(1)"#,
        "<svg/onload=alert(1)>",
        "&lt;b&gt; &amp; \u{202E}rtl",
    ]

    @Test(arguments: hostileTitles)
    func anAuthorTitleReachesThePageAsEscapedText(_ title: String) throws {
        for opening in [":::info", ":::danger", ":::spoiler"] {
            let html = MarkdownRenderer.render("\(opening) \(title)\n\nbody\n\n:::")
            let elements = try Self.elements(html)
            #expect(html.contains("callout") || html.contains("<details"), "positive fixture: \(opening) became a container")
            #expect(elements.map(\.name).allSatisfy { ["div", "p", "details", "summary"].contains($0) }, "\(opening) \(title): \(elements.map(\.name))")
            #expect(!html.contains("<script"), "\(opening) \(title)")
            #expect(!html.contains("<img"), "\(opening) \(title)")
            #expect(!html.contains("<svg"), "\(opening) \(title)")
        }
    }

    @Test func theTitleIsExactlyTheEscapedText() {
        let html = MarkdownRenderer.render(":::warning </p><script>\nx\n:::")
        #expect(html.contains(#"<p class="callout-title callout-title-author">&lt;/p&gt;&lt;script&gt;</p>"#), "\(html)")
        let quoted = MarkdownRenderer.render(#":::warning "><img src=x onerror=alert(1)>"# + "\nx\n:::")
        #expect(quoted.contains("&gt;&lt;img src=x onerror=alert(1)&gt;</p>"), "\(quoted)")
    }

    /// Every attribute of every element a callout writes comes from a fixed set.
    @Test func everyCalloutAttributeIsFromTheFixedSet() throws {
        let classes: Set<String> = [
            "callout callout-note", "callout callout-tip", "callout callout-important",
            "callout callout-warning", "callout callout-caution",
            "callout-title", "callout-title callout-title-author",
        ]
        var sources = Self.hostileTitles.flatMap { [":::info \($0)\nx\n:::", ":::spoiler \($0)\nx\n:::"] }
        sources += ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"].map { "> [!\($0)]\n> body" }
        sources += [":::success\n- a\n:::", ":::danger Title\n\n> [!TIP]\n> x\n\n:::"]
        var seen = 0
        for source in sources {
            for element in try Self.elements(MarkdownRenderer.render(source)) {
                switch element.name {
                case "div" where element.attributes["class"]?.hasPrefix("callout") == true:
                    seen += 1
                    #expect(Set(element.attributes.keys).isSubset(of: ["class", "data-line"]), "\(source.debugDescription): \(element)")
                    #expect(classes.contains(element.attributes["class"] ?? ""), "\(source.debugDescription): \(element)")
                    #expect(Int(element.attributes["data-line"] ?? "0") != nil, "\(source.debugDescription): \(element)")
                case "p" where element.attributes["class"]?.hasPrefix("callout-title") == true:
                    seen += 1
                    #expect(Set(element.attributes.keys) == ["class"], "\(source.debugDescription): \(element)")
                    #expect(classes.contains(element.attributes["class"] ?? ""), "\(source.debugDescription): \(element)")
                case "details":
                    seen += 1
                    #expect(Set(element.attributes.keys).isSubset(of: ["data-line"]), "no author-derived `open` or anything else: \(element)")
                case "summary":
                    #expect(element.attributes.isEmpty, "\(element)")
                default:
                    break
                }
            }
        }
        #expect(seen >= 30, "positive fixture: the walk saw the callout elements (\(seen))")
    }

    // MARK: Cost

    private static func seconds(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure(body)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// The best of a few runs, so one slow scheduling slice is not the measurement.
    private static func best(_ runs: Int = 3, _ body: () -> Void) -> Double {
        (0..<runs).map { _ in seconds(body) }.min() ?? 0
    }

    @Test func aMegabyteOfUnclosedOpenersTakesAsLongAsPlainText() {
        let line = ":::info\n"
        let openers = String(repeating: line, count: 1_048_576 / line.utf8.count)
        let plain = String(repeating: "plain!\n", count: 1_048_576 / 7)
        var result: MarkdownRenderer.RenderResult?
        let hostile = Self.best { result = MarkdownRenderer.renderResult(openers) }
        let baseline = Self.best { _ = MarkdownRenderer.renderResult(plain) }
        // Unclosed: nothing pairs, so it is one paragraph, as it always was.
        #expect(result?.fallback == nil)
        #expect(result?.html.hasPrefix("<p data-line=\"1\">:::info\n:::info") == true)
        #expect(hostile < 2 * baseline + 0.05, "openers \(hostile) s, plain \(baseline) s")
    }

    @Test func aMegabyteOfOpenersThenClosersTakesAsLongAsPlainText() {
        // Past the cap, everything pairs only at the depth the cap allows; the rest is literal.
        let pairs = 1_048_576 / 16
        let source = String(repeating: ":::info\n", count: pairs) + "x\n" + String(repeating: ":::\n", count: pairs)
        let plain = String(repeating: "plain!\n", count: source.utf8.count / 7)
        let hostile = Self.best { _ = MarkdownRenderer.renderResult(source) }
        let baseline = Self.best { _ = MarkdownRenderer.renderResult(plain) }
        #expect(hostile < 2 * baseline + 0.05, "nested \(hostile) s, plain \(baseline) s")
    }

    private static func nested(_ depth: Int) -> String {
        String(repeating: ":::info\n", count: depth) + "body\n" + String(repeating: ":::\n", count: depth)
    }

    private static func calloutCount(_ html: String) -> Int {
        html.components(separatedBy: #"<div class="callout callout-note""#).count - 1
    }

    @Test func nestingStopsAtTheCap() {
        #expect(Callouts.maxNesting == 8)
        let atCap = MarkdownRenderer.render(Self.nested(Callouts.maxNesting))
        #expect(Self.calloutCount(atCap) == Callouts.maxNesting)
        #expect(!atCap.contains(":::"))
        // One deeper: the innermost opener and its closer stay text, inside the eighth callout.
        let past = MarkdownRenderer.render(Self.nested(Callouts.maxNesting + 1))
        #expect(Self.calloutCount(past) == Callouts.maxNesting)
        #expect(past.contains("<p data-line=\"\(Callouts.maxNesting + 1)\">:::info\nbody\n:::</p>"), "\(past)")
    }

    @Test func twoHundredLevelsFinishAsFastAsPlainText() {
        let source = Self.nested(200)
        let plain = String(repeating: "plain!\n", count: source.utf8.count / 7)
        var html = ""
        let deep = Self.best { html = MarkdownRenderer.render(source) }
        let baseline = Self.best { _ = MarkdownRenderer.renderResult(plain) }
        #expect(Self.calloutCount(html) == Callouts.maxNesting)
        // Exactly 192 openers and as many closers stayed text.
        #expect(html.components(separatedBy: ":::info").count - 1 == 200 - Callouts.maxNesting)
        #expect(deep < 2 * baseline + 0.05, "200 deep \(deep) s, plain \(baseline) s")
    }
}
