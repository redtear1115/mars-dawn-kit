import Foundation
import Testing
@testable import MarsDawnKit

/// The default titles of callouts (kit #135) and how they are chosen. In-process: no
/// subprocess, no change to the CLI.
struct CalloutTitlesTests {
    static let zhHant = CalloutTitles(note: "附註", tip: "提示", important: "重要", warning: "警告", caution: "小心")
    static let ja = CalloutTitles(note: "メモ", tip: "ヒント", important: "重要", warning: "警告", caution: "危険")

    @Test func englishIsGitHubsWords() {
        #expect(CalloutTitles.english == CalloutTitles(note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution"))
    }

    @Test func localizedReturnsD2sTitles() {
        #expect(CalloutTitles.localized("zh-Hant") == Self.zhHant)
        #expect(CalloutTitles.localized("ja") == Self.ja)
        #expect(CalloutTitles.localized("ZH-HANT") == Self.zhHant, "the folder is found without regard to case")
        #expect(CalloutTitles.localized("en") == .english)
        #expect(CalloutTitles.localized("it") == .english)
    }

    @Test(arguments: [
        (["en", "zh-Hant"], "english"), (["zh-Hant"], "zh-Hant"), (["ja-JP"], "ja"), (["it"], "english"),
        (["zh-Hant-TW", "en"], "zh-Hant"), (["zh-TW"], "zh-Hant"), (["ja", "zh-Hant"], "ja"), ([], "english"),
    ] as [([String], String)])
    func preferredFollowsTheLanguageList(languages: [String], expected: String) {
        let titles = CalloutTitles.preferred(languages: languages)
        switch expected {
        case "english": #expect(titles == .english, "\(languages)")
        case "zh-Hant": #expect(titles == Self.zhHant, "\(languages)")
        default: #expect(titles == Self.ja, "\(languages)")
        }
    }

    /// The five languages added by kit #183 (Grok's titles, decided by the owner 2026-10-19).
    @Test(arguments: [
        ("zh-Hans", ["附注", "提示", "重要", "警告", "小心"]),
        ("ko", ["참고", "팁", "중요", "경고", "위험"]),
        ("de", ["Hinweis", "Tipp", "Wichtig", "Warnung", "Gefahr"]),
        ("fr", ["Remarque", "Conseil", "Important", "Avertissement", "Danger"]),
        ("es", ["Nota", "Consejo", "Importante", "Advertencia", "Peligro"]),
    ] as [(String, [String])])
    func theNewLanguagesHaveTheirTitles(localization: String, words: [String]) {
        let expected = CalloutTitles(note: words[0], tip: words[1], important: words[2], warning: words[3], caution: words[4])
        #expect(CalloutTitles.localized(localization) == expected)
        #expect(CalloutTitles.preferred(languages: [localization]) == expected)
    }

    @Test func shippedIsTheBundlesOwnList() {
        let bundle = Set(KitStrings.bundle.localizations.map { $0.lowercased() }.filter { $0 != "en" && $0 != "base" })
        #expect(Set(CalloutTitles.shipped.map { $0.lowercased() }) == bundle)
    }

    // MARK: No leak from the process's language

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MarsDawnKit")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    /// The renderer never writes a localized string into the HTML it returns, so what it returns
    /// does not depend on the process's language.
    @Test(arguments: ["Callouts.swift", "MarkdownRenderer.swift"])
    func theRendererNeverAsksForALocalizedString(_ file: String) throws {
        let text = try Self.source(file)
        #expect(text.count > 2000, "positive fixture: read \(file)")
        // The renderer does not touch the titles at all: not the kit's strings, not `CalloutTitles`.
        for needle in ["KitStrings", "String(localized:", "CalloutTitles", "preferredLanguages"] {
            #expect(!text.contains(needle), "\(file) contains \(needle)")
        }
    }

    /// `CalloutTitles` reads the table itself: asking the system to localize a string would answer
    /// in the process's language (the kit has no English table to answer with).
    @Test func calloutTitlesNeverAsksTheSystemToLocalize() throws {
        let text = try Self.source("CalloutTitles.swift")
        #expect(text.contains("Localizable.strings"), "positive fixture: read the right file")
        for needle in ["String(localized:", "NSLocalizedString", "localizedString(forKey"] {
            #expect(!text.contains(needle), "CalloutTitles.swift contains \(needle)")
        }
    }

    // MARK: The page script

    @Test func theUpdateScriptCarriesTheTitlesItIsGiven() {
        let script = PreviewWebView.updateScript(html: "x", calloutTitles: Self.zhHant)
        #expect(script.contains(Self.zhHant.labelsObject))
        for word in ["附註", "提示", "重要", "警告", "小心"] {
            #expect(script.contains(word))
        }
        #expect(!script.contains("\"Note\""), "the English title is not sent alongside")
        let japanese = PreviewWebView.updateScript(html: "x", calloutTitles: Self.ja)
        #expect(japanese.contains("ヒント") && japanese.contains("危険"))
    }

    @Test func withoutTitlesTheUpdateScriptCarriesThePreferredOnes() {
        let script = PreviewWebView.updateScript(html: "x")
        #expect(script.contains(CalloutTitles.preferred().labelsObject))
    }
}
