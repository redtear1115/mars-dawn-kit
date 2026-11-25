#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// iOS Dynamic Type in the real preview page (mars-dawn#652): `--text-scale`, `data-large-text`,
/// print locked to the default size, and switching without moving the reader.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PreviewTextScaleTests {
    private static let headings = "# One\n\n## Two\n\n### Three\n\nBody"

    private static let readStyles = """
        function readStyles() {
          const root = document.documentElement;
          const content = getComputedStyle(document.querySelector('.markdown-body'));
          return {
            scale: getComputedStyle(root).getPropertyValue('--text-scale').trim(),
            inline: root.style.getPropertyValue('--text-scale'),
            large: root.hasAttribute('data-large-text'),
            body: getComputedStyle(document.body).fontSize,
            padding: [content.paddingLeft, content.paddingRight],
            headings: ['h1', 'h2', 'h3'].map(tag => getComputedStyle(document.querySelector(tag)).fontSize),
            bodyPixels: parseFloat(getComputedStyle(document.body).fontSize)
          };
        }
        """

    @Test func defaultAndLargeTextLayout() async throws {
        defer { DetailsPageTests.closeHosts() }
        let webView = try await DetailsPageTests.loadedPreview()
        try await DetailsPageTests.push(Self.headings, to: webView)
        let original = try await DetailsPageTests.json(webView, Self.readStyles + "return readStyles();")
        #expect(original["scale"] as? String == "1")
        #expect(original["inline"] as? String == "")
        #expect(original["large"] as? Bool == false)
        #expect(original["body"] as? String == "15px")
        #expect(original["padding"] as? [String] == ["36px", "36px"])
        #expect((original["headings"] as? [String])?.first == "30px")

        let large = try await DetailsPageTests.json(webView, PreviewWebView.textScaleScript(2) + Self.readStyles + "return readStyles();")
        #expect(large["padding"] as? [String] == ["16px", "16px"])
        #expect(large["headings"] as? [String] == ["45px", "39px", "34.5px"])

        let restored = try await DetailsPageTests.json(webView, PreviewWebView.textScaleScript(1) + Self.readStyles + "return readStyles();")
        #expect(restored["padding"] as? [String] == ["36px", "36px"])
        #expect((restored["headings"] as? [String])?.first == "30px")
    }

    @Test func scaleAndAttributeFollowClampedInput() async throws {
        defer { DetailsPageTests.closeHosts() }
        let webView = try await DetailsPageTests.loadedPreview()
        try await DetailsPageTests.push(Self.headings, to: webView)
        let cases: [(Double, Double, String)] = [
            (1, 1, ""), (1.49, 1.49, "1.49"), (1.5, 1.5, "1.5"), (2, 2, "2"),
            (3, 2, "2"), (0.8, 0.8, "0.8"), (0, 1, ""), (-1, 1, ""),
            (.nan, 1, ""), (.infinity, 1, "")
        ]
        for (input, expected, inline) in cases {
            let state = try await DetailsPageTests.json(webView, PreviewWebView.textScaleScript(input) + Self.readStyles + "return readStyles();")
            #expect(state["inline"] as? String == inline, "scale \(input)")
            #expect(state["large"] as? Bool == (expected >= 1.5), "scale \(input)")
            let pixels = try #require(state["bodyPixels"] as? Double)
            #expect(abs(pixels - expected * 15) < 0.001, "scale \(input)")
        }

        for input in [#""abc""#, "null", "NaN", "Infinity", "0", "-1"] {
            let state = try await DetailsPageTests.json(webView, """
                MarsDawn.setTextScale(2);
                const applied = MarsDawn.setTextScale(\(input));
                \(Self.readStyles)
                return { ...readStyles(), applied };
                """)
            #expect(state["applied"] as? Double == 1, "scale \(input)")
            #expect(state["inline"] as? String == "")
            #expect(state["large"] as? Bool == false)
            #expect(state["body"] as? String == "15px")
        }
    }

    @Test func themeBodySizeScales() async throws {
        defer { DetailsPageTests.closeHosts() }
        let webView = try await DetailsPageTests.loadedPreview()
        try await DetailsPageTests.push(Self.headings, to: webView)
        let state = try await DetailsPageTests.json(webView, """
            MarsDawn.setTheme('classic');
            const original = getComputedStyle(document.body).fontSize;
            \(PreviewWebView.textScaleScript(1.5))
            \(Self.readStyles)
            return { ...readStyles(), original };
            """)
        #expect(state["original"] as? String == "16px")
        #expect(state["body"] as? String == "24px")
    }

    @Test func printLocksScaleAndExcludesLargeTextLayout() async throws {
        defer { DetailsPageTests.closeHosts() }
        let webView = try await DetailsPageTests.loadedPreview()
        try await DetailsPageTests.push(Self.headings, to: webView)
        let state = try await DetailsPageTests.json(webView, """
            MarsDawn.setTextScale(2);
            const sheet = [...document.styleSheets].find(s => s.href?.includes('preview.css'));
            const printBlocks = [];
            const conditions = [];
            const screenBlocks = new Set();
            function visit(rules, media) {
              for (const rule of rules) {
                if (rule instanceof CSSMediaRule) {
                  if (rule.conditionText === 'print') printBlocks.push(rule);
                  visit(rule.cssRules, rule);
                } else if (rule instanceof CSSStyleRule) {
                  // WebKit gives style rules a (nested) `cssRules` too, so test for them first.
                  if (rule.selectorText.includes('data-large-text')) {
                    conditions.push(media?.conditionText ?? '');
                    if (media?.conditionText === 'screen') screenBlocks.add(media);
                  }
                } else if (rule.cssRules) {
                  visit(rule.cssRules, media);
                }
              }
            }
            visit(sheet.cssRules);
            // Emulate print on the screen page by disabling the screen overrides and lifting print rules.
            for (const block of screenBlocks) block.media.mediaText = 'print';
            for (const block of printBlocks) for (const rule of [...block.cssRules])
              sheet.insertRule(rule.cssText, sheet.cssRules.length);
            \(Self.readStyles)
            return { ...readStyles(), conditions };
            """)
        // Four layout rules for every screen, two more for touch (the heading arrows); none for paper.
        let conditions = try #require(state["conditions"] as? [String])
        #expect(conditions.filter { $0 == "screen" }.count == 4)
        #expect(conditions.filter { $0 == "screen and (pointer: coarse)" }.count == 2)
        #expect(conditions.count == 6)
        #expect(state["inline"] as? String == "2")
        #expect(state["large"] as? Bool == true)
        #expect(state["scale"] as? String == "1")
        #expect(state["body"] as? String == "15px")
        #expect((state["headings"] as? [String])?.first == "30px")
        #expect(state["padding"] as? [String] == ["0px", "0px"])
    }

    @Test func userReadingPositionSurvivesRescaling() async throws {
        defer { DetailsPageTests.closeHosts() }
        let webView = try await DetailsPageTests.loadedPreview()
        let markdown = (1...200).map { "## Heading \($0)\n\nParagraph \($0)." }.joined(separator: "\n\n")
        try await DetailsPageTests.push(markdown, to: webView)
        let state = try await DetailsPageTests.json(webView, """
            window.__marker = 1;
            const anchors = [...document.querySelectorAll('.markdown-body [data-line]')];
            const paragraph = anchors.find(el => el.textContent === 'Paragraph 100.');
            const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve));
            function firstVisible() {
              const el = anchors.find(el => el.getBoundingClientRect().bottom > 0);
              return { line: el.dataset.line, top: el.getBoundingClientRect().top };
            }
            window.scrollTo(0, Math.ceil(paragraph.getBoundingClientRect().top + window.scrollY) + 1);
            await nextFrame();
            const before = firstVisible();
            \(PreviewWebView.textScaleScript(2))
            await nextFrame();
            const enlarged = firstVisible();
            \(PreviewWebView.textScaleScript(1))
            await nextFrame();
            return { target: paragraph.dataset.line, before, enlarged, restored: firstVisible(), marker: window.__marker };
            """)
        let target = try #require(state["target"] as? String)
        let before = try #require(state["before"] as? [String: Any])
        let top = try #require(before["top"] as? Double)
        #expect(before["line"] as? String == target)
        for key in ["enlarged", "restored"] {
            let position = try #require(state[key] as? [String: Any])
            #expect(position["line"] as? String == target)
            let current = try #require(position["top"] as? Double)
            #expect(abs(current - top) <= 4)
        }
        #expect(state["marker"] as? Int == 1)
    }

    private static let positionScript = """
        const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve));
        const maxScroll = () => Math.max(0, document.documentElement.scrollHeight - innerHeight);
        const anchors = [...document.querySelectorAll('.markdown-body [data-line]')];
        const position = () => ({ y: scrollY, max: maxScroll(),
                                  first: anchors.find(el => el.getBoundingClientRect().bottom > 0).textContent });
        """

    /// A document that fits the window isn't at its end: when large text makes it scroll, it stays
    /// at its first line instead of jumping to the new bottom.
    @Test func shortDocumentStaysAtItsFirstLineWhenItOutgrowsTheWindow() async throws {
        defer { DetailsPageTests.closeHosts() }
        let webView = try await DetailsPageTests.loadedPreview(height: 844)
        webView.window?.setContentSize(NSSize(width: 390, height: 844))
        let markdown = (1...12).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        try await DetailsPageTests.push(markdown, to: webView)
        let state = try await DetailsPageTests.json(webView, Self.positionScript + """
            const before = position();
            \(PreviewWebView.textScaleScript(2))
            await nextFrame();
            const enlarged = position();
            \(PreviewWebView.textScaleScript(1))
            await nextFrame();
            return { before, enlarged, restored: position() };
            """)
        let before = try #require(state["before"] as? [String: Any])
        #expect(before["max"] as? Double == 0, "positive fixture: the document fits the window")
        let enlarged = try #require(state["enlarged"] as? [String: Any])
        #expect(try #require(enlarged["max"] as? Double) > 0, "positive fixture: large text makes it scroll")
        for key in ["before", "enlarged", "restored"] {
            let position = try #require(state[key] as? [String: Any])
            #expect(position["y"] as? Double == 0, "\(key): \(position)")
            #expect(position["first"] as? String == "Paragraph 1.", "\(key): \(position)")
        }
    }

    /// A long document the reader left at its top or bottom stays there across rescaling.
    @Test(arguments: ["top", "bottom"])
    func longDocumentKeepsItsTopAndBottom(edge: String) async throws {
        defer { DetailsPageTests.closeHosts() }
        let webView = try await DetailsPageTests.loadedPreview()
        let markdown = (1...200).map { "## Heading \($0)\n\nParagraph \($0)." }.joined(separator: "\n\n")
        try await DetailsPageTests.push(markdown, to: webView)
        let state = try await DetailsPageTests.json(webView, Self.positionScript + """
            window.scrollTo(0, \(edge == "bottom" ? "maxScroll()" : "0"));
            await nextFrame();
            const before = position();
            \(PreviewWebView.textScaleScript(2))
            await nextFrame();
            const enlarged = position();
            \(PreviewWebView.textScaleScript(1))
            await nextFrame();
            return { before, enlarged, restored: position() };
            """)
        for key in ["before", "enlarged", "restored"] {
            let position = try #require(state[key] as? [String: Any])
            let y = try #require(position["y"] as? Double)
            let max = try #require(position["max"] as? Double)
            #expect(max > 0, "positive fixture: the document scrolls (\(key))")
            if edge == "bottom" {
                #expect(abs(y - max) <= 1, "\(key) stays at the bottom: \(position)")
            } else {
                #expect(y == 0, "\(key) stays at the top: \(position)")
            }
        }
    }

    @Test func swiftBridgeClampsBeforeGeneratingJavaScript() {
        #expect(PreviewWebView.textScaleScript(1.5) == "window.MarsDawn && MarsDawn.setTextScale(1.5);")
        #expect(PreviewWebView.textScaleScript(0) == "window.MarsDawn && MarsDawn.setTextScale(1.0);")
        #expect(PreviewWebView.textScaleScript(.nan) == "window.MarsDawn && MarsDawn.setTextScale(1.0);")
        #expect(PreviewWebView.textScaleScript(5) == "window.MarsDawn && MarsDawn.setTextScale(2.0);")
    }
}
#endif
