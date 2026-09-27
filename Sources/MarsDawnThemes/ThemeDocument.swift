import Foundation

/// A theme's colours: 6-digit hex strings, matching `PreviewTheme.Palette`'s field names and
/// order 1:1 so the Swift model stays the same (design §4.4).
package struct ThemeColors: Codable, Hashable, Sendable {
    package var background: String
    package var surface: String
    package var text: String
    package var muted: String
    package var border: String
    package var heading: String
    package var accent: String
    package var link: String
    package var quote: String
    package var syntax: ThemeSyntaxColors?
    package var diagram: ThemeDiagramColors?

    package init(
        background: String, surface: String, text: String, muted: String, border: String,
        heading: String, accent: String, link: String, quote: String,
        syntax: ThemeSyntaxColors? = nil, diagram: ThemeDiagramColors? = nil
    ) {
        self.background = background; self.surface = surface; self.text = text; self.muted = muted
        self.border = border; self.heading = heading; self.accent = accent; self.link = link
        self.quote = quote; self.syntax = syntax; self.diagram = diagram
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case background, surface, text, muted, border, heading, accent, link, quote, syntax, diagram
    }

    package init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decode(String.self, forKey: .background)
        surface = try c.decode(String.self, forKey: .surface)
        text = try c.decode(String.self, forKey: .text)
        muted = try c.decode(String.self, forKey: .muted)
        border = try c.decode(String.self, forKey: .border)
        heading = try c.decode(String.self, forKey: .heading)
        accent = try c.decode(String.self, forKey: .accent)
        link = try c.decode(String.self, forKey: .link)
        quote = try c.decode(String.self, forKey: .quote)
        syntax = try c.decodeIfPresent(ThemeSyntaxColors.self, forKey: .syntax)
        diagram = try c.decodeIfPresent(ThemeDiagramColors.self, forKey: .diagram)
    }
}

package struct ThemeSyntaxColors: Codable, Hashable, Sendable {
    package var keyword: String
    package var string: String
    package var comment: String
    package var number: String
    package var function: String
    package var type: String

    package init(keyword: String, string: String, comment: String, number: String, function: String, type: String) {
        self.keyword = keyword; self.string = string; self.comment = comment
        self.number = number; self.function = function; self.type = type
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case keyword, string, comment, number, function, type }

    package init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyword = try c.decode(String.self, forKey: .keyword)
        string = try c.decode(String.self, forKey: .string)
        comment = try c.decode(String.self, forKey: .comment)
        number = try c.decode(String.self, forKey: .number)
        function = try c.decode(String.self, forKey: .function)
        type = try c.decode(String.self, forKey: .type)
    }
}

package struct ThemeDiagramColors: Codable, Hashable, Sendable {
    package var node: String
    package var nodeBorder: String
    package var text: String
    package var line: String
    package var secondary: String
    package var tertiary: String
    package var note: String

    package init(node: String, nodeBorder: String, text: String, line: String, secondary: String, tertiary: String, note: String) {
        self.node = node; self.nodeBorder = nodeBorder; self.text = text; self.line = line
        self.secondary = secondary; self.tertiary = tertiary; self.note = note
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case node, nodeBorder, text, line, secondary, tertiary, note }

    package init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = try c.decode(String.self, forKey: .node)
        nodeBorder = try c.decode(String.self, forKey: .nodeBorder)
        text = try c.decode(String.self, forKey: .text)
        line = try c.decode(String.self, forKey: .line)
        secondary = try c.decode(String.self, forKey: .secondary)
        tertiary = try c.decode(String.self, forKey: .tertiary)
        note = try c.decode(String.self, forKey: .note)
    }
}

/// A localized-string map, e.g. `{"en": "Olympus Dusk", "zh-Hant": "奧林帕斯暮色"}`. `en` is
/// required (design §4.2); other languages are optional, and the app falls back to `en`. This
/// is a plain `[String: String]` under the hood, so it accepts any BCP-47 key without a
/// `CodingKeys` to compare against -- it is the one place `theme.json` doesn't reject unknown
/// keys, because every key is a language tag, not a schema field.
package struct LocalizedText: Codable, Hashable, Sendable {
    package var strings: [String: String]

    package init(en: String, others: [String: String] = [:]) {
        var all = others
        all["en"] = en
        self.strings = all
    }

    package var en: String { strings["en"] ?? "" }

    package subscript(language: String) -> String? { strings[language] }

    package init(from decoder: Decoder) throws {
        strings = try [String: String](from: decoder)
        guard strings["en"] != nil else {
            throw StrictDecodingError.missingEnglish(path: decoder.codingPath)
        }
    }

    package func encode(to encoder: Encoder) throws {
        try strings.encode(to: encoder)
    }
}

