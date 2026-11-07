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

    @Test func coarsePointerShowsFoldingAndProvidesTouchTargets() async throws {
        defer { Self.closeHosts() }
        let webView = try await Self.loadedPreview()
        try await Self.push(Self.touchFoldDocument, to: webView)
        let before = try await Self.json(webView, """
            const el = document.querySelector('h2 > .md-fold-toggle');
            return { coarse: matchMedia('(pointer: coarse)').matches,
                     opacity: getComputedStyle(el).opacity,
                     width: el.getBoundingClientRect().width, height: el.getBoundingClientRect().height };
            """)
        #expect(before["coarse"] as? Bool == false)
        #expect(before["opacity"] as? String == "0")
        #expect(try #require(before["width"] as? Double) < 44)
        #expect(try #require(before["height"] as? Double) < 44)
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
        let conditions = try #require(lifted["conditions"] as? [String])
        #expect(conditions.count == 1)
        #expect(conditions.allSatisfy { $0.contains("screen") })
        let state = try await Self.json(webView, """
            const controls = [...document.querySelectorAll('.md-fold-toggle, pre > .md-fold-block')];
            const summaries = [...document.querySelectorAll('details > summary')];
            return {
              controls: controls.map(el => {
                const after = getComputedStyle(el, '::after');
                return { opacity: Number(getComputedStyle(el).opacity), content: after.content,
                         width: parseFloat(after.width), height: parseFloat(after.height) };
              }),
              summaries: summaries.map(el => el.getBoundingClientRect().height),
              frontMatter: !!document.querySelector('.front-matter > summary'),
              callout: !!document.querySelector('summary.callout-title')
            };
            """)
        let controls = try #require(state["controls"] as? [[String: Any]])
        #expect(controls.count == 4)
        for control in controls {
            #expect(try #require(control["opacity"] as? Double) > 0)
            #expect(control["content"] as? String == "\"\"")
            #expect(try #require(control["width"] as? Double) >= 44)
            #expect(try #require(control["height"] as? Double) >= 44)
        }
        #expect(state["frontMatter"] as? Bool == true)
        #expect(state["callout"] as? Bool == true)
        let heights = try #require(state["summaries"] as? [Double])
        #expect(heights.count == 3)
        #expect(heights.allSatisfy { $0 >= 44 })
        // The arrow's target grows into the margin and stops at the heading's text.
        let hits = try await Self.json(webView, """
            const out = [];
            for (const h of document.querySelectorAll('h2, h3, h4')) {
              const toggle = h.querySelector(':scope > .md-fold-toggle');
              const box = toggle.getBoundingClientRect();
              const range = document.createRange();
              range.selectNodeContents(h);
              range.setStartAfter(toggle);
              const text = range.getClientRects()[0];
              const y = box.top + box.height / 2;
              out.push({ margin: toggle.contains(document.elementFromPoint(box.right - 30, y)),
                         text: toggle.contains(document.elementFromPoint(text.left + 2, y)) });
            }
            return { out };
            """)
        let hitList = try #require(hits["out"] as? [[String: Any]])
        #expect(hitList.count == 3)
        for hit in hitList {
            #expect(hit["margin"] as? Bool == true, "30 px into the margin still folds: \(hit)")
            #expect(hit["text"] as? Bool == false, "the heading's text isn't the arrow's: \(hit)")
        }
        let collapsed = try await Self.json(webView, """
            document.querySelector('pre > .md-fold-block').click();
            await new Promise(r => setTimeout(r, 200));
            const bar = document.querySelector('.md-block-collapsed > .md-fold-block');
            const result = { height: bar.getBoundingClientRect().height, position: getComputedStyle(bar).position,
                             opacity: getComputedStyle(bar).opacity };
            document.querySelector('h4 > .md-fold-toggle').click();
            await new Promise(r => setTimeout(r, 200));
            result.headingOpacity = getComputedStyle(document.querySelector('h4 > .md-fold-toggle')).opacity;
            return result;
            """)
        #expect(try #require(collapsed["height"] as? Double) >= 44)
        #expect(collapsed["position"] as? String == "relative")
        #expect(collapsed["opacity"] as? String == "1")
        #expect(collapsed["headingOpacity"] as? String == "1")
    }
}
#endif
