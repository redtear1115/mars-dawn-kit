import Foundation
import Testing
@testable import MarsDawnKit
@testable import MarsDawnThemes

/// kit #124: `ThemeCSSGenerator`'s output for the four built-ins, checked against the fixture
/// extracted from the removed 0.5.4 rules (`ThemeGoldenTests.swift`'s
/// `OriginalPerThemeSelectorFixtureTests`) and against the design's own constraints (§4.3: every
/// colour is a palette `var(--…)`, never a literal or a `url(`).
struct ThemeGeneratedCSSTests {
    /// Every generated rule's selector, scoped, split the same way the fixture-extractor splits a
    /// comma list (kit #124 plan item 4: "the list of generated selectors equals the list of
    /// selectors in the removed 0.5.4 blocks"). Root variable blocks (`:root[data-theme="…"]`)
    /// are real rules too, and the fixture's extractor counts them the same way, so they're
    /// included here for a like-for-like comparison.
    static var generatedSelectors: Set<String> {
        var all = Set<String>()
        for theme in PreviewTheme.all {
            let css = ThemeCSSGenerator.generate(id: theme.id, style: theme.style).css
            all.formUnion(CSSSelectorExtractor.selectors(in: css))
        }
        return all
    }

    @Test func generatedSelectorsMatchTheOriginalBlocks() throws {
        let originalURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("ThemeGolden/original-per-theme-rules.css")
        let original = CSSSelectorExtractor.selectors(in: try String(contentsOf: originalURL, encoding: .utf8))
        let generated = Self.generatedSelectors

        let missing = original.subtracting(generated)
        let extra = generated.subtracting(original)
        #expect(missing.isEmpty, "generator dropped selectors: \(missing.sorted())")
        #expect(extra.isEmpty, "generator added selectors the original didn't have: \(extra.sorted())")
    }

    @Test func generatedCSSHasNoLiteralColoursOrURLs() {
        for theme in PreviewTheme.all {
            let css = ThemeCSSGenerator.generate(id: theme.id, style: theme.style).css
            #expect(css.range(of: #"#[0-9A-Fa-f]{3,8}\b"#, options: .regularExpression) == nil, "\(theme.id): literal colour in generated CSS")
            #expect(!css.contains("url("), "\(theme.id): url() in generated CSS")
        }
    }

    /// Positive fixture: every theme that declares style options actually produced some CSS
    /// (Dawn's single `hr` option included), so an empty selector set above couldn't hide behind
    /// "nothing to compare".
    @Test func everyBuiltInWithStyleProducesRules() {
        for theme in PreviewTheme.all {
            let output = ThemeCSSGenerator.generate(id: theme.id, style: theme.style)
            #expect(!output.selectors.isEmpty, "\(theme.id) produced no rules")
        }
    }

    /// Every option value in the vocabulary (design §4.3) renders to at least one declaration,
    /// whether or not a built-in happens to use it -- catches a missing `ThemeStyles.json` entry
    /// that a built-in-only check couldn't see.
    @Test func everyOptionValueRenders() {
        let role = PaletteRole.accent
        let samples: [ThemeStyle] = [
            ThemeStyle(h1: .init(decoration: ThemeStyle.H1Decoration.none)),
            ThemeStyle(h1: .init(decoration: .shortRule(color: role))),
            ThemeStyle(h1: .init(decoration: .gradientBar(from: role, to: .heading))),
            ThemeStyle(h2: .init(decoration: ThemeStyle.H2Decoration.none)),
            ThemeStyle(h2: .init(decoration: .dot(color: role))),
            ThemeStyle(blockquote: .init(style: .bar(width: 2))),
            ThemeStyle(blockquote: .init(style: .panel)),
            ThemeStyle(hr: .init(style: .line(color: role, thickness: 2))),
            ThemeStyle(hr: .init(style: .shortCentered(color: role))),
            ThemeStyle(hr: .init(style: .gradient(colors: [role, .heading, .link]))),
            ThemeStyle(table: .init(header: .surface)),
            ThemeStyle(table: .init(header: .accentRule(color: role))),
            ThemeStyle(table: .init(header: .filled(background: .heading, text: .background, border: nil))),
        ]
        for style in samples {
            let output = ThemeCSSGenerator.generate(id: "probe", style: style)
            #expect(!output.css.isEmpty, "no CSS for \(style)")
        }
    }

    /// kit #124 review note: Vivid's `filled` table header also sets `border-color`, defaulting to
    /// the same role as `background` when the theme doesn't name one.
    @Test func filledTableHeaderDefaultsBorderToBackground() {
        let style = ThemeStyle(table: .init(header: .filled(background: .heading, text: .background, border: nil)))
        let css = ThemeCSSGenerator.generate(id: "probe", style: style).css
        #expect(css.contains("border-color: var(--heading);"))
    }

    /// kit #124 review note: `syntax.boldKeywords` also bolds `.hljs-title`.
    @Test func boldKeywordsAlsoBoldsHljsTitle() {
        let style = ThemeStyle(syntax: .init(boldKeywords: true))
        let css = ThemeCSSGenerator.generate(id: "probe", style: style).css
        #expect(css.contains(#"[data-theme="probe"] .hljs-keyword { font-weight: 650; }"#))
        #expect(css.contains(#"[data-theme="probe"] .hljs-title { font-weight: 650; }"#))
    }

    /// kit #124 review note: Classic's `shortCentered` hr carries `margin: 2.4em auto`.
    @Test func shortCenteredHrCarriesItsOwnMargin() {
        let style = ThemeStyle(hr: .init(style: .shortCentered(color: .accent)))
        let css = ThemeCSSGenerator.generate(id: "probe", style: style).css
        #expect(css.contains("margin: 2.4em auto;"))
    }
}