package struct ThemeAuthor: Codable, Hashable, Sendable {
    package var name: String
    package var github: String?

    package init(name: String, github: String? = nil) {
        self.name = name; self.github = github
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case name, github }

    package init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        github = try c.decodeIfPresent(String.self, forKey: .github)
    }
}

/// A closed scenario ID (design §4.5). The display name and threshold live in the validator/app
/// string table (#125), never in the file, so a submitter can't choose how a scenario is labelled.
package enum ThemeScenario: String, Codable, CaseIterable, Sendable {
    case agentReview = "agent-review"
    case technicalDocs = "technical-docs"
    case formalOutput = "formal-output"
    case notesSharing = "notes-sharing"
}

/// A `theme.json` document, schema version 1 (design §4.2). Parameters only: colours, a font
/// design, a closed set of style options and display strings -- never CSS.
package struct ThemeDocument: Codable, Hashable, Sendable {
    package var schemaVersion: Int
    package var id: String
    package var version: String
    package var name: LocalizedText
    package var summary: LocalizedText
    package var fontDesign: ThemeFontDesign
    package var scenarios: [ThemeScenario]
    package var author: ThemeAuthor?
    package var license: String?
    package var light: ThemeColors
    package var dark: ThemeColors
    package var style: ThemeStyle?

    package init(
        schemaVersion: Int = 1, id: String, version: String, name: LocalizedText, summary: LocalizedText,
        fontDesign: ThemeFontDesign, scenarios: [ThemeScenario], author: ThemeAuthor? = nil,
        license: String? = nil, light: ThemeColors, dark: ThemeColors, style: ThemeStyle? = nil
    ) {
        self.schemaVersion = schemaVersion; self.id = id; self.version = version
        self.name = name; self.summary = summary; self.fontDesign = fontDesign
        self.scenarios = scenarios; self.author = author; self.license = license
        self.light = light; self.dark = dark; self.style = style
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, version, name, summary, fontDesign, scenarios, author, license, light, dark, style
    }

    package init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, keyedBy: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(String.self, forKey: .version)
        name = try c.decode(LocalizedText.self, forKey: .name)
        summary = try c.decode(LocalizedText.self, forKey: .summary)
        fontDesign = try c.decode(ThemeFontDesign.self, forKey: .fontDesign)
        scenarios = try c.decode([ThemeScenario].self, forKey: .scenarios)
        author = try c.decodeIfPresent(ThemeAuthor.self, forKey: .author)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        light = try c.decode(ThemeColors.self, forKey: .light)
        dark = try c.decode(ThemeColors.self, forKey: .dark)
        style = try c.decodeIfPresent(ThemeStyle.self, forKey: .style)
    }
}

/// Matches `PreviewTheme.FontDesign`'s existing raw values.
package enum ThemeFontDesign: String, Codable, Sendable {
    case sans, serif, rounded
}

package enum ThemeDocumentLoader {
    package enum LoadError: Error { case notFound(String) }

    /// Decodes a `theme.json` from disk.
    package static func load(from url: URL) throws -> ThemeDocument {
        try JSONDecoder().decode(ThemeDocument.self, from: Data(contentsOf: url))
    }

    /// A built-in theme's `theme.json`, bundled under `Resources/Themes/<id>/theme.json`.
    package static func loadBuiltIn(id: String, bundle: Bundle = .module) throws -> ThemeDocument {
        guard let url = builtInURL(id: id, bundle: bundle) else { throw LoadError.notFound(id) }
        return try load(from: url)
    }

    /// Where a built-in's `theme.json` is bundled; only the four built-in ids are looked up.
    package static func builtInURL(id: String, bundle: Bundle = .module) -> URL? {
        guard ["dawn", "classic", "modern", "vivid"].contains(id) else { return nil }
        return bundle.url(forResource: "theme", withExtension: "json", subdirectory: "Themes/\(id)")
    }
}
