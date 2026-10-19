import Foundation
import Testing
@testable import MarsDawnKit

/// D11 (kit #128), the Swift side: `DataLabels` reads the kit's own tables, whatever the
/// process's language, and en / zh-Hant / ja are the owner-approved copy (kit #128
/// issuecomment-6261371894; `DataLabelsApprovedCopy` is generated from it). de, es, fr, ko and
/// zh-Hans are pending (KitLocalizationCoverageTests) and show English until they land.
struct DataLabelsTests {
    static let tables = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MarsDawnKit/Resources/Localization")

    static func table(_ localization: String) throws -> [String: String] {
        try #require(NSDictionary(contentsOf: tables.appendingPathComponent("\(localization).lproj/Localizable.strings")) as? [String: String])
    }

    static func values(_ labels: DataLabels) -> [String] {
        [labels.itemCount, labels.itemCountOne, labels.showMore, labels.cycle, labels.expansionStopped, labels.tooComplex, labels.overCap,
         labels.invalidEncoding, labels.parseErrorAt, labels.parseError, labels.showSourceGuidance, labels.showSourceButton]
    }

    @Test func everyLabelHasADistinctNameAndEnglishKey() {
        let dictionary = DataLabels.english.dictionary
        #expect(dictionary.count == 12)
        #expect(Set(dictionary.values) == Set(Self.values(.english)))
        #expect(Set(Self.values(.english)).count == 12)
        #expect(dictionary.keys.sorted() == DataLabelsApprovedCopy.names.sorted())
    }

    @Test(arguments: ["en", "zh-Hant", "ja"])
    func theApprovedCopyIsWhatShips(localization: String) {
        let labels = localization == "en" ? DataLabels.english : DataLabels.localized(localization)
        let approved = localization == "en" ? DataLabelsApprovedCopy.english
            : localization == "ja" ? DataLabelsApprovedCopy.ja : DataLabelsApprovedCopy.zhHant
        #expect(approved.count == 12)
        for name in DataLabelsApprovedCopy.names {
            #expect(labels.dictionary[name] == approved[name], "\(localization).\(name): \(String(describing: labels.dictionary[name])) is not the approved \(String(describing: approved[name]))")
        }
    }

    @Test(arguments: ["de", "es", "fr", "ko", "zh-Hans"])
    func thePendingLanguagesShowEnglish(localization: String) {
        #expect(DataLabels.localized(localization) == .english)
    }

    @Test(arguments: ["zh-Hant", "ja"])
    func localizedReadsEachLabelFromThatTable(localization: String) throws {
        let table = try Self.table(localization)
        let labels = DataLabels.localized(localization)
        for (english, shown) in zip(Self.values(.english), Self.values(labels)) {
            let entry = try #require(table[english], "\(localization) has no entry for \"\(english)\"")
            #expect(shown == entry, "\(localization): \"\(english)\" shows \(shown)")
        }
        // Any case of the language name finds the same table (zh-hant under Xcode 26).
        #expect(DataLabels.localized(localization.lowercased()) == labels)
    }

    @Test func englishAndUnshippedLanguagesGetTheEnglishLabels() {
        #expect(DataLabels.localized("en") == .english)
        #expect(DataLabels.localized("it") == .english)
        #expect(DataLabels.preferred(languages: ["it", "en"]) == .english)
        #expect(DataLabels.preferred(languages: ["en", "zh-Hant"]) == .english)
        #expect(DataLabels.preferred(languages: ["zh-Hant"]) == .localized("zh-Hant"))
        #expect(DataLabels.preferred(languages: ["ja-JP"]) == .localized("ja"))
        #expect(DataLabels.preferred(languages: ["zh-Hant-TW", "en"]) == .localized("zh-Hant"))
        #expect(DataLabels.localized("zh-Hant") != .english, "positive: the zh-Hant table is read")
    }

    /// Placeholders keep their braces in every table, so the page can fill them.
    @Test(arguments: CalloutTitles.shipped)
    func everyTableKeepsThePlaceholders(localization: String) {
        let labels = DataLabels.localized(localization)
        for (english, shown) in zip(Self.values(.english), Self.values(labels)) {
            let wanted = english.matches(of: /\{[a-z]+\}/).map { String($0.output) }.sorted()
            let got = shown.matches(of: /\{[a-z]+\}/).map { String($0.output) }.sorted()
            #expect(got == wanted, "\(localization): \"\(english)\" has \(got)")
        }
    }

    @Test func theSourceNeverAsksTheSystemToLocalize() throws {
        let source = try String(contentsOf: Self.tables.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DataLabels.swift"), encoding: .utf8)
        for call in ["String(localized:", "NSLocalizedString", "localizedString(forKey"] {
            #expect(!source.contains(call))
        }
    }
}
