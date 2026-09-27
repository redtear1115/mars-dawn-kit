#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit
@testable import MarsDawnThemes

// kit #125 (plan S2): the security-review dispositions that need the real page -- H1 (no hostile
// colour reaches CSS or Mermaid), L6 (splice integrity), Info (id pattern) -- and L1's display
// names, which need the kit's string tables.

private let previewCSSURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.css")
private let previewJSURL = previewCSSURL.deletingLastPathComponent().appendingPathComponent("preview.js")

/// A theme made through the lowest entry point there is -- `PreviewTheme`'s package initializer,
/// which takes any strings -- with `hostile` in the given colour.
private func hostileTheme(id: String = "evil", background: String? = nil, node: String? = nil, style: ThemeStyle? = nil) -> PreviewTheme {
    var light = PreviewTheme.dawn.light
    var dark = PreviewTheme.dawn.dark
    if let background { light.background = background; dark.background = background }
    if let node { light.diagram.node = node; dark.diagram.node = node }
    return PreviewTheme(id: id, name: "Evil", summary: "Hostile", fontDesign: .sans, light: light, dark: dark, style: style)
}

// MARK: - H1: the served stylesheets carry no byte of a refused theme

struct ThemeServedStylesheetRefusalTests {
    static let hostileColours = [
        "#FFFFFF;}", "#FFFFFF\n", "red", "var(--bg)", "\u{FF03}\u{FF26}\u{FF26}\u{FF26}\u{FF26}\u{FF26}\u{FF26}",
        "#\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}", "#FFF\u{0}FF", "#FFF",
        "#FFFFFF; background-image: url(https://example.com/pixel)",
    ]

    @Test(arguments: hostileColours)
    func aHostileColourLeavesTheWholeThemeOut(_ colour: String) {
        for theme in [hostileTheme(background: colour), hostileTheme(node: colour)] {
            #expect(theme.validated == nil)
            let served = PreviewTheme.stylesheet(for: PreviewTheme.all + [theme])
            #expect(served == PreviewTheme.stylesheet, "the served themes.css changed")
            #expect(!served.contains("evil"))
            #expect(PreviewTheme.generatedStyleCSS(for: PreviewTheme.all + [theme]) == PreviewTheme.generatedStyleCSS)
        }
    }

