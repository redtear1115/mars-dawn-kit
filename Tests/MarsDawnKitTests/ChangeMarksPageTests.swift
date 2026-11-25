#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Change marks in the real preview page (mars-dawn#358 T2): which elements `setChangeMarks` marks,
/// that an `update()` keeps them, and that a page nobody marks is the page it always was.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ChangeMarksPageTests {
    private typealias Page = DetailsPageTests

    private let document = """
    # Title

    One paragraph.
    Its second line.

    - first item
    - second item

    | head | more |
    |---|---|
    | cell | cell |

    Last paragraph.

    """

    private func set(_ marks: [PreviewWebView.ChangeMark], current: Int? = nil, in webView: PreviewWKWebView) async throws {
        _ = try await webView.evaluateJavaScript("\(PreviewWebView.changeMarksScript(marks, currentLine: current)); 0")
    }

    /// `[tag name: data-change-lines]` for every marked element, in page order.
    private func marked(_ webView: PreviewWKWebView) async throws -> [String] {
        let result = try await webView.callAsyncJavaScript("""
            return [...document.querySelectorAll("#content .md-change")].map((el) =>
              `${el.tagName} ${el.getAttribute("data-change-lines")} ${[...el.classList].sort().join(" ")}`);
            """, contentWorld: .page)
        return result as? [String] ?? []
    }

    private func page() async throws -> PreviewWKWebView {
        let webView = try await Page.loadedPreview()
        try await Page.push(document, to: webView)
        return webView
    }

    @Test func aMarkGoesOnTheInnermostElement() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        try await set([.init(firstLine: 6, lineCount: 1, kind: .changed)], in: webView)
        #expect(try await marked(webView) == ["LI 6 md-change md-change-changed"], "the item, not the list")
        try await set([.init(firstLine: 9, lineCount: 1, kind: .added)], in: webView)
        #expect(try await marked(webView) == ["TR 9 md-change md-change-added"], "the row, not the table")
    }

    @Test func aLineInsideABlockMarksTheBlock() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        try await set([.init(firstLine: 4, lineCount: 1, kind: .changed)], in: webView)
        #expect(try await marked(webView) == ["P 4 md-change md-change-changed"])
    }

    @Test func aRunMarksEveryBlockInItAndOneElementCanHoldTwoMarks() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        try await set([
            .init(firstLine: 1, lineCount: 3, kind: .added),
            .init(firstLine: 4, lineCount: 1, kind: .changed),
        ], in: webView)
        #expect(try await marked(webView) == [
            "H1 1 md-change md-change-added",
            "P 1 4 md-change md-change-added md-change-changed",
        ])
    }

    @Test func anUpdateMovesMarksWithTheAppsNextSetAndKeepsTheLastOne() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        try await set([.init(firstLine: 1, lineCount: 1, kind: .changed)], in: webView)
        try await Page.push("Inserted.\n\n" + document, to: webView)
        #expect(try await marked(webView) == ["P 1 md-change md-change-changed"], "the same line, on what's there now")
        try await set([], in: webView)
        #expect(try await marked(webView).isEmpty)
        try await Page.push(document, to: webView)
        #expect(try await marked(webView).isEmpty, "cleared stays cleared")
    }

    /// Bad values from anywhere are dropped: the page takes only whole lines and known kinds.
    @Test func badMarksAreDropped() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        _ = try await webView.evaluateJavaScript("""
            MarsDawn.setChangeMarks({ marks: [
              { firstLine: 1.5, lineCount: 1, kind: "added" },
              { firstLine: 1, lineCount: 0, kind: "added" },
              { firstLine: "1", lineCount: 1, kind: "added" },
              { firstLine: 1, lineCount: 1, kind: "x onload=alert(1)" },
              null,
              { firstLine: 3, lineCount: 1, kind: "changed" },
            ] }); MarsDawn.setChangeMarks; 0
            """)
        #expect(try await marked(webView) == ["P 3 md-change md-change-changed"])
        _ = try await webView.evaluateJavaScript("MarsDawn.setChangeMarks({ marks: 7 }); MarsDawn.setChangeMarks(); 0")
        #expect(try await marked(webView).isEmpty)
    }

    /// No new element, no `data-line` touched, no text, no height: scroll sync, VoiceOver and the
    /// page's own reading order see what they saw.
    @Test func aMarkChangesNothingElse() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        let state = """
            return { html: document.querySelector("#content").cloneNode(true).outerHTML,
                     text: document.querySelector("#content").innerText,
                     tops: [...document.querySelectorAll("#content [data-line]")].map((el) => el.getBoundingClientRect().top),
                     height: document.documentElement.scrollHeight };
            """
        let before = try await webView.callAsyncJavaScript(state, contentWorld: .page) as? [String: Any]
        try await set([
            .init(firstLine: 1, lineCount: 1, kind: .added),
            .init(firstLine: 6, lineCount: 2, kind: .changed),
            .init(firstLine: 13, lineCount: 1, kind: .removed),
        ], in: webView)
        let during = try await webView.callAsyncJavaScript(state, contentWorld: .page) as? [String: Any]
        #expect(during?["text"] as? String == before?["text"] as? String)
        #expect(during?["tops"] as? [Double] == before?["tops"] as? [Double])
        #expect(during?["height"] as? Double == before?["height"] as? Double)
        #expect(during?["html"] as? String != before?["html"] as? String, "positive fixture: marks landed")

        try await set([], in: webView)
        let after = try await webView.callAsyncJavaScript(state, contentWorld: .page) as? [String: Any]
        #expect(after?["html"] as? String == before?["html"] as? String, "clearing leaves the page as it was")
    }

    // MARK: Where a mark lands (#358's table)

    private func marks(_ text: String, _ marks: [PreviewWebView.ChangeMark], current: Int? = nil) async throws -> [String] {
        let webView = try await Page.loadedPreview()
        try await Page.push(text, to: webView)
        try await set(marks, current: current, in: webView)
        return try await marked(webView)
    }

    @Test func aChangeBeforeTheFirstBlockMarksTheFirstBlock() async throws {
        defer { Page.closeHosts() }
        #expect(try await marks("\n\n# T\n\npara\n", [.init(firstLine: 1, lineCount: 1, kind: .changed)])
            == ["H1 1 md-change md-change-changed"])
        #expect(try await marks("[x]: http://a.example\n\n# T\n", [.init(firstLine: 1, lineCount: 1, kind: .added)])
            == ["H1 1 md-change md-change-added"], "a link definition has no block")
    }

    @Test func aChangeOnALineWithNoBlockMarksTheBlockBefore() async throws {
        defer { Page.closeHosts() }
        #expect(try await marks("One.\n\nTwo.\n", [.init(firstLine: 2, lineCount: 1, kind: .changed)])
            == ["P 2 md-change md-change-changed"])
    }

    @Test func aDeletionMarksTheBlockAfterItOrTheLastOne() async throws {
        defer { Page.closeHosts() }
        let text = "One.\n\nTwo.\n"
        let after = try await marks(text, [.init(firstLine: 2, lineCount: 1, kind: .removed)])
        #expect(after == ["P 2 md-change md-change-removed"])
        let webView = try await Page.loadedPreview()
        try await Page.push(text, to: webView)
        try await set([.init(firstLine: 2, lineCount: 1, kind: .removed)], in: webView)
        let tops = try await webView.callAsyncJavaScript(
            #"return document.querySelector(".md-change").textContent"#, contentWorld: .page) as? String
        #expect(tops == "Two.", "the block after the deletion, not the one before it")
        let end = try await marks("One.\n\nTwo.\n", [.init(firstLine: 9, lineCount: 1, kind: .removed)])
        #expect(end == ["P 9 md-change md-change-removed"], "at the end of the document, the last block")
    }

    /// Not opened, and not marked out of sight.
    @Test func aChangeInACollapsedDetailsMarksWhatsAroundIt() async throws {
        defer { Page.closeHosts() }
        let text = "<details>\n<summary>S</summary>\n\ninner para\n\n</details>\n\nafter\n"
        let webView = try await Page.loadedPreview()
        try await Page.push(text, to: webView)
        try await set([.init(firstLine: 4, lineCount: 1, kind: .changed)], in: webView)
        let state = try await webView.callAsyncJavaScript("""
            const el = document.querySelector("#content .md-change");
            return { hidden: !!el?.closest("details:not([open])") && el.tagName !== "DETAILS",
                     contains: !!el?.querySelector("details, summary") || el?.tagName === "DETAILS",
                     open: !!document.querySelector("details[open]"),
                     lines: el?.getAttribute("data-change-lines") };
            """, contentWorld: .page) as? [String: Any]
        #expect(state?["contains"] as? Bool == true, "the mark is on what shows the details: \(state ?? [:])")
        #expect(state?["hidden"] as? Bool == false)
        #expect(state?["open"] as? Bool == false, "marking doesn't open it")
        #expect(state?["lines"] as? String == "4", "and still says which line")
    }

    /// The mark follows what shows the change, both ways, with no new marks from the app.
    @Test func aMarkFollowsADetailsOpenedOrClosed() async throws {
        defer { Page.closeHosts() }
        let webView = try await Page.loadedPreview()
        try await Page.push("<details open>\n<summary>S</summary>\n\ninner para\n\n</details>\n\nafter\n", to: webView)
        try await set([.init(firstLine: 4, lineCount: 1, kind: .changed)], in: webView)
        #expect(try await marked(webView) == ["P 4 md-change md-change-changed"])
        #expect(try await tag(webView, afterSetting: false) != "P", "a closed group shows the mark on what's around it")
        #expect(try await tag(webView, afterSetting: true) == "P", "and an open one on the paragraph")
    }

    /// Sets the only `<details>`, waits for the frame that follows, and names the marked element.
    private func tag(_ webView: PreviewWKWebView, afterSetting open: Bool) async throws -> String? {
        try await webView.callAsyncJavaScript("""
            const before = document.querySelector("#content .md-change");
            document.querySelector("details").open = open;
            for (let i = 0; i < 200 && document.querySelector("#content .md-change") === before; i++) {
              await new Promise((done) => setTimeout(done, 10));
            }
            return document.querySelector("#content .md-change")?.tagName ?? null;
            """, arguments: ["open": open], contentWorld: .page) as? String
    }

    /// A line that moves to the inner element takes its kind along, so a deletion keeps its triangle.
    @Test func aMovedLineKeepsItsKind() async throws {
        defer { Page.closeHosts() }
        let found = try await marks("- a\n  - b\n", [
            .init(firstLine: 1, lineCount: 1, kind: .removed),
            .init(firstLine: 2, lineCount: 1, kind: .added),
        ])
        #expect(found == ["LI 1 2 md-change md-change-added md-change-removed"], "\(found)")
    }

    /// The outer element's mark isn't drawn, but the line stays findable on the inner one.
    @Test func anInnerElementKeepsTheOuterOnesLine() async throws {
        defer { Page.closeHosts() }
        let found = try await marks("- a\n  - b\n", [
            .init(firstLine: 1, lineCount: 1, kind: .changed),
            .init(firstLine: 2, lineCount: 1, kind: .added),
        ], current: 1)
        #expect(found.count == 1)
        #expect(found.first?.hasPrefix("LI 1 2 md-change") == true, "\(found)")
        #expect(found.first?.contains("md-change-current") == true, "the current mark follows its line: \(found)")
    }

    /// A list, table or quote starts on its first child's line, so marking that child marks the
    /// outer element too. Its line is the first child's, and no neighbour's.
    @Test(arguments: [
        ("- one\n- two\n- three\n", [1, 2], ["LI 1 current", "LI 2"]),
        ("| a |\n|---|\n| b |\n| c |\n", [1, 4], ["TR 1 current", "TR 4"]),
        ("> one\n>\n> two\n", [1, 3], ["P 1 current", "P 3"]),
        ("1. one\n2. two\n", [1, 2], ["LI 1 current", "LI 2"]),
    ]) func anOuterElementsLineStaysOffItsNeighbours(text: String, lines: [Int], expected: [String]) async throws {
        defer { Page.closeHosts() }
        let found = try await marks(text, lines.map { .init(firstLine: $0, lineCount: 1, kind: .changed) }, current: 1)
        #expect(found.map(Self.shortForm) == expected, "\(found)")
    }

    /// A parent with text of its own has no kept element holding its line: the first child takes
    /// it, once, even though the list and the item both start there.
    @Test func aLineNothingInsideHoldsGoesToTheFirstOnly() async throws {
        defer { Page.closeHosts() }
        let found = try await marks("- a\n  - b\n  - c\n", [1, 2, 3].map { .init(firstLine: $0, lineCount: 1, kind: .changed) }, current: 1)
        #expect(found.map(Self.shortForm) == ["LI 1 2 current", "LI 3"], "\(found)")
    }

    /// `TAG lines`, with ` current` on the element the reader is on.
    private static func shortForm(_ line: String) -> String {
        let words = line.split(separator: " ")
        let lines = words.prefix { !$0.hasPrefix("md-change") }.joined(separator: " ")
        return line.contains("md-change-current") ? "\(lines) current" : lines
    }

    @Test func anAuthorsOwnLineAttributeIsIgnored() async throws {
        defer { Page.closeHosts() }
        let found = try await marks("<div data-line=\"nope\">Raw.</div>\n\nTarget.\n", [
            .init(firstLine: 3, lineCount: 1, kind: .changed),
        ])
        #expect(found == ["P 3 md-change md-change-changed"], "\(found)")
    }

    /// The mark the reader is on: every element holding that `firstLine`, kept through `update()`.
    @Test func theCurrentMarkIsMarkedAndMoves() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        let marks: [PreviewWebView.ChangeMark] = [
            .init(firstLine: 1, lineCount: 1, kind: .added),
            .init(firstLine: 6, lineCount: 1, kind: .changed),
        ]
        try await set(marks, current: 6, in: webView)
        #expect(try await marked(webView) == [
            "H1 1 md-change md-change-added",
            "LI 6 md-change md-change-changed md-change-current",
        ])
        try await Page.push(document, to: webView)
        #expect(try await marked(webView).contains("LI 6 md-change md-change-changed md-change-current"))
        try await set(marks, current: 1, in: webView)
        #expect(try await marked(webView) == [
            "H1 1 md-change md-change-added md-change-current",
            "LI 6 md-change md-change-changed",
        ])
        try await set(marks, in: webView)
        #expect(!(try await marked(webView).joined().contains("current")), "no current mark")
        _ = try await webView.evaluateJavaScript(#"MarsDawn.setChangeMarks({ marks: [{ firstLine: 1, lineCount: 1, kind: "added" }], currentLine: "1" }); 0"#)
        #expect(try await marked(webView) == ["H1 1 md-change md-change-added"], "a non-integer line is no line")
    }

    /// WebKit parses the alt-text form of `content`: an empty mark with nothing to read aloud.
    /// A declaration it rejected would leave no mark at all, and this would see `none`.
    @Test func webKitDrawsTheMarksPseudoElements() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        try await set([
            .init(firstLine: 1, lineCount: 1, kind: .added),
            .init(firstLine: 3, lineCount: 1, kind: .changed),
            .init(firstLine: 6, lineCount: 1, kind: .removed),
            .init(firstLine: 9, lineCount: 1, kind: .added),
        ], in: webView)
        let result = try await webView.callAsyncJavaScript("""
            const style = (el, pseudo) => getComputedStyle(el, pseudo);
            const q = (selector) => document.querySelector(selector);
            return {
              block: style(q("#content h1"), "::before").content,
              blockPosition: style(q("#content h1"), "::before").position,
              clip: style(q("#content li"), "::before").clipPath,
              rowCell: style(q("#content tr > :first-child"), "::before").content,
              row: style(q("#content tr"), "::before").content,
              dashes: style(q("#content p"), "::before").backgroundImage,
            };
            """, contentWorld: .page) as? [String: Any]
        print("ChangeMarksContent", result ?? [:])
        #expect(result?["block"] as? String != "none")
        #expect(result?["block"] as? String != "normal")
        #expect(result?["blockPosition"] as? String == "absolute")
        #expect((result?["clip"] as? String)?.contains("polygon") == true)
        #expect(result?["rowCell"] as? String != "none", "a row marks its first cell")
        #expect(result?["row"] as? String == "none", "and not itself: the table's overflow would clip it")
        #expect((result?["dashes"] as? String)?.contains("repeating-linear-gradient") == true)
    }

    /// A theme's own `h2::before` stays: a heading 2's mark is on `::after`.
    @Test func aSecondLevelHeadingLeavesItsBeforeToTheTheme() async throws {
        defer { Page.closeHosts() }
        let webView = try await Page.loadedPreview()
        try await Page.push("## Two\n", to: webView)
        try await set([.init(firstLine: 1, lineCount: 1, kind: .changed)], in: webView)
        let after = try await webView.evaluateJavaScript(#"getComputedStyle(document.querySelector("h2"), "::after").position"#)
        #expect(after as? String == "absolute")
    }

    @Test func printHidesMarks() async throws {
        defer { Page.closeHosts() }
        let webView = try await page()
        try await set([.init(firstLine: 1, lineCount: 1, kind: .changed)], current: 1, in: webView)
        let script = ##"(() => { const el = document.querySelector("#content .md-change"); return [getComputedStyle(el, "::before").display, getComputedStyle(el).backgroundColor].join(" | "); })()"##
        let screen = try await webView.evaluateJavaScript(script) as? String
        #expect(screen?.hasPrefix("none") == false, "positive fixture: on screen it shows: \(screen ?? "")")
        #expect(screen?.hasSuffix("rgba(0, 0, 0, 0)") == false, "and the current mark has its tint: \(screen ?? "")")
        webView.mediaType = "print"
        #expect(try await webView.evaluateJavaScript(script) as? String == "none | rgba(0, 0, 0, 0)")
    }

    @Test func theScriptCarriesOnlyWhatItWasGiven() {
        let script = PreviewWebView.changeMarksScript([.init(firstLine: 12, lineCount: 2, kind: .removed)])
        #expect(script == #"window.MarsDawn?.setChangeMarks?.({"currentLine":null,"marks":[{"firstLine":12,"kind":"removed","lineCount":2}]});"#)
        #expect(PreviewWebView.changeMarksScript([], currentLine: 7).contains(#"{"currentLine":7,"marks":[]}"#))
    }

    /// Thousands marked at once, last first, a batch at a time: in page order WebKit's layer
    /// search makes this quadratic (8 s for 40,000 paragraphs). What's left is the same page.
    @Test func aWholeDocumentMarksFromTheEndAndKeepsItsLayout() async throws {
        defer { Page.closeHosts() }
        let webView = try await Page.loadedPreview()
        let count = 3_000
        try await Page.push(String(repeating: "Para.\n\n", count: count), to: webView)
        let result = try await webView.callAsyncJavaScript("""
            const blocks = [...document.querySelectorAll("#content p")];
            const height = document.body.scrollHeight;
            const changed = [];
            const seen = new MutationObserver((records) => changed.push(...records));
            seen.observe(document.getElementById("content"), { attributes: true, subtree: true });
            const taken = () => { const list = [...changed, ...seen.takeRecords()]; changed.length = 0; return list; };
            MarsDawn.setChangeMarks({ marks: [{ firstLine: 1, lineCount: lines, kind: "changed" }] });
            const first = taken();
            const shown = document.querySelectorAll("#content .md-change");
            MarsDawn.setChangeMarks({ marks: [{ firstLine: 1, lineCount: lines, kind: "changed" }] });
            const again = taken();
            const at = (el) => first.findIndex((record) => record.target === el);
            return { startsAtTheEnd: at(blocks.at(-1)) < at(blocks[0]), marked: shown.length,
                     sameHeight: document.body.scrollHeight === height, rewrites: again.length };
            """, arguments: ["lines": count * 2], contentWorld: .page) as? [String: Any]
        #expect(result?["marked"] as? Int == count, "\(result ?? [:])")
        #expect(result?["startsAtTheEnd"] as? Bool == true, "\(result ?? [:])")
        #expect(result?["sameHeight"] as? Bool == true, "\(result ?? [:])")
        #expect(result?["rewrites"] as? Int == 0, "a mark that stays costs the page nothing: \(result ?? [:])")
    }

    /// Not an assertion until #358's tag: the 16 ms budget is for the release's measurement.
    @Test func measureAboutOneMegabyteAndFiveHundredMarks() async throws {
        defer { Page.closeHosts() }
        let webView = try await Page.loadedPreview()
        let block = "A paragraph of ordinary prose that runs on for a while, as paragraphs do in real documents.\n\n"
        let text = String(repeating: block, count: 1_048_576 / block.utf8.count)
        try await Page.push(text, to: webView)
        let lines = text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        let step = lines / 500
        let marks = stride(from: 1, to: lines, by: step).prefix(500).map {
            PreviewWebView.ChangeMark(firstLine: $0 | 1, lineCount: 1, kind: .changed)
        }
        let result = try await webView.callAsyncJavaScript("""
            const list = JSON.parse(payload);
            const start = performance.now();
            MarsDawn.setChangeMarks({ marks: list });
            const set = performance.now() - start;
            const blocks = document.querySelectorAll("#content .md-change").length;
            const again = performance.now();
            MarsDawn.setChangeMarks({ marks: list });
            const reapply = performance.now() - again;
            const html = document.querySelector("#content").innerHTML;
            const run = () => { const at = performance.now(); MarsDawn.update(html, 0); return performance.now() - at; };
            const rounds = [];
            for (let round = 0; round < 5; round++) {
              MarsDawn.setChangeMarks({ marks: [] });
              const plain = run();
              MarsDawn.setChangeMarks({ marks: list });
              rounds.push([plain, run()].map(Math.round).join("/"));
            }
            return { set, reapply, blocks, updatePlainThenMarked: rounds.join(" ") };
            """, arguments: ["payload": try jsonMarks(marks)], contentWorld: .page) as? [String: Any]
        print("ChangeMarksBudget", result ?? [:])
        #expect((result?["blocks"] as? Int ?? 0) > 400, "positive fixture: the marks landed")
    }

    private func jsonMarks(_ marks: [PreviewWebView.ChangeMark]) throws -> String {
        let list = marks.map { ["firstLine": $0.firstLine, "lineCount": $0.lineCount, "kind": $0.kind.rawValue] as [String: Any] }
        return String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)
    }
}
#endif
