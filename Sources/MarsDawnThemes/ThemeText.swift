import Foundation

/// Rules for the display strings a theme carries -- `name`, `summary`, `author.name` (kit #125,
/// security review L1). They are shown in the app's gallery and settings, never placed in CSS.
///
/// A string is first normalised to NFC; the checks and the stored value both use that form, so
/// two spellings of the same text can't pass with different lengths. Limits count Unicode scalars
/// (not bytes, not grapheme clusters, which a combining-mark run collapses into one).
package enum ThemeDisplayText {
    package enum Problem: String, CaseIterable, Sendable {
        /// Empty, or nothing but whitespace.
        case empty = "text.empty"
        /// More scalars than the field allows.
        case length = "text.length"
        /// A C0/C1 control (Cc), a line or paragraph separator (Zl, Zp).
        case control = "text.control"
        /// A bidirectional control: U+202A–202E, U+2066–2069, U+200E, U+200F, U+061C.
        case bidi = "text.bidi"
        /// An invisible format character: U+FEFF, U+200B, U+2060.
        case invisible = "text.invisible"
        /// More than `maxCombiningRun` combining marks on one base ("Zalgo" text).
        case combining = "text.combining"
        /// Looks like a link: contains `://` or `www.`.
        case url = "text.url"

        package var summary: String {
            switch self {
            case .empty: "is empty"
            case .length: "is too long"
            case .control: "contains a control character or a line break"
            case .bidi: "contains a bidirectional control character"
            case .invisible: "contains an invisible format character"
            case .combining: "stacks too many combining marks on one character"
            case .url: "contains a link"
            }
        }
    }

    /// Scalar limits per field.
    package static let nameLimit = 48
    package static let summaryLimit = 120
    package static let authorNameLimit = 64
    /// Enough for every script's legitimate stacking (Vietnamese, Thai, Devanagari use up to 2–3).
    package static let maxCombiningRun = 3

    private static let bidiControls: Set<UInt32> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C,
    ]
    private static let invisibles: Set<UInt32> = [0xFEFF, 0x200B, 0x2060]

    /// The NFC form of `text` and every rule it breaks (each rule at most once, in
    /// `Problem.allCases` order). An empty list means the string is fine as a display string.
    package static func check(_ text: String, limit: Int) -> (normalized: String, problems: [Problem]) {
        let normalized = text.precomposedStringWithCanonicalMapping
        var found = Set<Problem>()
        let scalars = normalized.unicodeScalars
        if scalars.allSatisfy({ $0.properties.isWhitespace }) { found.insert(.empty) }
        if scalars.count > limit { found.insert(.length) }
        var combiningRun = 0
        for scalar in scalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: found.insert(.control)
            default: break
            }
            if bidiControls.contains(scalar.value) { found.insert(.bidi) }
            if invisibles.contains(scalar.value) { found.insert(.invisible) }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                combiningRun += 1
                if combiningRun > maxCombiningRun { found.insert(.combining) }
            default:
                combiningRun = 0
            }
        }
        let lowered = normalized.lowercased()
        if lowered.contains("://") || lowered.contains("www.") { found.insert(.url) }
        return (normalized, Problem.allCases.filter(found.contains))
    }
}

/// Makes text that came from a theme file safe to repeat in a validation message (kit #125,
/// security review M4): messages are printed to terminals and pasted into CI comments, so
/// attacker-chosen text must not carry escape sequences, mentions, links or Markdown.
///
/// Only ASCII letters, digits, space and `_ . , - # % + =` pass through as themselves; every other
/// scalar (controls, ESC, BEL, `@`, brackets, backticks, `:`, non-ASCII) is written as `\u{…}`,
/// and at most `cap` scalars of the input are shown.
package enum ThemeMessageText {
    package static let cap = 64

    package static func quote(_ text: String) -> String {
        var out = ""
        var shown = 0
        for scalar in text.unicodeScalars {
            if shown == cap {
                out += "...(\(text.unicodeScalars.count - cap) more)"
                break
            }
            shown += 1
            if isPlain(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }
        return out
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        case 0x20, 0x5F, 0x2E, 0x2C, 0x2D, 0x23, 0x25, 0x2B, 0x3D: true
        default: false
        }
    }
}