    @Test(arguments: ["evil\n", #"evil"]{}*{background:url(https://example.com/p)}"#, "Evil", "a--b"])
    func aHostileIDLeavesTheWholeThemeOut(_ id: String) {
        let theme = hostileTheme(id: id)
        #expect(theme.validated == nil)
        #expect(PreviewTheme.stylesheet(for: PreviewTheme.all + [theme]) == PreviewTheme.stylesheet)
        #expect(PreviewTheme.generatedStyleCSS(for: PreviewTheme.all + [theme]) == PreviewTheme.generatedStyleCSS)
    }

    /// Positive control: the same entry point with a clean palette *is* served, so the tests above
    /// are showing the refusal, not a path that serves nothing.
    @Test func aCleanThemeThroughTheSameEntryPointIsServed() {
        let theme = hostileTheme(id: "clean", style: ThemeStyle(radius: 3))
        #expect(theme.validated != nil)
        #expect(PreviewTheme.stylesheet(for: PreviewTheme.all + [theme]).contains(#":root[data-theme="clean"]"#))
        #expect(PreviewTheme.generatedStyleCSS(for: PreviewTheme.all + [theme]).contains("--radius: 3px;"))
    }

    /// M3 at the served level: a second theme claiming a built-in's id is left out, and the
    /// built-in's own CSS is unchanged.
    @Test func aSecondThemeWithABuiltInsIDIsLeftOut() {
        let impostor = hostileTheme(id: "classic", style: ThemeStyle(radius: 16))
        #expect(impostor.validated != nil)
        #expect(PreviewTheme.stylesheet(for: PreviewTheme.all + [impostor]) == PreviewTheme.stylesheet)
        #expect(PreviewTheme.generatedStyleCSS(for: PreviewTheme.all + [impostor]) == PreviewTheme.generatedStyleCSS)
    }
}

// MARK: - The page, with a themes.css of the test's choosing

/// Serves the real preview page through `PreviewSchemeHandler`, except `themes.css`, which the test
/// supplies, and `/pixel…`, which answers with an image and is recorded: a request for it means
/// some CSS or SVG on the page fetched an image.
@MainActor
final class ThemeInjectingSchemeHandler: NSObject, WKURLSchemeHandler {
    private let inner = PreviewSchemeHandler()
    var themesCSS: String
    private(set) var paths: [String] = []

    init(themesCSS: String) {
        self.themesCSS = themesCSS
    }

    var pixelRequests: [String] { paths.filter { $0.hasPrefix("/pixel") } }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        paths.append(url.path)
        let body: Data
        let type: String
        if url.path == "/themes.css" {
            body = Data(themesCSS.utf8)
            type = "text/css"
        } else if url.path.hasPrefix("/pixel") {
            body = Self.png
            type = "image/png"
        } else {
            inner.webView(webView, start: urlSchemeTask)
            return
        }
        urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": type, "Content-Length": "\(body.count)"])!)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@MainActor
enum ThemePage {
    /// Records every `themeVariables` object preview.js hands to `mermaid.initialize`, from the
    /// very first call (preview.js configures Mermaid on `DOMContentLoaded`). Injected at document
    /// start, it catches `mermaid.min.js`'s own `globalThis["mermaid"] = …` with a setter and wraps
    /// `initialize` before preview.js can call it.
    static let initializeRecorder = """
    (() => {
      window.__themeVariables = [];
      let current;
      Object.defineProperty(window, "mermaid", {
        configurable: true,
        get() { return current; },
        set(value) {
          current = value;
          if (value && typeof value.initialize === "function") {
            const original = value.initialize.bind(value);
            value.initialize = (config) => {
              window.__themeVariables.push(JSON.parse(JSON.stringify((config && config.themeVariables) || {})));
              return original(config);
            };
          }
        },
      });
    })();
    """

    static let document = """
    # Heading

    Text with a [link](https://example.com) and `code`.

    > A quote

    | A | B |
    | --- | --- |
    | 1 | 2 |

    ---

    ```mermaid
    flowchart LR
      A[Start] --> B[End]
    ```
    """

    struct Loaded {
        let webView: PreviewWKWebView
        let handler: ThemeInjectingSchemeHandler
    }

    /// Loads the page for `themeID` with remote images **allowed** (the CSP's `img-src` then admits
    /// `https:`), renders `document`, and waits for Mermaid.
    static func load(themeID: String, darkThemeID: String? = nil, dark: Bool, themesCSS: String) async throws -> Loaded {
        let handler = ThemeInjectingSchemeHandler(themesCSS: themesCSS)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(source: initializeRecorder, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 900), configuration: configuration)
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: true))
        var components = URLComponents(url: PreviewSchemeHandler.pageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "theme", value: themeID), URLQueryItem(name: PreviewSchemeHandler.remoteImagesQueryItem, value: "1")]
        if let darkThemeID { components.queryItems?.append(URLQueryItem(name: "darkTheme", value: darkThemeID)) }
        _ = webView.load(URLRequest(url: components.url!))
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await webView.evaluateJavaScript(PreviewWebView.updateScript(html: MarkdownRenderer.render(document), lineCount: 20))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        // Give any image a stylesheet or the SVG asked for time to reach the handler.
        try await Task.sleep(for: .milliseconds(500))
        return Loaded(webView: webView, handler: handler)
    }

    static func recordedThemeVariables(_ webView: WKWebView) async throws -> [[String: Any]] {
        let json = try await webView.evaluateJavaScript("JSON.stringify(window.__themeVariables || [])") as? String ?? "[]"
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] ?? []
    }
}

/// What preview.js hands Mermaid: each `themeVariables` key and the CSS variable it reads,
/// parsed from preview.js itself (`key: c("--var")`).
enum PreviewJSThemeVariables {
    static func mapping() throws -> [String: String] {
        let js = try String(contentsOf: previewJSURL, encoding: .utf8)
        guard let start = js.range(of: "themeVariables: {"), let end = js.range(of: "\n      },", range: start.upperBound..<js.endIndex) else { return [:] }
        var out: [String: String] = [:]
        for match in js[start.upperBound..<end.lowerBound].matches(of: /([A-Za-z0-9]+): [cv]\("(--[a-z0-9-]+)"\)/) {
            out[String(match.output.1)] = String(match.output.2)
        }
        return out
    }
}

