import Foundation

/// One problem the validator found. `rule` is a stable id (`contrast.pair`, `id.pattern`, …);
/// `path` is the JSON path of the field, with every component passed through
/// `ThemeMessageText.quote`; `message` is safe to print to a terminal or paste into a CI comment
/// (kit #125, security review M4): it only repeats the validator's own wording, field names,
/// already-validated values, and attacker text that has been quoted and capped.
package struct ThemeIssue: Codable, Hashable, Sendable, CustomStringConvertible {
    package let rule: String
    package let path: String
    package let message: String

    package init(rule: String, path: String, message: String) {
        self.rule = rule
        self.path = path
        self.message = message
    }

    package var description: String { path.isEmpty ? "\(rule): \(message)" : "\(rule) at \(path): \(message)" }
}

/// A theme that passed every rule (kit #125, security review H1). Only `ThemeValidator` can make
/// one -- the initializer is `fileprivate` to this file -- and the CSS generator accepts nothing
/// else, so nothing reaches a stylesheet without having been validated.
///
/// `document` is the normalised form: display strings in NFC, numbers snapped to their steps.
/// `light`/`dark` have every colour filled (a missing `syntax`/`diagram` group from Dawn's).
package struct ValidatedTheme: Hashable, Sendable {
    package let document: ThemeDocument
    package let light: ResolvedPalette
    package let dark: ResolvedPalette

    package var id: String { document.id }

    fileprivate init(document: ThemeDocument, light: ResolvedPalette, dark: ResolvedPalette) {
        self.document = document
        self.light = light
        self.dark = dark
    }
}

package struct ThemeValidationReport: Sendable {
    package let issues: [ThemeIssue]
    /// Non-nil exactly when `issues` is empty.
    package let theme: ValidatedTheme?

    /// For a caller that refuses input before the validator sees it (the CLI's file checks). A
    /// `ValidatedTheme` still only comes from the validator.
    package init(issues: [ThemeIssue], theme: ValidatedTheme?) {
        self.issues = issues
        self.theme = theme
    }
}

