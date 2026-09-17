import Foundation
import Testing
@testable import MarsDawnKit

struct PreviewThemeTests {
    private static let cases: [(PreviewTheme, Bool)] = PreviewTheme.all.flatMap { [($0, false), ($0, true)] }

    @Test func themeIDsAreUniqueAndLookupFallsBack() {
        let ids = PreviewTheme.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(PreviewTheme.named("classic").id == "classic")
        #expect(PreviewTheme.named("nope").id == PreviewTheme.defaultID)
        #expect(PreviewTheme.named(nil).id == PreviewTheme.defaultID)
    }

    @Test func stylesheetDefinesEveryThemeForBothSchemes() {
        let css = PreviewTheme.stylesheet
        for theme in PreviewTheme.all {
            #expect(css.components(separatedBy: #":root[data-theme="\#(theme.id)"]"#).count == 3)
        }
        #expect(css.contains("prefers-color-scheme: dark"))
        #expect(css.contains("--mm-node"))
    }

    @Test(arguments: cases)
    func paletteColoursAreHex(theme: PreviewTheme, dark: Bool) {
        for color in allColors(theme.palette(dark: dark)) {
            #expect(color.range(of: #"^#[0-9A-F]{6}$"#, options: .regularExpression) != nil, "\(theme.id) \(color)")
        }
    }

    @Test(arguments: cases)
    func textIsReadable(theme: PreviewTheme, dark: Bool) {
        let p = theme.palette(dark: dark)
        let label = "\(theme.id) \(dark ? "dark" : "light")"
        // WCAG AA: 4.5 for body text; code tokens sit on the surface colour.
        #expect(contrast(p.text, p.background) >= 7, "\(label) body")
        #expect(contrast(p.heading, p.background) >= 4.5, "\(label) heading")
        #expect(contrast(p.link, p.background) >= 4.5, "\(label) link")
        #expect(contrast(p.muted, p.background) >= 4.5, "\(label) muted")
        for token in [p.syntax.keyword, p.syntax.string, p.syntax.number, p.syntax.function, p.syntax.type] {
            #expect(contrast(token, p.surface) >= 4.5, "\(label) token \(token)")
        }
        #expect(contrast(p.syntax.comment, p.surface) >= 3, "\(label) comment")
        #expect(contrast(p.diagram.text, p.diagram.node) >= 7, "\(label) diagram text")
        #expect(contrast(p.diagram.text, p.diagram.note) >= 7, "\(label) diagram note")
    }

    @Test func pageURLCarriesTheme() {
        let url = PreviewSchemeHandler.pageURL(theme: .vivid)
        #expect(url.absoluteString == "marsdawn-app://preview/index.html?theme=vivid")
        #expect(PreviewWebView.themeScript(.classic) == #"window.MarsDawn && MarsDawn.setTheme("classic");"#)
    }

    // MARK: Helpers

    private func allColors(_ p: PreviewTheme.Palette) -> [String] {
        [p.background, p.surface, p.text, p.muted, p.border, p.heading, p.accent, p.link, p.quote,
         p.syntax.keyword, p.syntax.string, p.syntax.comment, p.syntax.number, p.syntax.function, p.syntax.type,
         p.diagram.node, p.diagram.nodeBorder, p.diagram.text, p.diagram.line, p.diagram.secondary,
         p.diagram.tertiary, p.diagram.note]
    }

    private func luminance(_ hex: String) -> Double {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

extension PreviewTheme: CustomTestStringConvertible {
    public var testDescription: String { id }
}
