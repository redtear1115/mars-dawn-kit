import Foundation
import Testing
@testable import MarsDawnKit

/// Every colour pair the preview draws meets WCAG 2.x AA (#152): 4.5:1 for text, 3:1 for
/// non-text indicators (list markers, checkboxes, rules, the quote bar, diagram lines and node
/// borders, pie slices), each measured against the background it actually sits on. The app's
/// editor takes its colours from the same palettes, and its own test covers those roles.
///
/// Which variable draws what comes from preview.css and preview.js. The per-theme choices the
/// map depends on are checked against preview.css below, so a stylesheet change that moves a
/// colour onto a different element can't leave this map silently describing the old page.
///
/// Not measured: table grid lines and h1/h2 underlines (`--border`). They're decorative hairlines;
/// the text carries the structure (WCAG 1.4.11), a decision recorded on #152.
struct PreviewThemeContrastTests {
    static let text = 4.5
    static let ui = 3.0

    struct Pair: CustomStringConvertible {
        let theme: String, mode: String, element: String
        let foreground: String, background: String, threshold: Double
        var ratio: Double { Contrast.ratio(foreground, background) }
        var description: String {
            "\(theme) \(mode) \(element): \(foreground) on \(background) = \(String(format: "%.2f", ratio)), needs \(threshold)"
        }
    }

    static func pairs(_ theme: PreviewTheme, dark: Bool) -> [Pair] {
        let p = theme.palette(dark: dark)
        let id = theme.id, mode = dark ? "dark" : "light"
        var out: [Pair] = []
        func add(_ element: String, _ fg: String, _ bg: String, _ threshold: Double) {
            out.append(Pair(theme: id, mode: mode, element: element, foreground: fg, background: bg, threshold: threshold))
        }
        // preview.css: inline code sits on --code-chip, which dark mode lifts toward the text.
        let chip = dark ? Contrast.mix(p.surface, p.text, 0.10) : p.surface
        let frontMatter = Contrast.mix(p.surface, p.background, 0.35)

        add("body text", p.text, p.background, text)
        add("muted text", p.muted, p.background, text)
        add("headings", p.heading, p.background, text)
        add("links", p.link, p.background, text)
        add("inline code", p.text, chip, text)
        if id == "vivid" { add("inline code (coloured)", p.syntax.keyword, chip, text) }
        add("code block text", p.text, p.surface, text)
        for (name, color) in [("keyword", p.syntax.keyword), ("string", p.syntax.string), ("comment", p.syntax.comment),
                              ("number", p.syntax.number), ("function", p.syntax.function), ("type", p.syntax.type),
                              ("meta", p.muted)] {
            add("syntax \(name) in a code block", color, p.surface, text)
        }
        switch id {
        case "classic": add("table header", p.text, p.background, text)
        case "vivid": add("table header", p.background, p.heading, text)
        default: add("table header", p.text, p.surface, text)
        }
        add("table cell", p.text, p.background, text)
        if id == "vivid" { add("blockquote text", p.text, p.surface, text) }
        add("front matter label", p.muted, frontMatter, text)
        add("front matter value", p.text, frontMatter, text)
        add("banner and placeholder text", p.muted, p.surface, text)
        add("banner button", p.background, p.accent, text)
        add("math and diagram errors", p.syntax.keyword, p.background, text)
        for (name, bg) in [("node", p.diagram.node), ("secondary", p.diagram.secondary),
                           ("tertiary", p.diagram.tertiary), ("note", p.diagram.note), ("edge label", p.background)] {
            add("diagram label on \(name)", p.diagram.text, bg, text)
        }
        add("diagram title", p.heading, p.background, text)
        let slices = [p.accent, p.syntax.function, p.syntax.string, p.syntax.number, p.syntax.type, p.link]
        for (index, slice) in slices.enumerated() {
            add("pie slice \(index + 1) label", p.background, slice, text)
            add("pie slice \(index + 1)", slice, p.background, ui)
        }
        if !dark {
            for (name, color) in [("text", p.text), ("muted", p.muted), ("headings", p.heading), ("links", p.link)] {
                add("PDF \(name) on white paper", color, "#FFFFFF", text)
            }
        }

        add("list marker", id == "modern" ? p.muted : p.accent, p.background, ui)
        add("task checkbox", p.accent, p.background, ui)
        if id != "vivid" { add("blockquote bar", p.quote, p.background, ui) }
        switch id {
        case "vivid":
            for (name, color) in [("accent", p.accent), ("heading", p.heading), ("link", p.link)] {
                add("rule gradient stop \(name)", color, p.background, ui)
            }
        case "modern": add("rule", p.quote, p.background, ui)
        default: add("rule", p.accent, p.background, ui)
        }
        add("diagram lines", p.diagram.line, p.background, ui)
        add("diagram node border", p.diagram.nodeBorder, p.diagram.node, ui)
        return out
    }

