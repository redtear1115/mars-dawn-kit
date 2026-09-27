import Foundation

/// A palette with every colour present: the file's own `syntax`/`diagram` groups, or Dawn's for
/// the same appearance where the file leaves one out (design §4.2: both groups are optional in
/// the file, and the app fills anything missing).
package struct ResolvedPalette: Hashable, Sendable {
    package var background: String
    package var surface: String
    package var text: String
    package var muted: String
    package var border: String
    package var heading: String
    package var accent: String
    package var link: String
    package var quote: String
    package var syntax: ThemeSyntaxColors
    package var diagram: ThemeDiagramColors

    init(_ colors: ThemeColors, fallback: ResolvedPalette?) throws(ThemePairTable.MissingFallback) {
        guard let syntax = colors.syntax ?? fallback?.syntax, let diagram = colors.diagram ?? fallback?.diagram else {
            throw ThemePairTable.MissingFallback()
        }
        background = colors.background; surface = colors.surface; text = colors.text; muted = colors.muted
        border = colors.border; heading = colors.heading; accent = colors.accent; link = colors.link; quote = colors.quote
        self.syntax = syntax
        self.diagram = diagram
    }

    /// Every colour with its CSS custom-property name, in the order the palette block writes them.
    package var cssVariables: [(name: String, value: String)] {
        [
            ("bg", background), ("surface", surface), ("fg", text), ("muted", muted),
            ("border", border), ("heading", heading), ("accent", accent), ("link", link),
            ("quote", quote),
            ("hl-keyword", syntax.keyword), ("hl-string", syntax.string), ("hl-comment", syntax.comment),
            ("hl-number", syntax.number), ("hl-function", syntax.function), ("hl-type", syntax.type),
            ("mm-node", diagram.node), ("mm-border", diagram.nodeBorder), ("mm-text", diagram.text),
            ("mm-line", diagram.line), ("mm-secondary", diagram.secondary),
            ("mm-tertiary", diagram.tertiary), ("mm-note", diagram.note),
        ]
    }

    /// Every colour with its `theme.json` field path (e.g. `syntax.keyword`), for messages.
    package var fields: [(path: String, value: String)] {
        [
            ("background", background), ("surface", surface), ("text", text), ("muted", muted),
            ("border", border), ("heading", heading), ("accent", accent), ("link", link), ("quote", quote),
            ("syntax.keyword", syntax.keyword), ("syntax.string", syntax.string), ("syntax.comment", syntax.comment),
            ("syntax.number", syntax.number), ("syntax.function", syntax.function), ("syntax.type", syntax.type),
            ("diagram.node", diagram.node), ("diagram.nodeBorder", diagram.nodeBorder), ("diagram.text", diagram.text),
            ("diagram.line", diagram.line), ("diagram.secondary", diagram.secondary),
            ("diagram.tertiary", diagram.tertiary), ("diagram.note", diagram.note),
        ]
    }

    /// The colour a pair token names in this palette, or nil for an unknown token. Derived tokens
    /// follow `preview.css`: `chip` is `--code-chip` (surface, lifted 10% toward the text in dark
    /// mode), `frontMatter` the front-matter box, `footnoteTarget` the `:target` tint, `paper` the
    /// white page of a PDF.
    package func color(for token: String, dark: Bool) -> String? {
        switch token {
        case "background": background
        case "surface": surface
        case "text": text
        case "muted": muted
        case "border": border
        case "heading": heading
        case "accent": accent
        case "link": link
        case "quote": quote
        case "keyword": syntax.keyword
        case "string": syntax.string
        case "comment": syntax.comment
        case "number": syntax.number
        case "function": syntax.function
        case "type": syntax.type
        case "diagram.node": diagram.node
        case "diagram.nodeBorder": diagram.nodeBorder
        case "diagram.text": diagram.text
        case "diagram.line": diagram.line
        case "diagram.secondary": diagram.secondary
        case "diagram.tertiary": diagram.tertiary
        case "diagram.note": diagram.note
        case "chip": dark ? ThemeContrast.mix(surface, text, 0.10) : surface
        case "frontMatter": ThemeContrast.mix(surface, background, 0.35)
        case "footnoteTarget": ThemeContrast.mix(background, accent, 0.18)
        case "paper": "#FFFFFF"
        default: nil
        }
    }

    /// The CSS custom properties a pair token is drawn from, for the completeness walk.
    package static func cssVariables(for token: String) -> Set<String> {
        switch token {
        case "chip": return ["code-chip", "surface", "fg"]
        case "frontMatter": return ["surface", "bg"]
        case "footnoteTarget": return ["accent", "bg"]
        case "paper": return []
        default:
            if let role = PaletteRole(rawValue: token) { return [role.cssVariable] }
            let diagram = ["diagram.node": "mm-node", "diagram.nodeBorder": "mm-border", "diagram.text": "mm-text",
                           "diagram.line": "mm-line", "diagram.secondary": "mm-secondary",
                           "diagram.tertiary": "mm-tertiary", "diagram.note": "mm-note"]
            return diagram[token].map { [$0] } ?? []
        }
    }
}

