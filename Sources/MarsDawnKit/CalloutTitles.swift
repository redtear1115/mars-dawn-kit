import Foundation

/// The default titles of the five callouts (#135): what `> [!NOTE]` and `:::info` are headed with
/// when the author gives none.
///
/// The preview page draws them as generated content, from five custom properties that
/// `PreviewWebView.updateScript` sets, so the HTML `MarkdownRenderer` writes never holds one and
/// never depends on the language of the process that rendered it.
public struct CalloutTitles: Sendable, Equatable {
    public var note: String
    public var tip: String
    public var important: String
    public var warning: String
    public var caution: String

    public init(note: String, tip: String, important: String, warning: String, caution: String) {
        self.note = note
        self.tip = tip
        self.important = important
        self.warning = warning
        self.caution = caution
    }

    /// GitHub's own words. They are also the keys of the kit's string tables.
    public static let english = CalloutTitles(
        note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution"
    )

    /// The titles in `localization` (`"zh-Hant"`, `"ja"`, any case), or `english` when the kit does
    /// not ship that language, or has no translation of a title.
    ///
    /// This reads the kit's own `Localizable.strings` for that language, whatever the language of
    /// the process: an `.lproj` folder is found by name, without regard to case, and its table is
    /// read as a property list. Nothing here asks the system to localize a string, so the
    /// process's language cannot leak in (the kit has no English table: the keys are the English).
    public static func localized(_ localization: String) -> CalloutTitles {
        localized(localization, in: .module)
    }

    /// The titles for the first language in `languages` the kit ships, else English. Defaults to
    /// the process's preferred languages, in order.
    public static func preferred(languages: [String] = Locale.preferredLanguages) -> CalloutTitles {
        let choice = Bundle.preferredLocalizations(from: shipped + ["en"], forPreferences: languages).first ?? "en"
        return localized(choice)
    }

    /// The languages the kit ships a table for. A test holds this to the bundle's own list, so a
    /// language added without being listed here fails.
    static let shipped = ["de", "es", "fr", "ja", "ko", "zh-Hans", "zh-Hant"]

    static func localized(_ localization: String, in bundle: Bundle) -> CalloutTitles {
        guard localization.caseInsensitiveCompare("en") != .orderedSame,
              let folder = resolveLproj(localization, in: bundle),
              let table = NSDictionary(contentsOf: folder.appendingPathComponent("Localizable.strings")) as? [String: String]
        else { return .english }
        func title(_ key: String) -> String { table[key] ?? key }
        return CalloutTitles(
            note: title("Note"), tip: title("Tip"), important: title("Important"),
            warning: title("Warning"), caution: title("Caution")
        )
    }

    /// The `.lproj` folder of `bundle` for `localization`, matched without regard to case: SwiftPM
    /// under Xcode 26 writes `zh-hant.lproj`, under Xcode 27 `zh-Hant.lproj` (kit #35). The
    /// caller's spelling is never handed to a lookup, only the bundle's own.
    static func resolveLproj(_ localization: String, in bundle: Bundle) -> URL? {
        guard let name = bundle.localizations.first(where: { $0.caseInsensitiveCompare(localization) == .orderedSame })
        else { return nil }
        return bundle.url(forResource: name, withExtension: "lproj")
    }

    /// The `calloutTitles` argument of the page's `setLabels`: the five titles as a JSON object.
    var labelsObject: String {
        let pairs = [("note", note), ("tip", tip), ("important", important), ("warning", warning), ("caution", caution)]
        return "{ " + pairs.map { "\($0.0): \(PreviewWebView.jsonStringLiteral($0.1))" }.joined(separator: ", ") + " }"
    }
}
