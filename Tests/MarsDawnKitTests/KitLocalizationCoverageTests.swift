import Foundation
import Testing
@testable import MarsDawnKit

/// Every string the kit localizes has a translation in every language it ships, with the same
/// format specifiers as the Traditional Chinese one. zh-Hant is the reference because it was the
/// first and is the most reviewed. The keys are read from the source tables, and every lookup goes
/// through the built resource bundle, so a table that exists on disk but doesn't ship still fails.
@MainActor
struct KitLocalizationCoverageTests {
    nonisolated static let reference = "zh-Hant"
    nonisolated static let others = ["zh-Hans", "ja", "de", "fr", "es", "ko"]
    /// Translations that are the English word itself on purpose, so "equals the key" isn't a fallback.
    nonisolated static let sameAsEnglish: [String: Set<String>] = ["de": ["Modern"]]

    nonisolated private static let tables = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MarsDawnKit/Resources/Localization")

    private static func keys(_ localization: String) throws -> [String: String] {
        let url = tables.appendingPathComponent("\(localization).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "no table for \(localization)")
    }

    private static func specifiers(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:@|l{0,2}[dui]|f|s)"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { (text as NSString).substring(with: $0.range).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
            .sorted()
    }

    @Test func theReferenceTableIsTheRealOne() throws {
        let reference = try Self.keys(Self.reference)
        #expect(reference.count >= 11, "positive fixture: zh-Hant has the kit's strings (found \(reference.count))")
        #expect(reference["Dawn"] == "黎明")
    }

    @Test(arguments: others)
    func everyKeyIsTranslated(into localization: String) throws {
        let reference = try Self.keys(Self.reference)
        let table = try Self.keys(localization)
        #expect(Set(table.keys) == Set(reference.keys), "\(localization) keys differ: \(Set(table.keys).symmetricDifference(reference.keys).sorted())")
        for (key, referenceValue) in reference {
            let shipped = try #require(PreviewWebView.moduleLocalizedString(key, localization: localization),
                                       "\(localization) doesn't ship in the resource bundle")
            if !(Self.sameAsEnglish[localization]?.contains(key) ?? false) {
                #expect(shipped != key, "\(localization): \"\(key)\" falls back to English")
            }
            #expect(shipped == table[key], "\(localization): \"\(key)\" ships as \(shipped)")
            #expect(Self.specifiers(shipped) == Self.specifiers(referenceValue), "\(localization): \"\(key)\" format specifiers")
        }
    }
}
