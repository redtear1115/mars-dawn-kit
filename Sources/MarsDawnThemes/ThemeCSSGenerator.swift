import Foundation

/// Turns a `ThemeDocument`'s `style` (design §4.3) into the CSS a preview page needs: a block of
/// `:root[data-theme="<id>"]` custom-property overrides, and a set of `[data-theme="<id>"] <selector>`
/// rules. Every colour it emits is a palette `var(--…)`; every rule's selector is one of the fixed
/// selectors the four built-ins' hand-written per-theme rules (kit `30d323c`,
/// `Resources/Preview/preview.css` lines 301–383) already used, so the cascade — and the exact
/// specificity of every replaced rule — is preserved (kit #124).
///
/// The complex, multi-declaration option values (the ones with pseudo-elements or more than one
/// property) read their CSS shape from `ThemeStyles.json`, a single data file meant to be shared
/// with the site's simulator (design §4.3) once that exists (#125/#126); the simple scalar options
/// (sizes, weights, booleans) are generated directly, since a one-property rule needs no template.
package enum ThemeCSSGenerator {
    /// One property/value pair a fragment or a scalar option contributes to a selector.
    struct Declaration { let property: String; let value: String }

    /// The variable-override block plus the per-theme rules for one theme, as `(selector,
    /// declarations)` pairs in the order they were built. `selectors` is every selector a rule was
    /// emitted for (before scoping), for tests that only need to check which elements are touched.
    package struct Output {
        package let css: String
        package let selectors: [String]
    }

    /// Generates the `:root[data-theme="id"] { … }` variable block and every
    /// `[data-theme="id"] <selector>` rule for `style`. Empty (no output at all) when `style` is
    /// nil or sets nothing, matching a built-in that added no per-theme rules (kit `30d323c`'s Dawn).
    package static func generate(id: String, style: ThemeStyle?) -> Output {
        guard let style else { return Output(css: "", selectors: []) }
        var rules = OrderedRules()

        // Root-scoped custom-property overrides (kit 30d323c: e.g. Classic's `--heading-weight`,
        // `--body-size`, `--line-height`, `--radius`).
        var vars: [(String, String)] = []
        if let v = style.headingWeight { vars.append(("--heading-weight", cssNumber(v))) }
        if let v = style.bodySize { vars.append(("--body-size", "\(cssNumber(v))px")) }
        if let v = style.lineHeight { vars.append(("--line-height", cssNumber(v))) }
        if let v = style.radius { vars.append(("--radius", "\(cssNumber(v))px")) }

        if let v = style.maxWidth {
            rules.add(".markdown-body", "max-width", "\(cssNumber(v))px")
        }
        if let h1 = style.h1 {
            if let v = h1.align { rules.add("h1", "text-align", v.rawValue) }
            if let v = h1.size { rules.add("h1", "font-size", "\(cssNumber(v))em") }
            if let v = h1.letterSpacing { rules.add("h1", "letter-spacing", "\(cssNumber(v))em") }
            if let decoration = h1.decoration { apply(decoration, to: &rules) }
        }
        if let h2 = style.h2 {
            if let v = h2.letterSpacing { rules.add("h2", "letter-spacing", "\(cssNumber(v))em") }
            if let v = h2.italic, v { rules.add("h2", "font-style", "italic") }
            if let decoration = h2.decoration { apply(decoration, to: &rules) }
        }
        if let bq = style.blockquote {
            if let v = bq.italic, v { rules.add("blockquote", "font-style", "italic") }
            if let value = bq.style { apply(value, to: &rules) }
        }
        if let hr = style.hr, let value = hr.style {
            apply(value, to: &rules)
        }
        if let table = style.table {
            if let header = table.header { apply(header, to: &rules) }
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
        return Output(css: css, selectors: rules.selectorsInOrder)
    }

    // MARK: - Shaped options (via ThemeStyles.json)

    private static func apply(_ decoration: ThemeStyle.H1Decoration, to rules: inout OrderedRules) {
        switch decoration {
        case .rule: break // The default: the base `h1` rule already draws it. No override needed.
        case .none: rules.addFragments(Fragments.shared.fragments(for: "h1Decoration", value: "none", params: [:]))
        case .shortRule(let color):
            rules.addFragments(Fragments.shared.fragments(for: "h1Decoration", value: "shortRule", params: ["color": color.cssValue]))
        case .gradientBar(let from, let to):
            rules.addFragments(Fragments.shared.fragments(
                for: "h1Decoration", value: "gradientBar", params: ["from": from.cssValue, "to": to.cssValue]
            ))
        }
    }

    private static func apply(_ decoration: ThemeStyle.H2Decoration, to rules: inout OrderedRules) {
        switch decoration {
        case .rule: break
        case .none: rules.addFragments(Fragments.shared.fragments(for: "h2Decoration", value: "none", params: [:]))
        case .dot(let color):
            rules.addFragments(Fragments.shared.fragments(for: "h2Decoration", value: "dot", params: ["color": color.cssValue]))
        }
    }

    private static func apply(_ style: ThemeStyle.BlockquoteStyle, to rules: inout OrderedRules) {
        switch style {
        case .bar(let width):
            rules.addFragments(Fragments.shared.fragments(
                for: "blockquoteStyle", value: "bar", params: ["width": cssNumber(width ?? 3)]
            ))
        case .panel:
            rules.addFragments(Fragments.shared.fragments(for: "blockquoteStyle", value: "panel", params: [:]))
        }
    }

    private static func apply(_ style: ThemeStyle.HrStyle, to rules: inout OrderedRules) {
        switch style {
        case .line(let color, let thickness):
            // Handled directly, not through ThemeStyles.json: `thickness` is only emitted when the
            // theme names one (kit 30d323c: Modern's `hr` override touched only `background`,
            // leaving the shared rule's `height: 2px` alone -- emitting a redundant `height` would
            // still compute the same, but it isn't what the hand-written rule said).
            if let thickness { rules.add("hr", "height", "\(cssNumber(thickness))px") }
            rules.add("hr", "background", (color ?? .border).cssValue)
        case .shortCentered(let color):
            rules.addFragments(Fragments.shared.fragments(for: "hrStyle", value: "shortCentered", params: ["color": color.cssValue]))
        case .gradient(let colors):
            var params: [String: String] = [:]
            for (index, color) in colors.enumerated() { params["colors.\(index)"] = color.cssValue }
            rules.addFragments(Fragments.shared.fragments(for: "hrStyle", value: "gradient", params: params))
        }
    }

    private static func apply(_ header: ThemeStyle.TableHeader, to rules: inout OrderedRules) {
        switch header {
        case .surface:
            rules.addFragments(Fragments.shared.fragments(for: "tableHeader", value: "surface", params: [:]))
        case .accentRule(let color):
            rules.addFragments(Fragments.shared.fragments(for: "tableHeader", value: "accentRule", params: ["color": color.cssValue]))
        case .filled(let background, let text, let border):
            // kit #124 review: Vivid's `filled` header also sets `border-color`, defaulting to
            // the same role as `background` when the theme doesn't name one.
            rules.addFragments(Fragments.shared.fragments(
                for: "tableHeader", value: "filled",
                params: ["background": background.cssValue, "text": text.cssValue, "border": (border ?? background).cssValue]
            ))
        }
    }

    static func cssNumber(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
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
    /// selector as one string (which would only prefix its first part). Two options that touch
    /// the same simple selector (say `th` from both a `table.header` value and `verticalRules`)
    /// merge into the one rule that selector already has -- CSS gives the same computed result
    /// either way, since the two never set the same property.
    mutating func add(_ selector: String, _ property: String, _ value: String) {
        for part in selector.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if declarations[part] == nil {
                order.append(part)
                declarations[part] = []
            }
            declarations[part]!.append(.init(property: property, value: value))
        }
    }

    mutating func addFragments(_ fragments: [ThemeFragment]) {
        for fragment in fragments {
            for declaration in fragment.declarations {
                add(fragment.selector, declaration.property, declaration.value)
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

/// One `{selector, declarations}` entry from `ThemeStyles.json`, after `{{placeholder}}`
/// substitution. `declarations` keeps the file's own order, so generated CSS text is
/// deterministic even though it's assembled from a JSON array of `[property, value]` pairs.
struct ThemeFragment {
    let selector: String
    let declarations: [ThemeCSSGenerator.Declaration]
}

/// Reads and renders `ThemeStyles.json`'s CSS fragment templates. A `struct` holding only
/// immutable, `Sendable` data, so `shared` needs no actor isolation.
struct Fragments: Sendable {
    static let shared = Fragments()

    /// `declarations` is an array of two-element `[property, value]` arrays, not a JSON object:
    /// a `[String: String]` would lose the order CSS properties were written in (Swift's
    /// `Dictionary` doesn't preserve insertion order), which would make the generated stylesheet's
    /// text non-deterministic between runs.
    private struct RawFragment: Decodable { let selector: String; let declarations: [[String]] }
    private let table: [String: [String: [RawFragment]]]

    private init() {
        guard let url = Bundle.module.url(forResource: "ThemeStyles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: [RawFragment]]].self, from: data)
        else {
            table = [:]
            return
        }
        table = decoded
    }

    /// `option` (e.g. `"h1Decoration"`), `value` (e.g. `"shortRule"`), and the placeholder values
    /// to substitute (e.g. `["color": "var(--accent)"]`). Missing entries render as nothing rather
    /// than crashing: a theme just gets no rule for that option, which a test can still catch by
    /// checking the theme it broke.
    func fragments(for option: String, value: String, params: [String: String]) -> [ThemeFragment] {
        (table[option]?[value] ?? []).map { raw in
            ThemeFragment(
                selector: raw.selector,
                declarations: raw.declarations.map { pair in
                    .init(property: pair[0], value: substitute(pair[1], params: params))
                }
            )
        }
    }

    private func substitute(_ template: String, params: [String: String]) -> String {
        var result = template
        for (key, value) in params {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
