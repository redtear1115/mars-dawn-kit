import Foundation
import Testing
@testable import MarsDawnKit

struct RevealRequestTests {
    // MARK: Validation

    @Test(arguments: [
        "/Users/me/My Docs/a&b#c%d+e=f?g.md",
        "/Users/me/筆記/中文 檔案.md",
        "/tmp/😀 notes.md",
        "/a;b/c,d/'e'/\"f\"/[g]/~h.md",
        "/a/.hidden/..b/c..md",
        "/a",
    ])
    func validPathsAreKeptVerbatim(path: String) {
        let request = RevealRequest(path: path, line: 42)
        #expect(request?.path == path)
        #expect(request?.line == 42)
    }

    @Test(arguments: [
        "", "a.md", "./a.md", "~/a.md", "/a/../b.md", "/..", "/a/..", "/a/./b.md", "/.", "/a//b.md", "//a.md",
        "/a/", "/", "/a\0b.md", "/a\nb.md", "/a\rb.md", "/a\r\nb.md", "/a\tb.md", "/a\u{7F}b.md", "/a\u{85}b.md",
        "/a\u{9F}b.md",
        // A combining mark or variation selector after `/` must not hide the segment.
        "/a/b/../\u{301}c", "/a/./\u{301}c", "/a//\u{301}c", "/a/../\u{FE0F}b",
    ])
    func invalidPathsAreRejected(path: String) {
        #expect(RevealRequest(path: path, line: 1) == nil)
    }

    @Test(arguments: [
        "\u{200E}", "\u{200F}", "\u{061C}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{2028}", "\u{2029}",
    ])
    func bidiControlsAndSeparatorsAreRejected(scalar: String) {
        #expect(RevealRequest(path: "/docs/evil\(scalar)dm.md", line: 1) == nil)
    }

    @Test func otherFormatCharactersAreAllowed() {
        for path in [
            "/tmp/\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.md",  // ZWJ family emoji
            "/tmp/a\u{200B}b.md",  // zero-width space: format character, not in the rejected list
        ] {
            #expect(RevealRequest(path: path, line: 1)?.path == path)
        }
    }

    @Test func pathLengthLimitIsInUTF8Bytes() {
        let limit = RevealRequest.maxPathBytes
        #expect(limit == 1024)
        let fits = "/" + String(repeating: "a", count: limit - 1)
        #expect(RevealRequest(path: fits, line: 1) != nil)
        #expect(RevealRequest(path: fits + "a", line: 1) == nil)
        // 341 three-byte characters plus "/" is 1024 bytes; one more byte is over.
        let wide = "/" + String(repeating: "中", count: (limit - 1) / 3)
        #expect(wide.utf8.count == limit)
        #expect(RevealRequest(path: wide, line: 1) != nil)
        #expect(RevealRequest(path: wide + "a", line: 1) == nil)
        #expect(RevealRequest(path: "/" + String(repeating: "中", count: 400), line: 1) == nil)
    }

    @Test func lineRange() {
        #expect(RevealRequest(path: "/a.md", line: 1)?.line == 1)
        #expect(RevealRequest(path: "/a.md", line: 999_999_999)?.line == 999_999_999)
        for line in [0, -1, 1_000_000_000, Int.max, Int.min] {
            #expect(RevealRequest(path: "/a.md", line: line) == nil)
        }
    }

    // MARK: Arguments

    @Test func argumentParsing() {
        let files: Set<String> = ["a.md", "weird:12", "b.md:3", "/tmp/a.md"]
        func parse(_ arg: String) -> (String, Int?) {
            let result = RevealRequest.parseArgument(arg, fileExists: files.contains)
            return (result.path, result.line)
        }
        #expect(parse("a.md") == ("a.md", nil))
        #expect(parse("a.md:12") == ("a.md", 12))
        #expect(parse("weird:12") == ("weird:12", nil))
        #expect(parse("weird:12:4") == ("weird:12", 4))
        #expect(parse("a.md:12:5") == ("a.md", 12))
        #expect(parse("b.md:3:5") == ("b.md:3", 5))
        #expect(parse("a.md:") == ("a.md:", nil))
        #expect(parse("a.md:abc") == ("a.md:abc", nil))
        #expect(parse("a.md:12:") == ("a.md:12:", nil))
        #expect(parse("a.md::5") == ("a.md::5", nil))
        #expect(parse("a.md:12:x") == ("a.md:12:x", nil))
        #expect(parse("a.md:x:5") == ("a.md:x:5", nil))
        #expect(parse("a.md:+5") == ("a.md:+5", nil))
        #expect(parse("a.md:-5") == ("a.md:-5", nil))
        #expect(parse("a.md:1e3") == ("a.md:1e3", nil))
        #expect(parse("a.md:٣") == ("a.md:٣", nil))
        #expect(parse("a.md:５") == ("a.md:５", nil))
        #expect(parse("a.md:123456789") == ("a.md", 123_456_789))
        #expect(parse("a.md:1234567890") == ("a.md:1234567890", nil))
        #expect(parse("a.md:0") == ("a.md", 0))  // split, then rejected by init?(path:line:)
        #expect(parse("missing.md:3") == ("missing.md:3", nil))
        #expect(parse(":3") == (":3", nil))
        // A column must also be 1–9 digits; a 10-digit column means no line at all.
        #expect(parse("/tmp/a.md:5:123456789") == ("/tmp/a.md", 5))
        #expect(parse("/tmp/a.md:5:1234567890") == ("/tmp/a.md:5:1234567890", nil))
        #expect(parse("/tmp/a.md:5:1:2") == ("/tmp/a.md:5:1:2", nil))
    }

    /// The argument is split at the last ASCII `:` byte. A `Character` search misses a
    /// colon that a Prepend scalar has joined into one grapheme, and would hand back
    /// `note\u{0600}:12` whole as a path that no file matches.
    @Test func theColonIsFoundOnBytesNotGraphemes() {
        let files: Set<String> = ["/tmp/note\u{0600}.md", "/tmp/note.md\u{0301}"]
        func parse(_ arg: String) -> (String, Int?) {
            let result = RevealRequest.parseArgument(arg, fileExists: files.contains)
            return (result.path, result.line)
        }
        #expect(parse("/tmp/note\u{0600}.md:12") == ("/tmp/note\u{0600}.md", 12))
        // A mark on the digits is not a digit, so there is no line and the argument stands.
        #expect(parse("/tmp/note.md\u{0301}:1\u{0301}") == ("/tmp/note.md\u{0301}:1\u{0301}", nil))
        // A mark right after the colon, likewise.
        #expect(parse("/tmp/note.md\u{0301}:\u{0301}1") == ("/tmp/note.md\u{0301}:\u{0301}1", nil))
        // A mark on the path is part of the path, and the line still splits off.
        #expect(parse("/tmp/note.md\u{0301}:7") == ("/tmp/note.md\u{0301}", 7))
    }
}
