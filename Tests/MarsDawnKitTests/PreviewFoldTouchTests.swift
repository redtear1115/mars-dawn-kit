#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Measure touch CSS in the real page by lifting its media rules: Mac WebKit has a fine pointer.
extension DetailsPageTests {
    private static var touchFoldDocument: String {
        """
        ---
        title: Touch fixture
        ---

        ## Two

        two body

        ### Three

        three body

        #### Four

        four body

        ```text
        \((1...25).map { "line \($0)" }.joined(separator: "\n"))
        ```

        :::spoiler Spoiler title
        Hidden body
        :::

        > [!note]- Title
        > Callout body
        """
    }

    @Test func finePointerKeepsPreviewFoldingUnchanged() async throws {
        defer { Self.closeHosts() }
        let webView = try await Self.loadedPreview()
        try await Self.push(Self.touchFoldDocument, to: webView)
        let state = try await Self.json(webView, """
            const controls = [...document.querySelectorAll('.md-fold-toggle, pre > .md-fold-block')];
            const summaries = [...document.querySelectorAll('details > summary')];
            return {
              coarse: matchMedia('(pointer: coarse)').matches,
              controls: controls.map(el => {
                const rect = el.getBoundingClientRect();
                return { opacity: getComputedStyle(el).opacity,
                         after: getComputedStyle(el, '::after').content,
                         width: rect.width, height: rect.height };
              }),
              summaries: summaries.map(el => el.getBoundingClientRect().height)
            };
            """)
        #expect(state["coarse"] as? Bool == false)
        let controls = try #require(state["controls"] as? [[String: Any]])
        #expect(controls.count == 4, "three heading toggles and one code control")
        for control in controls {
            #expect(control["opacity"] as? String == "0")
            #expect(control["after"] as? String == "none")
            #expect(try #require(control["width"] as? Double) < 44)
            #expect(try #require(control["height"] as? Double) < 44)
        }
        let heights = try #require(state["summaries"] as? [Double])
        #expect(heights.count == 3, "spoiler, callout and front matter")
        #expect(heights.allSatisfy { $0 < 44 })
    }

    /// Lifts the page's `pointer: coarse` rules to the top level, as if the pointer were a finger.
    private static func liftTouchRules(_ webView: PreviewWKWebView) async throws -> [String] {
        let lifted = try await Self.json(webView, """
            const sheet = [...document.styleSheets].find(s => s.href?.includes('preview.css'));
            const blocks = [];
            function visit(rules) {
              for (const rule of [...rules]) {
                if (rule instanceof CSSMediaRule && rule.conditionText.includes('pointer: coarse')) blocks.push(rule);
                else if (rule.cssRules) visit(rule.cssRules);
              }
            }
            visit(sheet.cssRules);
            for (const block of blocks) for (const rule of [...block.cssRules])
              sheet.insertRule(rule.cssText, sheet.cssRules.length);
            // Let the existing opacity transition finish before measuring.
            await new Promise(r => setTimeout(r, 200));
            return { conditions: blocks.map(b => b.conditionText) };
            """)
        return try #require(lifted["conditions"] as? [String])
    }

    /// Where a tap really lands, not how big a box is: `document.elementFromPoint` one pixel at a
    /// time across and down through the control, after scrolling it into view. A target that
    /// reaches past the page's edge or is clipped by a scrolling `pre` comes out smaller.
    private static let hitScript = """
        function hitBox(el) {
          el.scrollIntoView({ block: 'center' });
          const r = el.getBoundingClientRect();
          const hits = (x, y) => { const e = document.elementFromPoint(x, y); return !!e && el.contains(e); };
          const cy = r.top + r.height / 2;
          const xs = [];
          for (let x = Math.floor(r.left) - 80; x <= Math.ceil(r.right) + 80; x++) if (hits(x, cy)) xs.push(x);
          if (!xs.length) return { width: 0, height: 0 };
          const cx = (xs[0] + xs[xs.length - 1]) / 2;
          const ys = [];
          for (let y = Math.floor(r.top) - 80; y <= Math.ceil(r.bottom) + 80; y++) if (hits(cx, y)) ys.push(y);
          return { width: xs.length, height: ys.length, left: xs[0], contiguous: xs[xs.length - 1] - xs[0] + 1 === xs.length };
        }
        """