/// The one authority on whether a `theme.json` is acceptable (design §6, kit #125): schema,
/// tokens, display strings, numbers, options, composed-pair contrast and scenario thresholds.
package enum ThemeValidator {
    /// A `theme.json` is a few kilobytes; anything over this is refused unread.
    package static let maxFileBytes = 16 * 1024

    /// Validates the raw bytes of a `theme.json`: size cap, the duplicate-key and depth pre-pass,
    /// strict decoding, then every rule in `validate(_:)`.
    package static func validate(data: Data) -> ThemeValidationReport {
        if data.count > maxFileBytes {
            return fail(ThemeIssue(rule: "file.tooLarge", path: "", message: "the file is larger than \(maxFileBytes) bytes"))
        }
        do {
            try JSONStructureScan.scan(data)
        } catch .duplicateKey(let path, let key) {
            let location = path.map(ThemeMessageText.quote).joined(separator: ".")
            return fail(ThemeIssue(rule: "json.duplicateKey", path: location,
                                   message: "the key `\(ThemeMessageText.quote(key))` appears more than once in the same object"))
        } catch .tooDeep {
            return fail(ThemeIssue(rule: "json.tooDeep", path: "", message: "the JSON nests deeper than \(JSONStructureScan.maxDepth) levels"))
        } catch {
            return fail(ThemeIssue(rule: "json.malformed", path: "", message: "the file is not valid JSON"))
        }
        let document: ThemeDocument
        do {
            document = try JSONDecoder().decode(ThemeDocument.self, from: data)
        } catch {
            return fail(issue(forDecodingError: error))
        }
        return validate(document)
    }

    /// Validates an already-decoded document.
    package static func validate(_ document: ThemeDocument) -> ThemeValidationReport {
        var issues: [ThemeIssue] = []
        guard document.schemaVersion == 1 else {
            let message = document.schemaVersion > 1
                ? "schemaVersion \(document.schemaVersion) needs a newer MarsDawn; this one understands 1"
                : "schemaVersion must be 1"
            return fail(ThemeIssue(rule: "schema.version", path: "schemaVersion", message: message))
        }
        var normalized = document

        if !ThemeGrammar.isThemeID(document.id) {
            issues.append(.init(rule: "id.pattern", path: "id",
                                message: "must be 1–\(ThemeGrammar.maxIDLength) lowercase ASCII letters and digits, in runs joined by single hyphens"))
        }
        if !ThemeGrammar.isVersion(document.version) {
            issues.append(.init(rule: "version.pattern", path: "version", message: "must be MAJOR.MINOR.PATCH, for example 1.0.0"))
        }
        normalized.name = checkLocalized(document.name, field: "name", limit: ThemeDisplayText.nameLimit, into: &issues)
        normalized.summary = checkLocalized(document.summary, field: "summary", limit: ThemeDisplayText.summaryLimit, into: &issues)
        if let author = document.author {
            let (name, problems) = ThemeDisplayText.check(author.name, limit: ThemeDisplayText.authorNameLimit)
            issues += problems.map { displayIssue($0, path: "author.name", limit: ThemeDisplayText.authorNameLimit) }
            normalized.author?.name = name
            if let github = author.github, !ThemeGrammar.isGitHubUsername(github) {
                issues.append(.init(rule: "author.github", path: "author.github",
                                    message: "must be a GitHub username: 1–39 ASCII letters, digits and single hyphens"))
            }
        }
        if let license = document.license, !ThemeGrammar.isLicense(license) {
            issues.append(.init(rule: "license.pattern", path: "license", message: "must be an SPDX licence identifier, for example Apache-2.0"))
        }
        if !(1...2).contains(document.scenarios.count) {
            issues.append(.init(rule: "scenarios.count", path: "scenarios", message: "must list one or two scenarios"))
        } else if Set(document.scenarios).count != document.scenarios.count {
            issues.append(.init(rule: "scenarios.duplicate", path: "scenarios", message: "lists the same scenario twice"))
        }

        var colorsValid = true
        for (mode, colors) in [("light", document.light), ("dark", document.dark)] {
            for (field, value) in colorFields(colors) where !ThemeGrammar.isHexColor(value) {
                colorsValid = false
                issues.append(.init(rule: "color.hex", path: "\(mode).\(field)", message: "must be # followed by six hex digits, for example #1C1C1C"))
            }
        }

        if let style = document.style {
            normalized.style = checkStyle(style, into: &issues)
        }

        if colorsValid {
            do throws(ThemePairTable.MissingFallback) {
                let fallback = dawnFallback
                let light = try ResolvedPalette(document.light, fallback: fallback?.light)
                let dark = try ResolvedPalette(document.dark, fallback: fallback?.dark)
                if issues.isEmpty {
                    let contrast = checkContrast(style: normalized.style, scenarios: document.scenarios, light: light, dark: dark)
                    if contrast.isEmpty {
                        return ThemeValidationReport(issues: [], theme: ValidatedTheme(document: normalized, light: light, dark: dark))
                    }
                    issues += contrast
                }
            } catch {
                issues.append(.init(rule: "schema.missing", path: "light", message: "needs its syntax and diagram colours (no fallback is available)"))
            }
        }
        return ThemeValidationReport(issues: issues, theme: nil)
    }

    // MARK: - Display strings

    private static func checkLocalized(_ text: LocalizedText, field: String, limit: Int, into issues: inout [ThemeIssue]) -> LocalizedText {
        var normalized: [String: String] = [:]
        for key in text.strings.keys.sorted() {
            let value = text.strings[key]!
            let path = "\(field).\(ThemeMessageText.quote(key))"
            if !ThemeGrammar.isLocaleKey(key) {
                issues.append(.init(rule: "locale.key", path: path,
                                    message: "`\(ThemeMessageText.quote(key))` is not a language tag such as en, zh-Hant or pt-BR"))
            }
            let (clean, problems) = ThemeDisplayText.check(value, limit: limit)
            issues += problems.map { displayIssue($0, path: path, limit: limit) }
            normalized[key] = clean
        }
        var result = text
        result.strings = normalized
        return result
    }

    private static func displayIssue(_ problem: ThemeDisplayText.Problem, path: String, limit: Int) -> ThemeIssue {
        let suffix = problem == .length ? " (at most \(limit) characters)" : ""
        return ThemeIssue(rule: problem.rawValue, path: path, message: problem.summary + suffix)
    }

    // MARK: - Colours

    private static func colorFields(_ colors: ThemeColors) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("background", colors.background), ("surface", colors.surface), ("text", colors.text),
            ("muted", colors.muted), ("border", colors.border), ("heading", colors.heading),
            ("accent", colors.accent), ("link", colors.link), ("quote", colors.quote),
        ]
        if let s = colors.syntax {
            fields += [("syntax.keyword", s.keyword), ("syntax.string", s.string), ("syntax.comment", s.comment),
                       ("syntax.number", s.number), ("syntax.function", s.function), ("syntax.type", s.type)]
        }
        if let d = colors.diagram {
            fields += [("diagram.node", d.node), ("diagram.nodeBorder", d.nodeBorder), ("diagram.text", d.text),
                       ("diagram.line", d.line), ("diagram.secondary", d.secondary), ("diagram.tertiary", d.tertiary),
                       ("diagram.note", d.note)]
        }
        return fields
    }

    /// Dawn's own palettes, for a theme that leaves `syntax` or `diagram` out.
    static let dawnFallback: (light: ResolvedPalette, dark: ResolvedPalette)? = {
        guard let dawn = try? ThemeDocumentLoader.loadBuiltIn(id: "dawn"),
              let light = try? ResolvedPalette(dawn.light, fallback: nil),
              let dark = try? ResolvedPalette(dawn.dark, fallback: nil)
        else { return nil }
        return (light, dark)
    }()

    // MARK: - Style options

    private static func snap(_ value: Double?, _ number: ThemeNumber, path: String, into issues: inout [ThemeIssue]) -> Double? {
        guard let value else { return nil }
        guard let snapped = number.snapped(value) else {
            issues.append(.init(rule: "number.range", path: path,
                                message: "must be a number from \(ThemeNumber.css(number.range.lowerBound)) to \(ThemeNumber.css(number.range.upperBound)) (in steps of \(ThemeNumber.css(number.step)))"))
            return value
        }
        return snapped
    }

    private static let inlineCodeRoles: Set<PaletteRole> = [.text, .keyword, .string, .comment, .number, .function, .type]

    private static func checkStyle(_ style: ThemeStyle, into issues: inout [ThemeIssue]) -> ThemeStyle {
        var s = style
        s.bodySize = snap(style.bodySize, .bodySize, path: "style.bodySize", into: &issues)
        s.lineHeight = snap(style.lineHeight, .lineHeight, path: "style.lineHeight", into: &issues)
        s.headingWeight = snap(style.headingWeight, .headingWeight, path: "style.headingWeight", into: &issues)
        s.radius = snap(style.radius, .radius, path: "style.radius", into: &issues)
        s.maxWidth = snap(style.maxWidth, .maxWidth, path: "style.maxWidth", into: &issues)
        if let h1 = style.h1 {
            s.h1?.size = snap(h1.size, .h1Size, path: "style.h1.size", into: &issues)
            s.h1?.letterSpacing = snap(h1.letterSpacing, .h1LetterSpacing, path: "style.h1.letterSpacing", into: &issues)
        }
        if let h2 = style.h2 {
            s.h2?.letterSpacing = snap(h2.letterSpacing, .h2LetterSpacing, path: "style.h2.letterSpacing", into: &issues)
        }
        if case .bar(let width)? = style.blockquote?.style {
            s.blockquote?.style = .bar(width: snap(width, .blockquoteBarWidth, path: "style.blockquote.style.width", into: &issues))
        }
        switch style.hr?.style {
        case .line(let color, let thickness)?:
            s.hr?.style = .line(color: color, thickness: snap(thickness, .hrThickness, path: "style.hr.style.thickness", into: &issues))
        case .gradient(let colors)? where !(2...3).contains(colors.count):
            issues.append(.init(rule: "option.gradientStops", path: "style.hr.style.colors", message: "a gradient takes two or three colour roles"))
        default: break
        }
        if let role = style.inlineCode, !inlineCodeRoles.contains(role) {
            issues.append(.init(rule: "option.role", path: "style.inlineCode", message: "must be text or a syntax role (keyword, string, comment, number, function, type)"))
        }
        return s
    }

    // MARK: - Contrast

    /// Design §4.5's scenario thresholds, beyond the composed pairs every theme must pass.
    private static func scenarioChecks(_ scenario: ThemeScenario) -> (fields: [String], against: String, modes: [Bool]) {
        switch scenario {
        case .agentReview: (["text", "heading", "link", "accent", "muted"], "background", [false, true])
        case .technicalDocs: (["keyword", "string", "comment", "number", "function", "type"], "surface", [false, true])
        case .formalOutput: (["text", "heading", "link", "accent", "muted"], "background", [false])
        case .notesSharing: ([], "background", [])
        }
    }

    private static func fieldName(_ token: String) -> String {
        ["keyword", "string", "comment", "number", "function", "type"].contains(token) ? "syntax.\(token)" : token
    }

    /// Every composed pair (shared + the picked options') in both palettes, and each declared
    /// scenario's threshold, reported so that one bad colour pair is one issue under one rule:
    ///
    /// 1. `contrast.baseline` -- body text on the page (and on a footnote highlight), which every
    ///    theme must pass whatever it declares;
    /// 2. `contrast.scenario` -- a declared scenario's threshold (design §4.5), in its own words;
    /// 3. `contrast.pair` -- any other composed pair, at the strictest threshold any of its uses
    ///    needs (4.5:1 text, 3:1 non-text), naming a notice when one is involved.
    ///
    /// A colour pair already reported by an earlier step isn't reported again by a later one.
    /// Contrast is symmetric, so `a` on `b` and `b` on `a` count as the same pair.
    package static func checkContrast(style: ThemeStyle?, scenarios: [ThemeScenario], light: ResolvedPalette, dark: ResolvedPalette) -> [ThemeIssue] {
        guard let table = ThemePairTable.bundled else {
            return [ThemeIssue(rule: "contrast.pair", path: "", message: "the kit's pair table could not be read")]
        }
        struct Key: Hashable {
            let a: String, b: String, dark: Bool
            init(_ x: String, _ y: String, dark: Bool) { (a, b) = x < y ? (x, y) : (y, x); self.dark = dark }
        }
        struct Group { var pairs: [ResolvedPair]; var needed: Double; var ratio: Double }
        var order: [Key] = []
        var groups: [Key: Group] = [:]
        for (palette, isDark) in [(light, false), (dark, true)] {
            for pair in table.pairs(style: style, palette: palette, dark: isDark) {
                let key = Key(pair.foreground, pair.background, dark: isDark)
                if groups[key] == nil {
                    order.append(key)
                    groups[key] = Group(pairs: [], needed: 0, ratio: pair.ratio)
                }
                groups[key]!.pairs.append(pair)
                groups[key]!.needed = max(groups[key]!.needed, pair.threshold)
            }
        }
        func mode(_ dark: Bool) -> String { dark ? "dark" : "light" }
        func pairIssue(_ rule: String, _ group: Group, _ pair: ResolvedPair) -> ThemeIssue {
            let noticeNote = rule == "contrast.pair" && pair.notice ? " (notice text must stay readable in every scenario)" : ""
            return ThemeIssue(
                rule: rule,
                path: "\(mode(pair.dark)).\(fieldName(pair.fgToken))",
                message: "\(mode(pair.dark)) \(pair.element): `\(fieldName(pair.fgToken))` \(pair.foreground) is \(ThemeContrast.format(group.ratio)):1 against `\(fieldName(pair.bgToken))` \(pair.background), needs \(ThemeNumber.css(group.needed)):1\(noticeNote)"
            )
        }

        var issues: [ThemeIssue] = []
        var reported: [Key: Double] = [:]

        // 1. Baseline.
        for key in order {
            let group = groups[key]!
            guard group.ratio < group.needed, let pair = group.pairs.first(where: \.baseline) else { continue }
            issues.append(pairIssue("contrast.baseline", group, pair))
            reported[key] = group.needed
        }
        // 2. Scenarios.
        for scenario in scenarios {
            let check = scenarioChecks(scenario)
            for isDark in check.modes {
                let palette = isDark ? dark : light
                guard let bg = palette.color(for: check.against, dark: isDark) else { continue }
                for token in check.fields {
                    guard let fg = palette.color(for: token, dark: isDark) else { continue }
                    let key = Key(fg, bg, dark: isDark)
                    let ratio = ThemeContrast.ratio(fg, bg)
                    guard ratio < 4.5, reported[key] == nil else { continue }
                    issues.append(ThemeIssue(
                        rule: "contrast.scenario",
                        path: "\(mode(isDark)).\(fieldName(token))",
                        message: "`\(scenario.rawValue)`: \(mode(isDark)) `\(fieldName(token))` \(fg) is \(ThemeContrast.format(ratio)):1 against `\(check.against)`, needs 4.5:1"
                    ))
                    reported[key] = 4.5
                }
            }
        }
        // 3. Every other composed pair.
        for key in order {
            let group = groups[key]!
            guard group.ratio < group.needed else { continue }
            if let covered = reported[key], covered >= group.needed { continue }
            let strictest = group.pairs.filter { $0.threshold == group.needed }
            let pair = strictest.first(where: \.notice) ?? strictest[0]
            issues.append(pairIssue("contrast.pair", group, pair))
            reported[key] = group.needed
        }
        return issues
    }

    // MARK: - Decoding errors

    private static func fail(_ issue: ThemeIssue) -> ThemeValidationReport {
        ThemeValidationReport(issues: [issue], theme: nil)
    }

    static func render(_ path: [CodingKey]) -> String {
        var out = ""
        for key in path {
            if let index = key.intValue {
                out += "[\(index)]"
            } else {
                out += (out.isEmpty ? "" : ".") + ThemeMessageText.quote(key.stringValue)
            }
        }
        return out
    }

    static func issue(forDecodingError error: Error) -> ThemeIssue {
        if let strict = error as? StrictDecodingError {
            switch strict {
            case .unknownKey(let key, let path):
                return ThemeIssue(rule: "schema.unknownKey", path: render(path),
                                  message: "unknown key `\(ThemeMessageText.quote(key))`")
            case .missingEnglish(let path):
                return ThemeIssue(rule: "schema.missing", path: render(path), message: "needs an `en` entry")
            }
        }
        guard let decoding = error as? DecodingError else {
            return ThemeIssue(rule: "json.malformed", path: "", message: "the file could not be read as a theme")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return ThemeIssue(rule: "schema.missing", path: render(context.codingPath + [key]), message: "is required")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return ThemeIssue(rule: "schema.type", path: render(context.codingPath), message: "has the wrong type")
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty {
                return ThemeIssue(rule: "json.malformed", path: "", message: "the file is not valid JSON")
            }
            return ThemeIssue(rule: "schema.value", path: render(context.codingPath), message: "is not one of the allowed values")
        @unknown default:
            return ThemeIssue(rule: "json.malformed", path: "", message: "the file could not be read as a theme")
        }
    }
}
