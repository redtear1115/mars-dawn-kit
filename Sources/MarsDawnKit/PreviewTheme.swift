import Foundation
import os
import MarsDawnThemes

/// A preview style: typography plus a light and a dark palette.
///
/// This is the single source of truth for theme colours. The preview page's
/// `themes.css` is generated from it, and native UI (settings swatches, editor
/// colours) reads the same values.
///
/// Since kit #124, a built-in theme's colours, font design and per-theme style options (§4.3 of
/// the theme-ecosystem design) are data: a bundled `theme.json` in `MarsDawnThemes`, decoded once
/// into this struct. `style` stays kit-internal (`package`), not part of the public API: it feeds
/// `ThemeCSSGenerator`, which the app and CLI never call directly.
///
/// Since kit #125 every `PreviewTheme` carries the `ValidatedTheme` it was checked as (`nil` if it
/// failed), and the served stylesheets are generated from that alone: a theme that didn't pass
/// `ThemeValidator` contributes no byte to `themes.css` or to the spliced `preview.css`, whichever
/// initializer made it (security review H1).
public struct PreviewTheme: Identifiable, Hashable, Sendable {
    public enum FontDesign: String, Sendable {
        case sans, serif, rounded
    }

    public struct Palette: Hashable, Sendable {
        public var background: String
        public var surface: String
        public var text: String
        public var muted: String
        public var border: String
        public var heading: String
        public var accent: String
        public var link: String
        public var quote: String
        public var syntax: Syntax
        public var diagram: Diagram
    }

    public struct Syntax: Hashable, Sendable {
        public var keyword: String
        public var string: String
        public var comment: String
        public var number: String
        public var function: String
        public var type: String
    }

    public struct Diagram: Hashable, Sendable {
        public var node: String
        public var nodeBorder: String
        public var text: String
        public var line: String
        public var secondary: String
        public var tertiary: String
        public var note: String
    }

    public let id: String
    public let name: String
    public let summary: String
    public let fontDesign: FontDesign
    public let light: Palette
    public let dark: Palette
    /// The theme's style options (design §4.3): kit-internal, not public API (see the type doc).
    package let style: ThemeStyle?
    /// What `ThemeValidator` made of this theme; `nil` when it failed. The only thing the
    /// stylesheet generator reads (kit #125, H1).
    package let validated: ValidatedTheme?

    /// `package`, not `public`: kit 0.5.4 had no public initializer for `PreviewTheme` (every
    /// instance was one of the four `static let`s below), and this slice adds no public API
    /// (verifier finding, kit #127 review). Nothing outside the module constructs a `PreviewTheme`
    /// directly.
    package init(id: String, name: String, summary: String, fontDesign: FontDesign, light: Palette, dark: Palette) {
        self.init(id: id, name: name, summary: summary, fontDesign: fontDesign, light: light, dark: dark, style: nil)
    }

    /// The lowest entry point: anything in the package can hand it any strings. It validates what
    /// it was given (as a `notes-sharing` theme, the scenario with no threshold beyond the pairs
    /// every theme must pass), so a hostile palette, id or style here still reaches no stylesheet.
    package init(id: String, name: String, summary: String, fontDesign: FontDesign, light: Palette, dark: Palette, style: ThemeStyle?) {
        let document = ThemeDocument(
            id: id, version: "1.0.0", name: LocalizedText(en: name), summary: LocalizedText(en: summary),
            fontDesign: ThemeFontDesign(rawValue: fontDesign.rawValue) ?? .sans, scenarios: [.notesSharing],
            light: ThemeColors(light), dark: ThemeColors(dark), style: style
        )
        self.init(id: id, name: name, summary: summary, fontDesign: fontDesign, light: light, dark: dark, style: style,
                  validated: ThemeValidator.validate(document).theme)
    }

