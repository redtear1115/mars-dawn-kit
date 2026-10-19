import Foundation
import Testing
@testable import MarsDawnThemes

/// The callout bars (kit #135, D-1) are composed pairs like any other: a bar in a palette role on
/// the page background, held to 3:1 for every theme, built-in or published.
struct CalloutPairTests {
    static let themes = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MarsDawnThemes/Resources/Themes")

    /// D-1: NOTE=accent, TIP=string, IMPORTANT=function, WARNING=number, CAUTION=keyword.
    static let bars: [(element: String, role: String)] = [
        ("note callout bar", "accent"), ("tip callout bar", "string"), ("important callout bar", "function"),
        ("warning callout bar", "number"), ("caution callout bar", "keyword"),
    ]

    static func data(_ id: String) throws -> Data {
        try Data(contentsOf: themes.appendingPathComponent("\(id)/theme.json"))
    }

    @Test(arguments: ["dawn", "classic", "modern", "vivid"])
    func aBuiltInThemePassesWithTheCalloutPairs(_ id: String) throws {
        let report = ThemeValidator.validate(data: try Self.data(id))
        #expect(report.issues.isEmpty, "\(id): \(report.issues)")
        let theme = try #require(report.theme)
        let table = try #require(ThemePairTable.bundled)
        for (palette, dark) in [(theme.light, false), (theme.dark, true)] {
            let pairs = table.pairs(style: theme.document.style, palette: palette, dark: dark)
            for bar in Self.bars {
                let pair = try #require(pairs.first { $0.element == bar.element }, "\(id) \(dark): no pair for \(bar.element)")
                #expect(pair.fgToken == bar.role && pair.bgToken == "background" && pair.kind == .nontext, "\(bar.element): \(pair)")
                #expect(pair.ratio >= 3, "\(id) \(dark) \(bar.element): \(pair.ratio)")
            }
        }
    }

    /// A theme whose `string` colour is nearly the page colour is rejected: the tip bar, the pie
    /// slice and the code colour all draw it on that background.
    @Test func aLowContrastStringOnTheBackgroundIsRejected() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Self.data("dawn")) as? [String: Any])
        var light = try #require(json["light"] as? [String: Any])
        var syntax = try #require(light["syntax"] as? [String: Any])
        let background = try #require(light["background"] as? String)
        syntax["string"] = background
        light["syntax"] = syntax
        json["light"] = light
        let report = ThemeValidator.validate(data: try JSONSerialization.data(withJSONObject: json))
        #expect(report.theme == nil)
        #expect(Set(report.issues.map(\.rule)) == ["contrast.pair"], "\(report.issues)")
        #expect(report.issues.contains { $0.path == "light.syntax.string" }, "\(report.issues)")
    }

    /// The bars are in the pair table for a theme with no `style` at all, which is what a
    /// published theme usually is.
    @Test func theBarsAreSharedPairs() throws {
        let table = try #require(ThemePairTable.bundled)
        let elements = Set(table.shared.map(\.element))
        for bar in Self.bars { #expect(elements.contains(bar.element), "\(bar.element)") }
    }
}
