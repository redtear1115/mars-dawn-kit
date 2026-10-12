#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// `<details>` grouping in the real preview page (redtear1115/mars-dawn#414): the DOM a browser
/// builds from the renderer's output, how it opens, and how scroll sync and `update()` treat it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(4)))
struct DetailsPageTests {
    // MARK: Harness

    /// The windows holding this test's pages. A web view with no window may never run an
    /// animation frame, and the page's scroll sync and toggle handling wait for one, as they do
    /// in the app and in Quick Look, where the view is always in a window.
    fileprivate static var hosts: [NSWindow] = []

    /// Set `DETAILS_RAF_STANDIN=1` on a machine whose screen is locked: the page gets a
    /// `setTimeout` in place of `requestAnimationFrame`, which a hidden page never runs. That
    /// shows the mechanism works, not that the real frame loop does; the tests are run again
    /// without it whenever the screen is unlocked.
    static let standIn = ProcessInfo.processInfo.environment["DETAILS_RAF_STANDIN"] == "1"

    static func closeHosts() {
        for window in hosts { window.contentView = nil; window.close() }
        hosts = []
    }

    static func loadedPreview(height: CGFloat = 800) async throws -> PreviewWKWebView {
        let configuration = PreviewWebView.makeConfiguration()
        if standIn {
            configuration.userContentController.addUserScript(WKUserScript(
                source: "window.requestAnimationFrame = (f) => setTimeout(() => f(performance.now()), 16);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: height), configuration: configuration)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderFrontRegardless()
        hosts.append(window)
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!webView.isLoading)
        return webView
    }

    fileprivate static func push(_ markdown: String, to webView: PreviewWKWebView) async throws {
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: LineIndex(markdown).lineCount)
        )
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    fileprivate static func json(_ webView: PreviewWKWebView, _ body: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let text = try #require(try await webView.callAsyncJavaScript(
            "return JSON.stringify(await (async () => {\(body)})());", arguments: arguments, contentWorld: .page
        ) as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func loaded(_ markdown: String) async throws -> PreviewWKWebView {
        let webView = try await Self.loadedPreview()
        try await Self.push(markdown, to: webView)
        return webView
    }

    // MARK: A1, A2, A3

    @Test func theGitHubFormIsOneElementWithItsMarkdownInside() async throws {
        defer { Self.closeHosts() }
        let webView = try await loaded(DetailsFixture.markdown)
        let state = try await Self.json(webView, """
            const content = document.getElementById("content");
            const a = content.querySelector("details");
            const after = [...content.querySelectorAll("p")].find((p) => p.textContent.startsWith("A 之後的段落"));
            return {
              blocks: content.querySelectorAll(":scope > .html-block").length,
              aParent: a.parentElement.className,
              summary: a.querySelector(":scope > summary").textContent,
              strong: !!a.querySelector(":scope > p > strong"), code: !!a.querySelector(":scope > p > code"),
              ul: a.querySelectorAll(":scope > ul > li").length, pre: !!a.querySelector(":scope > pre code"),
              afterOutside: !a.contains(after) && after.parentElement === content,
              literal: content.textContent.includes("</details>"),
              open: a.open,
            };
        """)
        #expect(state["blocks"] as? Int == 3)
        #expect(state["aParent"] as? String == "html-block")
        #expect(state["summary"] as? String == "A 補充細節")
        #expect(state["strong"] as? Bool == true)
        #expect(state["code"] as? Bool == true)
        #expect(state["ul"] as? Int == 2)
        #expect(state["pre"] as? Bool == true)
        #expect(state["afterOutside"] as? Bool == true)
        #expect(state["literal"] as? Bool == false)
        #expect(state["open"] as? Bool == false, "collapsed")
    }

    @Test func openIsKeptAndTheNestedOneIsInsideTheOuter() async throws {
        defer { Self.closeHosts() }
        let webView = try await loaded(DetailsFixture.markdown)
        let state = try await Self.json(webView, """
            const content = document.getElementById("content");
            const [a, c, outer, inner] = [...content.querySelectorAll("details")];
            return {
              count: content.querySelectorAll("details").length,
              cOpen: c.open, cText: c.textContent.includes("C 內文"),
              outerOpen: outer.open, innerOpen: inner.open,
              nested: inner.parentElement === outer, sameBlock: outer.parentElement === inner.closest(".html-block"),
              outerBlocks: content.querySelectorAll(":scope > .html-block > details").length,
              innerText: inner.textContent.includes("G 內文"), outerText: outer.textContent.includes("G 外文"),
              outerOwnText: [...outer.childNodes].some((n) => n.nodeType === 1 && n.tagName === "P" && n.textContent === "G 外文"),
              lastOutside: [...content.children].at(-1).textContent.includes("END-OF-FIXTURE"),
            };
        """)
        #expect(state["count"] as? Int == 4)
        #expect(state["cOpen"] as? Bool == true)
        #expect(state["cText"] as? Bool == true)
        #expect(state["outerOpen"] as? Bool == false)
        #expect(state["innerOpen"] as? Bool == false)
        #expect(state["nested"] as? Bool == true)
        #expect(state["sameBlock"] as? Bool == true)
        #expect(state["outerBlocks"] as? Int == 3, "A, C and G's outer one: three top-level blocks")
        #expect(state["innerText"] as? Bool == true)
        #expect(state["outerText"] as? Bool == true)
        #expect(state["outerOwnText"] as? Bool == true)
        #expect(state["lastOutside"] as? Bool == true)
    }

    // MARK: A5

    @Test func theSameGroupingInsideABlockQuoteAndAListItem() async throws {
        defer { Self.closeHosts() }
        let webView = try await loaded("""
            > <details>
            > <summary>Quoted</summary>
            >
            > Quote **body**
            >
            > </details>

            after quote

            - <details>
              <summary>Listed</summary>

              Item **body**

              </details>

            - second item
            """)
        let state = try await Self.json(webView, """
            const content = document.getElementById("content");
            const quoted = content.querySelector("blockquote > .html-block > details");
            const listed = content.querySelector("ul > li > .html-block > details");
            return {
              quoted: quoted.querySelector(":scope > summary").textContent, quotedBody: !!quoted.querySelector(":scope > p > strong"),
              listed: listed.querySelector(":scope > summary").textContent, listedBody: !!listed.querySelector(":scope > p > strong"),
              quoteHolds: content.querySelector("blockquote").textContent.includes("after quote"),
              items: content.querySelectorAll("ul > li").length,
              literal: content.textContent.includes("</details>"),
            };
        """)
        #expect(state["quoted"] as? String == "Quoted")
        #expect(state["quotedBody"] as? Bool == true)
        #expect(state["listed"] as? String == "Listed")
        #expect(state["listedBody"] as? Bool == true)
        #expect(state["quoteHolds"] as? Bool == false)
        #expect(state["items"] as? Int == 2)
        #expect(state["literal"] as? Bool == false)
    }

    // MARK: A7, page level

    @Test func theDomFilterStillRemovesMetaAndBaseInsideAGroup() async throws {
        defer { Self.closeHosts() }
        let webView = try await loaded("""
            <details>
            <summary>S</summary>

            <div>
            <meta http-equiv="refresh" content="0;url=https://example.com/">
            <base href="https://example.com/">
            <span id="kept">kept</span>
            </div>

            inner **text**

            </details>
            """)
        let state = try await Self.json(webView, """
            const content = document.getElementById("content");
            return {
              meta: content.querySelectorAll("meta, base").length,
              kept: !!content.querySelector("details #kept"),
              strong: !!content.querySelector("details > p > strong"),
              base: document.baseURI,
            };
        """)
        #expect(state["meta"] as? Int == 0)
        #expect(state["kept"] as? Bool == true)
        #expect(state["strong"] as? Bool == true)
        #expect(!(state["base"] as? String ?? "").contains("example.com"))
    }

    // MARK: A15, chained groups on the parsed DOM

    @Test func chainedDetailsAreSeparateElementsInOneBlock() async throws {
        defer { Self.closeHosts() }
        let webView = try await loaded("""
            <details>
            <summary>One</summary>

            first body

            </details>
            <details>
            <summary>Two</summary>

            second body

            </details>

            after both
            """)
        let state = try await Self.json(webView, """
            const content = document.getElementById("content");
            const [one, two] = [...content.querySelectorAll("details")];
            const after = [...content.querySelectorAll("p")].find((p) => p.textContent === "after both");
            return {
              count: content.querySelectorAll("details").length,
              oneText: one.textContent, twoText: two.textContent,
              oneSiblings: one.nextElementSibling === two, nested: one.contains(two) || two.contains(one),
              afterOutside: !one.contains(after) && !two.contains(after) && after.parentElement === content,
              blocks: content.querySelectorAll(":scope > .html-block").length,
            };
        """)
        #expect(state["count"] as? Int == 2)
        let one = state["oneText"] as? String ?? ""
        let two = state["twoText"] as? String ?? ""
        #expect(one.contains("first body") && !one.contains("second body") && !one.contains("Two"))
        #expect(two.contains("second body") && !two.contains("first body") && !two.contains("One"))
        #expect(state["oneSiblings"] as? Bool == true)
        #expect(state["nested"] as? Bool == false)
        #expect(state["afterOutside"] as? Bool == true)
        #expect(state["blocks"] as? Int == 1)
    }

    // MARK: A13, collapsed on a normal load

    @Test func collapsedAfterLoadAndAfterAFollowingUpdate() async throws {
        defer { Self.closeHosts() }
        let markdown = "---\ntitle: T\n---\n" + DetailsFixture.markdown
        let webView = try await loaded(markdown)
        let probe = """
            const content = document.getElementById("content");
            const [fm, a, c, outer, inner] = [...content.querySelectorAll("details")];
            return {
              fmClass: fm.className, fmOpen: fm.open, a: a.open, c: c.open, outer: outer.open, inner: inner.open,
              count: content.querySelectorAll("details").length,
            };
        """
        func expectState(_ state: [String: Any], _ when: String) {
            #expect(state["count"] as? Int == 5, "\(when)")
            #expect(state["fmClass"] as? String == "front-matter", "\(when)")
            #expect(state["fmOpen"] as? Bool == false, "\(when): front matter closed")
            #expect(state["a"] as? Bool == false, "\(when): A")
            #expect(state["c"] as? Bool == true, "\(when): C")
            #expect(state["outer"] as? Bool == false, "\(when): G outer")
            #expect(state["inner"] as? Bool == false, "\(when): G inner")
        }
        expectState(try await Self.json(webView, probe), "after load")
        try await Self.push(markdown + "\nA new last paragraph.\n", to: webView)
        expectState(try await Self.json(webView, probe), "after a following update")

        let clicked = try await Self.json(webView, """
            const a = document.querySelectorAll("#content details")[1];
            a.querySelector("summary").click();
            return { open: a.open, c: document.querySelectorAll("#content details")[2].open };
        """)
        #expect(clicked["open"] as? Bool == true, "clicking A's summary opens it")
        #expect(clicked["c"] as? Bool == true)
    }

    // MARK: A9, reuse

    @Test func anEditAfterAGroupKeepsItOpen() async throws {
        defer { Self.closeHosts() }
        let webView = try await loaded(DetailsFixture.markdown)
        _ = try await Self.json(webView, """
            const a = document.querySelector("#content details");
            a.open = true; a._probe = "same element";
            return {};
        """)
        try await Self.push(DetailsFixture.markdown + "\nTyped at the end.\n", to: webView)
        let kept = try await Self.json(webView, """
            const a = document.querySelector("#content details");
            return { probe: a._probe ?? null, open: a.open, typed: document.getElementById("content").textContent.includes("Typed at the end.") };
        """)
        #expect(kept["typed"] as? Bool == true)
        #expect(kept["probe"] as? String == "same element", "the group's element is reused")
        #expect(kept["open"] as? Bool == true, "and so its open state survives")
    }

    /// Known behaviour, recorded rather than required: an edit inside a group changes the
    /// group's block key, so its element may be rebuilt and come back collapsed.
    @Test func anEditInsideAGroupMayRebuildIt() async throws {
        defer { Self.closeHosts() }
        let webView = try await loaded(DetailsFixture.markdown)
        _ = try await Self.json(webView, """
            const a = document.querySelector("#content details");
            a.open = true; a._probe = "same element";
            return {};
        """)
        try await Self.push(DetailsFixture.markdown.replacingOccurrences(of: "A 清單二", with: "A 清單二 edited"), to: webView)
        let state = try await Self.json(webView, """
            const a = document.querySelector("#content details");
            return { probe: a._probe ?? null, open: a.open, edited: a.textContent.includes("A 清單二 edited") };
        """)
        #expect(state["edited"] as? Bool == true, "the edit shows")
        print("A9 edit inside a group: element reused = \(state["probe"] as? String == "same element"), still open = \(state["open"] as? Bool ?? false)")
    }

    // MARK: A17, CSP

    @Test func theScriptPolicyHasNoInlineAllowance() throws {
        defer { Self.closeHosts() }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/index.html")
        let page = try String(contentsOf: url, encoding: .utf8)
        let policy = try #require(page.components(separatedBy: "content=\"").first { $0.hasPrefix("default-src") })
        let scriptSrc = try #require(policy.components(separatedBy: ";").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("script-src") })
        #expect(scriptSrc.trimmingCharacters(in: .whitespaces) == "script-src marsdawn-app:")
        #expect(!scriptSrc.contains("unsafe-inline") && !scriptSrc.contains("unsafe-hashes"))
    }

    @Test func anInlineToggleHandlerInsideAGroupNeverRuns() async throws {
        defer { Self.closeHosts() }
        let webView = try await Self.visiblePreview()
        let before = try Self.titleOf(try await Self.json(webView, "return { title: document.title };"))
        try await Self.push(Self.inlineHandlerGroup, to: webView)
        let state = try await Self.json(webView, """
            window.__toggles = 0;
            document.addEventListener("toggle", () => { window.__toggles++; }, true);
            const inner = document.querySelector("#content details details");
            inner.open = false; inner.open = true; inner.open = false;
            return { has: inner.hasAttribute("ontoggle") };
        """)
        #expect(state["has"] as? Bool == true, "positive fixture: the attribute is there")
        let seen = try await Self.json(webView, """
            await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
            await new Promise((r) => setTimeout(r, 100));
            return { toggles: window.__toggles, title: document.title };
        """)
        #expect((seen["toggles"] as? Int ?? 0) >= 1, "positive fixture: toggle events fired")
        #expect(try Self.titleOf(seen) == before)
    }

    static let inlineHandlerGroup = """
        <details>
        <summary>S</summary>

        <div>
        <details open ontoggle="document.title='x'"><summary>t</summary>inner</details>
        </div>

        </details>
        """

    /// A preview page in a window that is really showing, or a failure that says why not:
    /// while the screen is locked or the display asleep WebKit reports the page hidden and
    /// never runs an animation frame, and a test that waited for one would hang.
    static func visiblePreview(height: CGFloat = 800) async throws -> PreviewWKWebView {
        let webView = try await loadedPreview(height: height)
        let state = try await json(webView, "return { visibility: document.visibilityState };")
        try #require(standIn || state["visibility"] as? String == "visible",
                     "the page is \(state["visibility"] as? String ?? "?"): unlock the screen and wake the display (no animation frames run otherwise)")
        return webView
    }

