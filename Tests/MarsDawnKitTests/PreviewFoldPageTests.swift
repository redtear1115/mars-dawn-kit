#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Viewer folding (redtear1115/mars-dawn#300) in the real preview page: heading arrows, the
/// code / image / diagram controls, `collapseAll` / `expandAll`, and what folding must never
/// touch (the file, the text the page exposes, scroll sync, print). Uses `DetailsPageTests`'s
/// harness: a page in an ordered-in window, so animation frames run.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(4)))
struct PreviewFoldPageTests {
    typealias Page = DetailsPageTests

    static let outline = """
        Intro paragraph.

        # Alpha

        alpha text

        ## Bravo

        bravo text

        ### Charlie

        charlie text

        ## Delta

        delta text

        # Echo

        echo text

        """

    /// The top-level blocks that are shown, as "TAG:text".
    static let shownScript = """
        return { shown: [...document.getElementById("content").children]
          .filter((el) => el.checkVisibility())
          .map((el) => el.tagName + ":" + el.textContent.trim()) };
        """

    private func shown(_ webView: PreviewWKWebView) async throws -> [String] {
        try await Page.json(webView, Self.shownScript)["shown"] as? [String] ?? ["<unreadable>"]
    }

    private func loaded(_ markdown: String) async throws -> PreviewWKWebView {
        let webView = try await Page.loadedPreview()
        try await Page.push(markdown, to: webView)
        return webView
    }

    /// Clicks the arrow of the top-level heading whose text is `text`.
    private func clickHeading(_ text: String, in webView: PreviewWKWebView) async throws {
        let state = try await Page.json(webView, """
            const h = [...document.querySelectorAll("#content > :is(h1,h2,h3,h4,h5,h6)")].find((h) => h.textContent.trim() === text);
            const button = h?.querySelector(":scope > button.md-fold-toggle");
            button?.click();
            return { found: !!button, expanded: button?.getAttribute("aria-expanded") ?? null, label: button?.getAttribute("aria-label") ?? null };
            """, arguments: ["text": text])
        #expect(state["found"] as? Bool == true, "\(text) has an arrow")
    }

    static let everything = ["P:Intro paragraph.", "H1:Alpha", "P:alpha text", "H2:Bravo", "P:bravo text", "H3:Charlie",
                             "P:charlie text", "H2:Delta", "P:delta text", "H1:Echo", "P:echo text"]

    // MARK: Headings

    @Test func foldingAHeadingHidesItsSectionUpToTheNextHeadingOfTheSameOrAHigherLevel() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded(Self.outline)
        #expect(try await shown(webView) == Self.everything, "nothing is folded by default")
        let arrows = try await Page.json(webView, """
            const c = document.getElementById("content");
            return { arrows: c.querySelectorAll(":scope > :is(h1,h2,h3) > button.md-fold-toggle[type=button][aria-expanded=true]").length,
                     labels: [...new Set([...c.querySelectorAll(".md-fold-toggle")].map((b) => b.getAttribute("aria-label")))] };
            """)
        #expect(arrows["arrows"] as? Int == 5)
        #expect(arrows["labels"] as? [String] == ["Collapse section"])

