import Foundation

/// The closed set of style options a theme can set (design §4.3), replacing free-form
/// `theme.css`. Every field is optional; `nil` means "use the default", which is Dawn's look.
/// Ranges and enum vocabularies are enforced by the validator (#125), not here: this type only
/// says what shape a `theme.json`'s `style` object has, and strictly rejects any other shape.
package struct ThemeStyle: Codable, Hashable, Sendable {
    package var bodySize: Double?
    package var lineHeight: Double?
    package var headingWeight: Double?
    package var radius: Double?
    package var maxWidth: Double?
    package var h1: H1?
    package var h2: H2?
    package var blockquote: Blockquote?
    package var hr: Hr?
    package var table: Table?
    package var listMarker: PaletteRole?
    package var inlineCode: PaletteRole?
    package var link: LinkOptions?
    package var syntax: SyntaxOptions?

    package init(
        bodySize: Double? = nil, lineHeight: Double? = nil, headingWeight: Double? = nil,
        radius: Double? = nil, maxWidth: Double? = nil, h1: H1? = nil, h2: H2? = nil,
        blockquote: Blockquote? = nil, hr: Hr? = nil, table: Table? = nil,
        listMarker: PaletteRole? = nil, inlineCode: PaletteRole? = nil,
        link: LinkOptions? = nil, syntax: SyntaxOptions? = nil
    ) {
        self.bodySize = bodySize
        self.lineHeight = lineHeight
        self.headingWeight = headingWeight
        self.radius = radius
        self.maxWidth = maxWidth
        self.h1 = h1
        self.h2 = h2
        self.blockquote = blockquote
        self.hr = hr
        self.table = table
        self.listMarker = listMarker
        self.inlineCode = inlineCode
        self.link = link
        self.syntax = syntax
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case bodySize, lineHeight, headingWeight, radius, maxWidth, h1, h2, blockquote, hr, table
        case listMarker, inlineCode, link, syntax
    }

    package init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bodySize = try c.decodeIfPresent(Double.self, forKey: .bodySize)
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight)
        headingWeight = try c.decodeIfPresent(Double.self, forKey: .headingWeight)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth)
        h1 = try c.decodeIfPresent(H1.self, forKey: .h1)
        h2 = try c.decodeIfPresent(H2.self, forKey: .h2)
        blockquote = try c.decodeIfPresent(Blockquote.self, forKey: .blockquote)
        hr = try c.decodeIfPresent(Hr.self, forKey: .hr)
        table = try c.decodeIfPresent(Table.self, forKey: .table)
        listMarker = try c.decodeIfPresent(PaletteRole.self, forKey: .listMarker)
        inlineCode = try c.decodeIfPresent(PaletteRole.self, forKey: .inlineCode)
        link = try c.decodeIfPresent(LinkOptions.self, forKey: .link)
        syntax = try c.decodeIfPresent(SyntaxOptions.self, forKey: .syntax)
    }

    // MARK: - Nested option groups

    package struct H1: Codable, Hashable, Sendable {
        package var size: Double?
        package var letterSpacing: Double?
        package var align: Align?
        package var decoration: H1Decoration?

        package init(size: Double? = nil, letterSpacing: Double? = nil, align: Align? = nil, decoration: H1Decoration? = nil) {
            self.size = size; self.letterSpacing = letterSpacing; self.align = align; self.decoration = decoration
        }

        package enum Align: String, Codable, Sendable { case left, center }

        enum CodingKeys: String, CodingKey, CaseIterable { case size, letterSpacing, align, decoration }

        package init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            size = try c.decodeIfPresent(Double.self, forKey: .size)
            letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing)
            align = try c.decodeIfPresent(Align.self, forKey: .align)
            decoration = try c.decodeIfPresent(H1Decoration.self, forKey: .decoration)
        }
    }

    package struct H2: Codable, Hashable, Sendable {
        package var letterSpacing: Double?
        package var decoration: H2Decoration?
        package var italic: Bool?

        package init(letterSpacing: Double? = nil, decoration: H2Decoration? = nil, italic: Bool? = nil) {
            self.letterSpacing = letterSpacing; self.decoration = decoration; self.italic = italic
        }

        enum CodingKeys: String, CodingKey, CaseIterable { case letterSpacing, decoration, italic }

        package init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing)
            decoration = try c.decodeIfPresent(H2Decoration.self, forKey: .decoration)
            italic = try c.decodeIfPresent(Bool.self, forKey: .italic)
        }
    }

    /// `{"type": "rule"}` / `{"type": "none"}` / `{"type": "shortRule", "color": role}` /
    /// `{"type": "gradientBar", "from": role, "to": role}`.
    package enum H1Decoration: Hashable, Sendable {
        case rule
        case none
        case shortRule(color: PaletteRole)
        case gradientBar(from: PaletteRole, to: PaletteRole)
    }

    /// `{"type": "rule"}` / `{"type": "none"}` / `{"type": "dot", "color": role}`.
    package enum H2Decoration: Hashable, Sendable {
        case rule
        case none
        case dot(color: PaletteRole)
    }

    package struct Blockquote: Codable, Hashable, Sendable {
        package var style: BlockquoteStyle?
        package var italic: Bool?

        package init(style: BlockquoteStyle? = nil, italic: Bool? = nil) {
            self.style = style; self.italic = italic
        }

        enum CodingKeys: String, CodingKey, CaseIterable { case style, italic }

        package init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            style = try c.decodeIfPresent(BlockquoteStyle.self, forKey: .style)
            italic = try c.decodeIfPresent(Bool.self, forKey: .italic)
        }
    }

    /// `{"type": "bar", "width": 2}` (width optional, defaults to 3) / `{"type": "panel"}`.
    package enum BlockquoteStyle: Hashable, Sendable {
        case bar(width: Double?)
        case panel
    }

    package struct Hr: Codable, Hashable, Sendable {
        package var style: HrStyle?

        package init(style: HrStyle? = nil) { self.style = style }

        enum CodingKeys: String, CodingKey, CaseIterable { case style }

        package init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            style = try c.decodeIfPresent(HrStyle.self, forKey: .style)
        }
    }

    /// `{"type": "line", "color": role, "thickness": 2}` (both optional: default `border`/2px) /
    /// `{"type": "shortCentered", "color": role}` / `{"type": "gradient", "colors": [role, role, role]}`.
    package enum HrStyle: Hashable, Sendable {
        case line(color: PaletteRole?, thickness: Double?)
        case shortCentered(color: PaletteRole)
        case gradient(colors: [PaletteRole])
    }

    package struct Table: Codable, Hashable, Sendable {
        package var header: TableHeader?
        package var verticalRules: Bool?
        package var rounded: Bool?

        package init(header: TableHeader? = nil, verticalRules: Bool? = nil, rounded: Bool? = nil) {
            self.header = header; self.verticalRules = verticalRules; self.rounded = rounded
        }

        enum CodingKeys: String, CodingKey, CaseIterable { case header, verticalRules, rounded }

        package init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            header = try c.decodeIfPresent(TableHeader.self, forKey: .header)
            verticalRules = try c.decodeIfPresent(Bool.self, forKey: .verticalRules)
            rounded = try c.decodeIfPresent(Bool.self, forKey: .rounded)
        }
    }

    /// `{"type": "surface"}` / `{"type": "accentRule", "color": role}` /
    /// `{"type": "filled", "background": role, "text": role, "border": role}` (`border` optional,
    /// defaults to `background` -- kit #124 review: Vivid's `filled` also sets `border-color`).
    package enum TableHeader: Hashable, Sendable {
        case surface
        case accentRule(color: PaletteRole)
        case filled(background: PaletteRole, text: PaletteRole, border: PaletteRole?)
    }

    package struct LinkOptions: Codable, Hashable, Sendable {
        package var underline: Bool?
        package init(underline: Bool? = nil) { self.underline = underline }
        enum CodingKeys: String, CodingKey, CaseIterable { case underline }
        package init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
            underline = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .underline)
        }
    }

    package struct SyntaxOptions: Codable, Hashable, Sendable {
        package var boldKeywords: Bool?
        package init(boldKeywords: Bool? = nil) { self.boldKeywords = boldKeywords }
        enum CodingKeys: String, CodingKey, CaseIterable { case boldKeywords }
        package init(from decoder: Decoder) throws {
            try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
            boldKeywords = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .boldKeywords)
        }
    }
}