    private init(id: String, name: String, summary: String, fontDesign: FontDesign, light: Palette, dark: Palette, style: ThemeStyle?, validated: ValidatedTheme?) {
        self.id = id
        self.name = name
        self.summary = summary
        self.fontDesign = fontDesign
        self.light = light
        self.dark = dark
        self.style = style
        self.validated = validated
    }

    public func palette(dark isDark: Bool) -> Palette {
        isDark ? dark : light
    }

    public static let defaultID = "dawn"

    /// The theme with `id` in the process's `ThemeRegistry`, or Dawn.
    public static func named(_ id: String?) -> PreviewTheme {
        ThemeRegistry.current.snapshot.named(id)
    }

    /// Every theme in the process's `ThemeRegistry` (kit #126): the four built-ins in their fixed
    /// order, then any installed themes the host has loaded. Just the built-ins until
    /// `ThemeRegistry.shared.loadInstalled(from:revokedIDs:revokedAuthors:)` is called.
    public static var all: [PreviewTheme] { ThemeRegistry.current.snapshot.themes }
}

// MARK: - Built-in themes

private let builtInLog = Logger(subsystem: "dev.southern-light.marsdawn-kit", category: "PreviewTheme")

public extension PreviewTheme {
    /// Decodes and validates a built-in's bundled `theme.json` (kit #124, #125), naming it from
    /// the kit's own string table by its id (design §4.2: "Built-in themes keep their
    /// string-table localizations"). `nil` on any failure -- a damaged bundle, not a bad theme --
    /// which the caller logs and falls back from.
    private static func decodedBuiltIn(id: String) -> PreviewTheme? {
        guard let document = try? ThemeDocumentLoader.loadBuiltIn(id: id),
              let validated = ThemeValidator.validate(document).theme
        else { return nil }
        return PreviewTheme(validated: validated)
    }

    static let dawn: PreviewTheme = {
        guard let theme = decodedBuiltIn(id: "dawn") else {
            builtInLog.fault("THEME-DECODE-FAILED: dawn/theme.json didn't decode or validate; using the compiled-in fallback")
            return compiledDawn
        }
        return theme
    }()

    static let classic: PreviewTheme = {
        guard let theme = decodedBuiltIn(id: "classic") else {
            builtInLog.fault("THEME-DECODE-FAILED: classic/theme.json didn't decode or validate; falling back to dawn")
            return dawn
        }
        return theme
    }()

    static let modern: PreviewTheme = {
        guard let theme = decodedBuiltIn(id: "modern") else {
            builtInLog.fault("THEME-DECODE-FAILED: modern/theme.json didn't decode or validate; falling back to dawn")
            return dawn
        }
        return theme
    }()

    static let vivid: PreviewTheme = {
        guard let theme = decodedBuiltIn(id: "vivid") else {
            builtInLog.fault("THEME-DECODE-FAILED: vivid/theme.json didn't decode or validate; falling back to dawn")
            return dawn
        }
        return theme
    }()