/// One declared pair from `ThemeStyles.json`.
package struct PairDeclaration: Decodable, Hashable, Sendable {
    package enum Kind: String, Decodable, Sendable { case text, nontext }
    package let id: String?
    package let element: String
    package let fg: String
    package let bg: String
    package let kind: Kind
    package let notice: Bool?
    package let baseline: Bool?
    package let modes: [String]?
    package let css: [String]?
    package let mermaid: [String]?
}

package struct DecorativeDeclaration: Decodable, Hashable, Sendable {
    package let reason: String
    package let css: [String]?
    package let mermaid: [String]?
}

package struct OptionPairs: Decodable, Hashable, Sendable {
    package let replaces: [String]?
    package let decorative: [String]?
    package let pairs: [PairDeclaration]
}

/// A pair resolved against one palette: real colours and the threshold they need.
package struct ResolvedPair: Hashable, Sendable {
    package let id: String?
    package let element: String
    package let fgToken: String
    package let bgToken: String
    package let foreground: String
    package let background: String
    package let kind: PairDeclaration.Kind
    package let notice: Bool
    package let baseline: Bool
    package let dark: Bool

    package var threshold: Double { kind == .text ? 4.5 : 3.0 }
    package var ratio: Double { ThemeContrast.ratio(foreground, background) }
}