// MARK: - Codable for the "type"-discriminated enums

extension ThemeStyle.H1Decoration: Codable {
    private enum Kind: String, Codable { case rule, none, shortRule, gradientBar }
    private enum Key: String, CodingKey { case type, color, from, to }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .rule:
            try rejectUnknownKeys(decoder, allowed: ["type"])
            self = .rule
        case .none:
            try rejectUnknownKeys(decoder, allowed: ["type"])
            self = .none
        case .shortRule:
            try rejectUnknownKeys(decoder, allowed: ["type", "color"])
            self = .shortRule(color: try c.decode(PaletteRole.self, forKey: .color))
        case .gradientBar:
            try rejectUnknownKeys(decoder, allowed: ["type", "from", "to"])
            self = .gradientBar(from: try c.decode(PaletteRole.self, forKey: .from), to: try c.decode(PaletteRole.self, forKey: .to))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .rule: try c.encode(Kind.rule, forKey: .type)
        case .none: try c.encode(Kind.none, forKey: .type)
        case .shortRule(let color):
            try c.encode(Kind.shortRule, forKey: .type)
            try c.encode(color, forKey: .color)
        case .gradientBar(let from, let to):
            try c.encode(Kind.gradientBar, forKey: .type)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        }
    }
}

extension ThemeStyle.H2Decoration: Codable {
    private enum Kind: String, Codable { case rule, none, dot }
    private enum Key: String, CodingKey { case type, color }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .rule:
            try rejectUnknownKeys(decoder, allowed: ["type"])
            self = .rule
        case .none:
            try rejectUnknownKeys(decoder, allowed: ["type"])
            self = .none
        case .dot:
            try rejectUnknownKeys(decoder, allowed: ["type", "color"])
            self = .dot(color: try c.decode(PaletteRole.self, forKey: .color))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .rule: try c.encode(Kind.rule, forKey: .type)
        case .none: try c.encode(Kind.none, forKey: .type)
        case .dot(let color):
            try c.encode(Kind.dot, forKey: .type)
            try c.encode(color, forKey: .color)
        }
    }
}

