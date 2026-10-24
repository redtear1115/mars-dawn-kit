#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// D8 / D8c (kit #128): the tree's colours are the theme's syntax colours on its surface, in every
/// built-in theme and appearance and in a gallery theme loaded through the registry; the page
/// follows appearance changes and `themeScript(light:dark:)`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DataDocumentThemeTests {
    /// Element (selector) → the theme variable its property must equal.
    static let expectations: [(selector: String, property: String, variable: String)] = [
        (".data-key", "color", "--hl-function"),
        (".data-string", "color", "--hl-string"),
        (".data-number", "color", "--hl-number"),
        (".data-bool", "color", "--hl-keyword"),
        (".data-null", "color", "--hl-keyword"),
        (".data-punct", "color", "--muted"),
        (".data-count", "color", "--muted"),
        (".data-cycle", "color", "--muted"),
        (".data-notice", "color", "--muted"),
        (".data-panel", "background-color", "--surface"),
        (".data-toggle", "color", "--fg"),
        (".data-more", "color", "--bg"),
        (".data-more", "background-color", "--accent"),
    ]

    static let errorExpectations: [(selector: String, property: String, variable: String)] = [
        (".data-error", "color", "--hl-keyword"),
        (".data-guidance", "color", "--muted"),
        (".data-source-button", "color", "--bg"),
        (".data-source-button", "background-color", "--accent"),
        ("body", "background-color", "--bg"),
    ]

    static func mismatches(_ list: [(selector: String, property: String, variable: String)]) -> String {
        let rows = list.map { "[\(PreviewWebView.jsonStringLiteral($0.selector)), \(PreviewWebView.jsonStringLiteral($0.property)), \(PreviewWebView.jsonStringLiteral($0.variable))]" }
        return """
        (() => {
          const probe = document.createElement('span');
          document.body.append(probe);
          const resolve = (variable) => {
            const raw = getComputedStyle(document.documentElement).getPropertyValue(variable).trim();
            probe.style.color = raw;
            return { raw, rgb: getComputedStyle(probe).color };
          };
          const out = [];
          for (const [selector, property, variable] of [\(rows.joined(separator: ", "))]) {
            const el = document.querySelector('#data ' + selector) || (selector === 'body' ? document.body : null);
            const want = resolve(variable);
            if (!el) { out.push(selector + ' missing'); continue; }
            if (!want.raw) { out.push(variable + ' undefined'); continue; }
            const got = getComputedStyle(el)[property === 'color' ? 'color' : 'backgroundColor'];
            if (got !== want.rgb) out.push(selector + ' ' + property + ' ' + got + ' != ' + variable + ' ' + want.raw + ' ' + want.rgb);
          }
          probe.remove();
          return out;
        })()
        """
    }

    /// A tree with every kind of row, a "show more" button and the stopped notice.
    static let tree = "&a {k: \"s\", n: 1, b: true, z: null, c: *a, l: [1, 2, 3, 4, 5, 6]}\n"

    static let builtIns: [PreviewTheme] = [.dawn, .classic, .modern, .vivid]

    @Test(arguments: [false, true])
    func everyBuiltInColoursTheTreeWithItsOwnVariables(dark: Bool) async throws {
        for theme in Self.builtIns {
            let webView = try await DataPage.load(theme: theme, dark: dark)
            #expect(await DataPage.render(Self.tree, kind: .yaml, in: webView, limits: ["maximumRenderedNodes": 10]) == .capped)
            let wrong = try await DataPage.value(Self.mismatches(Self.expectations), in: webView) as? [String]
            #expect(wrong == [], "\(theme.id) \(dark ? "dark" : "light"): \(String(describing: wrong))")
            #expect(await DataPage.render("[1,", kind: .json, in: webView, sequence: 2) == .parseError)
            let wrongError = try await DataPage.value(Self.mismatches(Self.errorExpectations), in: webView) as? [String]
            #expect(wrongError == [], "\(theme.id) \(dark ? "dark" : "light"): \(String(describing: wrongError))")
        }
    }

    /// Built-ins differ from one another, so the comparisons above can fail.
    @Test func theBuiltInsKeyColoursDiffer() async throws {
        var keys: Set<String> = []
        for theme in Self.builtIns {
            let webView = try await DataPage.load(theme: theme)
            #expect(await DataPage.render("{\"a\": 1}", kind: .json, in: webView) == .rendered)
            keys.insert(try await DataPage.string("getComputedStyle(document.querySelector('#data .data-key')).color", in: webView))
        }
        #expect(keys.count >= 3, "\(keys)")
    }

    /// A gallery theme installed in a registry reaches data.html: its themes.css is pinned to the
    /// registry's snapshot (F-D5).
    @Test(arguments: [false, true])
    func aGalleryThemeLoadedThroughTheRegistryColoursThePage(dark: Bool) async throws {
        let bytes = Data((GalleryThemeFixture.nord + "\n").utf8)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == "bc50d00ae2d1e6a7476800bc425ded3f533afd80c3b083e55df062f0b61b00c9",
                "the fixture is the served file, byte for byte")
        let installed = try InstalledThemes()
        try installed.add(GalleryThemeFixture.nordID, bytes)
        let registry = ThemeRegistry()
        let loaded = installed.load(into: registry)
        #expect(loaded.map(\.id) == ["nord"])
        let palette = try #require((try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?[dark ? "dark" : "light"] as? [String: Any])
        let handler = RecordingPreviewSchemeHandler(registry: registry)
        let nord = try #require(loaded.first)
        let webView = try await DataPage.load(theme: nord, dark: dark, handler: handler)
        #expect(await DataPage.render(Self.tree, kind: .yaml, in: webView, limits: ["maximumRenderedNodes": 10]) == .capped)
        let bg = try await DataPage.string("getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()", in: webView)
        #expect(bg.uppercased() == (palette["background"] as? String)?.uppercased(), "page --bg \(bg)")
        let fn = try await DataPage.string("getComputedStyle(document.documentElement).getPropertyValue('--hl-function').trim()", in: webView)
        #expect(fn.uppercased() == ((palette["syntax"] as? [String: Any])?["function"] as? String)?.uppercased())
        let wrong = try await DataPage.value(Self.mismatches(Self.expectations), in: webView) as? [String]
        #expect(wrong == [], "\(String(describing: wrong))")
        #expect(handler.paths.contains { $0.hasPrefix("/themes.css?snapshot=") }, "\(handler.paths)")
    }

    // MARK: D8c

    static func colours(_ webView: WKWebView) async throws -> [String] {
        try await DataPage.value("[document.documentElement.dataset.theme, getComputedStyle(document.body).backgroundColor, getComputedStyle(document.querySelector('#data .data-key')).color]", in: webView) as? [String] ?? []
    }

    func reference(_ theme: PreviewTheme, dark: Bool) async throws -> [String] {
        let webView = try await DataPage.load(theme: theme, dark: dark)
        #expect(await DataPage.render("{\"a\": 1}", kind: .json, in: webView) == .rendered)
        return try await Self.colours(webView)
    }

    @Test func thePageFollowsTheAppearanceAndThemeScript() async throws {
        let classicLight = try await reference(.classic, dark: false)
        let modernDark = try await reference(.modern, dark: true)
        let vividDark = try await reference(.vivid, dark: true)
        #expect(classicLight != modernDark && modernDark != vividDark)

        let webView = try await DataPage.load(theme: .classic, darkTheme: .modern, dark: false)
        #expect(await DataPage.render("{\"a\": 1}", kind: .json, in: webView) == .rendered)
        #expect(try await Self.colours(webView) == classicLight)
        webView.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await Self.colours(webView) == modernDark, "after the flip to dark")
        _ = try await webView.evaluateJavaScript(DataDocumentPreview.themeScript(light: .dawn, dark: .vivid))
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await Self.colours(webView) == vividDark, "after themeScript")
        webView.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await Self.colours(webView).first == "dawn")
    }
}
#endif
