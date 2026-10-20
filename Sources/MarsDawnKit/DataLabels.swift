import Foundation

/// The words the JSON and YAML tree page (kit #128) draws: one per state it can be in.
///
/// Placeholders in braces are filled by the page with numbers or fixed words, by plain text
/// replacement: `{n}` (a count; a count of one uses `itemCountOne`), `{size}` (megabytes), `{format}` (`JSON` or `YAML`), `{line}` and
/// `{column}`. The English wording is also the key of each string in the kit's string tables, as
/// with `CalloutTitles`, and the tables are read the same way, whatever the process's language.
public struct DataLabels: Sendable, Equatable {
    /// A container's size, e.g. "{n} items".
    public var itemCount: String
    /// A container holding exactly one item, e.g. "1 item".
    public var itemCountOne: String
    /// The button under a list or a long string that shows the next part, e.g. "Show {n} more".
    public var showMore: String
    /// Drawn in place of a value that contains itself (a YAML alias back to an ancestor).
    public var cycle: String
    /// Above a tree whose automatic opening stopped at the row or time budget.
    public var expansionStopped: String
    /// A document too deep, with too many parts or too slow to parse.
    public var tooComplex: String
    /// A file over the size limit, `{size}` in megabytes.
    public var overCap: String
    /// A file that isn't UTF-8.
    public var invalidEncoding: String
    /// A parse error with its position: `{format}`, `{line}`, `{column}`.
    public var parseErrorAt: String
    /// A parse error with no position to give: `{format}`.
    public var parseError: String
    /// The line pointing the reader to the source view, under every state that has no tree.
    public var showSourceGuidance: String
    /// The button that asks the host for the source view.
    public var showSourceButton: String

    public init(
        itemCount: String, itemCountOne: String, showMore: String, cycle: String, expansionStopped: String,
        tooComplex: String, overCap: String, invalidEncoding: String, parseErrorAt: String,
        parseError: String, showSourceGuidance: String, showSourceButton: String
    ) {
        self.itemCount = itemCount
        self.itemCountOne = itemCountOne
        self.showMore = showMore
        self.cycle = cycle
        self.expansionStopped = expansionStopped
        self.tooComplex = tooComplex
        self.overCap = overCap
        self.invalidEncoding = invalidEncoding
        self.parseErrorAt = parseErrorAt
        self.parseError = parseError
        self.showSourceGuidance = showSourceGuidance
        self.showSourceButton = showSourceButton
    }

    /// The English wording (approved, kit #128), which is also each string's key in the kit's tables.
    public static let english = DataLabels(
        itemCount: "{n} items",
        itemCountOne: "1 item",
        showMore: "Show {n} More",
        cycle: "Circular reference",
        expansionStopped: "Part of this file is collapsed to keep the preview responsive. Click a row to expand it.",
        tooComplex: "This file is too deeply nested or too large to show as a tree.",
        overCap: "This file is larger than {size} MB, so it can't be shown as a tree.",
        invalidEncoding: "This file isn't UTF-8 text, so it can't be shown as a tree.",
        parseErrorAt: "This file isn't valid {format} (line {line}, column {column}).",
        parseError: "This file isn't valid {format}.",
        showSourceGuidance: "To read it as text, choose View ▸ Source Only in MarsDawn.",
        showSourceButton: "Show Source Only"
    )

    /// The labels in `localization` (`"zh-Hant"`, `"ja"`, any case), or `english` when the kit does
    /// not ship that language; a label the table lacks stays English.
    public static func localized(_ localization: String) -> DataLabels {
        localized(localization, in: .module)
    }

    /// The labels for the first language in `languages` the kit ships, else English. Defaults to
    /// the process's preferred languages, in order.
    public static func preferred(languages: [String] = Locale.preferredLanguages) -> DataLabels {
        let choice = Bundle.preferredLocalizations(from: CalloutTitles.shipped + ["en"], forPreferences: languages).first ?? "en"
        return localized(choice)
    }

    static func localized(_ localization: String, in bundle: Bundle) -> DataLabels {
        guard localization.caseInsensitiveCompare("en") != .orderedSame,
              let folder = CalloutTitles.resolveLproj(localization, in: bundle),
              let table = NSDictionary(contentsOf: folder.appendingPathComponent("Localizable.strings")) as? [String: String]
        else { return .english }
        let english = DataLabels.english
        func label(_ key: String) -> String { table[key] ?? key }
        return DataLabels(
            itemCount: label(english.itemCount), itemCountOne: label(english.itemCountOne), showMore: label(english.showMore), cycle: label(english.cycle),
            expansionStopped: label(english.expansionStopped), tooComplex: label(english.tooComplex),
            overCap: label(english.overCap), invalidEncoding: label(english.invalidEncoding),
            parseErrorAt: label(english.parseErrorAt), parseError: label(english.parseError),
            showSourceGuidance: label(english.showSourceGuidance), showSourceButton: label(english.showSourceButton)
        )
    }

    /// The page's `labels` argument: each label by the name data.js reads it under.
    var dictionary: [String: String] {
        [
            "itemCount": itemCount, "itemCountOne": itemCountOne, "showMore": showMore, "cycle": cycle,
            "expansionStopped": expansionStopped, "tooComplex": tooComplex, "overCap": overCap,
            "invalidEncoding": invalidEncoding, "parseErrorAt": parseErrorAt, "parseError": parseError,
            "showSourceGuidance": showSourceGuidance, "showSourceButton": showSourceButton,
        ]
    }
}
