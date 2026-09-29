import Foundation
import MarsDawnThemes

/// Checks a `theme.json` the way `ThemeRegistry.loadInstalled` will, before a host installs it
/// (app #293): a host that downloads a theme can refuse it up front and say why, instead of
/// installing a file the next load silently drops.
///
/// Read-only: it takes bytes, returns a value, and touches no file, no registry and no stylesheet.
/// The rules are exactly the ones `loadInstalled` applies to one file's bytes -- the size cap,
/// then `ThemeValidator` (every schema, string, colour, option and contrast rule, with a missing
/// `syntax`/`diagram` group filled from Dawn's as a load does), then the reserved built-in ids.
/// What depends on the rest of the folder or on the host's lists -- the folder name, two folders
/// claiming one id, revocations, the install limit -- isn't known from the bytes and isn't checked.
public enum ThemeValidation {
    /// The largest `theme.json` accepted, in bytes; a larger one is refused unread.
    public static let maxFileBytes = ThemeValidator.maxFileBytes

    /// One reason a theme was refused.
    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        /// A stable id, the same one `marsdawn theme validate` reports: `file.tooLarge`,
        /// `json.malformed`, `schema.version`, `id.pattern`, `color.hex`, `contrast.pair`, …, and
        /// `id.reserved` for a theme whose id is a built-in's. A host shows its own localized text
        /// keyed by this.
        public let rule: String
        /// The JSON path of the field (`light.accent`), or empty for the file as a whole.
        public let path: String
        /// An English sentence, safe to log or print: it only repeats the validator's own wording,
        /// field names and quoted, length-capped text from the file.
        public let message: String

        public var description: String { path.isEmpty ? "\(rule): \(message)" : "\(rule) at \(path): \(message)" }
    }

    /// What `validate(data:)` made of a file.
    public struct Result: Sendable, Hashable {
        /// The theme's id when the file is accepted; `nil` exactly when `issues` is not empty.
        public let themeID: String?
        /// Why the file is refused; empty when it is accepted.
        public let issues: [Issue]

        public var isValid: Bool { themeID != nil }
    }

    /// Validates the raw bytes of a `theme.json`.
    public static func validate(data: Data) -> Result {
        let report = ThemeValidator.validate(data: data)
        guard let theme = report.theme else {
            return Result(themeID: nil, issues: report.issues.map { Issue(rule: $0.rule, path: $0.path, message: $0.message) })
        }
        if ThemeRegistry.reservedIDs.contains(theme.id) {
            return Result(themeID: nil, issues: [Issue(rule: "id.reserved", path: "id",
                                                       message: "`\(theme.id)` is a built-in theme's id; an installed theme needs its own")])
        }
        return Result(themeID: theme.id, issues: [])
    }
}