    /// The compiled-in Dawn, kit `0.5.4`'s Swift constants, kept only as the last-resort fallback
    /// if the bundled `Themes/dawn/theme.json` can't be decoded. `PreviewThemeDecodingTests`
    /// asserts this equals the decoded `dawn/theme.json`, so the two can't silently drift apart.
    static let compiledDawn = PreviewTheme(
        id: "dawn",
        name: String(localized: "Dawn", bundle: .module),
        summary: String(localized: "Warm Martian sunrise", bundle: .module),
        fontDesign: .sans,
        light: Palette(
            background: "#FFFDFB", surface: "#F6F0EC", text: "#26211F", muted: "#6F6660",
            border: "#EADFD8", heading: "#26211F", accent: "#C8471B", link: "#B03C0C", quote: "#D97A4A",
            syntax: Syntax(keyword: "#B03C0C", string: "#2F6F5E", comment: "#746B66", number: "#9A5B00", function: "#5B3E8C", type: "#1F6FB2"),
            diagram: Diagram(node: "#FBE9E0", nodeBorder: "#CA6C3C", text: "#26211F", line: "#8A6A5C", secondary: "#E6F1EE", tertiary: "#FFF6F1", note: "#FFF1D6")
        ),
        dark: Palette(
            background: "#1C1A1F", surface: "#262229", text: "#EBE4DF", muted: "#A39992",
            border: "#3A343A", heading: "#F4EEEA", accent: "#FF8A50", link: "#FF9E6B", quote: "#E08A5C",
            syntax: Syntax(keyword: "#FF9E6B", string: "#7FD1B9", comment: "#938A84", number: "#F2C572", function: "#C7A6F5", type: "#6CB6FF"),
            diagram: Diagram(node: "#3A2A26", nodeBorder: "#E08A5C", text: "#EBE4DF", line: "#B8A69C", secondary: "#23332F", tertiary: "#2B2427", note: "#3D3322")
        ),
        // Dawn's only per-theme rule (kit 30d323c, preview.css line 378): a 1px accent-coloured
        // `hr`. Hard-coded here, independent of the bundle, matching `dawn/theme.json`'s own
        // `style.hr` -- `PreviewThemeDecodingTests` checks the two can't drift apart.
        style: ThemeStyle(hr: ThemeStyle.Hr(style: .line(color: .accent, thickness: 1)))
    )
}

// MARK: - Mapping from the schema type (MarsDawnThemes.ThemeDocument)

package extension PreviewTheme {
    /// Builds a `PreviewTheme` from a decoded `theme.json`, keeping the caller's own name and
    /// summary rather than the file's `name`/`summary` fields. Validates the document; a failure
    /// leaves `validated` nil, so the theme draws nothing.
    init(document: ThemeDocument, name: String, summary: String) {
        let validated = ThemeValidator.validate(document).theme
        self.init(
            id: document.id,
            name: name,
            summary: summary,
            fontDesign: FontDesign(rawValue: document.fontDesign.rawValue) ?? .sans,
            light: validated.map { Palette($0.light) } ?? Palette(document.light),
            dark: validated.map { Palette($0.dark) } ?? Palette(document.dark),
            style: validated?.document.style ?? document.style,
            validated: validated
        )
    }

    /// Builds a `PreviewTheme` from a theme that passed the validator (kit #125). Its display name
    /// and summary follow L1: a built-in is named from the kit's string table **by its id**, and
    /// any other theme shows its own `name`/`summary` verbatim -- never passed through a string
    /// table, where a name that happens to equal a key (`"Dawn"`) would be translated and one
    /// like `"%@ %n"` would be read as a format. `localization` picks the language (e.g.
    /// `"zh-Hant"`); nil means the process's own.
    init(validated: ValidatedTheme, localization: String? = nil) {
        let strings = Self.displayStrings(for: validated.document, localization: localization)
        self.init(
            id: validated.id,
            name: strings.name,
            summary: strings.summary,
            fontDesign: FontDesign(rawValue: validated.document.fontDesign.rawValue) ?? .sans,
            light: Palette(validated.light),
            dark: Palette(validated.dark),
            style: validated.document.style,
            validated: validated
        )
    }

    /// L1: the name and summary a theme is shown with.
    static func displayStrings(for document: ThemeDocument, localization: String?) -> (name: String, summary: String) {
        if let keys = builtInStringKeys[document.id] {
            return (localizedBuiltIn(keys.name, localization: localization), localizedBuiltIn(keys.summary, localization: localization))
        }
        let language = localization ?? Locale.preferredLanguages.first ?? "en"
        func pick(_ text: LocalizedText) -> String {
            text[language] ?? text[String(language.prefix { $0 != "-" })] ?? text.en
        }
        return (pick(document.name), pick(document.summary))
    }

    /// The string-table keys of the four built-ins, looked up by id only. Literal keys, so the
    /// kit's localization coverage test sees them.
    private static let builtInStringKeys: [String: (name: String.LocalizationValue, summary: String.LocalizationValue)] = [
        "dawn": ("Dawn", "Warm Martian sunrise"),
        "classic": ("Classic", "Elegant serif on paper"),
        "modern": ("Modern", "Clean and familiar"),
        "vivid": ("Vivid", "Playful, bright and rounded"),
    ]

    /// `String(localized:bundle:locale:)` ignores `locale:` for a package's resource bundle, so an
    /// explicit localization reads that `.lproj` directly (as `PreviewWebView.moduleLocalizedString`
    /// does for the tests).
    private static func localizedBuiltIn(_ key: String.LocalizationValue, localization: String?) -> String {
        guard let localization,
              let folder = Bundle.module.localizations.first(where: { $0.caseInsensitiveCompare(localization) == .orderedSame }),
              let path = Bundle.module.path(forResource: folder, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return String(localized: key, bundle: .module) }
        return String(localized: key, bundle: bundle)
    }
}

