#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import MarsDawnExport

/// mars-dawn#15: keep-with-next measures in rounds (all reads, then all wraps) instead of reading
/// a height after every wrap. It must wrap exactly what the wrap-then-read loop it replaced did:
/// both run on the same prepared page, unwrapped again in between, and the page must come out the
/// same, wrapper for wrapper.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct KeepWithNextTests {
    /// The script as it was before mars-dawn#15, verbatim: the reference.
    static let wrapThenReadScript = """
    (() => {
      const budget = 300;
      const headings = [...document.querySelectorAll("#content > :is(h1, h2, h3, h4, h5, h6)")];
      for (const heading of headings.reverse()) {
        const next = heading.nextElementSibling;
        if (!next || next.offsetHeight > budget) continue;
        const keep = document.createElement("div");
        keep.className = "keep-with-next";
        heading.before(keep);
        keep.append(heading, next);
      }
      return 0;
    })()
    """

    /// Takes every heading out of its wrapper again, and returns the page's content.
    static let unwrapScript = """
    (() => {
      for (const keep of document.querySelectorAll(".keep-with-next")) keep.replaceWith(...keep.childNodes);
      return document.getElementById("content").innerHTML;
    })()
    """

    static let stateScript = """
    (() => JSON.stringify({
      html: document.getElementById("content").innerHTML,
      kept: document.querySelectorAll(".keep-with-next").length,
      nested: document.querySelectorAll(".keep-with-next > .keep-with-next").length,
      firstKept: document.getElementById("content").firstElementChild.classList.contains("keep-with-next"),
      alone: document.querySelectorAll("#content > :is(h1, h2, h3, h4, h5, h6)").length
    }))()
    """

    struct State: Decodable, Equatable {
        var html: String
        var kept: Int
        var nested: Int
        var firstKept: Bool
        var alone: Int
    }

    /// Headings before blocks whose heights step across the 300 px budget (code of 10–24 lines:
    /// fractional heights, some a pixel either side of it), runs of two to four headings, a heading
    /// first, last and before a `<!--BREAK-->` marker, and headings before tables and quotes.
    static let fixture: String = {
        // An h6 first: wrapping it gives it back a 20.4 px top margin, a shift by a fraction of a
        // pixel, which can change how every height below rounds.
        var blocks = ["###### First heading", "Opening paragraph."]
        for n in 0..<60 {
            let lines = 10 + n % 15
            let code = "```\n" + (0..<lines).map { "line \($0) of block \(n)" }.joined(separator: "\n") + "\n```"
            switch n % 6 {
            case 0: blocks.append("## Run \(n)\n\n### Sub \(n)\n\n\(code)")
            case 1: blocks.append("# A \(n)\n\n## B \(n)\n\n### C \(n)\n\n#### D \(n)\n\nText under four headings.")
            case 2: blocks.append("### Before a break \(n)\n\n<!--BREAK-->\n\nAfter the break \(n).")
            case 3: blocks.append("## Table \(n)\n\n| a | b |\n|---|---|\n" + (0..<(n % 9 + 1)).map { "| \($0) | x |" }.joined(separator: "\n"))
            case 4: blocks.append("#### Quote \(n)\n\n> " + String(repeating: "Quoted words for \(n). ", count: n % 40 + 1))
            default: blocks.append("## Code \(n)\n\n\(code)\n\nParagraph \(n).")
            }
        }
        blocks.append("## Last heading")
        return blocks.joined(separator: "\n\n") + "\n"
    }()

    @Test(arguments: [false, true])
    func roundsWrapExactlyWhatWrapThenReadDid(markersShown: Bool) async throws {
        let width = ExportLayout.document.printableWidth(paperWidth: DocumentExporter.Paper.a4.size.width)
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false, width: width)
        try await exporter.prepare(markdown: Self.fixture, theme: .dawn)
        let webView = exporter.webView
        func state() async throws -> State {
            let raw = try await webView.evaluateJavaScript(Self.stateScript) as? String ?? "{}"
            return try JSONDecoder().decode(State.self, from: Data(raw.utf8))
        }
        let prepared = try await state()
        _ = try await webView.evaluateJavaScript(Self.unwrapScript)
        // pageBreaks hid the markers after keep-with-next ran; keep-with-next itself saw them.
        if markersShown {
            _ = try await webView.evaluateJavaScript(
                #"document.querySelectorAll("div.html-block").forEach((el) => { el.style.display = ""; }); 0"#)
        }
        _ = try await webView.evaluateJavaScript(Self.wrapThenReadScript)
        let reference = try await state()
        _ = try await webView.evaluateJavaScript(Self.unwrapScript)
        _ = try await webView.evaluateJavaScript(DocumentExporter.keepHeadingsWithNextScript)
        let rounds = try await state()

        // Positive: the fixture exercises what it is for.
        #expect(reference.kept > 40, "some headings kept")
        #expect(reference.nested > 10, "runs of headings kept together")
        #expect(reference.firstKept, "the first heading kept")
        #expect(reference.alone > 5, "some headings before blocks over the budget, left alone")
        #expect(rounds == reference)
        if !markersShown { #expect(prepared == reference, "prepare's own run matches the reference") }
    }
}
#endif