// MARK: - H1: zero image requests with remote images on

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ThemeHostilePaletteImageRequestTests {
    /// kit 0.5.4 wrote palette values into `themes.css` verbatim. This is that shape, for the
    /// control: it shows a colour that isn't one really does make the page fetch an image, so the
    /// real test's zero is the generator's doing and not a blind instrument.
    static func verbatimBlock(id: String, background: String) -> String {
        ":root[data-theme=\"\(id)\"] {\n  --bg: \(background);\n}\n"
    }

    static let payload = "#FFFFFF; background-image: url(marsdawn-app://preview/pixel-root.png)"

    @Test func controlAVerbatimHostileColourFetchesAnImage() async throws {
        let css = PreviewTheme.stylesheet + "\n" + Self.verbatimBlock(id: "evil", background: Self.payload)
        let page = try await ThemePage.load(themeID: "evil", dark: false, themesCSS: css)
        #expect(try await page.webView.evaluateJavaScript("document.documentElement.dataset.theme") as? String == "evil")
        #expect(page.handler.pixelRequests.contains("/pixel-root.png"), "the control fetched nothing: \(page.handler.paths)")
    }

    @Test(arguments: [false, true])
    func theGeneratedStylesheetFetchesNothingForAHostilePalette(dark: Bool) async throws {
        let hostile = [
            hostileTheme(id: "evil", background: Self.payload, node: "url(marsdawn-app://preview/pixel-node.png)"),
            hostileTheme(id: "evil-two", background: "#FFFFFF;}:root{background-image:url(marsdawn-app://preview/pixel-two.png)}"),
        ]
        let css = PreviewTheme.stylesheet(for: PreviewTheme.all + hostile)
        #expect(!css.contains("pixel"))
        let page = try await ThemePage.load(themeID: "evil", darkThemeID: "evil-two", dark: dark, themesCSS: css)
        // The page really did try to use the hostile theme.
        #expect(try await page.webView.evaluateJavaScript("document.documentElement.dataset.theme") as? String == (dark ? "evil-two" : "evil"))
        #expect(try await page.webView.evaluateJavaScript("document.querySelectorAll('.mermaid-output svg').length") as? Int == 1,
                "positive fixture: the diagram rendered")
        #expect(page.handler.pixelRequests.isEmpty, "image requests: \(page.handler.pixelRequests)")
    }

    /// The same through an https server when this system can make a TLS identity (macOS 26): the
    /// hostile value names a real https image the page's CSP admits with remote images on.
    @Test(.enabled(if: TestTLS.isAvailable))
    func noHTTPSRequestReachesAServer() async throws {
        guard #available(macOS 26, *) else { return }
        let tls = try TestTLSIdentity.make()
        let server = try await RecordingServer.start(identity: tls.identity)
        defer { server.stop() }
        let url = "https://127.0.0.1:\(server.port)/pixel.png"
        let hostile = hostileTheme(id: "evil", background: "#FFFFFF; background-image: url(\(url))", node: "url(\(url))")
        let css = PreviewTheme.stylesheet(for: PreviewTheme.all + [hostile])
        #expect(!css.contains(url))
        let page = try await ThemePage.load(themeID: "evil", dark: false, themesCSS: css)
        try await Task.sleep(for: .seconds(1))
        #expect(server.accepts == 0, "connections: \(server.accepts), paths: \(server.paths)")
        _ = page
    }
}

