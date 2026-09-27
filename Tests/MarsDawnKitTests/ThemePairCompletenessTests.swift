import Foundation
import Testing
@testable import MarsDawnKit
@testable import MarsDawnThemes

/// kit #125, security review M2: the composed pairs the validator checks (`ThemeStyles.json`'s
/// `pairs`) must account for every colour the preview actually draws, and must not drop anything
/// `PreviewThemeContrastTests` enforced before the validator existed.
///
/// Three walks, each over what is really served:
/// - the served `preview.css` (with the built-ins' generated rules spliced in): every declaration
///   that paints with a colour variable is claimed by a shared pair or by the decorative list;
/// - preview.js's Mermaid `themeVariables`: every colour-valued one is claimed the same way;
/// - every style option value: every colour variable its generated CSS uses is one of the roles
///   its own pair declarations name.
struct ThemePairCompletenessTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let previewCSS = root.appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.css")
    static let previewJS = root.appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.js")

    /// The custom properties that hold colours. Everything else (`--radius`, `--font-*`, sizes) is
    /// not a colour.
    static func isColourVariable(_ name: String) -> Bool {
        ["bg", "surface", "fg", "muted", "border", "heading", "accent", "link", "quote", "code-chip", "code-chip-edge"].contains(name)
            || name.hasPrefix("hl-") || name.hasPrefix("mm-")
    }

    static func colourVariables(in value: String) -> Set<String> {
        Set(value.matches(of: /var\(--([a-z0-9-]+)\)/).map { String($0.output.1) }.filter(isColourVariable))
    }

    struct Declaration { let selector: String; let property: String; let value: String }

    /// Every declaration of a flat-or-`@media`-nested stylesheet, with its rule's selector text
    /// normalised (comments dropped, whitespace collapsed).
    static func declarations(in css: String) -> [Declaration] {
        let text = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var out: [Declaration] = []
        func walk(_ text: Substring) {
            var index = text.startIndex
            var prelude = ""
            while index < text.endIndex {
                let character = text[index]
                if character == "{" {
                    var depth = 1
                    var end = text.index(after: index)
                    while end < text.endIndex, depth > 0 {
                        if text[end] == "{" { depth += 1 } else if text[end] == "}" { depth -= 1 }
                        end = text.index(after: end)
                    }
                    let body = text[text.index(after: index)..<text.index(before: end)]
                    let selector = prelude.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if selector.hasPrefix("@") {
                        walk(body)
                    } else {
                        for part in body.split(separator: ";") {
                            guard let colon = part.firstIndex(of: ":") else { continue }
                            let property = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                            let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                            out.append(Declaration(selector: selector, property: property, value: value))
                        }
                    }
                    prelude = ""
                    index = end
                } else {
                    prelude.append(character)
                    index = text.index(after: index)
                }
            }
        }
        walk(Substring(text))
        return out
    }

    static var table: ThemePairTable { ThemePairTable.bundled! }

    /// Which pair (or decorative entry) claims each `selector|property`, and the colour variables it
    /// may use there.
    static func cssClaims() -> [String: (owner: String, variables: Set<String>)] {
        var claims: [String: (String, Set<String>)] = [:]
        for pair in table.shared {
            let variables = ResolvedPalette.cssVariables(for: pair.fg).union(ResolvedPalette.cssVariables(for: pair.bg))
            for key in pair.css ?? [] { claims[key] = (pair.id ?? pair.element, variables) }
        }
        for entry in table.decorative {
            for key in entry.css ?? [] { claims[key] = ("decorative", ["border", "code-chip-edge"]) }
        }
        return claims
    }

    @Test func theServedStylesheetHasNoUnclaimedColour() throws {
        let served = String(decoding: PreviewSchemeHandler.splicedPreviewCSS(try Data(contentsOf: Self.previewCSS)), as: UTF8.self)
        let claims = Self.cssClaims()
        var unclaimed: [String] = []
        var wrongVariable: [String] = []
        var seen = Set<String>()
        var generated = 0
        for declaration in Self.declarations(in: served) where !declaration.property.hasPrefix("--") {
            let variables = Self.colourVariables(in: declaration.value)
            guard !variables.isEmpty else { continue }
            if declaration.selector.hasPrefix("[data-theme=") || declaration.selector.hasPrefix(":root[data-theme=") {
                generated += 1 // an option value's own rule: checked by everyOptionValueDeclaresTheColoursItDraws
                continue
            }
            let key = "\(declaration.selector)|\(declaration.property)"
            seen.insert(key)
            guard let claim = claims[key] else {
                unclaimed.append("\(key): \(declaration.value)")
                continue
            }
            if !variables.isSubset(of: claim.variables) {
                wrongVariable.append("\(key) uses \(variables.sorted()) but \(claim.owner) covers \(claim.variables.sorted())")
            }
        }
        #expect(seen.count >= 40, "positive fixture: the walk found the shared colour declarations (\(seen.count))")
        #expect(generated >= 10, "positive fixture: the built-ins' generated rules were in the served stylesheet (\(generated))")
        #expect(unclaimed.isEmpty, "colours the stylesheet draws that no pair declares:\n\(unclaimed.joined(separator: "\n"))")
        #expect(wrongVariable.isEmpty, Comment(rawValue: wrongVariable.joined(separator: "\n")))
        let stale = Set(claims.keys).subtracting(seen)
        #expect(stale.isEmpty, "pairs claim declarations the stylesheet no longer has: \(stale.sorted())")
    }

    @Test func mermaidThemeVariablesHaveNoUnclaimedColour() throws {
        let js = try String(contentsOf: Self.previewJS, encoding: .utf8)
        let start = try #require(js.range(of: "themeVariables: {"))
        let end = try #require(js.range(of: "\n      },", range: start.upperBound..<js.endIndex))
        var mapping: [String: String] = [:]
        for match in js[start.upperBound..<end.lowerBound].matches(of: /([A-Za-z0-9]+): [cv]\("--([a-z0-9-]+)"\)/) {
            mapping[String(match.output.1)] = String(match.output.2)
        }
        let colourValued = mapping.filter { Self.isColourVariable($0.value) }
        #expect(colourValued.count >= 45, "positive fixture: preview.js's colour themeVariables were parsed (\(colourValued.count))")

        var claims: [String: (owner: String, variables: Set<String>)] = [:]
        for pair in Self.table.shared {
            let variables = ResolvedPalette.cssVariables(for: pair.fg).union(ResolvedPalette.cssVariables(for: pair.bg))
            for name in pair.mermaid ?? [] { claims[name] = (pair.id ?? pair.element, variables) }
        }
        for entry in Self.table.decorative {
            for name in entry.mermaid ?? [] { claims[name] = ("decorative", ["border", "bg"]) }
        }
        var problems: [String] = []
        for (name, variable) in colourValued.sorted(by: { $0.key < $1.key }) {
            guard let claim = claims[name] else {
                problems.append("\(name) (--\(variable)) has no pair")
                continue
            }
            if !claim.variables.contains(variable) {
                problems.append("\(name) reads --\(variable) but \(claim.owner) covers \(claim.variables.sorted())")
            }
        }
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        let stale = Set(claims.keys).subtracting(colourValued.keys)
        #expect(stale.isEmpty, "pairs claim themeVariables preview.js doesn't set: \(stale.sorted())")
    }

    /// Every colour variable an option value's CSS uses is one its own pair declarations (or its
    /// declared decorative placeholders) name. Placeholders are bound to roles no other part of the
    /// value uses, so a role can't be covered by accident.
    @Test func everyOptionValueDeclaresTheColoursItDraws() throws {
        let samples: [(String, ThemeStyle)] = [
            ("h1Decoration.none", ThemeStyle(h1: .init(decoration: ThemeStyle.H1Decoration.none))),
            ("h1Decoration.shortRule", ThemeStyle(h1: .init(decoration: .shortRule(color: .quote)))),
            ("h1Decoration.gradientBar", ThemeStyle(h1: .init(decoration: .gradientBar(from: .link, to: .muted)))),
            ("h2Decoration.none", ThemeStyle(h2: .init(decoration: ThemeStyle.H2Decoration.none))),
            ("h2Decoration.dot", ThemeStyle(h2: .init(decoration: .dot(color: .quote)))),
            ("blockquoteStyle.bar", ThemeStyle(blockquote: .init(style: .bar(width: 3)))),
            ("blockquoteStyle.panel", ThemeStyle(blockquote: .init(style: .panel))),
            ("hrStyle.line", ThemeStyle(hr: .init(style: .line(color: .quote, thickness: 2)))),
            ("hrStyle.line default", ThemeStyle(hr: .init(style: .line(color: nil, thickness: nil)))),
            ("hrStyle.shortCentered", ThemeStyle(hr: .init(style: .shortCentered(color: .link)))),
            ("hrStyle.gradient", ThemeStyle(hr: .init(style: .gradient(colors: [.muted, .link, .quote])))),
            ("tableHeader.surface", ThemeStyle(table: .init(header: .surface))),
            ("tableHeader.accentRule", ThemeStyle(table: .init(header: .accentRule(color: .quote)))),
            ("tableHeader.filled", ThemeStyle(table: .init(header: .filled(background: .heading, text: .background, border: .muted)))),
            ("listMarker", ThemeStyle(listMarker: .quote)),
            ("inlineCode", ThemeStyle(inlineCode: .string)),
        ]
        var drawnSomething = 0
        for (label, style) in samples {
            let css = try ThemeCSSGenerator.checkedRules(id: "probe", style: style).css
            let drawn = Self.colourVariables(in: css)
            if !drawn.isEmpty { drawnSomething += 1 }
            var declared = Set<String>()
            for selection in ThemePairTable.selections(for: style) {
                let option = try #require(Self.table.options[selection.option]?[selection.value], "\(label): no pair entry for \(selection.option).\(selection.value)")
                for pair in option.pairs {
                    for token in ThemePairTable.expand(pair.fg, params: selection.params) + ThemePairTable.expand(pair.bg, params: selection.params) {
                        declared.formUnion(ResolvedPalette.cssVariables(for: token))
                    }
                }
                for token in (option.decorative ?? []).flatMap({ ThemePairTable.expand($0, params: selection.params) }) {
                    declared.formUnion(ResolvedPalette.cssVariables(for: token))
                }
            }
            #expect(drawn.isSubset(of: declared), "\(label) draws \(drawn.subtracting(declared).sorted()) without a pair")
        }
        #expect(drawnSomething >= 11, "positive fixture: the samples really draw colours (\(drawnSomething))")
    }

    /// The shared pairs plus each built-in's options cover every element of today's
    /// `PreviewThemeContrastTests` map, at a threshold at least as strict.
    @Test func thePairsCoverTheContrastMap() throws {
        var missing: [String] = []
        var checked = 0
        for theme in PreviewTheme.all {
            let validated = try #require(theme.validated)
            for dark in [false, true] {
                let resolved = Self.table.pairs(style: validated.document.style, palette: dark ? validated.dark : validated.light, dark: dark)
                for expected in PreviewThemeContrastTests.pairs(theme, dark: dark) {
                    checked += 1
                    let covered = resolved.contains {
                        $0.foreground == expected.foreground && $0.background == expected.background && $0.threshold >= expected.threshold
                    }
                    if !covered { missing.append(expected.description) }
                }
            }
        }
        #expect(checked >= 370, "positive fixture: the whole map was compared (\(checked))")
        #expect(missing.isEmpty, "the validator's pairs drop what the contrast map enforces:\n\(missing.joined(separator: "\n"))")
    }

    /// Notices (the remote-image banner and its button, image placeholders, Mermaid and math
    /// errors) are text pairs at 4.5:1 in every scenario, including notes-sharing, the one with no
    /// threshold of its own.
    @Test func noticePairsAreMandatoryTextPairs() throws {
        let notices = Self.table.shared.filter { $0.notice == true }
        #expect(Set(notices.compactMap(\.id)) == ["banner-text", "banner-button", "error-text"])
        #expect(notices.allSatisfy { $0.kind == .text && $0.modes == nil })
        var document = try ThemeDocumentLoader.loadBuiltIn(id: "dawn")
        document.id = "notes"
        document.scenarios = [.notesSharing]
        document.dark.syntax?.keyword = document.dark.background
        let report = ThemeValidator.validate(document)
        #expect(report.issues.contains { $0.rule == "contrast.pair" && $0.message.contains("math and diagram errors") && $0.message.contains("notice") }, "\(report.issues)")
    }
}
