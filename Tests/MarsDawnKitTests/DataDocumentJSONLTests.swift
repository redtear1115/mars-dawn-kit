#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// JSON Lines on the tree page (redtear1115/mars-dawn#563): one top-level row per non-empty line,
/// keyed by its line number in the file; a broken line is an error row of its own; blank lines are
/// skipped; the line cap, the depth limit and the parse budget make the document too complex.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DataDocumentJSONLTests {
    /// Each top-level row: its key (the line number), and its value, count or error text.
    static let topRows = """
    Array.from(document.querySelectorAll('#data .data-panel > .data-node')).map((row) => {
      const head = row.querySelector(':scope > .data-toggle') || row;
      const key = head.querySelector(':scope > .data-key');
      const shown = row.querySelector(':scope > .data-value, :scope > .data-error') || head.querySelector(':scope > .data-count');
      return (key ? key.textContent : '-') + ' ' + (row.querySelector(':scope > .data-error') ? 'error ' : '')
        + (shown ? shown.textContent : '?') + (row.classList.contains('data-document') ? '' : ' (not a document row)');
    })
    """

    static func topRows(_ webView: WKWebView) async throws -> [String] {
        try await DataPage.value(topRows, in: webView) as? [String] ?? []
    }

    static let invalidJSON = DataLabels.english.parseError.replacingOccurrences(of: "{format}", with: "JSON")

    @Test func eachLineIsATopLevelRowKeyedByItsLineNumber() async throws {
        let webView = try await DataPage.load()
        let text = "{\"a\": 1, \"b\": [true, null]}\n[1, 2, 3]\n\"text\"\n42\n"
        #expect(await DataPage.render(text, kind: .jsonl, in: webView) == .rendered)
        #expect(try await Self.topRows(webView) == ["1 2 items", "2 3 items", "3 \"text\"", "4 42"])
        // The values open as JSON's do; nested rows keep their own keys.
        let rows = try await DataDocumentPageTests.rows(webView)
        #expect(rows.contains(DataDocumentPageTests.Row(level: 1, key: "a", kind: "data-number", text: "1", expanded: nil)), "\(rows)")
        #expect(rows.contains(DataDocumentPageTests.Row(level: 2, key: "0", kind: "data-bool", text: "true", expanded: nil)), "\(rows)")
        #expect(try await DataPage.messageText(in: webView) == "")
    }

    @Test func aBrokenLineIsAnErrorRowAndTheOthersRender() async throws {
        let webView = try await DataPage.load()
        // Line 2 has a position from the scanner; line 4 is a plain YAML scalar, so it has none.
        let text = "{\"a\": 1}\n{\"b\": [1,,]}\n[2]\nnope\n3"
        #expect(await DataPage.render(text, kind: .jsonl, in: webView) == .rendered)
        let rows = try await Self.topRows(webView)
        #expect(rows.count == 5, "\(rows)")
        guard rows.count == 5 else { return }
        #expect(rows[0] == "1 1 item")
        // The column is within the line: the second comma.
        #expect(rows[1] == "2 error " + DataPage.parseErrorAt("JSON", 2, 10))
        #expect(rows[2] == "3 1 item")
        #expect(rows[3] == "4 error " + Self.invalidJSON)
        #expect(rows[4] == "5 3")
        // Nothing else of the page reports an error: the tree is shown, not a message.
        #expect(try await DataPage.messageText(in: webView) == "")
    }

    @Test func blankLinesAreSkippedAndLineNumbersStayTheSourceLines() async throws {
        let webView = try await DataPage.load()
        let text = "\n  \n1\n\t\n\n{\"x\": 2}\n   \n\"last\"\n\n"
        #expect(await DataPage.render(text, kind: .jsonl, in: webView) == .rendered)
        #expect(try await Self.topRows(webView) == ["3 1", "6 1 item", "8 \"last\""])
    }

    @Test func crlfLinesKeepTheirNumbersAndValues() async throws {
        let webView = try await DataPage.load()
        let text = "{\"a\": \"x\"}\r\n\r\n[1]\r\nbad\r\n\"y\"\r\n"
        #expect(await DataPage.render(text, kind: .jsonl, in: webView) == .rendered)
        #expect(try await Self.topRows(webView) == ["1 1 item", "3 1 item", "4 error " + Self.invalidJSON, "5 \"y\""])
        let rows = try await DataDocumentPageTests.rows(webView)
        #expect(rows.contains(DataDocumentPageTests.Row(level: 1, key: "a", kind: "data-string", text: "\"x\"", expanded: nil)), "\(rows)")
    }

    @Test func aLeadingByteOrderMarkIsNotPartOfTheFirstLine() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render("\u{FEFF}{\"a\": 1}\n2", kind: .jsonl, in: webView) == .rendered)
        #expect(try await Self.topRows(webView) == ["1 1 item", "2 2"])
    }

    @Test func aFileWithNoValueIsNotValidJSON() async throws {
        let webView = try await DataPage.load()
        for text in ["", "\n\n", "  \r\n\t\n"] {
            #expect(await DataPage.render(text, kind: .jsonl, in: webView) == .parseError, "\(text.debugDescription)")
            #expect(try await DataPage.messageText(in: webView) == Self.invalidJSON)
        }
    }

    @Test func overTheLineCapTheDocumentIsTooComplex() async throws {
        let webView = try await DataPage.load()
        let limits = ["maximumJSONLLines": 3]
        // Blank lines don't count; broken lines do.
        #expect(await DataPage.render("1\n\n2\n  \nbad\n", kind: .jsonl, in: webView, limits: limits) == .rendered)
        #expect(await DataPage.render("1\n2\n3\n4\n", kind: .jsonl, in: webView, limits: limits) == .tooComplex)
        #expect(try await DataPage.messageText(in: webView) == DataLabels.english.tooComplex)
        #expect(try await DataPage.rows(in: webView) == 0)
        #expect(await DataPage.render("1\n2\n3\nbad\n", kind: .jsonl, in: webView, limits: limits) == .tooComplex)
    }

    @Test func aLineDeeperThanTheTreeLimitIsTooComplex() async throws {
        let webView = try await DataPage.load()
        let limits = ["maximumTreeDepth": 5]
        // Five levels on one line is within the limit; levels never add up across lines.
        let five = DataPage.nestedSequences(5)
        #expect(await DataPage.render("\(five)\n\(five)\n", kind: .jsonl, in: webView, limits: limits) == .rendered)
        #expect(await DataPage.render("1\n\(DataPage.nestedSequences(6))\n2\n", kind: .jsonl, in: webView, limits: limits) == .tooComplex)
        #expect(try await DataPage.messageText(in: webView) == DataLabels.english.tooComplex)
        // A scalar counts as a level, as for JSON.
        #expect(await DataPage.render("[[[[[1]]]]]", kind: .jsonl, in: webView, limits: limits) == .tooComplex)
    }

    @Test func theParseBudgetApplies() async throws {
        let page = try await DataPage.load(userScript: "let tick = 0; performance.now = () => (tick += 10);")
        #expect(await DataPage.render("1\n2\n3\n", kind: .jsonl, in: page, limits: ["parseBudgetMilliseconds": 1]) == .tooComplex)
        #expect(try await DataPage.messageText(in: page) == DataLabels.english.tooComplex)
    }

    /// Document text stays text in a line's key, value and error row alike.
    @Test func hostileLinesAreTextOnly() async throws {
        let webView = try await DataPage.load()
        let text = "{\"<img src=x onerror=alert(1)>\": \"<script>window.__x = 1</script>\"}\n<b>bold</b>\n"
        #expect(await DataPage.render(text, kind: .jsonl, in: webView) == .rendered)
        #expect(try await DataPage.int("document.querySelectorAll('#data img, #data script, #data b').length", in: webView) == 0)
        #expect(try await Self.topRows(webView) == ["1 1 item", "2 error " + Self.invalidJSON])
    }
}
#endif