    static var allPairs: [Pair] {
        PreviewTheme.all.flatMap { pairs($0, dark: false) + pairs($0, dark: true) }
    }

    @Test func everyPairMeetsAA() {
        let pairs = Self.allPairs
        #expect(pairs.count >= 370, "positive fixture: the map covers every theme and element (374 today)")
        let failing = pairs.filter { $0.ratio < $0.threshold }
        #expect(failing.isEmpty, "below WCAG AA:\n\(failing.map(\.description).joined(separator: "\n"))")
    }

    /// The instrument itself: known reference values, and a pair below each threshold fails.
    @Test func contrastMatchesTheWCAGFormula() {
        #expect(abs(Contrast.ratio("#000000", "#FFFFFF") - 21) < 0.001)
        #expect(abs(Contrast.ratio("#767676", "#FFFFFF") - 4.54) < 0.01)
        #expect(Contrast.ratio("#777777", "#FFFFFF") < Self.text)
        #expect(Contrast.ratio("#FFFFFF", "#767676") == Contrast.ratio("#767676", "#FFFFFF"))
        #expect(Contrast.mix("#000000", "#FFFFFF", 0.5) == "#808080")
    }

    /// The per-theme rules the map above assumes are really in the stylesheet.
    @Test func theMapMatchesPreviewCSS() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.css")
        let css = try String(contentsOf: url, encoding: .utf8)
        for rule in [
            #"[data-theme="dawn"] hr { height: 1px; background: var(--accent); }"#,
            #"[data-theme="modern"] hr { background: var(--quote); }"#,
            #"[data-theme="classic"] hr { height: 1px; width: 30%; margin: 2.4em auto; background: var(--accent); }"#,
            #"[data-theme="modern"] li::marker { color: var(--muted); }"#,
            #"[data-theme="vivid"] th { background: var(--heading); color: var(--bg); border-color: var(--heading); }"#,
            #"[data-theme="vivid"] code:not(pre code) { color: var(--hl-keyword); }"#,
            #"li::marker { color: var(--accent); }"#,
            "--code-chip: color-mix(in srgb, var(--surface), var(--fg) 10%);",
            "background: color-mix(in srgb, var(--surface), var(--bg) 35%);",
        ] {
            #expect(css.contains(rule), "preview.css no longer has: \(rule)")
        }
    }
}

/// WCAG 2.x contrast from sRGB hex colours.
enum Contrast {
    static func components(_ hex: String) -> [Double] {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)].map { $0 / 255 }
    }

    static func luminance(_ hex: String) -> Double {
        let linear = components(hex).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    static func ratio(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `color-mix(in srgb, a, b amount)`: interpolation of the gamma-encoded components.
    static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        let mixed = zip(components(a), components(b)).map { ($0 * (1 - amount) + $1 * amount) * 255 }
        return String(format: "#%02X%02X%02X", Int(mixed[0].rounded()), Int(mixed[1].rounded()), Int(mixed[2].rounded()))
    }
}