    // MARK: A18, measured only (F6)

    /// How long `update()` takes for one group holding 200 code blocks and 200 math expressions,
    /// first and after an edit inside it, against the same blocks as separate top-level blocks
    /// (what `section` makes of them: the shape the base renders a `<details>` in). Recorded in
    /// the PR; nothing here is asserted but that the edit shows.
    @Test func updateCostOfALargeGroup() async throws {
        defer { Self.closeHosts() }
        func document(wrapper: String, edit: Bool) -> String {
            var text = "<\(wrapper)>\n<summary>Big</summary>\n\n"
            for index in 1...200 {
                text += "```swift\nlet value\(index) = \(index)\(edit && index == 100 ? " + edited" : "")\n```\n\n$$\nx_{\(index)}^2 + y\n$$\n\n"
            }
            return text + "</\(wrapper)>\n\nTail.\n"
        }
        func time(_ markdown: String, on webView: PreviewWKWebView) async throws -> Double {
            let html = MarkdownRenderer.render(markdown)
            let state = try await Self.json(webView, """
                const t0 = performance.now();
                MarsDawn.update(html, lines);
                await MarsDawn.idle();
                return { ms: performance.now() - t0, text: document.getElementById("content").textContent.includes("edited") };
            """, arguments: ["html": html, "lines": LineIndex(markdown).lineCount])
            return state["ms"] as? Double ?? -1
        }
        var results: [String: [Double]] = [:]
        for (label, wrapper) in [("group", "details"), ("separate blocks", "section")] {
            let webView = try await Self.loadedPreview()
            let first = try await time(document(wrapper: wrapper, edit: false), on: webView)
            let edited = try await time(document(wrapper: wrapper, edit: true), on: webView)
            let shows = try await Self.json(webView, "return { text: document.getElementById('content').textContent.includes('edited') };")
            #expect(shows["text"] as? Bool == true, "\(label): the edit shows")
            results[label] = [first, edited]
            Self.closeHosts()
        }
        print("A18 group of 200 code blocks + 200 math: first update \(results["group"]![0]) ms, edit inside \(results["group"]![1]) ms; separate blocks: first \(results["separate blocks"]![0]) ms, edit \(results["separate blocks"]![1]) ms")
    }