        try await clickHeading("Bravo", in: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "P:alpha text", "H2:Bravo",
                                             "H2:Delta", "P:delta text", "H1:Echo", "P:echo text"], "h2 folds its h3 too, until the next h2")
        let folded = try await Page.json(webView, """
            const b = [...document.querySelectorAll("#content > h2")][0].querySelector(".md-fold-toggle");
            return { expanded: b.getAttribute("aria-expanded"), label: b.getAttribute("aria-label") };
            """)
        #expect(folded["expanded"] as? String == "false")
        #expect(folded["label"] as? String == "Expand section")

        try await clickHeading("Charlie", in: webView)  // hidden, but can still hold its own state
        try await clickHeading("Bravo", in: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "P:alpha text", "H2:Bravo", "P:bravo text",
                                             "H3:Charlie", "H2:Delta", "P:delta text", "H1:Echo", "P:echo text"], "the nested h3 stays folded")
        try await clickHeading("Charlie", in: webView)
        #expect(try await shown(webView) == Self.everything)

        try await clickHeading("Alpha", in: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "H1:Echo", "P:echo text"], "h1 folds until the next h1")
    }

    @Test func collapseAllToH2LeavesTheH1AndH2HeadingsAndWhatComesBeforeThem() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded(Self.outline)
        _ = try await webView.evaluateJavaScript(PreviewWebView.collapseAllScript(level: 2))
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "H2:Bravo", "H2:Delta", "H1:Echo"])
        // Expanding an h1 then shows its own text, with its h2s still folded.
        try await clickHeading("Alpha", in: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "P:alpha text", "H2:Bravo", "H2:Delta", "H1:Echo"])

        _ = try await webView.evaluateJavaScript(PreviewWebView.expandAllScript())
        #expect(try await shown(webView) == Self.everything)

        _ = try await webView.evaluateJavaScript(PreviewWebView.collapseAllScript(level: 1))
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "H1:Echo"])
        _ = try await webView.evaluateJavaScript(PreviewWebView.collapseAllScript(level: 3))
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "H2:Bravo", "H3:Charlie", "H2:Delta", "H1:Echo"])
        _ = try await webView.evaluateJavaScript(PreviewWebView.expandAllScript())
        #expect(try await shown(webView) == Self.everything)

        // Out-of-range levels are clamped by the builder and refused by the page.
        #expect(PreviewWebView.collapseAllScript(level: 9) == "window.MarsDawn && MarsDawn.collapseAll && MarsDawn.collapseAll(6);")
        #expect(PreviewWebView.collapseAllScript(level: -1).hasSuffix("MarsDawn.collapseAll(1);"))
        _ = try await webView.evaluateJavaScript("MarsDawn.collapseAll(0); MarsDawn.collapseAll('2; x'); 0")
        #expect(try await shown(webView) == Self.everything)
    }

    /// After Collapse All, a reader opens one section: its text and subheadings come back and the
    /// rest stays folded, so the arrow's state is what the page shows.
    @Test func opensOneSectionAfterCollapseAll() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded(Self.outline)
        _ = try await webView.evaluateJavaScript(PreviewWebView.collapseAllScript(level: 2))
        try await clickHeading("Bravo", in: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "H2:Bravo", "P:bravo text", "H3:Charlie",
                                             "P:charlie text", "H2:Delta", "H1:Echo"])
        // Folding it again goes back; a folded h3 inside the opened h2 still hides its own text.
        try await clickHeading("Charlie", in: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "H2:Bravo", "P:bravo text", "H3:Charlie",
                                             "H2:Delta", "H1:Echo"])
        try await clickHeading("Bravo", in: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "H2:Bravo", "H2:Delta", "H1:Echo"])
    }

    @Test func aFoldedHeadingHidesEverythingUnderIt() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded(Self.outline)
        try await clickHeading("Alpha", in: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph.", "H1:Alpha", "H1:Echo", "P:echo text"])
    }

    @Test func theFootnotesStayWhenTheLastSectionIsFolded() async throws {
        defer { Page.closeHosts() }
        let markdown = "Intro[^1].\n\n# One\n\nx[^2].\n\n# Last\n\nbody\n\n[^1]: first note\n[^2]: second note\n"
        let webView = try await loaded(markdown)
        let footnotes = "document.querySelector('#content > section.footnotes')?.checkVisibility() ?? null"
        #expect(try await webView.evaluateJavaScript(footnotes) as? Bool == true, "positive fixture: the page has them")
        try await clickHeading("Last", in: webView)
        #expect(try await webView.evaluateJavaScript(footnotes) as? Bool == true, "they aren't the last section's")
        #expect(try await !shown(webView).contains("P:body"), "the section's own text is folded")
        _ = try await webView.evaluateJavaScript(PreviewWebView.collapseAllScript(level: 1))
        #expect(try await webView.evaluateJavaScript(footnotes) as? Bool == true, "Collapse All leaves them too")
    }

    @Test func aDocumentWithoutH1OrH2CollapsesToItsTopHeadings() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded("### One\n\none text\n\n#### Sub\n\nsub text\n\n### Two\n\ntwo text\n")
        _ = try await webView.evaluateJavaScript(PreviewWebView.collapseAllScript(level: 2))
        #expect(try await shown(webView) == ["H3:One", "H3:Two"])
    }

    @Test func aFoldedHeadingStaysFoldedAcrossEditsAndReusedBlocksAreNotDuplicated() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded(Self.outline)
        try await clickHeading("Bravo", in: webView)
        _ = try await Page.json(webView, """
            [...document.querySelectorAll("#content > h2")][0]._foldProbe = 1;
            return {};
            """)
        let edited = Self.outline.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, edited.\n\nA new paragraph.")
            .replacingOccurrences(of: "echo text", with: "echo text, edited")
        try await Page.push(edited, to: webView)
        #expect(try await shown(webView) == ["P:Intro paragraph, edited.", "P:A new paragraph.", "H1:Alpha", "P:alpha text", "H2:Bravo",
                                             "H2:Delta", "P:delta text", "H1:Echo", "P:echo text, edited"])
        let reuse = try await Page.json(webView, """
            const c = document.getElementById("content");
            const bravo = [...c.querySelectorAll(":scope > h2")].filter((h) => h.textContent.trim() === "Bravo");
            return { bravos: bravo.length, reused: bravo[0]?._foldProbe === 1,
                     arrows: bravo[0]?.querySelectorAll("button").length,
                     blocks: c.children.length,
                     lines: [...c.children].map((el) => el.getAttribute("data-line")) };
            """)
        #expect(reuse["bravos"] as? Int == 1)
        #expect(reuse["reused"] as? Bool == true, "positive fixture: the pool reused the folded heading")
        #expect(reuse["arrows"] as? Int == 1)
        #expect(reuse["blocks"] as? Int == 12)
        let lines = (reuse["lines"] as? [String] ?? []).compactMap(Int.init)
        #expect(lines.count == 12 && lines == lines.sorted(), "blocks in source order: \(lines)")

        // Renaming the folded heading drops its state.
        try await Page.push(edited.replacingOccurrences(of: "## Bravo", with: "## Bravissimo"), to: webView)
        #expect(try await shown(webView).contains("P:bravo text"))
        // And deleting a folded heading leaves nothing folded behind.
        try await clickHeading("Delta", in: webView)
        try await Page.push(edited.replacingOccurrences(of: "## Delta\n\n", with: ""), to: webView)
        #expect(try await shown(webView).contains("P:delta text"))
    }

    // MARK: Code, images, diagrams

    static func codeBlock(lines: Int) -> String {
        "```swift\n" + (1...lines).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n```\n"
    }

    @Test func onlyLongCodeBlocksGetAControlAndNoneIsCollapsedByDefault() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded([40, 5, 20, 21].map(Self.codeBlock).joined(separator: "\nText.\n\n"))
        let state = try await Page.json(webView, """
            const pres = [...document.querySelectorAll("#content > pre")];
            return { controls: pres.map((p) => p.querySelector(":scope > button.md-fold-block[type=button]")?.getAttribute("data-summary") ?? ""),
                     expanded: pres.map((p) => p.querySelector(":scope > .md-fold-block")?.getAttribute("aria-expanded") ?? ""),
                     labels: pres.map((p) => p.querySelector(":scope > .md-fold-block")?.getAttribute("aria-label") ?? ""),
                     collapsed: document.querySelectorAll(".md-block-collapsed, .md-fold-hidden").length,
                     codeShown: pres.every((p) => p.querySelector("code").checkVisibility()) };
            """)
        #expect(state["controls"] as? [String] == ["Code, 40 lines", "", "", "Code, 21 lines"])
        #expect(state["expanded"] as? [String] == ["true", "", "", "true"])
        #expect(state["labels"] as? [String] == ["Collapse", "", "", "Collapse"])
        #expect(state["collapsed"] as? Int == 0)
        #expect(state["codeShown"] as? Bool == true)

        let collapsed = try await Page.json(webView, """
            const pre = document.querySelector("#content > pre");
            const button = pre.querySelector(".md-fold-block");
            const before = pre.getBoundingClientRect().height;
            button.click();
            return { collapsed: pre.classList.contains("md-block-collapsed"), codeShown: pre.querySelector("code").checkVisibility(),
                     buttonShown: button.checkVisibility(), expanded: button.getAttribute("aria-expanded"), label: button.getAttribute("aria-label"),
                     row: getComputedStyle(button, "::before").content, before, after: pre.getBoundingClientRect().height };
            """)
        #expect(collapsed["collapsed"] as? Bool == true)
        #expect(collapsed["codeShown"] as? Bool == false)
        #expect(collapsed["buttonShown"] as? Bool == true)
        #expect(collapsed["expanded"] as? String == "false")
        #expect(collapsed["label"] as? String == "Code, 40 lines", "collapsed, the name says what is folded")
        #expect((collapsed["row"] as? String ?? "").contains("Code, 40 lines"), "row: \(collapsed["row"] ?? "nil")")
        let before = collapsed["before"] as? Double ?? 0, after = collapsed["after"] as? Double ?? 0
        #expect(after < 60 && before > 400, "a single row: \(before) → \(after)")

        // The host's wording replaces the fallback, including the line count.
        let localized = try await Page.json(webView, """
            MarsDawn.setLabels({ fold: { code: "程式碼 %d 行" } });
            const button = document.querySelector("#content > pre > .md-fold-block");
            return { summary: button.getAttribute("data-summary"), label: button.getAttribute("aria-label") };
            """)
        #expect(localized["summary"] as? String == "程式碼 40 行")
        #expect(localized["label"] as? String == "程式碼 40 行")

        // A collapsed block reused by an edit elsewhere stays collapsed, once.
        try await Page.push([40, 5, 20, 21].map(Self.codeBlock).joined(separator: "\nText, edited.\n\n"), to: webView)
        let reused = try await Page.json(webView, """
            const pre = document.querySelector("#content > pre");
            return { collapsed: pre.classList.contains("md-block-collapsed"), controls: pre.querySelectorAll(".md-fold-block").length };
            """)
        #expect(reused["collapsed"] as? Bool == true)
        #expect(reused["controls"] as? Int == 1)

        _ = try await webView.evaluateJavaScript(PreviewWebView.expandAllScript())
        let expanded = try await Page.json(webView, "return { n: document.querySelectorAll('.md-block-collapsed').length };")
        #expect(expanded["n"] as? Int == 0)
    }

    @Test func tallImagesAndDiagramsGetAControlShortOnesDoNot() async throws {
        defer { Page.closeHosts() }
        let tall = "flowchart TD\n" + (1...14).map { "  N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        let markdown = "```mermaid\n\(tall)\n```\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nEnd.\n"
        let webView = try await loaded(markdown)
        // Images whose size the page knows without loading anything: an `<img>` without `src`,
        // sized by attributes, stands in for a tall and a short picture (the sandboxed test page
        // can't serve a real one).
        let state = try await Page.json(webView, """
            const c = document.getElementById("content");
            const make = (h, line) => {
              const p = document.createElement("p");
              p.dataset.line = line;
              const img = document.createElement("img");
              img.alt = ""; img.width = 40; img.height = h;
              img.style.display = "block";
              p.append(img);
              return p;
            };
            c.append(make(900, "90"), make(100, "91"));
            await MarsDawn.idle();
            const blocks = [...c.querySelectorAll(":scope > .mermaid-block, :scope > p:has(> img)")];
            return { kinds: blocks.map((b) => b.querySelector(":scope > .md-fold-block")?.dataset.kind ?? ""),
                     heights: blocks.map((b) => Math.round(b.getBoundingClientRect().height)),
                     collapsed: c.querySelectorAll(".md-block-collapsed").length };
            """)
        #expect(state["kinds"] as? [String] == ["diagram", "", "image", ""], "heights: \(state["heights"] ?? "nil")")
        #expect(state["collapsed"] as? Int == 0, "nothing folds by itself")

        let folded = try await Page.json(webView, """
            const c = document.getElementById("content");
            const diagram = c.querySelector(".mermaid-block > .md-fold-block");
            const image = c.querySelector("p > .md-fold-block");
            diagram.click(); image.click();
            await MarsDawn.idle();
            return { diagram: getComputedStyle(diagram, "::before").content, image: getComputedStyle(image, "::before").content,
                     svgShown: c.querySelector(".mermaid-block svg").checkVisibility(),
                     imgShown: image.parentElement.querySelector("img").checkVisibility(),
                     stillThere: !!c.querySelector(".mermaid-block > .md-fold-block") && !!c.querySelector("p > .md-fold-block") };
            """)
        #expect((folded["diagram"] as? String ?? "").contains("Diagram"))
        #expect((folded["image"] as? String ?? "").contains("Image"))
        #expect(folded["svgShown"] as? Bool == false)
        #expect(folded["imgShown"] as? Bool == false)
        #expect(folded["stillThere"] as? Bool == true, "a collapsed block keeps its control though it is now short")
    }

    // MARK: What folding must not touch

    @Test func controlLabelsNeverReachTheTextFindOrCopy() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded(Self.outline + Self.codeBlock(lines: 40))
        let state = try await Page.json(webView, """
            const c = document.getElementById("content");
            const plain = c.textContent, inner = c.innerText;
            document.querySelector("#content > pre > .md-fold-block").click();
            [...c.querySelectorAll(":scope > h2 > .md-fold-toggle")][0].click();
            const labels = ["Code, 40 lines", "Collapse", "▸", "▾"];
            const selection = getSelection();
            selection.selectAllChildren(c);
            const copied = selection.toString();
            selection.removeAllRanges();
            return { controls: c.querySelectorAll(".md-fold-block, .md-fold-toggle").length,
                     textSame: c.textContent === plain,
                     leaks: labels.filter((l) => plain.includes(l) || inner.includes(l) || c.innerText.includes(l) || copied.includes(l)),
                     found: labels.filter((l) => window.find(l, true, false, true)),
                     positive: window.find("alpha text", true, false, true),
                     buttonsEmpty: [...c.querySelectorAll("button")].every((b) => b.childNodes.length === 0),
                     noLines: c.querySelectorAll("button[data-line]").length };
            """)
        #expect(state["controls"] as? Int == 6, "positive fixture: five arrows and a code control")
        #expect(state["textSame"] as? Bool == true)
        #expect(state["leaks"] as? [String] == [])
        #expect(state["found"] as? [String] == [])
        #expect(state["positive"] as? Bool == true, "positive fixture: find works on the page")
        #expect(state["buttonsEmpty"] as? Bool == true)
        #expect(state["noLines"] as? Int == 0)
    }

    /// The page-shortening scroll a fold causes isn't the user's; a scroll of the user's still
    /// ends the sync, fold or no fold.
    @Test func aFoldDoesNotBringBackASyncTheUserScrolledAway() async throws {
        defer { Page.closeHosts() }
        guard let webView = try await Page.visiblePreview() else { return }
        let fillers = (1...60).map { "Filler \($0)." }.joined(separator: "\n\n")
        let markdown = "# Top\n\n" + fillers + "\n\n# Bottom\n\n" + fillers.replacingOccurrences(of: "Filler", with: "Later") + "\n"
        try await Page.push(markdown, to: webView)
        let result = try await Page.json(webView, """
            const line = Number([...document.querySelectorAll("#content > p")]
                .find((p) => p.textContent.startsWith("Later 10.")).dataset.line);
            MarsDawn.scrollToLine(line, false);
            await new Promise((r) => setTimeout(r, 200));
            window.scrollTo(0, 3000);
            await new Promise((r) => setTimeout(r, 100));
            document.querySelector("#content > h1 > .md-fold-toggle").click();
            await new Promise((r) => setTimeout(r, 100));
            return { y: window.scrollY, bottom: document.documentElement.scrollHeight - innerHeight };
            """)
        #expect(abs((result["y"] as? Double ?? -1) - (result["bottom"] as? Double ?? -9)) <= 2, "\(result)")
    }

    @Test func scrollSyncSkipsFoldedBlocksAndResyncsWhenAFoldChanges() async throws {
        defer { Page.closeHosts() }
        guard let webView = try await Page.visiblePreview() else { return }
        let fillers = (1...60).map { "Filler \($0)." }.joined(separator: "\n\n")
        let markdown = "# Top\n\n" + fillers + "\n\n# Bottom\n\n" + fillers.replacingOccurrences(of: "Filler", with: "Later") + "\n"
        try await Page.push(markdown, to: webView)
        let later = try await Page.json(webView, """
            const ps = [...document.querySelectorAll("#content > p")].filter((p) => p.textContent.startsWith("Later 10."));
            return { line: Number(ps[0].dataset.line) };
            """)
        let line = try #require(later["line"] as? Int)
        let check = """
            MarsDawn.scrollToLine(\(line), false);
            const el = document.querySelector('#content [data-line="\(line)"]');
            return { y: window.scrollY, want: Math.min(document.documentElement.scrollHeight - innerHeight, el.getBoundingClientRect().top + window.scrollY) };
            """
        let open = try await Page.json(webView, check)
        #expect(abs((open["y"] as? Double ?? -1) - (open["want"] as? Double ?? -9)) <= 2)
        // Fold the section above: the synced line must follow its text after one frame, without
        // another scrollToLine from the host. The wait outlasts the scroll listener's window after
        // `scrollToLine`, as any real click does: inside it, this passes without the fix (kit #257).
        try await Task.sleep(for: .milliseconds(200))
        let resynced = try await Page.json(webView, """
            const before = window.scrollY;
            document.querySelector("#content > h1 > .md-fold-toggle").click();
            await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
            const el = document.querySelector('#content [data-line="\(line)"]');
            return { before, y: window.scrollY,
                     want: Math.min(document.documentElement.scrollHeight - innerHeight, el.getBoundingClientRect().top + window.scrollY) };
            """)
        #expect((resynced["y"] as? Double ?? 0) < (resynced["before"] as? Double ?? 0) - 500, "positive fixture: folding moved the text up")
        #expect(abs((resynced["y"] as? Double ?? -1) - (resynced["want"] as? Double ?? -9)) <= 2, "\(resynced)")
        // A line inside the fold maps to the folded heading's place, not past the text after it.
        let inside = try await Page.json(webView, """
            MarsDawn.scrollToLine(20, false);
            return { y: window.scrollY, bottom: document.querySelectorAll("#content > h1")[1].getBoundingClientRect().top + window.scrollY };
            """)
        #expect((inside["y"] as? Double ?? 1e9) <= (inside["bottom"] as? Double ?? -1), "\(inside)")
        let after = try await Page.json(webView, check)
        #expect(abs((after["y"] as? Double ?? -1) - (after["want"] as? Double ?? -9)) <= 2, "\(after)")
    }

    @Test func printShowsEverythingTheViewerFoldedAndNoControls() async throws {
        defer { Page.closeHosts() }
        let webView = try await loaded(Self.outline + Self.codeBlock(lines: 40))
        _ = try await webView.evaluateJavaScript(PreviewWebView.collapseAllScript(level: 1))
        _ = try await webView.evaluateJavaScript("document.querySelector('#content > pre > .md-fold-block').click(); 0")
        let probe = """
            const c = document.getElementById("content");
            const controls = [...c.querySelectorAll(".md-fold-toggle, .md-fold-block")];
            return { print: matchMedia("print").matches,
                     hidden: [...c.children].filter((el) => !el.checkVisibility()).length,
                     codeShown: c.querySelector("pre > code").checkVisibility(),
                     controlsShown: controls.filter((b) => b.checkVisibility()).length, controls: controls.length };
            """
        let screen = try await Page.json(webView, probe)
        #expect(screen["print"] as? Bool == false)
        #expect((screen["hidden"] as? Int ?? 0) > 5, "positive fixture: folded on screen")
        #expect(screen["codeShown"] as? Bool == false)
        webView.mediaType = "print"
        let print = try await Page.json(webView, probe)
        #expect(print["print"] as? Bool == true, "positive fixture: the page sees print media")
        #expect(print["hidden"] as? Int == 0)
        #expect(print["codeShown"] as? Bool == true)
        #expect(print["controlsShown"] as? Int == 0)
        #expect(print["controls"] as? Int == 6)
        webView.mediaType = nil
        let back = try await Page.json(webView, probe)
        #expect(back["hidden"] as? Int == screen["hidden"] as? Int, "the fold state is untouched by printing")
    }

    // MARK: Labels

    @Test func theUpdateCarriesTheKitsFoldLabels() {
        let script = PreviewWebView.updateScript(html: "<p>x</p>")
        #expect(script.contains("fold: { code: \(PreviewWebView.jsonStringLiteral(PreviewWebView.foldCodeLabelFormat)), image: "))
        #expect(script.contains("collapse: \(PreviewWebView.jsonStringLiteral(PreviewWebView.collapseBlockLabel)) }"))
    }

    /// The proposed copy (pending approval) is what ships for zh-Hant; English is the key.
    @Test func theProposedCopyIsWhatShips() {
        for (key, value) in FoldLabelsProposedCopy.zhHant {
            #expect(PreviewWebView.moduleLocalizedString(key, localization: "zh-Hant") == value, "\(key)")
            #expect(PreviewWebView.moduleLocalizedString(key, localization: "ja") == key, "ja falls back to English: \(key)")
        }
        #expect(FoldLabelsProposedCopy.zhHant.count == 6)
    }
}
#endif
