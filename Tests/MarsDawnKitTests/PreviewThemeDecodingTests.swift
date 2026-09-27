import Foundation
import Testing
@testable import MarsDawnKit
@testable import MarsDawnThemes

/// kit #124: built-in themes are decoded from bundled `theme.json` files, not hard-coded Swift
/// literals, and `ThemeDocument` rejects any `theme.json` shape it doesn't recognise (design §4.2:
/// "Unknown keys are rejected, at every level").
struct PreviewThemeDecodingTests {
    @Test func everyBuiltInDecodesFromItsBundledFile() throws {
        for id in ["dawn", "classic", "modern", "vivid"] {
            let document = try ThemeDocumentLoader.loadBuiltIn(id: id)
            #expect(document.id == id)
            #expect(document.schemaVersion == 1)
            #expect(!document.scenarios.isEmpty)
            #expect(document.name.en.isEmpty == false)
        }
    }

    /// The decoded palette actually reached `PreviewTheme` -- not just that the file parses.
    @Test func decodedPalettesMatchPreviewTheme() throws {
        for (id, theme) in [("dawn", PreviewTheme.dawn), ("classic", PreviewTheme.classic), ("modern", PreviewTheme.modern), ("vivid", PreviewTheme.vivid)] {
            let document = try ThemeDocumentLoader.loadBuiltIn(id: id)
            #expect(theme.light.background == document.light.background)
            #expect(theme.dark.accent == document.dark.accent)
            #expect(theme.light.syntax.keyword == document.light.syntax?.keyword)
        }
    }

    /// The compiled-in Dawn fallback (kit 0.5.4's Swift constants, kept for when the bundle can't
    /// be read) can't silently drift from what `dawn/theme.json` actually decodes to.
    @Test func compiledInDawnEqualsDecodedDawn() throws {
        let document = try ThemeDocumentLoader.loadBuiltIn(id: "dawn")
        let decoded = PreviewTheme(document: document, name: PreviewTheme.compiledDawn.name, summary: PreviewTheme.compiledDawn.summary)
        #expect(decoded.light == PreviewTheme.compiledDawn.light)
        #expect(decoded.dark == PreviewTheme.compiledDawn.dark)
        #expect(decoded.fontDesign == PreviewTheme.compiledDawn.fontDesign)
        #expect(decoded.style == PreviewTheme.compiledDawn.style)
    }

    // MARK: - Strict decoding (design §4.2: unknown keys rejected at every level)

    private func decode(_ json: String) throws -> ThemeDocument {
        try JSONDecoder().decode(ThemeDocument.self, from: Data(json.utf8))
    }

    private static let validMinimal = """
    {
      "schemaVersion": 1, "id": "probe", "version": "1.0.0",
      "name": { "en": "Probe" }, "summary": { "en": "A probe theme" },
      "fontDesign": "sans", "scenarios": ["agent-review"],
      "light": { "background": "#FFFFFF", "surface": "#EEEEEE", "text": "#000000", "muted": "#666666",
                 "border": "#CCCCCC", "heading": "#000000", "accent": "#FF0000", "link": "#0000FF", "quote": "#999999" },
      "dark": { "background": "#000000", "surface": "#111111", "text": "#FFFFFF", "muted": "#999999",
                "border": "#333333", "heading": "#FFFFFF", "accent": "#FF6666", "link": "#6666FF", "quote": "#666666" }
    }
    """

    @Test func validMinimalThemeDecodes() throws {
        let document = try decode(Self.validMinimal)
        #expect(document.id == "probe")
        #expect(document.style == nil)
    }

    @Test func unknownKeyAtTopLevelIsRejected() {
        let json = Self.validMinimal.replacingOccurrences(of: "\"schemaVersion\": 1,", with: "\"schemaVersion\": 1, \"bogus\": true,")
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test func unknownKeyInPaletteIsRejected() {
        let json = Self.validMinimal.replacingOccurrences(
            of: "\"background\": \"#FFFFFF\",", with: "\"background\": \"#FFFFFF\", \"bogus\": \"#FFFFFF\","
        )
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test func unknownKeyInStyleIsRejected() {
        let json = Self.validMinimal.replacingOccurrences(
            of: "\"quote\": \"#999999\" }", with: "\"quote\": \"#999999\" }, \"style\": { \"bogus\": 1 }"
        )
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test func unknownKeyInNestedOptionIsRejected() {
        let json = Self.validMinimal.replacingOccurrences(
            of: "\"quote\": \"#999999\" }", with: "\"quote\": \"#999999\" }, \"style\": { \"h1\": { \"bogus\": 1 } }"
        )
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test func missingRequiredEnglishNameIsRejected() {
        let json = Self.validMinimal.replacingOccurrences(of: "{ \"en\": \"Probe\" }", with: "{ \"zh-Hant\": \"探針\" }")
        #expect(throws: (any Error).self) { try decode(json) }
    }
}