    // MARK: A14, scroll sync

    /// Below a collapsed group, the lines still sync to where their text is, and a line inside
    /// the group syncs once it has been opened. Through `MarsDawn.scrollToLine` and the DOM only.
    @Test func scrollSyncSkipsACollapsedGroupAndFollowsItsOpening() async throws {
        defer { Self.closeHosts() }
        let webView = try await Self.visiblePreview()
        let fillers = (1...200).map { "Filler paragraph \($0)." }.joined(separator: "\n\n")
        try await Self.push(DetailsFixture.markdown + "\n" + fillers + "\n", to: webView)

        let setup = try await Self.json(webView, """
            window.scrollTo(0, document.documentElement.scrollHeight);
            window.dispatchEvent(new Event("resize"));
            const lines = [...document.querySelectorAll("#content p[data-line]")]
              .filter((p) => p.textContent.startsWith("Filler paragraph")).map((p) => Number(p.dataset.line));
            return { lines, scrollable: document.documentElement.scrollHeight > innerHeight * 2, aOpen: document.querySelector("#content details").open };
        """)
        #expect(setup["scrollable"] as? Bool == true, "positive fixture: the page scrolls")
        #expect(setup["aOpen"] as? Bool == false, "A is collapsed")
        let all = (setup["lines"] as? [Int]) ?? []
        #expect(all.count == 200)
        let chosen = stride(from: 5, to: all.count, by: max(1, (all.count - 5) / 20)).prefix(20).map { all[$0] }
        #expect(chosen.count == 20)

        var previous = -1.0
        for line in chosen {
            let state = try await Self.json(webView, """
                MarsDawn.scrollToLine(\(line), false);
                const el = document.querySelector('#content [data-line="\(line)"]');
                return { y: window.scrollY,
                         want: Math.min(document.documentElement.scrollHeight - innerHeight, el.getBoundingClientRect().top + window.scrollY) };
            """)
            let y = state["y"] as? Double ?? -1, want = state["want"] as? Double ?? -2
            #expect(abs(y - want) <= 2, "line \(line): scrolled to \(y), its text is at \(want)")
            #expect(y >= previous, "line \(line): scrolled to \(y) after \(previous)")
            previous = y
        }

        let opened = try await Self.json(webView, """
            document.querySelector("#content details").open = true;
            await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
            MarsDawn.scrollToLine(15, false);
            const el = document.querySelector('#content [data-line="15"]');
            return { y: window.scrollY, top: el.getBoundingClientRect().top + window.scrollY,
                     max: document.documentElement.scrollHeight - innerHeight };
        """)
        let y = opened["y"] as? Double ?? -1, top = opened["top"] as? Double ?? -2, max = opened["max"] as? Double ?? -3
        #expect(abs(y - top) <= 2 || y >= max - 1, "line 15 inside the opened group: scrolled to \(y), its code block is at \(top) (max \(max))")
    }