public extension PreviewTheme {
    /// The display-string rules themes are held to (kit #125, L1), for the app to apply to any text
    /// it shows from a theme: the string normalised to NFC, or nil if it is empty, longer than
    /// `limit` scalars, or contains a control, line-break, bidirectional-control or invisible
    /// format character, a run of more than three combining marks, or a link. Show the result with
    /// `Text(verbatim:)`, never as a localization key.
    static func acceptedDisplayString(_ text: String, limit: Int = 48) -> String? {
        let (normalized, problems) = ThemeDisplayText.check(text, limit: limit)
        return problems.isEmpty ? normalized : nil
    }
}

private extension ThemeColors {
    init(_ palette: PreviewTheme.Palette) {
        self.init(
            background: palette.background, surface: palette.surface, text: palette.text, muted: palette.muted,
            border: palette.border, heading: palette.heading, accent: palette.accent, link: palette.link, quote: palette.quote,
            syntax: ThemeSyntaxColors(keyword: palette.syntax.keyword, string: palette.syntax.string, comment: palette.syntax.comment,
                                      number: palette.syntax.number, function: palette.syntax.function, type: palette.syntax.type),
            diagram: ThemeDiagramColors(node: palette.diagram.node, nodeBorder: palette.diagram.nodeBorder, text: palette.diagram.text,
                                        line: palette.diagram.line, secondary: palette.diagram.secondary,
                                        tertiary: palette.diagram.tertiary, note: palette.diagram.note)
        )
    }
}

private extension PreviewTheme.Palette {
    init(_ palette: ResolvedPalette) {
        self.init(
            background: palette.background, surface: palette.surface, text: palette.text, muted: palette.muted,
            border: palette.border, heading: palette.heading, accent: palette.accent, link: palette.link, quote: palette.quote,
            syntax: PreviewTheme.Syntax(palette.syntax), diagram: PreviewTheme.Diagram(palette.diagram)
        )
    }
}

private extension PreviewTheme.Palette {
    /// `ThemeColors.syntax`/`.diagram` are optional in the schema (a submitted theme may omit
    /// them, design §4.2); the kit's own built-ins always carry both, so a missing one here means
    /// a damaged bundled `theme.json`, not a submitter's choice -- `PreviewTheme.decodedBuiltIn`
    /// already treats a decode failure as "use the fallback", so this only needs to not crash.
    init(_ colors: ThemeColors) {
        self.init(
            background: colors.background, surface: colors.surface, text: colors.text, muted: colors.muted,
            border: colors.border, heading: colors.heading, accent: colors.accent, link: colors.link, quote: colors.quote,
            syntax: colors.syntax.map(PreviewTheme.Syntax.init) ?? PreviewTheme.Syntax(keyword: colors.text, string: colors.text, comment: colors.muted, number: colors.text, function: colors.text, type: colors.text),
            diagram: colors.diagram.map(PreviewTheme.Diagram.init) ?? PreviewTheme.Diagram(node: colors.surface, nodeBorder: colors.border, text: colors.text, line: colors.border, secondary: colors.surface, tertiary: colors.background, note: colors.surface)
        )
    }
}