// MARK: - H1: what Mermaid receives

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ThemeMermaidVariablesTests {
    /// Every colour-valued `themeVariables` entry Mermaid receives, for every built-in in both
    /// appearances, is exactly the palette value kit 0.5.4 passed (it read the same CSS variable
    /// straight through), and the rendered flowchart's node is painted with it.
    @Test(arguments: ["dawn", "classic", "modern", "vivid"])
    func builtInsHandMermaidTheirOwnColours(_ id: String) async throws {
        let mapping = try PreviewJSThemeVariables.mapping()
        #expect(mapping.count >= 40, "positive fixture: preview.js's themeVariables were parsed (\(mapping.count))")
        let theme = PreviewTheme.named(id)
        let validated = try #require(theme.validated)
        for dark in [false, true] {
            let palette = Dictionary(uniqueKeysWithValues: (dark ? validated.dark : validated.light).cssVariables.map { ("--\($0.name)", $0.value) })
            let page = try await ThemePage.load(themeID: id, dark: dark, themesCSS: PreviewTheme.stylesheet)
            let recorded = try await ThemePage.recordedThemeVariables(page.webView)
            let variables = try #require(recorded.last, "\(id) \(dark): mermaid.initialize wasn't called")
            var mismatches: [String] = []
            for (key, cssVariable) in mapping.sorted(by: { $0.key < $1.key }) {
                guard cssVariable != "--font-body" else { continue }
                let expected = palette[cssVariable]
                let actual = variables[key] as? String
                if actual != expected { mismatches.append("\(key) (\(cssVariable)): got \(actual ?? "nil"), want \(expected ?? "nil")") }
            }
            #expect(mismatches.isEmpty, "\(id) \(dark ? "dark" : "light"):\n\(mismatches.joined(separator: "\n"))")
            let fill = try await page.webView.evaluateJavaScript(
                "(() => { const r = document.querySelector('.mermaid-output .node rect, .mermaid-output .node polygon'); return r ? getComputedStyle(r).fill : ''; })()"
            ) as? String ?? ""
            #expect(ThemeGoldenHarness.normalize(fill) == Self.rgba(palette["--mm-node"] ?? ""), "\(id) \(dark): node fill \(fill)")
        }
    }

    /// A colour that isn't `#RRGGBB` -- here put straight into `themes.css`, bypassing the
    /// generator, the lowest point there is -- reaches Mermaid as Dawn's value instead.
    @Test(arguments: [false, true])
    func aNonHexCustomPropertyReachesMermaidAsDawns(dark: Bool) async throws {
        let css = PreviewTheme.stylesheet + """

        :root[data-theme="evil"] {
          --bg: #123456;
          --mm-node: url(marsdawn-app://preview/pixel-node.png);
          --mm-text: rgb(1, 2, 3);
          --mm-line: red;
          --accent: #ABCDEF00;
          --link: #1234567;
        }
        """
        let page = try await ThemePage.load(themeID: "evil", dark: dark, themesCSS: css)
        let variables = try #require(try await ThemePage.recordedThemeVariables(page.webView).last)
        let dawn = Dictionary(uniqueKeysWithValues: (dark ? PreviewTheme.dawn.validated!.dark : PreviewTheme.dawn.validated!.light).cssVariables.map { ("--\($0.name)", $0.value) })
        #expect(variables["background"] as? String == "#123456", "positive fixture: a real hex passes through")
        #expect(variables["primaryColor"] as? String == dawn["--mm-node"])
        #expect(variables["primaryTextColor"] as? String == dawn["--mm-text"])
        #expect(variables["lineColor"] as? String == dawn["--mm-line"])
        #expect(variables["pie1"] as? String == dawn["--accent"])
        #expect(variables["pie6"] as? String == dawn["--link"])
        #expect(variables["fontSize"] as? String == "14px", "non-colour variables are untouched")
        #expect(page.handler.pixelRequests.isEmpty, "image requests: \(page.handler.pixelRequests)")
    }

    /// preview.js's Dawn fallback table is `dawn/theme.json`'s, so the two can't drift apart.
    @Test func theFallbackTableIsDawns() throws {
        let js = try String(contentsOf: previewJSURL, encoding: .utf8)
        let start = try #require(js.range(of: "const dawnMermaidColors = {"))
        let end = try #require(js.range(of: "\n  };", range: start.upperBound..<js.endIndex))
        let table = js[start.upperBound..<end.lowerBound]
        let darkStart = try #require(table.range(of: "dark: {"))
        func entries(_ text: Substring) -> [String: String] {
            Dictionary(text.matches(of: /"(--[a-z0-9-]+)": "(#[0-9A-Fa-f]{6})"/).map { (String($0.output.1), String($0.output.2)) }, uniquingKeysWith: { a, _ in a })
        }
        let light = entries(table[table.startIndex..<darkStart.lowerBound])
        let dark = entries(table[darkStart.upperBound...])
        let dawn = try #require(PreviewTheme.dawn.validated)
        let dawnLight = Dictionary(uniqueKeysWithValues: dawn.light.cssVariables.map { ("--\($0.name)", $0.value) })
        let dawnDark = Dictionary(uniqueKeysWithValues: dawn.dark.cssVariables.map { ("--\($0.name)", $0.value) })
        let needed = Set(try PreviewJSThemeVariables.mapping().values).subtracting(["--font-body"])
        #expect(needed.count >= 15, "positive fixture: \(needed)")
        #expect(Set(light.keys) == needed, "light table keys: \(light.keys.sorted()) vs \(needed.sorted())")
        #expect(Set(dark.keys) == needed)
        for key in needed {
            #expect(light[key] == dawnLight[key], "light \(key)")
            #expect(dark[key] == dawnDark[key], "dark \(key)")
        }
    }

    static func rgba(_ hex: String) -> String {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return "rgba(\((value >> 16) & 0xFF), \((value >> 8) & 0xFF), \(value & 0xFF), 1.00)"
    }
}

