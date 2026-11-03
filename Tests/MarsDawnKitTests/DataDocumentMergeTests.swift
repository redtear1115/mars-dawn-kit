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