    // MARK: A17, toggle volume

    /// The page's own work per `toggle` event is constant and coalesced: opening 20k `<details>`
    /// at once costs at most twice what 20k `<section>` blocks cost.
    @Test func manyToggleEventsCostOneSyncPerFrame() async throws {
        defer { Self.closeHosts() }
        let count = 20_000
        let detailsHTML = MarkdownRenderer.render(String(repeating: "<details open>\n<summary>s</summary>\n</details>\n\n", count: count))
        let sectionHTML = MarkdownRenderer.render(String(repeating: "<section>\n<p>s</p>\n</section>\n\n", count: count))
        #expect(detailsHTML.components(separatedBy: "<details open>").count - 1 == count)

        func measure(_ html: String) async throws -> (seconds: Double, toggles: Int, onInsert: Int)? {
            let webView = try await Self.visiblePreview()
            let script = """
                window.__toggles = 0;
                document.addEventListener("toggle", () => { window.__toggles++; }, true);
                MarsDawn.scrollToLine(1, false);
                const t0 = performance.now();
                MarsDawn.update(html, lines);
                await MarsDawn.idle();
                await new Promise((r) => setTimeout(r, 0));
                const onInsert = window.__toggles;
                if (document.querySelector("#content details") && onInsert < expected) {
                  for (const d of document.querySelectorAll("#content details")) d.open = false;
                }
                const limit = performance.now() + 60000;
                while (document.querySelector("#content details") && window.__toggles < expected && performance.now() < limit) {
                  await new Promise((r) => setTimeout(r, 0));
                }
                await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
                return JSON.stringify({ ms: performance.now() - t0, toggles: window.__toggles, onInsert });
                """
            let host = Flag()
            let reply: String? = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    let value = try? await webView.callAsyncJavaScript(
                        script, arguments: ["html": html, "lines": count * 4, "expected": count], contentWorld: .page
                    ) as? String
                    if !host.done { host.done = true; continuation.resume(returning: value) }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(100))
                    if !host.done { host.done = true; continuation.resume(returning: nil) }
                }
            }
            Self.closeHosts()
            guard let reply, let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else { return nil }
            return ((object["ms"] as? Double ?? 0) / 1000, object["toggles"] as? Int ?? 0, object["onInsert"] as? Int ?? 0)
        }

        var details: [Double] = [], sections: [Double] = []
        var toggles = 0, onInsert = 0
        for _ in 0..<2 {
            let d = try await measure(detailsHTML)
            let s = try await measure(sectionHTML)
            try #require(d != nil, "the \(count) <details open> update did not finish within 100 s")
            try #require(s != nil, "the \(count) <section> update did not finish within 100 s")
            details.append(d!.seconds); sections.append(s!.seconds)
            toggles = d!.toggles; onInsert = d!.onInsert
        }
        let detailsTime = details.min()!, sectionTime = sections.min()!
        print("A17 \(count) <details open>: \(details) s, \(count) <section>: \(sections) s, ratio \(detailsTime / sectionTime); toggle events seen \(toggles), of them on insert \(onInsert)")
        #expect(toggles >= count, "the counter saw \(toggles) toggle events")
        #expect(detailsTime <= sectionTime * 2, "\(detailsTime) s against \(sectionTime) s")
    }

    @MainActor final class Flag { var done = false }

    static func titleOf(_ state: [String: Any]) throws -> String { try #require(state["title"] as? String) }
}
#endif