// MARK: - L6: the splice keeps the print block last

struct ThemeSpliceIntegrityTests {
    /// Top-level blocks of a stylesheet, as (prelude, body), skipping comments.
    static func topLevelBlocks(_ css: String) -> (blocks: [String], balanced: Bool) {
        let text = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var blocks: [String] = []
        var depth = 0
        var prelude = ""
        var balanced = true
        for character in text {
            if character == "{" {
                if depth == 0 { blocks.append(prelude.trimmingCharacters(in: .whitespacesAndNewlines)) }
                depth += 1
                prelude = ""
            } else if character == "}" {
                depth -= 1
                if depth < 0 { balanced = false }
                prelude = ""
            } else if depth == 0 {
                prelude.append(character)
            }
        }
        return (blocks, balanced && depth == 0)
    }

    static func splice(_ themes: [PreviewTheme]) throws -> String {
        let raw = try String(contentsOf: previewCSSURL, encoding: .utf8)
        return raw.replacingOccurrences(of: PreviewSchemeHandler.themeRulesMarker, with: PreviewTheme.generatedStyleCSS(for: themes))
    }

    @Test func theHelperSplicesLikeTheSchemeHandler() throws {
        let served = String(decoding: PreviewSchemeHandler.splicedPreviewCSS(try Data(contentsOf: previewCSSURL)), as: UTF8.self)
        #expect(try Self.splice(PreviewTheme.all) == served)
    }

