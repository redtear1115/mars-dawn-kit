import Foundation

/// The words the JSON and YAML tree page (kit #128) draws: one per state it can be in.
///
/// Placeholders in braces are filled by the page with numbers or fixed words, by plain text
/// replacement: `{n}` (a count), `{size}` (megabytes), `{format}` (`JSON` or `YAML`), `{line}` and
/// `{column}`. The English wording is also the key of each string in the kit's string tables, as
/// with `CalloutTitles`, and the tables are read the same way, whatever the process's language.
public struct DataLabels: Sendable, Equatable {
    /// A container's size, e.g. "{n} items".
    public var itemCount: String
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
        itemCount: String, showMore: String, cycle: String, expansionStopped: String,
        tooComplex: String, overCap: String, invalidEncoding: String, parseErrorAt: String,
        parseError: String, showSourceGuidance: String, showSourceButton: String
    ) {
        self.itemCount = itemCount
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

    /// The English wording, which is also each string's key in the kit's tables.
    ///
    /// Working wording for kit #128 (needs-copy): the approved copy replaces it, and every other
    /// language's table holds a marked placeholder until then (KitLocalizationCoverageTests fails
    /// while one is left).
    public static let english = DataLabels(
        itemCount: "{n} items",
        showMore: "Show {n} more",
        cycle: "Cycle",
        expansionStopped: "Showing part of this document. The rest is collapsed: click a row to open it.",
        tooComplex: "This document is too complex to show as a tree.",
        overCap: "This document is larger than {size} MB, too large to show as a tree.",
        invalidEncoding: "This document is not valid UTF-8 text.",
        parseErrorAt: "Not valid {format} at line {line}, column {column}.",
        parseError: "Not valid {format}.",
        showSourceGuidance: "Open the source view to read the document as text.",
        showSourceButton: "Show Source"
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
            itemCount: label(english.itemCount), showMore: label(english.showMore), cycle: label(english.cycle),
            expansionStopped: label(english.expansionStopped), tooComplex: label(english.tooComplex),
            overCap: label(english.overCap), invalidEncoding: label(english.invalidEncoding),
            parseErrorAt: label(english.parseErrorAt), parseError: label(english.parseError),
            showSourceGuidance: label(english.showSourceGuidance), showSourceButton: label(english.showSourceButton)
        )
    }

    /// The page's `labels` argument: each label by the name data.js reads it under.
    var dictionary: [String: String] {
        [
            "itemCount": itemCount, "showMore": showMore, "cycle": cycle,
            "expansionStopped": expansionStopped, "tooComplex": tooComplex, "overCap": overCap,
            "invalidEncoding": invalidEncoding, "parseErrorAt": parseErrorAt, "parseError": parseError,
            "showSourceGuidance": showSourceGuidance, "showSourceButton": showSourceButton,
        ]
    }
}