extension ThemeStyle.BlockquoteStyle: Codable {
    private enum Kind: String, Codable { case bar, panel }
    private enum Key: String, CodingKey { case type, width }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .bar:
            try rejectUnknownKeys(decoder, allowed: ["type", "width"])
            self = .bar(width: try c.decodeIfPresent(Double.self, forKey: .width))
        case .panel:
            try rejectUnknownKeys(decoder, allowed: ["type"])
            self = .panel
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .bar(let width):
            try c.encode(Kind.bar, forKey: .type)
            try c.encodeIfPresent(width, forKey: .width)
        case .panel: try c.encode(Kind.panel, forKey: .type)
        }
    }
}

extension ThemeStyle.HrStyle: Codable {
    private enum Kind: String, Codable { case line, shortCentered, gradient }
    private enum Key: String, CodingKey { case type, color, thickness, colors }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .line:
            try rejectUnknownKeys(decoder, allowed: ["type", "color", "thickness"])
            self = .line(color: try c.decodeIfPresent(PaletteRole.self, forKey: .color), thickness: try c.decodeIfPresent(Double.self, forKey: .thickness))
        case .shortCentered:
            try rejectUnknownKeys(decoder, allowed: ["type", "color"])
            self = .shortCentered(color: try c.decode(PaletteRole.self, forKey: .color))
        case .gradient:
            try rejectUnknownKeys(decoder, allowed: ["type", "colors"])
            self = .gradient(colors: try c.decode([PaletteRole].self, forKey: .colors))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .line(let color, let thickness):
            try c.encode(Kind.line, forKey: .type)
            try c.encodeIfPresent(color, forKey: .color)
            try c.encodeIfPresent(thickness, forKey: .thickness)
        case .shortCentered(let color):
            try c.encode(Kind.shortCentered, forKey: .type)
            try c.encode(color, forKey: .color)
        case .gradient(let colors):
            try c.encode(Kind.gradient, forKey: .type)
            try c.encode(colors, forKey: .colors)
        }
    }
}

extension ThemeStyle.TableHeader: Codable {
    private enum Kind: String, Codable { case surface, accentRule, filled }
    private enum Key: String, CodingKey { case type, color, background, text, border }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .surface:
            try rejectUnknownKeys(decoder, allowed: ["type"])
            self = .surface
        case .accentRule:
            try rejectUnknownKeys(decoder, allowed: ["type", "color"])
            self = .accentRule(color: try c.decode(PaletteRole.self, forKey: .color))
        case .filled:
            try rejectUnknownKeys(decoder, allowed: ["type", "background", "text", "border"])
            self = .filled(
                background: try c.decode(PaletteRole.self, forKey: .background),
                text: try c.decode(PaletteRole.self, forKey: .text),
                border: try c.decodeIfPresent(PaletteRole.self, forKey: .border)
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .surface: try c.encode(Kind.surface, forKey: .type)
        case .accentRule(let color):
            try c.encode(Kind.accentRule, forKey: .type)
            try c.encode(color, forKey: .color)
        case .filled(let background, let text, let border):
            try c.encode(Kind.filled, forKey: .type)
            try c.encode(background, forKey: .background)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(border, forKey: .border)
        }
    }
}