    @Test func thePrintBlockStaysLastWithHostileThemesPresent() throws {
        var extreme = try ThemeDocumentLoader.loadBuiltIn(id: "vivid")
        extreme.id = "extreme"
        extreme.style = ThemeStyle(bodySize: 18, lineHeight: 1.9, headingWeight: 900, radius: 16, maxWidth: 1000,
                                   h1: .init(size: 2.4, letterSpacing: 0.03, align: .center, decoration: .shortRule(color: .accent)),
                                   h2: .init(letterSpacing: -0.03, decoration: .dot(color: .heading), italic: true),
                                   blockquote: .init(style: .panel, italic: true), hr: .init(style: .gradient(colors: [.accent, .heading])),
                                   table: .init(header: .filled(background: .heading, text: .background, border: .border), verticalRules: false, rounded: true),
                                   listMarker: .heading, inlineCode: .keyword, link: .init(underline: true), syntax: .init(boldKeywords: true))
        let valid = PreviewTheme(document: extreme, name: "Extreme", summary: "Every option")
        #expect(valid.validated != nil, "positive fixture: the extreme theme validates")
        let hostile = [
            valid,
            hostileTheme(id: #"x"]{}@media print{*{display:none}}"#),
            hostileTheme(id: "evil", background: "#FFFFFF;}@media print{body{display:none}}"),
            hostileTheme(id: "evil-two", style: ThemeStyle(radius: 1e308)),
        ]
        let css = try Self.splice(PreviewTheme.all + hostile)
        #expect(!css.contains(PreviewSchemeHandler.themeRulesMarker))
        #expect(css.contains(#"[data-theme="extreme"] h1::after"#), "positive fixture: the valid hostile-ish theme's rules are there")
        let (blocks, balanced) = Self.topLevelBlocks(css)
        #expect(balanced, "braces don't balance")
        #expect(blocks.last == "@media print", "last top-level block: \(blocks.last ?? "none")")
        #expect(blocks.filter { $0 == "@media print" }.count == 2, "the print block count changed: \(blocks.filter { $0.hasPrefix("@media") })")
        let lastPrint = try #require(css.range(of: "@media print {", options: .backwards))
        let lastGenerated = try #require(css.range(of: "[data-theme=", options: .backwards))
        #expect(lastGenerated.lowerBound < lastPrint.lowerBound)
    }
}

// MARK: - Info: one id pattern in theme-boot.js and preview.js

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ThemeIDPatternPageTests {
    private func dataTheme(_ webView: WKWebView) async throws -> String {
        try await webView.evaluateJavaScript("document.documentElement.dataset.theme") as? String ?? ""
    }

    @Test func theBootScriptTakesOnlyTheSharedPattern() async throws {
        for (id, expected) in [("vivid", "vivid"), ("vivid-", "dawn"), ("-vivid", "dawn"), ("a--b", "dawn"),
                               (String(repeating: "a", count: 33), "dawn"), (String(repeating: "a", count: 32), String(repeating: "a", count: 32))] {
            let page = try await ThemePage.load(themeID: id, dark: false, themesCSS: PreviewTheme.stylesheet)
            #expect(try await dataTheme(page.webView) == expected, "?theme=\(id)")
        }
    }

    @Test func setThemesTakesOnlyTheSharedPattern() async throws {
        let page = try await ThemePage.load(themeID: "classic", dark: false, themesCSS: PreviewTheme.stylesheet)
        #expect(try await dataTheme(page.webView) == "classic")
        for id in ["vivid-", "a--b", "Vivid", String(repeating: "a", count: 33)] {
            _ = try await page.webView.evaluateJavaScript("MarsDawn.setThemes(\(PreviewWebView.jsonStringLiteral(id)), null)")
            #expect(try await dataTheme(page.webView) == "classic", "setThemes(\(id)) was accepted")
        }
        _ = try await page.webView.evaluateJavaScript("MarsDawn.setThemes(\"modern\", null)")
        #expect(try await dataTheme(page.webView) == "modern", "positive fixture: a valid id is applied")
    }
}

// MARK: - L1: names come from the string table by built-in id only

struct ThemeDisplayNameTests {
    private func document(id: String, name: String, summary: String = "A summary") throws -> ThemeDocument {
        var document = try ThemeDocumentLoader.loadBuiltIn(id: "dawn")
        document.id = id
        document.name = LocalizedText(en: name)
        document.summary = LocalizedText(en: summary)
        return document
    }

    @Test func aBuiltInIsNamedFromTheStringTable() throws {
        let theme = PreviewTheme(validated: try #require(PreviewTheme.dawn.validated), localization: "zh-Hant")
        #expect(theme.name == "黎明", "positive fixture: the zh-Hant table is really read")
        #expect(theme.summary == "溫暖的火星日出")
    }

    @Test(arguments: ["Dawn", "%@ %n", "Classic", "%1$@ %2$@ %d"])
    func anInstalledThemesNameIsShownVerbatim(_ name: String) throws {
        let validated = try #require(ThemeValidator.validate(try document(id: "my-theme", name: name, summary: name)).theme)
        let theme = PreviewTheme(validated: validated, localization: "zh-Hant")
        #expect(theme.name == name)
        #expect(theme.summary == name)
    }

    @Test func anInstalledThemeFallsBackToEnglish() throws {
        var doc = try document(id: "my-theme", name: "Olympus Dusk")
        doc.name = LocalizedText(en: "Olympus Dusk", others: ["zh-Hant": "奧林帕斯暮色"])
        let validated = try #require(ThemeValidator.validate(doc).theme)
        #expect(PreviewTheme(validated: validated, localization: "zh-Hant").name == "奧林帕斯暮色")
        #expect(PreviewTheme(validated: validated, localization: "ja").name == "Olympus Dusk")
    }

    @Test func theStandaloneRuleMatchesTheValidator() {
        #expect(PreviewTheme.acceptedDisplayString("Olympus Dusk") == "Olympus Dusk")
        #expect(PreviewTheme.acceptedDisplayString("Cafe\u{301}") == "Café")
        for bad in ["a\u{202E}b", "a\u{0}b", "a\u{FEFF}b", "Z\u{301}\u{302}\u{303}\u{304}\u{305}", "www.example.com", "   ", String(repeating: "x", count: 49)] {
            #expect(PreviewTheme.acceptedDisplayString(bad) == nil, "accepted \(bad.debugDescription)")
        }
    }
}
#endif
