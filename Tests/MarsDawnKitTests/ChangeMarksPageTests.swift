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
        try await set([.init(firstLine: 4, lineCount: 1, kind: .removed)], in: webView)
        #expect(try await marked(webView) == ["P 4 md-change md-change-removed"])
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
        #expect(script == #"window.MarsDawn && MarsDawn.setChangeMarks({"currentLine":null,"marks":[{"firstLine":12,"kind":"removed","lineCount":2}]});"#)
        #expect(PreviewWebView.changeMarksScript([], currentLine: 7).contains(#"{"currentLine":7,"marks":[]}"#))
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
            return { set, reapply: performance.now() - again, blocks };
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
