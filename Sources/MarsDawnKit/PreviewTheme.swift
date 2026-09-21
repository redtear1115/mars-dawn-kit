import Foundation

/// A preview style: typography plus a light and a dark palette.
///
/// This is the single source of truth for theme colours. The preview page's
/// `themes.css` is generated from it, and native UI (settings swatches, editor
/// colours) reads the same values.
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

public extension PreviewTheme {
    static let dawn = PreviewTheme(
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
        )
    )

    static let classic = PreviewTheme(
        id: "classic",
        name: String(localized: "Classic", bundle: .module),
        summary: String(localized: "Elegant serif on paper", bundle: .module),
        fontDesign: .serif,
        light: Palette(
            background: "#FCFCFB", surface: "#F2F2F0", text: "#1C1C1C", muted: "#5E5E5E",
            border: "#DDDDDB", heading: "#111111", accent: "#2E2E2E", link: "#1C1C1C", quote: "#8C8C8C",
            syntax: Syntax(keyword: "#1C1C1C", string: "#4D4D4D", comment: "#6A6A6A", number: "#3A3A3A", function: "#1C1C1C", type: "#3A3A3A"),
            diagram: Diagram(node: "#F2F2F0", nodeBorder: "#5E5E5E", text: "#1C1C1C", line: "#6A6A6A", secondary: "#EAEAE8", tertiary: "#FCFCFB", note: "#F6F6F3")
        ),
        dark: Palette(
            background: "#171717", surface: "#222222", text: "#E6E6E6", muted: "#A6A6A6",
            border: "#363636", heading: "#F2F2F2", accent: "#D4D4D4", link: "#EDEDED", quote: "#7C7C7C",
            syntax: Syntax(keyword: "#F2F2F2", string: "#C4C4C4", comment: "#9C9C9C", number: "#D4D4D4", function: "#F2F2F2", type: "#D4D4D4"),
            diagram: Diagram(node: "#262626", nodeBorder: "#A6A6A6", text: "#E6E6E6", line: "#9C9C9C", secondary: "#202020", tertiary: "#1B1B1B", note: "#2B2B2B")
        )
    )

    static let modern = PreviewTheme(
        id: "modern",
        name: String(localized: "Modern", bundle: .module),
        summary: String(localized: "Clean and familiar", bundle: .module),
        fontDesign: .sans,
        light: Palette(
            background: "#FFFFFF", surface: "#F6F8FA", text: "#1F2328", muted: "#59636E",
            border: "#D1D9E0", heading: "#1F2328", accent: "#0969DA", link: "#0969DA", quote: "#8C939A",
            syntax: Syntax(keyword: "#CF222E", string: "#0A3069", comment: "#59636E", number: "#0550AE", function: "#8250DF", type: "#953800"),
            diagram: Diagram(node: "#EEF4FC", nodeBorder: "#0969DA", text: "#1F2328", line: "#59636E", secondary: "#F1ECFB", tertiary: "#F6F8FA", note: "#FFF8C5")
        ),
        dark: Palette(
            background: "#0D1117", surface: "#151B23", text: "#E6EDF3", muted: "#9198A1",
            border: "#30363D", heading: "#F0F6FC", accent: "#4493F8", link: "#4493F8", quote: "#5B636C",
            syntax: Syntax(keyword: "#FF7B72", string: "#A5D6FF", comment: "#9198A1", number: "#79C0FF", function: "#D2A8FF", type: "#FFA657"),
            diagram: Diagram(node: "#172233", nodeBorder: "#4493F8", text: "#E6EDF3", line: "#9198A1", secondary: "#221B33", tertiary: "#151B23", note: "#2E2A12")
        )
    )

    static let vivid = PreviewTheme(
        id: "vivid",
        name: String(localized: "Vivid", bundle: .module),
        summary: String(localized: "Playful, bright and rounded", bundle: .module),
        fontDesign: .rounded,
        light: Palette(
            background: "#FFFDF8", surface: "#F3EEFF", text: "#2D2A32", muted: "#6B6475",
            border: "#E6DCFB", heading: "#5B3BE0", accent: "#D5316B", link: "#087481", quote: "#FFB020",
            syntax: Syntax(keyword: "#B8246A", string: "#07734F", comment: "#70697C", number: "#A44D06", function: "#5B3BE0", type: "#087481"),
            diagram: Diagram(node: "#EFE9FF", nodeBorder: "#6C4BF4", text: "#2D2A32", line: "#E8457A", secondary: "#E0F7F4", tertiary: "#FFF1F6", note: "#FFF1CC")
        ),
        dark: Palette(
            background: "#1A1625", surface: "#251F36", text: "#F1ECFA", muted: "#AFA6BE",
            border: "#3A3150", heading: "#B69CFF", accent: "#FF7AA2", link: "#3DD6D0", quote: "#FFC857",
            syntax: Syntax(keyword: "#FF7AB8", string: "#5BE3A8", comment: "#948BA6", number: "#FFA657", function: "#B69CFF", type: "#3DD6D0"),
            diagram: Diagram(node: "#2E2548", nodeBorder: "#B69CFF", text: "#F1ECFA", line: "#FF7AA2", secondary: "#1D3534", tertiary: "#2A1F2E", note: "#3D3420")
        )
    )
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

    /// CSS custom properties for every theme, keyed by `data-theme` and colour scheme.
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
