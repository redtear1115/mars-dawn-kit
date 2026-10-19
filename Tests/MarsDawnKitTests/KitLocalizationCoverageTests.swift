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
    nonisolated static let sameAsEnglish: [String: Set<String>] = ["de": ["Modern"], "fr": ["Important"]]
    /// Keys allowed to be missing from a language, per language. A pending entry FAILS once its
    /// translation lands: delete it from here then. The callout titles of kit #135 landed in all
    /// seven with kit #183. The JSON and YAML page's labels (kit #128) are approved in zh-Hant and
    /// ja; these five languages get them through needs-i18n, gated before the 0.7.2 tag.
    nonisolated static let pendingDataLabelKeys: Set<String> = Set(DataLabels.english.dictionary.values)
    nonisolated static let pendingLocalizations = ["de", "es", "fr", "ko", "zh-Hans"]
    nonisolated static let pending: [String: Set<String>] = Dictionary(
        uniqueKeysWithValues: pendingLocalizations.map { ($0, pendingDataLabelKeys) }
    )

    @Test func thePendingSetIsExactlyFiveLanguagesTimesTheTwelveLabels() {
        #expect(Self.pendingDataLabelKeys.count == 12)
        #expect(Set(Self.pending.keys) == ["de", "es", "fr", "ko", "zh-Hans"])
        #expect(Set(Self.others + [Self.reference]).subtracting(Self.pending.keys) == ["zh-Hant", "ja"])
    }

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
        #expect(reference.count >= 16, "positive fixture: zh-Hant has the kit's strings (found \(reference.count))")
        #expect(reference["Dawn"] == "黎明")
    }

    /// The JSON and YAML page's labels (kit #128) were written into every table as marked
    /// placeholders while their copy waits for approval (needs-copy). This fails, naming each one,
    /// until every placeholder is replaced by the approved translation.
    nonisolated static let placeholderMarker = "NEEDS-COPY"

    @Test(arguments: [reference] + others)
    func noPlaceholderCopyIsLeft(in localization: String) throws {
        let table = try Self.keys(localization)
        let placeholders = table.filter { $0.value.contains(Self.placeholderMarker) }.keys.sorted()
        #expect(placeholders.isEmpty, "\(localization): \(placeholders.count) placeholder(s) awaiting copy (kit #128): \(placeholders)")
    }

    @Test(arguments: others)
    func everyKeyIsTranslated(into localization: String) throws {
        let reference = try Self.keys(Self.reference)
        let table = try Self.keys(localization)
        let pending = Self.pending[localization] ?? []
        for key in pending {
            #expect(reference[key] != nil, "\(localization): \"\(key)\" is pending but the reference table has no such key")
            #expect(table[key] == nil, "\(localization): \"\(key)\" now has a translation: remove it from `pending`")
        }
        let expected = Set(reference.keys).subtracting(pending)
        #expect(Set(table.keys) == expected, "\(localization) keys differ: \(Set(table.keys).symmetricDifference(expected).sorted())")
        for (key, referenceValue) in reference {
            let shipped = try #require(PreviewWebView.moduleLocalizedString(key, localization: localization),
                                       "\(localization) doesn't ship in the resource bundle")
            if pending.contains(key) {
                #expect(shipped == key, "\(localization): pending \"\(key)\" ships as \(shipped)")
                continue
            }
            if !(Self.sameAsEnglish[localization]?.contains(key) ?? false) {
                #expect(shipped != key, "\(localization): \"\(key)\" falls back to English")
            }
            #expect(shipped == table[key], "\(localization): \"\(key)\" ships as \(shipped)")
            #expect(Self.specifiers(shipped) == Self.specifiers(referenceValue), "\(localization): \"\(key)\" format specifiers")
        }
    }
}
