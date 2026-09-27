import Foundation

/// Turns validated themes into the CSS a preview page needs (kit #124, hardened in #125):
///
/// - the palette block: `:root[data-theme="<id>"] { --bg: …; … }` plus its dark-mode twin, served
///   as `themes.css`;
/// - the per-theme style rules: `:root[data-theme="<id>"]` custom-property overrides and
///   `[data-theme="<id>"] <selector>` rules, spliced into `preview.css`.
///
/// Every colour a style rule emits is a palette `var(--…)`; every selector is one of the fixed
/// selectors the four built-ins' hand-written 0.5.4 rules used, so the cascade -- and the exact
/// specificity of every replaced rule -- is preserved.
///
/// **Only a `ValidatedTheme` gets in** (security review H1): the package API takes nothing else,
/// and a `ValidatedTheme` can only come from `ThemeValidator`. The generator still re-checks what
/// it writes (M1, L3): every id against `ThemeGrammar.isThemeID`, every colour against
/// `ThemeGrammar.isHexColor`, every number against its option's range and step, and no unresolved
/// `{{placeholder}}`. A value that fails refuses the whole theme -- nothing of it is emitted.
package enum ThemeCSSGenerator {
    /// One property/value pair a fragment or a scalar option contributes to a selector.
    struct Declaration { let property: String; let value: String }

    /// Why the generator refused a theme. Carries no attacker text: the field named is the
    /// generator's own label for it, and `duplicateID` only ever holds an id that passed the
    /// validator.
    package enum Refusal: Error, Equatable, CustomStringConvertible {
        case invalidID
        case invalidColor(field: String)
        case invalidNumber(field: String)
        case unresolvedPlaceholder
        case duplicateID(String)

        package var description: String {
            switch self {
            case .invalidID: "the theme id is not a valid id"
            case .invalidColor(let field): "\(field) is not a #RRGGBB colour"
            case .invalidNumber(let field): "\(field) is outside its range or step"
            case .unresolvedPlaceholder: "a style fragment has an unresolved placeholder"
            case .duplicateID(let id): "two themes share the id \(id)"
            }
        }
    }

    /// The per-theme rules for one theme, and every selector a rule was emitted for (before
    /// scoping), for tests that only need to check which elements are touched.
    package struct Output {
        package let css: String
        package let selectors: [String]
    }

    /// The whole theme CSS for a set of themes: `variables` is `themes.css`, `rules` is what gets
    /// spliced into `preview.css`. Refuses a list in which two themes share an id (M3): the
    /// second would silently restyle the first.
    package static func stylesheet(for themes: [ValidatedTheme]) throws(Refusal) -> (variables: String, rules: String) {
        var seen = Set<String>()
        for theme in themes where !seen.insert(theme.id).inserted {
            throw .duplicateID(theme.id)
        }
        var blocks: [String] = []
        var rules = ""
        for theme in themes {
            blocks.append(try variables(for: theme))
            rules += try checkedRules(id: theme.id, style: theme.document.style).css
        }
        return (blocks.joined(separator: "\n"), rules)
    }

    /// The palette block for one validated theme.
    package static func variables(for theme: ValidatedTheme) throws(Refusal) -> String {
        try variableBlock(id: theme.id, light: theme.light, dark: theme.dark, fontStack: theme.document.fontDesign.cssFontStack)
    }

    /// The per-theme style rules for one validated theme.
    package static func rules(for theme: ValidatedTheme) throws(Refusal) -> Output {
        try checkedRules(id: theme.id, style: theme.document.style)
    }

    // MARK: - Palette block

    /// Byte-for-byte the block kit 0.5.4's `PreviewTheme.css` wrote. Internal: reachable only
    /// through `variables(for:)`/`stylesheet(for:)` and the tests that feed it hostile values.
    static func variableBlock(id: String, light: ResolvedPalette, dark: ResolvedPalette, fontStack: String) throws(Refusal) -> String {
        guard ThemeGrammar.isThemeID(id) else { throw .invalidID }
        for (mode, palette) in [("light", light), ("dark", dark)] {
            for (field, value) in palette.fields where !ThemeGrammar.isHexColor(value) {
                throw .invalidColor(field: "\(mode).\(field)")
            }
        }
        func lines(_ palette: ResolvedPalette, fonts: String?) -> String {
            var pairs = palette.cssVariables
            if let fonts { pairs.append(("font-body", fonts)) }
            return pairs.map { "  --\($0.name): \($0.value);" }.joined(separator: "\n")
        }
        return """
        :root[data-theme="\(id)"] {
        \(lines(light, fonts: fontStack))
        }
        @media (prefers-color-scheme: dark) {
          :root[data-theme="\(id)"] {
        \(lines(dark, fonts: nil))
          }
        }
        """
    }

    // MARK: - Style rules

    /// kit #124's entry point, kept internal for its tests: the same checks as `rules(for:)`, but
    /// a refusal yields no CSS at all instead of an error.
    static func generate(id: String, style: ThemeStyle?) -> Output {
        (try? checkedRules(id: id, style: style)) ?? Output(css: "", selectors: [])
    }

    static func checkedRules(id: String, style: ThemeStyle?) throws(Refusal) -> Output {
        guard ThemeGrammar.isThemeID(id) else { throw .invalidID }
        guard let style else { return Output(css: "", selectors: []) }
        var rules = OrderedRules()

        func number(_ value: Double, _ option: ThemeNumber) throws(Refusal) -> String {
            guard option.isAcceptable(value) else { throw .invalidNumber(field: option.rawValue) }
            return ThemeNumber.css(value)
        }

        // Root-scoped custom-property overrides (kit 30d323c: e.g. Classic's `--heading-weight`,
        // `--body-size`, `--line-height`, `--radius`).
        var vars: [(String, String)] = []
        if let v = style.headingWeight { vars.append(("--heading-weight", try number(v, .headingWeight))) }
        if let v = style.bodySize { vars.append(("--body-size", "\(try number(v, .bodySize))px")) }
        if let v = style.lineHeight { vars.append(("--line-height", try number(v, .lineHeight))) }
        if let v = style.radius { vars.append(("--radius", "\(try number(v, .radius))px")) }

        if let v = style.maxWidth {
            rules.add(".markdown-body", "max-width", "\(try number(v, .maxWidth))px")
        }
        if let h1 = style.h1 {
            if let v = h1.align { rules.add("h1", "text-align", v.rawValue) }
            if let v = h1.size { rules.add("h1", "font-size", "\(try number(v, .h1Size))em") }
            if let v = h1.letterSpacing { rules.add("h1", "letter-spacing", "\(try number(v, .h1LetterSpacing))em") }
            if let decoration = h1.decoration { try apply(decoration, to: &rules) }
        }
        if let h2 = style.h2 {
            if let v = h2.letterSpacing { rules.add("h2", "letter-spacing", "\(try number(v, .h2LetterSpacing))em") }
            if let v = h2.italic, v { rules.add("h2", "font-style", "italic") }
            if let decoration = h2.decoration { try apply(decoration, to: &rules) }
        }
        if let bq = style.blockquote {
            if let v = bq.italic, v { rules.add("blockquote", "font-style", "italic") }
            if let value = bq.style {
                switch value {
                case .bar(let width):
                    let text = try number(width ?? 3, .blockquoteBarWidth)
                    try rules.addFragments(for: "blockquoteStyle", value: "bar", params: ["width": text])
                case .panel:
                    try rules.addFragments(for: "blockquoteStyle", value: "panel", params: [:])
                }
            }
        }
        if let hr = style.hr, let value = hr.style {
            switch value {
            case .line(let color, let thickness):
                // Handled directly, not through ThemeStyles.json: `thickness` is only emitted when
                // the theme names one (kit 30d323c: Modern's `hr` override touched only
                // `background`, leaving the shared rule's `height: 2px` alone).
                if let thickness { rules.add("hr", "height", "\(try number(thickness, .hrThickness))px") }
                rules.add("hr", "background", (color ?? .border).cssValue)
            case .shortCentered(let color):
                try rules.addFragments(for: "hrStyle", value: "shortCentered", params: ["color": color.cssValue])
            case .gradient(let colors):
                guard (2...3).contains(colors.count) else { throw .unresolvedPlaceholder }
                try rules.addFragments(for: "hrStyle", value: "gradient", params: ["colors": colors.map(\.cssValue).joined(separator: ", ")])
            }
        }
        if let table = style.table {
            if let header = table.header {
                switch header {
                case .surface:
                    try rules.addFragments(for: "tableHeader", value: "surface", params: [:])
                case .accentRule(let color):
                    try rules.addFragments(for: "tableHeader", value: "accentRule", params: ["color": color.cssValue])
                case .filled(let background, let text, let border):
                    // kit #124 review: Vivid's `filled` header also sets `border-color`, defaulting
                    // to the same role as `background` when the theme doesn't name one.
                    try rules.addFragments(for: "tableHeader", value: "filled", params: [
                        "background": background.cssValue, "text": text.cssValue, "border": (border ?? background).cssValue,
                    ])
                }
            }
            if let v = table.verticalRules, !v {
                rules.add("th, td", "border-left", "0")
                rules.add("th, td", "border-right", "0")
            }
            if let v = table.rounded, v { rules.add("table", "border-radius", "var(--radius)") }
        }
        if let role = style.listMarker { rules.add("li::marker", "color", role.cssValue) }
        if let role = style.inlineCode { rules.add("code:not(pre code)", "color", role.cssValue) }
        if let v = style.link?.underline, v {
            rules.add("a", "text-decoration", "underline")
            rules.add("a", "text-underline-offset", "0.15em")
            rules.add("a", "text-decoration-thickness", "1px")
        }
        if let v = style.syntax?.boldKeywords, v {
            rules.add(".hljs-keyword, .hljs-title", "font-weight", "650")
        }

        var css = ""
        if !vars.isEmpty {
            css += ":root[data-theme=\"\(id)\"] {\n"
            css += vars.map { "  \($0.0): \($0.1);" }.joined(separator: "\n")
            css += "\n}\n"
        }
        css += rules.render(scopedTo: id)
        guard !css.contains("{{") else { throw .unresolvedPlaceholder }
        return Output(css: css, selectors: rules.selectorsInOrder)
    }

    private static func apply(_ decoration: ThemeStyle.H1Decoration, to rules: inout OrderedRules) throws(Refusal) {
        switch decoration {
        case .rule: break // The default: the base `h1` rule already draws it. No override needed.
        case .none: try rules.addFragments(for: "h1Decoration", value: "none", params: [:])
        case .shortRule(let color):
            try rules.addFragments(for: "h1Decoration", value: "shortRule", params: ["color": color.cssValue])
        case .gradientBar(let from, let to):
            try rules.addFragments(for: "h1Decoration", value: "gradientBar", params: ["from": from.cssValue, "to": to.cssValue])
        }
    }

    private static func apply(_ decoration: ThemeStyle.H2Decoration, to rules: inout OrderedRules) throws(Refusal) {
        switch decoration {
        case .rule: break
        case .none: try rules.addFragments(for: "h2Decoration", value: "none", params: [:])
        case .dot(let color):
            try rules.addFragments(for: "h2Decoration", value: "dot", params: ["color": color.cssValue])
        }
    }
}

