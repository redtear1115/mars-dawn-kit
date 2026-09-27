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
/// `ThemeCSSGenerator`, which the app and CLI never call directly, and a later slice replaces it
/// with a validated-theme type before any of this decoding is exposed publicly.
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

    public init(id: String, name: String, summary: String, fontDesign: FontDesign, light: Palette, dark: Palette) {
        self.id = id
        self.name = name
        self.summary = summary
        self.fontDesign = fontDesign
        self.light = light
        self.dark = dark
        self.style = nil
    }

    package init(id: String, name: String, summary: String, fontDesign: FontDesign, light: Palette, dark: Palette, style: ThemeStyle?) {
        self.id = id
        self.name = name
        self.summary = summary
        self.fontDesign = fontDesign
        self.light = light
        self.dark = dark
        self.style = style
    }

    public func palette(dark isDark: Bool) -> Palette {
        isDark ? dark : light
    }

    public static let defaultID = "dawn"

    public static func named(_ id: String?) -> PreviewTheme {
        all.first { $0.id == id } ?? dawn
    }

    public static var all: [PreviewTheme] { [dawn, classic, modern, vivid] }
}

// MARK: - Built-in themes

private let builtInLog = Logger(subsystem: "dev.southern-light.marsdawn-kit", category: "PreviewTheme")

public extension PreviewTheme {
    /// Decodes a built-in's bundled `theme.json` (kit #124), using the kit's own string table for
    /// its localized name and summary (design §4.2: "Built-in themes keep their string-table
    /// localizations"). `nil` on any failure -- a damaged bundle, not a bad theme -- which the
    /// caller logs and falls back from.
    private static func decodedBuiltIn(id: String, name: String, summary: String) -> PreviewTheme? {
        guard let document = try? ThemeDocumentLoader.loadBuiltIn(id: id) else { return nil }
        return PreviewTheme(document: document, name: name, summary: summary)
    }

    static let dawn: PreviewTheme = {
        let name = String(localized: "Dawn", bundle: .module)
        let summary = String(localized: "Warm Martian sunrise", bundle: .module)
        guard let theme = decodedBuiltIn(id: "dawn", name: name, summary: summary) else {
            builtInLog.fault("THEME-DECODE-FAILED: dawn/theme.json didn't decode; using the compiled-in fallback")
            return compiledDawn
        }
        return theme
    }()

    static let classic: PreviewTheme = {
        let name = String(localized: "Classic", bundle: .module)
        let summary = String(localized: "Elegant serif on paper", bundle: .module)
        guard let theme = decodedBuiltIn(id: "classic", name: name, summary: summary) else {
            builtInLog.fault("THEME-DECODE-FAILED: classic/theme.json didn't decode; falling back to dawn")
            return dawn
        }
        return theme
    }()

    static let modern: PreviewTheme = {
        let name = String(localized: "Modern", bundle: .module)
        let summary = String(localized: "Clean and familiar", bundle: .module)
        guard let theme = decodedBuiltIn(id: "modern", name: name, summary: summary) else {
            builtInLog.fault("THEME-DECODE-FAILED: modern/theme.json didn't decode; falling back to dawn")
            return dawn
        }
        return theme
    }()

    static let vivid: PreviewTheme = {
        let name = String(localized: "Vivid", bundle: .module)
        let summary = String(localized: "Playful, bright and rounded", bundle: .module)
        guard let theme = decodedBuiltIn(id: "vivid", name: name, summary: summary) else {
            builtInLog.fault("THEME-DECODE-FAILED: vivid/theme.json didn't decode; falling back to dawn")
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
    /// Builds a `PreviewTheme` from a decoded `theme.json`, keeping the caller's own (string-table)
    /// name and summary for a built-in rather than the file's `name`/`summary` fields.
    init(document: ThemeDocument, name: String, summary: String) {
        self.init(
            id: document.id,
            name: name,
            summary: summary,
            fontDesign: FontDesign(rawValue: document.fontDesign.rawValue) ?? .sans,
            light: Palette(document.light),
            dark: Palette(document.dark),
            style: document.style
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
        switch fontDesign {
        case .sans: #"-apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang TC", "PingFang SC", sans-serif"#
        case .serif: #"ui-serif, "New York", Georgia, "Songti TC", "Songti SC", serif"#
        case .rounded: #"ui-rounded, "SF Pro Rounded", -apple-system, "PingFang TC", "PingFang SC", sans-serif"#
        }
    }

    /// CSS custom properties for every theme, keyed by `data-theme` and colour scheme. Palette
    /// variables only (kit #124): per-theme style rules are generated separately by
    /// `ThemeCSSGenerator` and spliced into `preview.css` by `PreviewSchemeHandler`, not into this
    /// stylesheet, so they keep the exact cascade position the hand-written rules had.
    static var stylesheet: String {
        all.map(\.css).joined(separator: "\n")
    }

    private var css: String {
        """
        :root[data-theme="\(id)"] {
        \(Self.variables(light, fonts: bodyFontStack))
        }
        @media (prefers-color-scheme: dark) {
          :root[data-theme="\(id)"] {
        \(Self.variables(dark, fonts: nil))
          }
        }
        """
    }

    private static func variables(_ p: Palette, fonts: String?) -> String {
        var pairs: [(String, String)] = [
            ("bg", p.background), ("surface", p.surface), ("fg", p.text), ("muted", p.muted),
            ("border", p.border), ("heading", p.heading), ("accent", p.accent), ("link", p.link),
            ("quote", p.quote),
            ("hl-keyword", p.syntax.keyword), ("hl-string", p.syntax.string), ("hl-comment", p.syntax.comment),
            ("hl-number", p.syntax.number), ("hl-function", p.syntax.function), ("hl-type", p.syntax.type),
            ("mm-node", p.diagram.node), ("mm-border", p.diagram.nodeBorder), ("mm-text", p.diagram.text),
            ("mm-line", p.diagram.line), ("mm-secondary", p.diagram.secondary),
            ("mm-tertiary", p.diagram.tertiary), ("mm-note", p.diagram.note),
        ]
        if let fonts { pairs.append(("font-body", fonts)) }
        return pairs.map { "  --\($0.0): \($0.1);" }.joined(separator: "\n")
    }
}

// MARK: - Per-theme style CSS (kit #124)

package extension PreviewTheme {
    /// The generated per-theme rules for every built-in, in `PreviewTheme.all` order, joined --
    /// what `PreviewSchemeHandler` splices into `preview.css` at the removed blocks' old position.
    static var generatedStyleCSS: String {
        all.map { ThemeCSSGenerator.generate(id: $0.id, style: $0.style).css }.joined()
    }
}