/// The pair declarations of `ThemeStyles.json` (kit #125, security review M2): the shared
/// stylesheet's own pairs, and each option value's.
package struct ThemePairTable: Decodable, Sendable {
    struct MissingFallback: Error {}

    package let shared: [PairDeclaration]
    package let decorative: [DecorativeDeclaration]
    package let options: [String: [String: OptionPairs]]

    /// One option value a theme picked, and the palette roles its placeholders stand for.
    package struct Selection: Hashable, Sendable {
        package let option: String
        package let value: String
        package let params: [String: [PaletteRole]]
    }

    /// The option values `style` picks that draw colours, in a fixed order.
    package static func selections(for style: ThemeStyle?) -> [Selection] {
        guard let style else { return [] }
        var out: [Selection] = []
        switch style.h1?.decoration {
        case .none?: out.append(.init(option: "h1Decoration", value: "none", params: [:]))
        case .shortRule(let color)?: out.append(.init(option: "h1Decoration", value: "shortRule", params: ["color": [color]]))
        case .gradientBar(let from, let to)?: out.append(.init(option: "h1Decoration", value: "gradientBar", params: ["from": [from], "to": [to]]))
        case .rule?, nil: break
        }
        switch style.h2?.decoration {
        case .none?: out.append(.init(option: "h2Decoration", value: "none", params: [:]))
        case .dot(let color)?: out.append(.init(option: "h2Decoration", value: "dot", params: ["color": [color]]))
        case .rule?, nil: break
        }
        switch style.blockquote?.style {
        case .bar?: out.append(.init(option: "blockquoteStyle", value: "bar", params: [:]))
        case .panel?: out.append(.init(option: "blockquoteStyle", value: "panel", params: [:]))
        case nil: break
        }
        switch style.hr?.style {
        case .line(let color, _)?: out.append(.init(option: "hrStyle", value: "line", params: ["color": [color ?? .border]]))
        case .shortCentered(let color)?: out.append(.init(option: "hrStyle", value: "shortCentered", params: ["color": [color]]))
        case .gradient(let colors)?: out.append(.init(option: "hrStyle", value: "gradient", params: ["colors": colors]))
        case nil: break
        }
        switch style.table?.header {
        case .surface?: out.append(.init(option: "tableHeader", value: "surface", params: [:]))
        case .accentRule(let color)?: out.append(.init(option: "tableHeader", value: "accentRule", params: ["color": [color]]))
        case .filled(let background, let text, let border)?:
            out.append(.init(option: "tableHeader", value: "filled", params: ["background": [background], "text": [text], "border": [border ?? background]]))
        case nil: break
        }
        if let role = style.listMarker { out.append(.init(option: "listMarker", value: "role", params: ["color": [role]])) }
        if let role = style.inlineCode { out.append(.init(option: "inlineCode", value: "role", params: ["color": [role]])) }
        return out
    }

    /// Expands a declared token: a literal token stays itself, `{{name}}` becomes each role the
    /// selection bound to `name`.
    static func expand(_ token: String, params: [String: [PaletteRole]]) -> [String] {
        guard token.hasPrefix("{{"), token.hasSuffix("}}") else { return [token] }
        let name = String(token.dropFirst(2).dropLast(2))
        return (params[name] ?? []).map(\.rawValue)
    }

    /// Every pair a theme with `style` composes in one palette: the shared pairs (minus the ones
    /// an option replaces, and minus light-only pairs in dark mode) plus each picked option's.
    /// Nontext pairs drawn in `border` are left out: they are the decorative hairlines #152 exempts.
    package func pairs(style: ThemeStyle?, palette: ResolvedPalette, dark: Bool) -> [ResolvedPair] {
        let selections = Self.selections(for: style)
        var replaced = Set<String>()
        var declared: [(PairDeclaration, fg: String, bg: String)] = []
        for selection in selections {
            guard let option = options[selection.option]?[selection.value] else { continue }
            replaced.formUnion(option.replaces ?? [])
            for pair in option.pairs {
                for fg in Self.expand(pair.fg, params: selection.params) {
                    for bg in Self.expand(pair.bg, params: selection.params) {
                        declared.append((pair, fg, bg))
                    }
                }
            }
        }
        let sharedPairs = shared.filter { !replaced.contains($0.id ?? "") }.map { ($0, fg: $0.fg, bg: $0.bg) }
        var out: [ResolvedPair] = []
        for (pair, fgToken, bgToken) in sharedPairs + declared {
            if let modes = pair.modes, !modes.contains(dark ? "dark" : "light") { continue }
            if pair.kind == .nontext, fgToken == "border" { continue }
            guard let fg = palette.color(for: fgToken, dark: dark), let bg = palette.color(for: bgToken, dark: dark) else { continue }
            out.append(ResolvedPair(
                id: pair.id, element: pair.element, fgToken: fgToken, bgToken: bgToken,
                foreground: fg, background: bg, kind: pair.kind,
                notice: pair.notice ?? false, baseline: pair.baseline ?? false, dark: dark
            ))
        }
        return out
    }

    package static let bundled: ThemePairTable? = ThemeStylesFile.shared?.pairs
}

/// `ThemeStyles.json`, decoded once: the CSS fragments and the pair declarations.
struct ThemeStylesFile: Decodable, Sendable {
    struct RawFragment: Decodable, Sendable { let selector: String; let declarations: [[String]] }
    let fragments: [String: [String: [RawFragment]]]
    let pairs: ThemePairTable

    static let shared: ThemeStylesFile? = {
        guard let url = Bundle.module.url(forResource: "ThemeStyles", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(ThemeStylesFile.self, from: data)
    }()
}
