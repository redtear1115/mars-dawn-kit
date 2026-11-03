#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DataDocumentMergeTests {
    // Read the displayed child rows of a named mapping, including their order and scalar values.
    private func children(_ name: String, in page: WKWebView) async throws -> [String] {
        try await DataPage.value("""
        (() => {
          const key = Array.from(document.querySelectorAll('#data .data-key')).find(k => k.textContent === \(PreviewWebView.jsonStringLiteral(name)));
          return Array.from(key.parentElement.parentElement.querySelector('.data-children').children)
            .filter(r => r.classList.contains('data-node'))
            .map(r => r.querySelector('.data-key').textContent + '=' + (r.querySelector('.data-value')?.textContent || ''));
        })()
        """, in: page) as? [String] ?? []
    }

    private func rowScript(_ path: [String]) -> String {
        let names = path.map { PreviewWebView.jsonStringLiteral($0) }.joined(separator: ",")
        return """
        (() => {
          let group = document.querySelector('.data-document > .data-children');
          let row;
          for (const name of [\(names)]) {
            row = Array.from(group.children).find(r =>
              (r.querySelector(':scope > .data-key') || r.querySelector(':scope > .data-toggle > .data-key'))?.textContent === name);
            group = row.querySelector(':scope > .data-children');
          }
          return row;
        })()
        """
    }

    private func marker(_ path: [String], in page: WKWebView) async throws -> String {
        try await DataPage.string("""
        (() => {
          const row = \(rowScript(path));
          return (row.querySelector(':scope > .data-source') || row.querySelector(':scope > .data-toggle > .data-source'))?.textContent || '';
        })()
        """, in: page)
    }

    @Test func singleMergeMarkersAccessibilityAndCopy() async throws {
        let page = try await DataPage.load()
        #expect(await DataPage.render("base: &base {host: localhost}\ndev: {<<: *base}\nx: *base\n", kind: .yaml, in: page) == .rendered)
        #expect(try await marker(["base"], in: page) == "&base")
        #expect(try await marker(["x"], in: page) == "*base")
        #expect(try await marker(["dev", "host"], in: page) == "*base")
        #expect(try await children("x", in: page) == ["host=\"localhost\""])
        #expect(try await DataPage.string("(\(rowScript(["dev", "host"]))).textContent", in: page).contains("*base"))
        #expect(try await DataPage.string("(\(rowScript(["base"]))).querySelector('.data-toggle').textContent", in: page).contains("&base"))
        // Visible markers participate in row/toggle text, outside the copyable value.
        #expect(try await DataPage.int("(\(rowScript(["dev", "host"]))).querySelectorAll('.data-value .data-source').length", in: page) == 0)
        #expect(try await DataPage.int("(\(rowScript(["base"]))).querySelectorAll(':scope > .data-toggle > .data-source').length", in: page) == 1)
        // Native copy uses selection; selecting the value must contain only its quoted text.
        #expect(try await DataPage.string("""
        (() => {
          const row = \(rowScript(["dev", "host"]));
          const range = document.createRange();
          range.selectNodeContents(row.querySelector('.data-value'));
          const selection = window.getSelection();
          selection.removeAllRanges(); selection.addRange(range);
          const copied = selection.toString(); selection.removeAllRanges();
          return copied;
        })()
        """, in: page) == "\"localhost\"")
        #expect(try await DataPage.string("getComputedStyle((\(rowScript(["dev", "host"]))).querySelector('.data-source')).webkitUserSelect", in: page) == "none")
    }

    @Test func multipleMergeSourceMarkers() async throws {
        let page = try await DataPage.load()
        #expect(await DataPage.render("a: &a {shared: 1, first: 2}\nb: &b {shared: 3, second: 4}\ndev: {<<: [*a, *b]}\n", kind: .yaml, in: page) == .rendered)
        #expect(try await marker(["dev", "shared"], in: page) == "*a")
        #expect(try await marker(["dev", "first"], in: page) == "*a")
        #expect(try await marker(["dev", "second"], in: page) == "*b")
    }

    @Test func localOverrideHasNoSourceMarker() async throws {
        let page = try await DataPage.load()
        for body in ["<<: *base, host: local", "host: local, <<: *base"] {
            #expect(await DataPage.render("base: &base {host: localhost, port: 42}\ndev: {\(body)}\n", kind: .yaml, in: page) == .rendered)
            #expect(try await marker(["dev", "host"], in: page) == "")
            #expect(try await marker(["dev", "port"], in: page) == "*base")
            #expect(try await children("dev", in: page).contains("host=\"local\""))
        }
    }

    @Test func nestedAliasKeepsOccurrenceMarkersAndExpansion() async throws {
        let page = try await DataPage.load()
        #expect(await DataPage.render("inner: &inner {host: localhost}\nbase: &base {nested: *inner}\nx: *base\n", kind: .yaml, in: page) == .rendered)
        #expect(try await marker(["inner"], in: page) == "&inner")
        #expect(try await marker(["base", "nested"], in: page) == "*inner")
        #expect(try await marker(["x"], in: page) == "*base")
        #expect(try await marker(["x", "nested"], in: page) == "*inner")
        // Open the next level explicitly; auto expansion may stop at this depth.
        _ = try await DataPage.value("(\(rowScript(["x", "nested"]))).querySelector('.data-toggle').click()", in: page)
        #expect(try await DataPage.string("(\(rowScript(["x", "nested", "host"]))).querySelector('.data-value').textContent", in: page) == "\"localhost\"")
    }

    @Test func singleMergeOwnValuesAndInsertionOrder() async throws {
        let page = try await DataPage.load()
        let text = "base: &a {host: localhost, port: 5432, tail: 1}\ndev:\n  before: 0\n  <<: *a\n  port: 5433\n  after: 2\n"
        #expect(await DataPage.render(text, kind: .yaml, in: page) == .rendered)
        #expect(try await children("dev", in: page) == ["before=0", "host=\"localhost\"", "port=5433", "tail=1", "after=2"])
        #expect(await DataPage.render("base: &a {port: 5432, host: localhost}\ndev: {port: 5433, <<: *a}\n", kind: .yaml, in: page) == .rendered)
        #expect(try await children("dev", in: page) == ["port=5433", "host=\"localhost\""])
    }

    @Test func multipleSourcesEarlierWinsAndNestedMergesResolve() async throws {
        let page = try await DataPage.load()
        let text = "a: &a {shared: 1, first: 2}\nb: &b {shared: 3, second: 4}\nc: &c {<<: [*a, *b], own: 5}\ndev: {<<: *c, second: 6}\n"
        #expect(await DataPage.render(text, kind: .yaml, in: page) == .rendered)
        #expect(try await children("dev", in: page) == ["shared=1", "first=2", "second=6", "own=5"])
    }

    @Test(arguments: ["text", "42", "[{}, text]", "[{}, 42]", "[{}, []]"])
    func invalidSourcesAreParseErrors(source: String) async throws {
        let page = try await DataPage.load()
        #expect(await DataPage.render("dev: {<<: \(source)}\n", kind: .yaml, in: page) == .parseError)
        #expect(try await DataPage.messageText(in: page) == DataPage.parseErrorAt("YAML", 1, 7))
    }

    @Test(arguments: ["\"<<\"", "'<<'", "!!str <<"])
    func stringKeysAreOrdinaryKeys(key: String) async throws {
        let page = try await DataPage.load()
        #expect(await DataPage.render("dev: {\(key): 7, other: 8}\n", kind: .yaml, in: page) == .rendered)
        #expect(try await children("dev", in: page) == ["<<=7", "other=8"])
    }

    @Test func mergeWorkIsBoundedBeforeCopiesEvenWhenKeysCollide() async throws {
        let page = try await DataPage.load()
        let text = DataDocumentBombTests.aliasesToAMapping(keys: 400, aliases: 0)
            + "dev: {<<: [" + Array(repeating: "*m", count: 100).joined(separator: ",") + "]}\n"
        let start = ContinuousClock.now
        #expect(await DataPage.render(text, kind: .yaml, in: page, limits: ["maximumAliases": 1000]) == .tooComplex)
        #expect(ContinuousClock.now - start < .seconds(3))
        // Alias count alone, independent of the copied-entry allowance.
        #expect(await DataPage.render("a: &a {}\ndev: {<<: [*a, *a]}\n", kind: .yaml, in: page,
                                      limits: ["maximumAliases": 1]) == .tooComplex)
    }

    @Test func layeredMergeBombIsTooComplex() async throws {
        let page = try await DataPage.load()
        var text = "a0: &a0 {x: 1}\n"
        for level in 1...50 {
            let sources = Array(repeating: "*a\(level - 1)", count: 100).joined(separator: ",")
            text += "a\(level): &a\(level) {<<: [\(sources)], k\(level): \(level)}\n"
        }
        let start = ContinuousClock.now
        #expect(await DataPage.render(text, kind: .yaml, in: page) == .tooComplex)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func mergedAliasCyclesRemainMarkersAndDepthIsChecked() async throws {
        let page = try await DataPage.load()
        #expect(await DataPage.render("a: &a {self: *a, x: 1}\ndev: {<<: *a}\n", kind: .yaml, in: page) == .rendered)
        #expect(try await DataPage.int("document.querySelectorAll('#data .data-cycle').length", in: page) == 2)
        #expect(await DataPage.render("a: &a {x: {y: 1}}\ndev: {nested: {<<: *a}}\n", kind: .yaml, in: page,
                                      limits: ["maximumTreeDepth": 3]) == .tooComplex)
    }

    @Test func mergeParseBudgetStillApplies() async throws {
        let page = try await DataPage.load(userScript: "let tick = 0; performance.now = () => (tick += 10);")
        #expect(await DataPage.render("a: &a {x: 1}\ndev: {<<: *a}\n", kind: .yaml, in: page,
                                      limits: ["parseBudgetMilliseconds": 1]) == .tooComplex)
    }
}
#endif
