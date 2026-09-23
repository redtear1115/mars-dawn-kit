#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Display math keeps its shape when the page is zoomed (#144). The app zooms the preview with
/// `pageZoom`, and at 75% and below an operator with side limits (`\int_0^\infty`) sank about 0.9 em
/// away from its limits: KaTeX anchors each vlist's baseline on a zero-width space in a
/// `font-size: 1px` cell (`.vlist-s`), and under that zoom WebKit drops the 1px text, so the line
/// box grows and the operator falls. preview.css gives that cell 2px, which survives.
///
/// Each construct is laid out at 100% and at the other zooms, and every element's position in CSS
/// px is compared. Below 75% WebKit also stops shrinking text specified at 9px or more below 9
/// device px, which makes scripts a little larger; that moves things by a few px, and the tolerance
/// allows it, while the sink it guards against moves them by about 16.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PreviewMathZoomTests {
    nonisolated static let constructs: [(String, String)] = [
        ("integral with limits", #"\int_0^\infty e^{-x^2}\,dx"#),
        ("sum with limits", #"\sum_{k=1}^{n} k^2"#),
        ("fraction", #"\frac{n(n+1)}{2}"#),
        ("square root", #"\sqrt{\pi}"#),
        ("superscript", #"x^2 + y_i^2"#),
        ("matrix", #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#),
        ("aligned", #"\begin{aligned} a &= b + c \\ d &= e \end{aligned}"#),
    ]
    static let zooms: [Double] = [0.5, 0.75, 3.0]

    /// Largest vertical shift of any element, in CSS px, that still counts as the same layout.
    static let tolerance = 6.0

    private func loadedPreview() async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!webView.isLoading)
        return webView
    }

    private struct Layout: Decodable {
        let height: Double
        let tops: [Double]
        let fonts: [String]
        let labels: [String]
    }

    /// Every element of the display's HTML tree: its top relative to the formula, in CSS px.
    private func layout(in webView: WKWebView) async throws -> Layout {
        let json = try await webView.callAsyncJavaScript("""
            await document.fonts.ready;
            // Not requestAnimationFrame: a web view without a window may never run one.
            await new Promise(r => setTimeout(r, 150));
            const k = document.querySelector('.math-block .katex');
            const html = k.querySelector('.katex-html');
            const top = k.getBoundingClientRect().top;
            return JSON.stringify({
                height: html.getBoundingClientRect().height,
                tops: [...html.querySelectorAll('*')].map(e => e.getBoundingClientRect().top - top),
                fonts: [...html.querySelectorAll('*')].map(e => getComputedStyle(e).fontSize),
                labels: [...html.querySelectorAll('*')].map(e => (e.className || e.tagName) + ' "' + e.textContent.slice(0, 12) + '"')
            });
            """, contentWorld: .page) as? String
        return try JSONDecoder().decode(Layout.self, from: Data(try #require(json).utf8))
    }

    @Test(arguments: constructs)
    func displayMathKeepsItsLayoutWhenZoomed(name: String, tex: String) async throws {
        let webView = try await loadedPreview()
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render("$$\n\(tex)\n$$\n"), lineCount: 3))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)

        webView.pageZoom = 1
        let reference = try await layout(in: webView)
        #expect(reference.tops.count > 3, "positive fixture: \(name) rendered as KaTeX")

        for zoom in Self.zooms {
            webView.pageZoom = zoom
            let zoomed = try await layout(in: webView)
            try #require(zoomed.tops.count == reference.tops.count, "\(name) at \(zoom): same tree")
            // Elements WebKit drew at its 9-device-px floor have a different computed size; they
            // move because they grew, which is the floor, not this bug. Everything else must stay.
            let compared = reference.tops.indices.filter { reference.fonts[$0] == zoomed.fonts[$0] }
            let clamped = reference.tops.count - compared.count
            let worst = compared.max { abs(reference.tops[$0] - zoomed.tops[$0]) < abs(reference.tops[$1] - zoomed.tops[$1]) }
            let shift = worst.map { abs(reference.tops[$0] - zoomed.tops[$0]) } ?? 0
            let label = worst.map { zoomed.labels[$0] } ?? "-"
            #expect(compared.count > reference.tops.count / 2, "\(name) at \(zoom): most elements are comparable (\(clamped) clamped)")
            #expect(shift <= Self.tolerance,
                    "\(name) at \(Int(zoom * 100))%: \(label) moved \(shift) CSS px (\(clamped) clamped elements left out)")
            #expect(abs(zoomed.height - reference.height) <= Self.tolerance,
                    "\(name) at \(Int(zoom * 100))%: the formula's height went \(reference.height) → \(zoomed.height) CSS px")
        }
    }
}
#endif