private extension PreviewTheme.Syntax {
    init(_ syntax: ThemeSyntaxColors) {
        self.init(keyword: syntax.keyword, string: syntax.string, comment: syntax.comment, number: syntax.number, function: syntax.function, type: syntax.type)
    }
}

private extension PreviewTheme.Diagram {
    init(_ diagram: ThemeDiagramColors) {
        self.init(node: diagram.node, nodeBorder: diagram.nodeBorder, text: diagram.text, line: diagram.line, secondary: diagram.secondary, tertiary: diagram.tertiary, note: diagram.note)
    }
}

// MARK: - Stylesheet

public extension PreviewTheme {
    var bodyFontStack: String {
        (ThemeFontDesign(rawValue: fontDesign.rawValue) ?? .sans).cssFontStack
    }

    /// CSS custom properties for every theme in `all`, keyed by `data-theme` and colour scheme,
    /// generated once per registry snapshot (kit #126). Palette
    /// variables only (kit #124): per-theme style rules are generated separately by
    /// `ThemeCSSGenerator` and spliced into `preview.css` by `PreviewSchemeHandler`, not into this
    /// stylesheet, so they keep the exact cascade position the hand-written rules had.
    static var stylesheet: String {
        ThemeRegistry.current.snapshot.variablesCSS
    }
}

// MARK: - Per-theme style CSS (kit #124)

private let stylesheetLog = Logger(subsystem: "dev.southern-light.marsdawn-kit", category: "PreviewTheme")

package extension PreviewTheme {
    /// The generated per-theme rules for every built-in, in `PreviewTheme.all` order, joined --
    /// what `PreviewSchemeHandler` splices into `preview.css` at the removed blocks' old position.
    static var generatedStyleCSS: String {
        ThemeRegistry.current.snapshot.rulesCSS
    }

    /// `themes.css` for `themes`: each theme's palette block, generated from its `ValidatedTheme`
    /// only. A theme that failed validation, that the generator refuses, or whose id an earlier
    /// theme in the list already has, is left out entirely (kit #125, H1/M3).
    static func stylesheet(for themes: [PreviewTheme]) -> String {
        accepted(themes).compactMap { theme -> String? in
            do throws(ThemeCSSGenerator.Refusal) {
                return try ThemeCSSGenerator.variables(for: theme)
            } catch {
                stylesheetLog.fault("THEME-REFUSED: the generator refused a validated theme's palette (\(error.description, privacy: .public))")
                return nil
            }
        }.joined(separator: "\n")
    }

    /// The per-theme rules for `themes`, under the same rules as `stylesheet(for:)`.
    static func generatedStyleCSS(for themes: [PreviewTheme]) -> String {
        accepted(themes).compactMap { theme -> String? in
            do throws(ThemeCSSGenerator.Refusal) {
                return try ThemeCSSGenerator.rules(for: theme).css
            } catch {
                stylesheetLog.fault("THEME-REFUSED: the generator refused a validated theme's rules (\(error.description, privacy: .public))")
                return nil
            }
        }.joined()
    }

    /// The validated themes of `themes`, first occurrence of each id only.
    private static func accepted(_ themes: [PreviewTheme]) -> [ValidatedTheme] {
        var seen = Set<String>()
        var out: [ValidatedTheme] = []
        for theme in themes {
            guard let validated = theme.validated else {
                stylesheetLog.error("THEME-REFUSED: a theme failed validation and is left out of the stylesheet")
                continue
            }
            guard seen.insert(validated.id).inserted else {
                stylesheetLog.error("THEME-REFUSED: a second theme with the same id is left out of the stylesheet")
                continue
            }
            out.append(validated)
        }
        return out
    }
}