    @Test(arguments: [600.0, 390.0])
    func coarsePointerShowsFoldingAndGivesRealTouchTargets(width: Double) async throws {
        defer { Self.closeHosts() }
        let webView = try await Self.loadedPreview()
        webView.window?.setContentSize(NSSize(width: width, height: 800))
        try await Self.push(Self.touchFoldDocument, to: webView)
        let before = try await Self.json(webView, Self.hitScript + """
            const el = document.querySelector('h2 > .md-fold-toggle');
            return { coarse: matchMedia('(pointer: coarse)').matches, opacity: getComputedStyle(el).opacity,
                     innerWidth, hit: hitBox(el) };
            """)
        #expect(before["coarse"] as? Bool == false)
        #expect(before["opacity"] as? String == "0")
        #expect(abs((before["innerWidth"] as? Double ?? 0) - width) <= 1, "positive fixture: the page is \(width) wide")
        let beforeHit = try #require(before["hit"] as? [String: Any])
        #expect(try #require(beforeHit["width"] as? Double) < 44, "positive fixture: a fine pointer's arrow is small")

        let conditions = try await Self.liftTouchRules(webView)
        #expect(conditions.count == 1)
        #expect(conditions.allSatisfy { $0.contains("screen") })

        let state = try await Self.json(webView, Self.hitScript + """
            const controls = [...document.querySelectorAll('.md-fold-toggle, pre > .md-fold-block')];
            return {
              controls: controls.map(el => ({ name: el.parentElement.tagName, opacity: Number(getComputedStyle(el).opacity), hit: hitBox(el) })),
              summaries: [...document.querySelectorAll('details > summary')].map(el => el.getBoundingClientRect().height),
              frontMatter: !!document.querySelector('.front-matter > summary'),
              callout: !!document.querySelector('summary.callout-title')
            };
            """)
        let controls = try #require(state["controls"] as? [[String: Any]])
        #expect(controls.count == 4, "three heading arrows and one code block control")
        for control in controls {
            let hit = try #require(control["hit"] as? [String: Any])
            #expect(try #require(control["opacity"] as? Double) > 0, "\(control)")
            #expect(try #require(hit["width"] as? Double) >= 44, "taps land on \(control)")
            #expect(try #require(hit["height"] as? Double) >= 44, "taps land on \(control)")
            #expect(hit["contiguous"] as? Bool == true, "\(control)")
            #expect(try #require(hit["left"] as? Double) >= 0, "inside the page: \(control)")
        }
        #expect(state["frontMatter"] as? Bool == true)
        #expect(state["callout"] as? Bool == true)
        let heights = try #require(state["summaries"] as? [Double])
        #expect(heights.count == 3)
        #expect(heights.allSatisfy { $0 >= 44 })

        // The arrow's target stops at the heading's text: a link there still takes the tap.
        let hits = try await Self.json(webView, """
            const out = [];
            for (const h of document.querySelectorAll('h2, h3, h4')) {
              h.scrollIntoView({ block: 'center' });
              const toggle = h.querySelector(':scope > .md-fold-toggle');
              const box = toggle.getBoundingClientRect();
              const range = document.createRange();
              range.selectNodeContents(h);
              range.setStartAfter(toggle);
              const text = range.getClientRects()[0];
              out.push(toggle.contains(document.elementFromPoint(text.left + 2, box.top + box.height / 2)));
            }
            return { out };
            """)
        let onText = try #require(hits["out"] as? [Bool])
        #expect(onText == [false, false, false], "the heading's text isn't the arrow's")

        let collapsed = try await Self.json(webView, Self.hitScript + """
            document.querySelector('pre > .md-fold-block').click();
            await new Promise(r => setTimeout(r, 200));
            const bar = document.querySelector('.md-block-collapsed > .md-fold-block');
            const result = { hit: hitBox(bar), opacity: getComputedStyle(bar).opacity };
            document.querySelector('h4 > .md-fold-toggle').click();
            await new Promise(r => setTimeout(r, 200));
            result.headingOpacity = getComputedStyle(document.querySelector('h4 > .md-fold-toggle')).opacity;
            return result;
            """)
        let barHit = try #require(collapsed["hit"] as? [String: Any])
        #expect(try #require(barHit["height"] as? Double) >= 44)
        #expect(collapsed["opacity"] as? String == "1")
        #expect(collapsed["headingOpacity"] as? String == "1")
    }
}
#endif
