import Foundation
import Testing
@testable import MarsDawnKit

/// Callouts (kit #135): GitHub alerts and HackMD containers, at the HTML the renderer writes.
/// Each case has its exact source and expected output written out, so the list in the PR is this
/// list. Cases that must stay what they were before callouts existed carry the base's output.
struct CalloutRenderTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let source: String
        let html: String
        var testDescription: String { name }
    }

    private static func callout(_ style: String, line: Int = 1, title: String = #"<p class="callout-title"></p>"#, _ body: String) -> String {
        "<div class=\"callout callout-\(style)\" data-line=\"\(line)\">\n\(title)\n\(body)</div>\n"
    }

    /// What base (release/0.7.1 at 7e82573) wrote for these sources.
    private static let literalQuote = "<blockquote data-line=\"1\">\n<p data-line=\"1\">[!FOO]\nbody</p>\n</blockquote>\n"

    nonisolated static let cases: [Case] = [
        // Alerts: the five types, any case.
        Case(name: "alert NOTE", source: "> [!NOTE]\n> body", html: callout("note", "<p data-line=\"2\">body</p>\n")),
        Case(name: "alert TIP", source: "> [!TIP]\n> body", html: callout("tip", "<p data-line=\"2\">body</p>\n")),
        Case(name: "alert IMPORTANT", source: "> [!IMPORTANT]\n> body", html: callout("important", "<p data-line=\"2\">body</p>\n")),
        Case(name: "alert WARNING", source: "> [!WARNING]\n> body", html: callout("warning", "<p data-line=\"2\">body</p>\n")),
        Case(name: "alert CAUTION", source: "> [!CAUTION]\n> body", html: callout("caution", "<p data-line=\"2\">body</p>\n")),
        Case(name: "alert in lower case", source: "> [!note]\n> body", html: callout("note", "<p data-line=\"2\">body</p>\n")),
        // Not alerts: today's output, byte for byte.
        Case(name: "unknown alert type", source: "> [!FOO]\n> body", html: literalQuote),
        Case(name: "text after the marker", source: "> [!NOTE] extra\n> body",
             html: "<blockquote data-line=\"1\">\n<p data-line=\"1\">[!NOTE] extra\nbody</p>\n</blockquote>\n"),
        Case(name: "marker not first", source: "> body\n> [!NOTE]",
             html: "<blockquote data-line=\"1\">\n<p data-line=\"1\">body\n[!NOTE]</p>\n</blockquote>\n"),
        Case(name: "alert in a list", source: "- item\n\n  > [!TIP]\n  > body",
             html: "<ul data-line=\"1\">\n<li data-line=\"1\"><p data-line=\"1\">item</p>\n"
                + callout("tip", line: 3, "<p data-line=\"4\">body</p>\n") + "</li>\n</ul>\n"),

        // Containers, with blank lines.
        Case(name: "info, blank-line form", source: ":::info\n\nbody\n\n:::", html: callout("note", "<p data-line=\"3\">body</p>\n")),
        Case(name: "warning with a title", source: ":::warning Careful\n\nbody\n\n:::",
             html: callout("warning", title: #"<p class="callout-title callout-title-author">Careful</p>"#, "<p data-line=\"3\">body</p>\n")),
        // Containers, the usual HackMD form.
        Case(name: "info, no blank lines", source: ":::info\nbody\n:::", html: callout("note", "<p data-line=\"2\">body</p>\n")),
        Case(name: "success is TIP, danger is CAUTION", source: ":::success\nbody\n:::\n\n:::danger\nbody\n:::",
             html: callout("tip", "<p data-line=\"2\">body</p>\n") + callout("caution", line: 5, "<p data-line=\"6\">body</p>\n")),
        Case(name: "paragraph, callout, paragraph", source: "para\n:::info\nbody\n:::\nafter",
             html: "<p data-line=\"1\">para</p>\n" + callout("note", line: 2, "<p data-line=\"3\">body</p>\n") + "<p data-line=\"5\">after</p>\n"),
        Case(name: "spoiler is a closed details", source: ":::spoiler More\nhidden\n:::",
             html: "<details data-line=\"1\">\n<summary>More</summary>\n<p data-line=\"2\">hidden</p>\n</details>\n"),
        Case(name: "list closed by lazy continuation", source: ":::success\n- a\n- b\n:::",
             html: callout("tip", "<ul data-line=\"2\">\n<li data-line=\"2\">a\n</li>\n<li data-line=\"3\">b\n</li>\n</ul>\n")),
        Case(name: "nested list closed by lazy continuation", source: ":::info\n- a\n  - b\n:::",
             html: callout("note", "<ul data-line=\"2\">\n<li data-line=\"2\">a\n<ul data-line=\"3\">\n<li data-line=\"3\">b\n</li>\n</ul>\n</li>\n</ul>\n")),
        Case(name: "code block inside", source: ":::info\n\n```\ncode\n```\n\n:::",
             html: callout("note", "<pre data-line=\"3\"><code>code\n</code></pre>\n")),
        Case(name: "nested containers", source: ":::info\n\n:::warning\n\ninner\n\n:::\n\n:::",
             html: callout("note", callout("warning", line: 3, "<p data-line=\"5\">inner</p>\n"))),
        Case(name: "spoiler holding a callout", source: ":::spoiler S\n:::info\nx\n:::\n:::",
             html: "<details data-line=\"1\">\n<summary>S</summary>\n" + callout("note", line: 2, "<p data-line=\"3\">x</p>\n") + "</details>\n"),
        Case(name: "container in a tight list item", source: "- :::info\n  text\n  :::",
             html: "<ul data-line=\"1\">\n<li data-line=\"1\">" + callout("note", "<p data-line=\"2\">text</p>\n") + "</li>\n</ul>\n"),
        Case(name: "container in an alert", source: "> [!WARNING]\n> :::info\n> x\n> :::",
             html: callout("warning", callout("note", line: 2, "<p data-line=\"3\">x</p>\n"))),
        Case(name: "nested Markdown", source: ":::info\n**bold** and `code`\n:::",
             html: callout("note", "<p data-line=\"2\"><strong>bold</strong> and <code>code</code></p>\n")),

        // Not containers: what cmark made of them, byte for byte as before.
        Case(name: "closer absorbed into a table", source: ":::info\n| a |\n|---|\n| b |\n:::",
             html: "<p>:::info</p>\n<table data-line=\"1\">\n<thead>\n<tr data-line=\"1\"><th>a</th></tr>\n</thead>\n<tbody>\n"
                + "<tr data-line=\"4\"><td>b</td></tr>\n<tr data-line=\"5\"><td>:::</td></tr>\n</tbody>\n</table>\n"),
        Case(name: "unknown type", source: ":::nope\nx\n:::", html: "<p data-line=\"1\">:::nope\nx\n:::</p>\n"),
        Case(name: "unclosed", source: ":::info\nunclosed", html: "<p data-line=\"1\">:::info\nunclosed</p>\n"),
        Case(name: "later item follows the absorbed closer", source: ":::info\n- a\n:::\n- b",
             html: "<p data-line=\"1\">:::info</p>\n<ul data-line=\"2\">\n<li data-line=\"2\">a\n:::\n</li>\n<li data-line=\"4\">b\n</li>\n</ul>\n"),
        Case(name: "more lazy text follows the absorbed closer", source: ":::info\n- a\n:::\nmore",
             html: "<p data-line=\"1\">:::info</p>\n<ul data-line=\"2\">\n<li data-line=\"2\">a\n:::\nmore\n</li>\n</ul>\n"),
        Case(name: "spoiler without a title", source: ":::spoiler\nx\n:::", html: "<p data-line=\"1\">:::spoiler\nx\n:::</p>\n"),
        Case(name: "outer opener never closed", source: ":::info\n:::warning\nx\n:::",
             html: "<p data-line=\"1\">:::info</p>\n" + callout("warning", line: 2, "<p data-line=\"3\">x</p>\n")),
        Case(name: "a title with formatting is not a marker", source: ":::info **b**\nx\n:::",
             html: "<p data-line=\"1\">:::info <strong>b</strong>\nx\n:::</p>\n"),
    ]

    @Test(arguments: cases)
    func theSourceRendersAsExpected(_ item: Case) {
        #expect(MarkdownRenderer.render(item.source) == item.html, "\(item.name): \(item.source.debugDescription)")
    }

    /// Headings take their ids in document order, whatever callout they stand in.
    @Test func headingsInsideCalloutsKeepTheirOrder() {
        let html = MarkdownRenderer.render("# A\n\n:::info\n\n# B\n\n:::\n\n# C")
        #expect(html == "<h1 id=\"a\" data-line=\"1\">A</h1>\n"
            + Self.callout("note", line: 3, "<h1 id=\"b\" data-line=\"5\">B</h1>\n") + "<h1 id=\"c\" data-line=\"9\">C</h1>\n")
    }

    /// A GitHub `<details>` run (#414) inside a callout is grouped there.
    @Test func aDetailsRunInsideACalloutIsGroupedThere() {
        let html = MarkdownRenderer.render(":::info\n\n<details>\n<summary>S</summary>\n\nbody\n\n</details>\n\n:::")
        #expect(html == Self.callout("note", "<div class=\"html-block\" data-line=\"3\"><details>\n<summary>S</summary>\n<p data-line=\"6\">body</p>\n</details>\n</div>\n"))
    }

    /// The rendered HTML never depends on the process's language: the default title is not in it.
    @Test func theDefaultTitleIsNotInTheHTML() {
        for style in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] {
            let html = MarkdownRenderer.render("> [!\(style)]\n> body")
            #expect(html.contains(#"<p class="callout-title"></p>"#), "\(style)")
        }
    }
}
