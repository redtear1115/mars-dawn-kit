#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Callouts in the real preview page (kit #135): the bar's colour per type, theme and appearance,
/// the default title drawn from the host's labels, and what a hostile label can and cannot do.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct CalloutPageTests {
    /// The palette role each type's bar is drawn in (CSS variable names).
    static let roles: [(type: String, variable: String)] = [
        ("note", "accent"), ("tip", "hl-string"), ("important", "hl-function"), ("warning", "hl-number"), ("caution", "hl-keyword"),
    ]

    static let document = """
    > [!NOTE]
    > a

    > [!TIP]
    > b

    > [!IMPORTANT]
    > c

    > [!WARNING]
    > d

    > [!CAUTION]
    > e

    plain paragraph
    """

    private func load(theme: PreviewTheme, dark: Bool, markdown: String = document, titles: CalloutTitles = .english) async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 900), configuration: PreviewWebView.makeConfiguration())
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: theme))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await update(webView, markdown: markdown, titles: titles)
        return webView
    }

    private func update(_ webView: PreviewWKWebView, markdown: String, titles: CalloutTitles) async throws {
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: 40, calloutTitles: titles)
        )
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    private func string(_ script: String, in webView: WKWebView) async throws -> String {
        try await webView.callAsyncJavaScript("return \(script);", contentWorld: .page) as? String ?? ""
    }

    /// `#RRGGBB` as the computed-style spelling.
    private static func rgb(_ hex: String) -> String {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return "rgb(\(value >> 16), \((value >> 8) & 0xFF), \(value & 0xFF))"
    }

    private func barColour(_ type: String, in webView: WKWebView) async throws -> String {
        try await string("getComputedStyle(document.querySelector('.callout-\(type)')).borderLeftColor", in: webView)
    }

    /// The text of a callout's default title: what the page draws before the empty element.
    private func drawnTitle(_ type: String, in webView: WKWebView) async throws -> String {
        try await string("""
        (() => {
          const content = getComputedStyle(document.querySelector('.callout-\(type) > .callout-title'), '::before').content;
          return content.slice(1, -1).replace(/\\\\(["\\\\])/g, '$1');
        })()
        """, in: webView)
    }

    // MARK: C4: colours

    @Test(arguments: ["dawn", "classic", "modern", "vivid"])
    func theBarIsDrawnInItsRoleInEveryThemeAndAppearance(_ id: String) async throws {
        let theme = PreviewTheme.named(id)
        let validated = try #require(theme.validated)
        for dark in [false, true] {
            let palette = Dictionary(uniqueKeysWithValues: (dark ? validated.dark : validated.light).cssVariables.map { ($0.name, $0.value) })
            let webView = try await load(theme: theme, dark: dark)
            var drawn: [String: String] = [:]
            for (type, variable) in Self.roles {
                let colour = try await barColour(type, in: webView)
                drawn[type] = colour
                #expect(colour == Self.rgb(try #require(palette[variable])), "\(id) \(dark ? "dark" : "light") \(type): \(colour), want --\(variable) \(palette[variable] ?? "?")")
            }
            // No two types share a bar colour where the palette has the hues for it.
            if id != "classic" {
                let shared = Dictionary(grouping: drawn.keys.sorted(), by: { drawn[$0]! }).filter { $0.value.count > 1 }
                #expect(shared.isEmpty, "COLLISION in \(id) \(dark ? "dark" : "light"): \(shared.values.map { $0.joined(separator: " = ") })")
            }
        }
    }

    @Test func classicSharesHuesAndTheTitleTellsThemApart() async throws {
        // Classic is greyscale: light IMPORTANT = CAUTION; dark also NOTE = WARNING (kit #135). The
        // title, not the colour, tells them apart there.
        let validated = try #require(PreviewTheme.classic.validated)
        let light = Dictionary(uniqueKeysWithValues: validated.light.cssVariables.map { ($0.name, $0.value) })
        #expect(light["hl-function"] == light["hl-keyword"], "positive fixture: Classic light shares IMPORTANT and CAUTION")
        let webView = try await load(theme: .classic, dark: false)
        #expect(try await drawnTitle("important", in: webView) == "Important")
        #expect(try await drawnTitle("caution", in: webView) == "Caution")
    }

    // MARK: Default titles

    @Test func theDefaultTitleIsTheHostsLabel() async throws {
        let webView = try await load(theme: .dawn, dark: false, titles: CalloutTitles(note: "附註", tip: "提示", important: "重要", warning: "警告", caution: "小心"))
        for (type, word) in [("note", "附註"), ("tip", "提示"), ("important", "重要"), ("warning", "警告"), ("caution", "小心")] {
            #expect(try await drawnTitle(type, in: webView) == word, Comment(rawValue: type))
        }
        // And the element itself holds nothing: it is generated content.
        #expect(try await string("document.querySelector('.callout-note > .callout-title').textContent", in: webView) == "")
    }

    @Test func withoutLabelsTheStylesheetsEnglishShows() async throws {
        // A page that never ran `setLabels`.
        let fresh = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 900), configuration: PreviewWebView.makeConfiguration())
        fresh.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        _ = fresh.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn)))
        let deadline = ContinuousClock.now + .seconds(20)
        while fresh.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await fresh.evaluateJavaScript("MarsDawn.update(\(PreviewWebView.jsonStringLiteral(MarkdownRenderer.render("> [!TIP]\n> x"))), 3);")
        #expect(try await drawnTitle("tip", in: fresh) == "Tip")
    }

    @Test func anAuthorTitleReplacesTheDefault() async throws {
        let webView = try await load(theme: .dawn, dark: false, markdown: ":::warning Careful now\n\nbody\n\n:::")
        let before = try await string("getComputedStyle(document.querySelector('.callout-title'), '::before').content", in: webView)
        #expect(before == "none" || before == "normal", "no default title beside the author's: \(before)")
        #expect(try await string("document.querySelector('.callout-title').textContent", in: webView) == "Careful now")
    }

    // MARK: C2: a hostile label

    private static let hostile = #"");} * { color: red } x { content: ("#

    @Test func aHostileLabelIsDrawnAsTextAndNothingElse() async throws {
        let webView = try await load(theme: .dawn, dark: false)
        func snapshot() async throws -> String {
            try await string("""
            (() => {
              const out = [];
              for (const el of [document.body, document.documentElement, ...document.querySelectorAll('p, .callout, .callout-title')]) {
                const style = getComputedStyle(el);
                out.push(el.tagName + ':' + [...style].map((name) => name + '=' + style.getPropertyValue(name)).filter((s) => !s.startsWith('--callout')).join(';'));
              }
              return out.join('\\n');
            })()
            """, in: webView)
        }
        let before = try await snapshot()
        let scriptsBefore = try await string("String(document.querySelectorAll('script').length)", in: webView)
        #expect(before.count > 1000, "positive fixture: the snapshot has the computed styles")
        let labels = CalloutTitles(note: Self.hostile, tip: "a\\b'c\"d</style><script>", important: "\u{1F680} 中文 x", warning: "W", caution: "C")
        try await update(webView, markdown: Self.document, titles: labels)
        #expect(try await drawnTitle("note", in: webView) == Self.hostile)
        #expect(try await drawnTitle("tip", in: webView) == "a\\b'c\"d</style><script>")
        #expect(try await drawnTitle("important", in: webView) == "\u{1F680} 中文 x")
        let after = try await snapshot()
        // Only the titles' generated text differs: nothing took the colour red, nothing else moved.
        #expect(before == after, "computed styles changed")
        #expect(try await string("getComputedStyle(document.body).color", in: webView) == Self.rgb("#26211F"))
        #expect(try await string("String(document.querySelectorAll('script').length)", in: webView) == scriptsBefore, "no script element came of a label")
    }
}
#endif
