import Foundation

/// A palette colour a style option can paint with. Never a literal colour: every style option
/// value in a `theme.json` names one of these, and the generator resolves it to the matching
/// `var(--…)` custom property (design §4.3 -- "Colours inside those fragments are always palette
/// roles ... never literal colours, so the contrast check stays closed over the palette").
package enum PaletteRole: String, Codable, CaseIterable, Sendable {
    case background, surface, text, muted, border, heading, accent, link, quote
    case keyword, string, comment, number, function, type

    /// The CSS custom property this role reads, matching `PreviewTheme`'s existing `--bg`/`--fg`
    /// naming (`Resources/Preview/preview.css`, `PreviewTheme.variables`).
    var cssVariable: String {
        switch self {
        case .background: "bg"
        case .surface: "surface"
        case .text: "fg"
        case .muted: "muted"
        case .border: "border"
        case .heading: "heading"
        case .accent: "accent"
        case .link: "link"
        case .quote: "quote"
        case .keyword: "hl-keyword"
        case .string: "hl-string"
        case .comment: "hl-comment"
        case .number: "hl-number"
        case .function: "hl-function"
        case .type: "hl-type"
        }
    }

    /// The resolved CSS value: always a `var(--…)` reference, never a literal colour.
    package var cssValue: String { "var(--\(cssVariable))" }
}