/// The CSS font stack for each font design (kit 0.5.4's `PreviewTheme.bodyFontStack`, moved here
/// so the palette block is generated from a `ValidatedTheme` alone).
extension ThemeFontDesign {
    package var cssFontStack: String {
        switch self {
        case .sans: #"-apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang TC", "PingFang SC", sans-serif"#
        case .serif: #"ui-serif, "New York", Georgia, "Songti TC", "Songti SC", serif"#
        case .rounded: #"ui-rounded, "SF Pro Rounded", -apple-system, "PingFang TC", "PingFang SC", sans-serif"#
        }
    }
}

/// Accumulates declarations per (unscoped) selector, in first-seen order, so several options that
/// touch the same element (e.g. Classic's `h1` gets `text-align`, `font-size`, `letter-spacing`
/// *and* its decoration's `border-bottom`/`padding-bottom`) become one rule, exactly as the
/// hand-written CSS did.
private struct OrderedRules {
    private var order: [String] = []
    private var declarations: [String: [ThemeCSSGenerator.Declaration]] = [:]

    /// `selector` may be a comma-separated list (e.g. `"th, td"`, `".hljs-keyword, .hljs-title"`):
    /// each part is scoped and recorded on its own, so `render` never has to scope a compound
    /// selector as one string (which would only prefix its first part).
    mutating func add(_ selector: String, _ property: String, _ value: String) {
        for part in selector.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if declarations[part] == nil {
                order.append(part)
                declarations[part] = []
            }
            declarations[part]!.append(.init(property: property, value: value))
        }
    }

    /// Adds `ThemeStyles.json`'s fragments for an option value. A missing table or entry refuses
    /// the theme rather than silently drawing it without that option.
    mutating func addFragments(for option: String, value: String, params: [String: String]) throws(ThemeCSSGenerator.Refusal) {
        guard let raw = ThemeStylesFile.shared?.fragments[option]?[value] else { throw .unresolvedPlaceholder }
        for fragment in raw {
            for pair in fragment.declarations {
                guard pair.count == 2 else { throw .unresolvedPlaceholder }
                var value = pair[1]
                for (key, replacement) in params {
                    value = value.replacingOccurrences(of: "{{\(key)}}", with: replacement)
                }
                add(fragment.selector, pair[0], value)
            }
        }
    }

    var selectorsInOrder: [String] { order }

    func render(scopedTo id: String) -> String {
        order.map { selector in
            let scoped = "[data-theme=\"\(id)\"] \(selector)"
            let body = declarations[selector]!.map { "\($0.property): \($0.value);" }.joined(separator: " ")
            return "\(scoped) { \(body) }\n"
        }.joined()
    }
}
