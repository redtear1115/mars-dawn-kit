#if os(macOS)
import AppKit
import Foundation
import WebKit
@testable import MarsDawnKit

/// The fixed sample document the theme golden renders (kit #124, plan S1 item 5): headings,
/// a paragraph with a link, lists including a task list, a nested blockquote, a table, inline
/// code, a fenced code block with keywords and a title, a rule, an invalid Mermaid diagram, an
/// invalid math expression, front matter with its own table, and footnotes.
enum ThemeGoldenDocument {
    static let markdown = """
    ---
    title: Golden fixture
    author: MarsDawn
    ---
    # Heading one

    ## Heading two

    ### Heading three

    A paragraph with a [link](https://example.com) in it.

    - one
    - two

    1. first
    2. second

    - [ ] not done
    - [x] done

    > Outer quote
    >
    > > Nested quote

    | Col A | Col B |
    | --- | --- |
    | a | b |

    Inline `code` in a sentence.

    ```js
    function GOLDENTITLE01() {
      // GOLDENKEYWORD01
      return 1;
    }
    ```

    ---

    ```mermaid
    this is not valid GOLDENMERMAID01 (((
    ```

    $$ \\frac{1 GOLDENMATH01 }{ \\notarealcommand $$

    Text with a footnote[^1].

    [^1]: The footnote body.
    """

    /// One selector per required element (plan item 5), plus the pseudo-elements a per-theme
    /// style option can draw (`h1::after`, `h2::before`, `li::marker`, the Mermaid error's own
    /// `::before`).
    static let selectors: [String] = [
        ".markdown-body",
        "h1", "h1::after",
        "h2", "h2::before",
        "h3",
        "p", "p a",
        "ul", "ol", "li", "li::marker",
        ".task-list-item input",
        "blockquote", "blockquote blockquote",
        "table", "th", "td",
        // kit #125 carry-over from #127's verification: `table`/`th`/`td` above match the
        // front-matter table first (querySelector order), so the body table's header rules
        // (Classic `accentRule`, Vivid `filled`) weren't in the golden. These sample the body's
        // own table, a direct child of the article.
        ".markdown-body > table", ".markdown-body > table th", ".markdown-body > table td",
        "code:not(pre code)",
        "pre code", ".hljs-keyword", ".hljs-title",
        "hr",
        ".mermaid-error", ".mermaid-error::before",
        ".math-error",
        "details.front-matter", "details.front-matter th", "details.front-matter td",
        ".footnotes", ".footnote-ref a",
    ]

    /// Limited to values that don't depend on layout (no offset widths/heights from wrapping,
    /// no line-height or font-size, which a font-metrics difference between WebKit versions could
    /// change) or on how a browser happens to serialize a colour -- colours are read as
    /// `color`/`background-color`/border colours and normalised to `rgba(...)` before comparison
    /// (`ThemeGoldenHarness.normalize`), never compared as raw strings. `content` and `maxWidth` are literal,
    /// arithmetic-only values (a quoted string, or a number of pixels computed from another
    /// number in the stylesheet), so they carry no such risk either.
    static let properties: [String] = [
        "color", "backgroundColor",
        "borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor",
        "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
        "borderRadius",
        "fontWeight", "fontStyle",
        "letterSpacing",
        "textAlign", "textDecorationLine",
        "listStyleType",
        "content",
        "maxWidth",
    ]

    /// `width`/`height` for the handful of selectors whose size is a literal number a per-theme
    /// rule sets directly (a decoration's bar, dot or gradient thickness, `hr`'s own height and
    /// percentage width against the fixed-width viewport) -- not left out of `properties` above
    /// with everything else that depends on text flow, since a style option's whole visible effect
    /// there *is* a width or a height (e.g. Classic's `h1::after` bar, plan's own example control).
    static let geometryProperties: [String] = ["width", "height"]
    static let geometrySelectors: Set<String> = ["h1::after", "h2::before", "hr"]
}

/// One element's dumped computed style, keyed by theme id, colour scheme and selector.
struct GoldenKey: Hashable, Codable, Comparable {
    let theme: String
    let mode: String // "light" | "dark"
    let selector: String

    static func < (lhs: GoldenKey, rhs: GoldenKey) -> Bool {
        (lhs.theme, lhs.mode, lhs.selector) < (rhs.theme, rhs.mode, rhs.selector)
    }
}

struct GoldenSnapshot: Codable, Equatable {
    /// Sorted by key for a stable diff and a deterministic file on disk.
    var entries: [Entry]

    struct Entry: Codable, Equatable {
        let theme: String
        let mode: String
        let selector: String
        let properties: [String: String]
    }

    subscript(_ key: GoldenKey) -> [String: String]? {
        entries.first { $0.theme == key.theme && $0.mode == key.mode && $0.selector == key.selector }?.properties
    }
}

@MainActor
enum ThemeGoldenHarness {
    /// Renders the fixture document under every built-in theme, in light and dark, and dumps
    /// `ThemeGoldenDocument.properties` for every selector in `ThemeGoldenDocument.selectors`
    /// (element or pseudo-element). Colours are normalised to `rgba(r, g, b, a)` so a harmless
    /// difference in how a WebKit version formats a colour string doesn't fail the comparison.
    static func capture() async throws -> GoldenSnapshot {
        var entries: [GoldenSnapshot.Entry] = []
        for theme in PreviewTheme.all {
            for dark in [false, true] {
                let properties = try await captureOne(theme: theme, dark: dark)
                for selector in ThemeGoldenDocument.selectors {
                    entries.append(.init(
                        theme: theme.id, mode: dark ? "dark" : "light", selector: selector,
                        properties: properties[selector] ?? [:]
                    ))
                }
            }
        }
        entries.sort { ($0.theme, $0.mode, $0.selector) < ($1.theme, $1.mode, $1.selector) }
        return GoldenSnapshot(entries: entries)
    }

