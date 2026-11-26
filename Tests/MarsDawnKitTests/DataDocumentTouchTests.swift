#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// The tree on touch devices (mars-dawn#533): rows and Show More reach 44 pt, and a phone's width
/// holds a deep value. The Mac's WebKit never matches `pointer: coarse`, so `applyTouchRules` lifts
/// those rules out of their media blocks and the page is measured with them in force.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DataDocumentTouchTests {
    /// Eight levels down to a long value, and a string long enough for Show More.
    private static var document: String {
        let deep = (0..<8).reduce(#""\#(String(repeating: "value ", count: 40))""#) { #"{"level\#($1)": \#($0)}"# }
        return #"{"deep": \#(deep), "long": "\#(String(repeating: "v", count: 25_000))"}"#
    }

    private func page(width: CGFloat) async throws -> WKWebView {
        let webView = try await DataPage.load()
        webView.setFrameSize(NSSize(width: width, height: 800))
        #expect(await DataPage.render(Self.document, kind: .json, in: webView, limits: ["autoExpandDepth": 12]) == .rendered)
        #expect(try await DataPage.int("document.querySelectorAll('#data .data-more').length", in: webView) >= 1, "positive fixture")
        return webView
    }

    /// Moves every rule of the touch media blocks to the top level; answers how many blocks it found.
    private func applyTouchRules(in webView: WKWebView) async throws -> Int {
        try await DataPage.int("""
        (() => {
          const sheet = Array.from(document.styleSheets).find((s) => s.href && s.href.includes('data.css'));
          const blocks = Array.from(sheet.cssRules).filter((r) => r instanceof CSSMediaRule && r.conditionText.includes('pointer: coarse'));
          for (const block of blocks) for (const rule of Array.from(block.cssRules)) sheet.insertRule(rule.cssText, sheet.cssRules.length);
          return blocks.length;
        })()
        """, in: webView)
    }

    private func height(_ selector: String, in webView: WKWebView) async throws -> Double {
        try await DataPage.value("document.querySelector('#data \(selector)').getBoundingClientRect().height", in: webView) as? Double ?? -1
    }

    private func overflow(in webView: WKWebView) async throws -> Int {
        try await DataPage.int("document.documentElement.scrollWidth - document.documentElement.clientWidth", in: webView)
    }

    @Test func aPointerKeepsTheDesktopLayout() async throws {
        let webView = try await page(width: 800)
        #expect(try await DataPage.value("matchMedia('(pointer: coarse)').matches", in: webView) as? Bool == false)
        let values = try await DataPage.value("""
        (() => {
          const of = (selector) => getComputedStyle(document.querySelector('#data ' + selector));
          const toggle = of('.data-toggle'), more = of('.data-more');
          return [toggle.display, toggle.paddingTop, more.minHeight, more.paddingLeft,
                  of('.data-panel').paddingLeft, Math.round(parseFloat(of('.data-children').paddingLeft))].join(' ');
        })()
        """, in: webView) as? String
        #expect(values == "inline-block 0px 0px 10px 16px 18", "\(values ?? "-")")
        #expect(try await height(".data-toggle", in: webView) < 44, "the rows are only tall on touch")
        #expect(try await height(".data-more", in: webView) < 44)
    }

    @Test func touchRowsAndShowMoreAreTallEnough() async throws {
        let webView = try await page(width: 390)
        #expect(try await height(".data-toggle", in: webView) < 44, "positive fixture: not tall yet")
        #expect(try await applyTouchRules(in: webView) == 2)
        #expect(try await height(".data-toggle", in: webView) >= 44)
        #expect(try await height(".data-more", in: webView) >= 44)
    }

    @Test func aDeepValueFitsAPhoneWidth() async throws {
        let webView = try await page(width: 320)
        #expect(try await applyTouchRules(in: webView) == 2)
        let levels = try await DataPage.int("""
        (() => {
          let at = Array.from(document.querySelectorAll('#data .data-string')).find((e) => e.textContent.includes('value value')), n = 0;
          for (; at && at.id !== 'data'; at = at.parentElement) if (at.classList.contains('data-children')) n++;
          return n;
        })()
        """, in: webView)
        #expect(levels >= 8, "positive fixture: the value is drawn at level \(levels)")
        #expect(try await overflow(in: webView) <= 0)
    }
}
#endif
