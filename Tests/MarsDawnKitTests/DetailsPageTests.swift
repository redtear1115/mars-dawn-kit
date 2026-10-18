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
        // WebKit treats the page as hidden, with no animation frames, while its window's occlusion
        // state says covered, and that state changes only while AppKit takes events. `swift test`
        // runs no event loop (taking events here stops the run loop the test process exits on), so
        // the window stays "covered" on an unlocked screen too. The page goes by whether the window
        // is ordered in instead; `visiblePreview` checks that a frame really runs.
        let occlusionDetection = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusionDetection) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusionDetection), to: Setter.self)(webView, occlusionDetection, false)
        }
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

    static func push(_ markdown: String, to webView: PreviewWKWebView) async throws {
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: LineIndex(markdown).lineCount)
        )
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    static func json(_ webView: PreviewWKWebView, _ body: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
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
        guard let webView = try await Self.visiblePreview() else { return }
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

    /// A preview page whose animation frames really run, or a failure that says why not: while
    /// the screen is locked or the display asleep no frame runs, and a test that waited for one
    /// would hang.
    ///
    /// On CI (the `CI` variable set) a page with no frame skips the test with one line instead
    /// of failing, since a runner may have no unlocked screen: this returns `nil` and the caller
    /// returns. A test whose skip would read as a pass (A17) passes `skipOnCI: false`.
    static func visiblePreview(height: CGFloat = 800, test: String = #function, skipOnCI: Bool = true) async throws -> PreviewWKWebView? {
        let name = test.replacingOccurrences(of: "()", with: "")
        let webView = try await loadedPreview(height: height)
        if standIn { print("STAND-IN requestAnimationFrame active: \(name)") }
        let state = try await json(webView, """
            return await new Promise((done) => {
                const late = setTimeout(() => done({ frame: false, visibility: document.visibilityState }), 2000);
                requestAnimationFrame(() => { clearTimeout(late); done({ frame: true, visibility: document.visibilityState }); });
            });
            """)
        let frame = state["frame"] as? Bool ?? false
        let visibility = state["visibility"] as? String ?? "?"
        if !frame, skipOnCI, ProcessInfo.processInfo.environment["CI"] != nil {
            print("SKIPPED (no animation frame on CI): \(name) — needs a visible, unlocked screen")
            closeHosts()
            return nil
        }
        try #require(frame, "no animation frame ran in 2 s (the page is \(visibility)): unlock the screen and wake the display")
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
        guard let webView = try await Self.visiblePreview() else { return }
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
        // The lines right after the groups are where a hidden block's position matters: a
        // collapsed group's content reports tops beyond what follows it (WebKit lays it out but
        // doesn't paint it), so without the skip the anchors for those lines are dropped. Then
        // the first few and some spread-out paragraphs further down.
        let afterGroups = [21, 23, 25, 28, 32, 34, 48]
        let chosen = (afterGroups + Array(all.prefix(8)) + stride(from: 20, to: all.count, by: 20).map { all[$0] }).sorted()
        #expect(chosen.count >= 20)

        var previous = -1.0
        for line in chosen {
            let state = try await Self.json(webView, """
                MarsDawn.scrollToLine(\(line), false);
                const el = document.querySelector('#content [data-line="\(line)"]');
                return { y: window.scrollY,
                         want: Math.min(document.documentElement.scrollHeight - innerHeight, el.getBoundingClientRect().top + window.scrollY) };
            """)
            let y = state["y"] as? Double ?? -1, want = state["want"] as? Double ?? -2
            #expect(abs(y - want) <= 2.0, "line \(line): scrolled to \(y), its text is at \(want)")
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

    /// The page's work per `toggle` event is constant and coalesced (F3). A17a, on every machine:
    /// opening 20k `<details>` at once rebuilds the scroll anchors (an O(n) pass) at most once per
    /// animation frame beyond what an update costs anyway, counted through the DOM. A17b, off CI
    /// only: it costs at most twice what 20k `<section>` blocks cost. On CI's VMs that ratio
    /// measures WebKit's own toggle dispatch, which runs about 9× even with no toggle sync at all.
    @Test func manyToggleEventsCostOneSyncPerFrame() async throws {
        defer { Self.closeHosts() }
        let count = 20_000
        let test = "manyToggleEventsCostOneSyncPerFrame()"
        // No CI skip: since e4a1f12 CI's pages run frames, and a skipped A17 would read as green.
        _ = try #require(try await Self.visiblePreview(test: test, skipOnCI: false))
        Self.closeHosts()
        let detailsHTML = MarkdownRenderer.render(String(repeating: "<details open>\n<summary>s</summary>\n</details>\n\n", count: count))
        let sectionHTML = MarkdownRenderer.render(String(repeating: "<section>\n<p>s</p>\n</section>\n\n", count: count))
        #expect(detailsHTML.components(separatedBy: "<details open>").count - 1 == count)

        struct Run { var seconds: Double; var toggles: Int; var onInsert: Int; var rebuilds: Int; var frames: Int; var overflow: Bool }

        /// One update in a fresh page. `bound` is the section run's rebuild count, or -1 for none:
        /// once the details run's rebuilds pass frames + bound + 1 the verdict is red, so later
        /// anchor queries return nothing and a per-event storm ends, and the counts come back.
        func measure(_ html: String, bound: Int) async throws -> Run? {
            let webView = try #require(try await Self.visiblePreview(test: test, skipOnCI: false))
            let script = """
                window.__toggles = 0;
                document.addEventListener("toggle", () => { window.__toggles++; }, true);
                MarsDawn.scrollToLine(1, false);
                const content = document.getElementById("content");
                const original = Element.prototype.querySelectorAll;
                let rebuilds = 0, frames = 0, overflow = false, done = false;
                Element.prototype.querySelectorAll = function (selector) {
                  if (this === content && selector === "[data-line]") {
                    rebuilds++;
                    if (overflow || (bound >= 0 && rebuilds > frames + bound + 1)) {
                      overflow = true;
                      return original.call(this, ":not(*)");
                    }
                  }
                  return original.call(this, selector);
                };
                const tick = () => { frames++; if (!done) requestAnimationFrame(tick); };
                requestAnimationFrame(tick);
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
                await MarsDawn.idle();
                await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
                const ms = performance.now() - t0;
                done = true;
                Element.prototype.querySelectorAll = original;
                return JSON.stringify({ ms, toggles: window.__toggles, onInsert, rebuilds, frames, overflow });
                """
            let host = Flag()
            let reply: String? = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    let value = try? await webView.callAsyncJavaScript(
                        script, arguments: ["html": html, "lines": count * 4, "expected": count, "bound": bound], contentWorld: .page
                    ) as? String
                    if !host.done { host.done = true; continuation.resume(returning: value) }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(100))
                    if !host.done { host.done = true; continuation.resume(returning: nil) }
                }
            }
            Self.closeHosts()
            guard let reply, let o = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else { return nil }
            return Run(seconds: (o["ms"] as? Double ?? 0) / 1000, toggles: o["toggles"] as? Int ?? 0, onInsert: o["onInsert"] as? Int ?? 0,
                       rebuilds: o["rebuilds"] as? Int ?? -1, frames: o["frames"] as? Int ?? -1, overflow: o["overflow"] as? Bool ?? false)
        }

        var details: [Double] = [], sections: [Double] = []
        for _ in 0..<2 {
            let s = try #require(try await measure(sectionHTML, bound: -1), "the \(count) <section> update did not finish within 100 s")
            let d = try #require(try await measure(detailsHTML, bound: s.rebuilds), "the \(count) <details open> update did not finish within 100 s")
            print("A17a \(count) <details open>: rebuilds \(d.rebuilds), frames \(d.frames), toggles \(d.toggles) (on insert \(d.onInsert)), overflow \(d.overflow); \(count) <section>: rebuilds \(s.rebuilds), frames \(s.frames)")
            #expect(s.rebuilds >= 1 && d.rebuilds >= 1, "no anchor rebuild counted (section \(s.rebuilds), details \(d.rebuilds)): the count sees nothing")
            #expect(d.rebuilds <= d.frames + s.rebuilds + 1, "details rebuilds \(d.rebuilds) > frames \(d.frames) + section \(s.rebuilds) + 1")
            #expect(d.toggles >= count, "the counter saw \(d.toggles) toggle events")
            details.append(d.seconds); sections.append(s.seconds)
        }
        let detailsTime = details.min()!, sectionTime = sections.min()!
        let onCI = ProcessInfo.processInfo.environment["CI"] != nil
        print("A17b\(onCI ? " (CI, not asserted)" : "") \(count) <details open>: \(details) s, \(count) <section>: \(sections) s, ratio \(detailsTime / sectionTime)")
        if !onCI {
            #expect(detailsTime <= sectionTime * 2, "\(detailsTime) s against \(sectionTime) s")
        }
    }

    @MainActor final class Flag { var done = false }

    static func titleOf(_ state: [String: Any]) throws -> String { try #require(state["title"] as? String) }
}
#endif
