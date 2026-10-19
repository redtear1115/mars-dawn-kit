#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnKit

/// The language folder of a bundle is found whatever the case of its name (kit #135, #35): SwiftPM
/// writes `zh-hant.lproj` under Xcode 26 (what CI uses) and `zh-Hant.lproj` under Xcode 27. Two
/// copied fixture bundles hold D-2's Traditional Chinese titles under each spelling.
struct CalloutFolderCaseTests {
    static let zhHant = CalloutTitles(note: "附註", tip: "提示", important: "重要", warning: "警告", caution: "小心")

    private static func fixture(_ name: String) throws -> Bundle {
        let root = try #require(Bundle.module.url(forResource: "CalloutLproj", withExtension: nil))
        return try #require(Bundle(url: root.appendingPathComponent(name)), "\(name) is a bundle")
    }

    /// The folder is `zh-hant.lproj` in one bundle and `zh-Hant.lproj` in the other; both give D-2's
    /// titles, whichever way the caller spells the language.
    @Test(arguments: ["lowercase", "mixedcase"])
    func theFolderIsFoundWhateverItsCase(_ name: String) throws {
        let bundle = try Self.fixture(name)
        let folder = try #require(bundle.localizations.first, "positive fixture: the bundle holds one localization")
        #expect(folder == (name == "lowercase" ? "zh-hant" : "zh-Hant"), "positive fixture: the folder is spelled as the fixture says")
        for spelling in ["zh-Hant", "zh-hant", "ZH-HANT"] {
            let url = try #require(CalloutTitles.resolveLproj(spelling, in: bundle), "\(name) / \(spelling)")
            #expect(url.lastPathComponent == "\(folder).lproj")
            #expect(CalloutTitles.localized(spelling, in: bundle) == Self.zhHant, "\(name) / \(spelling)")
        }
        #expect(CalloutTitles.resolveLproj("ja", in: bundle) == nil)
        #expect(CalloutTitles.localized("ja", in: bundle) == .english)
    }
}
#endif