    private static func captureOne(theme: PreviewTheme, dark: Bool) async throws -> [String: [String: String]] {
        let webView = PreviewWKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 1400),
            configuration: PreviewWebView.makeConfiguration()
        )
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        _ = webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: theme)))
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(ThemeGoldenDocument.markdown), lineCount: 60)
        )
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        // Force the front-matter <details> open, so its table's computed style is what a reader
        // actually sees, not the UA's `[hidden]`-equivalent collapse (plan: "open front matter").
        _ = try? await webView.evaluateJavaScript("document.querySelectorAll('.front-matter').forEach(d => d.open = true);")

        let selectorsJSON = try jsonArrayLiteral(ThemeGoldenDocument.selectors)
        let propertiesJSON = try jsonArrayLiteral(ThemeGoldenDocument.properties)
        let geometryPropertiesJSON = try jsonArrayLiteral(ThemeGoldenDocument.geometryProperties)
        let geometrySelectorsJSON = try jsonArrayLiteral(Array(ThemeGoldenDocument.geometrySelectors))
        let script = """
        (() => {
          const selectors = \(selectorsJSON);
          const props = \(propertiesJSON);
          const geometryProps = \(geometryPropertiesJSON);
          const geometrySelectors = new Set(\(geometrySelectorsJSON));
          const out = {};
          for (const sel of selectors) {
            let base = sel, pseudo = null;
            const m = sel.match(/^(.*)(::[a-zA-Z-]+)$/);
            if (m) { base = m[1]; pseudo = m[2]; }
            const el = document.querySelector(base);
            if (!el) continue;
            const style = getComputedStyle(el, pseudo);
            const dump = {};
            for (const p of props) { dump[p] = style[p]; }
            if (geometrySelectors.has(sel)) { for (const p of geometryProps) { dump[p] = style[p]; } }
            out[sel] = dump;
          }
          return JSON.stringify(out);
        })()
        """
        let text = try await webView.callAsyncJavaScript("return \(script);", contentWorld: .page) as? String ?? "{}"
        let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: String]] ?? [:]
        return raw.mapValues { properties in properties.mapValues(normalize) }
    }

    /// WebKit changed its disabled checkbox default in macOS 27. These are real colour
    /// changes, not alternate spellings; keep the exception confined to the UA-owned values.
    static let macOS27DisabledCheckboxColors = [
        "light": "oklab(0.34 0 0)",
        "dark": "oklab(0.739911 0 0)",
    ]
    static let disabledCheckboxColorProperties: Set<String> = [
        "color", "borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor",
    ]

    static func expectedValue(
        _ golden: String, selector: String, property: String, mode: String,
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> String {
        if osMajorVersion >= 27, selector == ".task-list-item input",
           disabledCheckboxColorProperties.contains(property),
           let color = macOS27DisabledCheckboxColors[mode] {
            return normalize(color)
        }
        return normalize(golden)
    }

    /// Numeric RGB, sRGB and OKLab colours share integer sRGB channels and a fixed-precision
    /// alpha. Unsupported syntax passes through so it cannot silently become a different colour.
    static func normalize(_ value: String) -> String {
        func numbers(_ parts: [String]) -> [Double]? {
            let values = parts.compactMap(Double.init)
            guard values.count == parts.count, values.allSatisfy({ $0.isFinite }) else { return nil }
            return values
        }
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        func rgba(_ channels: [Double], alpha: Double) -> String {
            let rgb = channels.map { Int((clamp($0) * 255).rounded()) }
            return "rgba(\(rgb[0]), \(rgb[1]), \(rgb[2]), \(String(format: "%.2f", clamp(alpha))))"
        }
        if value.hasPrefix("rgb(") || value.hasPrefix("rgba(") {
            guard value.hasSuffix(")") else { return value }
            let inside = value.dropFirst(value.hasPrefix("rgba(") ? 5 : 4).dropLast()
            let parts = inside.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4, let n = numbers(parts) else { return value }
            return rgba(Array(n.prefix(3)).map { $0 / 255 }, alpha: n.count == 4 ? n[3] : 1)
        }
        let isOKLab = value.hasPrefix("oklab(")
        guard isOKLab || value.hasPrefix("color(srgb "), value.hasSuffix(")") else { return value }
        let inside = value.dropFirst(isOKLab ? 6 : 11).dropLast()
        let components = inside.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2,
              let channels = numbers(components[0].split(whereSeparator: { $0.isWhitespace }).map(String.init)),
              channels.count == 3 else { return value }
        var alpha = 1.0
        if components.count == 2 {
            guard let parsed = numbers([components[1].trimmingCharacters(in: .whitespaces)]) else { return value }
            alpha = parsed[0]
        }
        if !isOKLab { return rgba(channels, alpha: alpha) }

        // OKLab -> LMS cube roots -> linear sRGB -> gamma-encoded sRGB.
        let L = channels[0], a = channels[1], b = channels[2]
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let linear = [
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        ]
        let gamma = linear.map { channel -> Double in
            let x = clamp(channel)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return rgba(gamma, alpha: alpha)
    }

    private static func jsonArrayLiteral(_ strings: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: strings, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
