import Foundation
import Testing
@testable import MarsDawnThemes

// kit #125: one suite per security-review disposition (plan S2). Everything here is Foundation-only,
// like MarsDawnThemes itself.

private func builtIn(_ id: String) throws -> ThemeDocument { try ThemeDocumentLoader.loadBuiltIn(id: id) }

private func validated(_ document: ThemeDocument, sourceLocation: SourceLocation = #_sourceLocation) throws -> ValidatedTheme {
    let report = ThemeValidator.validate(document)
    return try #require(report.theme, "\(document.id): \(report.issues)", sourceLocation: sourceLocation)
}

// MARK: - M1: one byte-level predicate for ids (and hex)

struct ThemeIDPredicateTests {
    static let rejected: [String] = [
        "dawn\n", "dawn\r", "dawn\r\n", "dawn\u{0301}", "\u{FF44}\u{FF41}\u{FF57}\u{FF4E}", "da\u{0}wn",
        String(repeating: "a", count: 33), "-dawn", "dawn-", "a--b", "", "-", "Dawn", "dawn ", " dawn",
        "d_awn", "dawn/..", #"x"]{}*{background:red}"#, "\u{0661}\u{0662}",
    ]

    @Test(arguments: rejected)
    func validatorAndGeneratorRejectTheID(_ id: String) throws {
        #expect(!ThemeGrammar.isThemeID(id))
        var document = try builtIn("dawn")
        document.id = id
        let report = ThemeValidator.validate(document)
        #expect(report.theme == nil)
        #expect(report.issues.map(\.rule) == ["id.pattern"], "\(report.issues)")
        #expect(throws: ThemeCSSGenerator.Refusal.invalidID) {
            try ThemeCSSGenerator.checkedRules(id: id, style: ThemeStyle(radius: 4))
        }
        let dawn = try validated(try builtIn("dawn"))
        #expect(throws: ThemeCSSGenerator.Refusal.invalidID) {
            try ThemeCSSGenerator.variableBlock(id: id, light: dawn.light, dark: dawn.dark, fontStack: "serif")
        }
        // kit #124's non-throwing entry point emits nothing at all for it.
        #expect(ThemeCSSGenerator.generate(id: id, style: ThemeStyle(radius: 4)).css.isEmpty)
    }

    @Test(arguments: ["dawn", "a", "a-b", "olympus-dusk", "x1-2y", String(repeating: "a", count: 32)])
    func acceptedIDs(_ id: String) {
        #expect(ThemeGrammar.isThemeID(id))
    }

    /// The reason the predicate is byte-level: `NSRegularExpression`'s `$` matches before a
    /// trailing newline, so the obvious regular expression accepts `"dawn\n"`. If this ever stops
    /// being true the predicate is still right; the test documents why it exists.
    @Test func aRegexWithDollarWouldHaveAcceptedATrailingNewline() throws {
        let regex = try NSRegularExpression(pattern: "^[a-z0-9]+(-[a-z0-9]+)*$")
        let text = "dawn\n"
        #expect(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
        #expect(!ThemeGrammar.isThemeID(text))
    }
}

// MARK: - H1: colours are exactly # + 6 ASCII hex, and only a ValidatedTheme is generated

struct ThemeHexRefusalTests {
    static let hostile: [String] = [
        "#FFFFFF;}", "#FFFFFF\n", "red", "var(--bg)", "\u{FF03}\u{FF26}\u{FF26}\u{FF26}\u{FF26}\u{FF26}\u{FF26}",
        "#\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}", "#FFF\u{0}FF", "#FFF", "#FFFFFF00", "url(x)", "#GGGGGG", "",
        "#FFFFFF;background-image:url(https://example.com/p)", "\u{FEFF}#FFFFFF",
    ]

    @Test(arguments: hostile)
    func theGeneratorRefusesTheColour(_ color: String) throws {
        #expect(!ThemeGrammar.isHexColor(color))
        let dawn = try validated(try builtIn("dawn"))
        var light = dawn.light
        light.background = color
        #expect(throws: ThemeCSSGenerator.Refusal.invalidColor(field: "light.background")) {
            try ThemeCSSGenerator.variableBlock(id: "evil", light: light, dark: dawn.dark, fontStack: "serif")
        }
        var dark = dawn.dark
        dark.diagram.node = color
        #expect(throws: ThemeCSSGenerator.Refusal.invalidColor(field: "dark.diagram.node")) {
            try ThemeCSSGenerator.variableBlock(id: "evil", light: dawn.light, dark: dark, fontStack: "serif")
        }
    }

    @Test(arguments: hostile)
    func theValidatorRefusesTheColour(_ color: String) throws {
        var document = try builtIn("dawn")
        document.dark.accent = color
        let report = ThemeValidator.validate(document)
        #expect(report.theme == nil)
        #expect(report.issues.map(\.rule) == ["color.hex"])
        #expect(report.issues.first?.path == "dark.accent")
    }

    @Test(arguments: ["#000000", "#ffffff", "#C8471B", "#c8471b", "#0a0B0c"])
    func acceptedColours(_ color: String) {
        #expect(ThemeGrammar.isHexColor(color))
    }
}

// MARK: - M3 (generator side): ids are unique across what is emitted

struct ThemeUniqueIDTests {
    @Test func twoThemesWithOneIDAreRefused() throws {
        let dawn = try validated(try builtIn("dawn"))
        var classicDocument = try builtIn("classic")
        classicDocument.id = "dawn"
        let impostor = try validated(classicDocument)
        #expect(throws: ThemeCSSGenerator.Refusal.duplicateID("dawn")) {
            try ThemeCSSGenerator.stylesheet(for: [dawn, impostor])
        }
        // Control: the same two with distinct ids generate.
        #expect(throws: Never.self) { try ThemeCSSGenerator.stylesheet(for: [dawn, try validated(try builtIn("classic"))]) }
    }
}

// MARK: - L3: numbers

struct ThemeNumberTests {
    @Test func nonFiniteAndHugeNumbersAreRefused() {
        for option in ThemeNumber.allCases {
            for value in [1e308, -1e308, .infinity, -.infinity, .nan, Double.greatestFiniteMagnitude] {
                #expect(option.snapped(value) == nil, "\(option) accepted \(value)")
                #expect(!option.isAcceptable(value))
            }
        }
    }

    @Test func negativeZeroBecomesZero() {
        let snapped = ThemeNumber.radius.snapped(-0.0)
        #expect(snapped == 0)
        #expect(snapped?.sign == .plus)
        #expect(ThemeNumber.css(-0.0) == "0")
        #expect(ThemeNumber.h1LetterSpacing.snapped(-0.0).map(ThemeNumber.css) == "0")
    }

    /// Off-step values snap to the nearest step, and the range is applied to the snapped value.
    @Test func offStepValuesSnap() {
        #expect(ThemeNumber.h1LetterSpacing.snapped(0.030000001) == 0.03)
        #expect(ThemeNumber.lineHeight.snapped(1.75 + 1e-9) == 1.75)
        #expect(ThemeNumber.lineHeight.snapped(1.75 - 1e-9) == 1.75)
        #expect(ThemeNumber.headingWeight.snapped(612) == 600)
        #expect(ThemeNumber.lineHeight.snapped(1.95) == nil) // snaps to 1.95, above 1.9
        #expect(ThemeNumber.h1LetterSpacing.snapped(-0.0151) == -0.015)
    }

    /// The validator stores the snapped value, so the generator writes the step, never the input.
    @Test func theValidatorStoresSnappedValues() throws {
        var document = try builtIn("classic")
        document.style?.lineHeight = 1.75 + 1e-9
        document.style?.h1?.letterSpacing = 0.010000001
        let theme = try validated(document)
        #expect(theme.document.style?.lineHeight == 1.75)
        let css = try ThemeCSSGenerator.rules(for: theme).css
        #expect(css.contains("--line-height: 1.75;"))
        #expect(css.contains("letter-spacing: 0.01em;"))
    }

    /// The generator's own check refuses an unsnapped or out-of-range number even though the
    /// validator would never hand it one.
    @Test func theGeneratorRefusesUnsnappedOrOutOfRangeNumbers() {
        for style in [ThemeStyle(lineHeight: 1.76), ThemeStyle(radius: 17), ThemeStyle(radius: .nan), ThemeStyle(bodySize: 1e308),
                      ThemeStyle(h1: .init(letterSpacing: 0.0301)), ThemeStyle(blockquote: .init(style: .bar(width: 9))),
                      ThemeStyle(hr: .init(style: .line(color: nil, thickness: -0.5)))] {
            #expect(throws: ThemeCSSGenerator.Refusal.self) { try ThemeCSSGenerator.checkedRules(id: "probe", style: style) }
        }
    }

    @Test func theFormatterIsFixedPoint() {
        #expect(ThemeNumber.css(600) == "600")
        #expect(ThemeNumber.css(1.75) == "1.75")
        #expect(ThemeNumber.css(2.2) == "2.2")
        #expect(ThemeNumber.css(-0.015) == "-0.015")
        #expect(ThemeNumber.css(0.01) == "0.01")
        #expect(ThemeNumber.css(1000) == "1000")
        #expect(ThemeNumber.css(0.005) == "0.005")
    }
}

/// `setlocale` is process-wide: this suite runs alone and restores it.
@Suite(.serialized)
struct ThemeNumberLocaleTests {
    private static func cPrintf(_ value: Double) -> String {
        var buffer = [CChar](repeating: 0, count: 32)
        _ = withVaList([value]) { vsnprintf(&buffer, buffer.count, "%.2f", $0) }
        return String(cString: buffer)
    }

    private static func everything() throws -> String {
        var themes: [ValidatedTheme] = []
        for id in ["dawn", "classic", "modern", "vivid"] {
            themes.append(try validated(try builtIn(id)))
        }
        var edge = try builtIn("dawn")
        edge.id = "edge"
        edge.style = ThemeStyle(bodySize: 17, lineHeight: 1.45, headingWeight: 450, radius: 0.0, maxWidth: 610,
                                h1: .init(size: 1.9, letterSpacing: -0.025), h2: .init(letterSpacing: 0.005))
        themes.append(try validated(edge))
        let sheet = try ThemeCSSGenerator.stylesheet(for: themes)
        return sheet.variables + sheet.rules
    }

    @Test func outputIsByteEqualUnderGermanAndPOSIXLocales() throws {
        let saved = String(cString: setlocale(LC_ALL, nil))
        defer { setlocale(LC_ALL, saved) }

        #expect(setlocale(LC_ALL, "en_US_POSIX") != nil || setlocale(LC_ALL, "C") != nil)
        let posix = try Self.everything()
        #expect(Self.cPrintf(1.5) == "1.50")

        let german = setlocale(LC_ALL, "de_DE.UTF-8") ?? setlocale(LC_ALL, "de_DE")
        try #require(german != nil, "no German locale on this machine: the comparison would prove nothing")
        // The instrument: C formatting really does use a decimal comma now.
        #expect(Self.cPrintf(1.5) == "1,50")
        let underGerman = try Self.everything()

        #expect(Data(underGerman.utf8) == Data(posix.utf8))
        #expect(posix.contains("--line-height: 1.45;"), "positive fixture: a fractional number is in the output")
    }
}

// MARK: - L6: what the generator can emit

struct ThemeGeneratedCSSAllowListTests {
    /// Themes covering every option value: the built-ins, the fixtures' `every-option` and
    /// `edge-numbers`, and one theme per remaining option value.
    static func themes() throws -> [ValidatedTheme] {
        var out: [ValidatedTheme] = []
        for id in ["dawn", "classic", "modern", "vivid"] { out.append(try validated(try builtIn(id))) }
        let variants: [ThemeStyle] = [
            ThemeStyle(h1: .init(decoration: ThemeStyle.H1Decoration.none), h2: .init(decoration: ThemeStyle.H2Decoration.none)),
            ThemeStyle(h1: .init(decoration: .rule), h2: .init(decoration: .rule)),
            ThemeStyle(hr: .init(style: .gradient(colors: [.accent, .heading]))),
            ThemeStyle(hr: .init(style: .line(color: nil, thickness: nil))),
            ThemeStyle(table: .init(header: .surface, verticalRules: true, rounded: false)),
            ThemeStyle(table: .init(header: .filled(background: .heading, text: .background, border: .border))),
            ThemeStyle(bodySize: 14, lineHeight: 1.9, headingWeight: 400, radius: 16, maxWidth: 600,
                       h1: .init(size: 1.8, letterSpacing: -0.03, align: .left), h2: .init(letterSpacing: 0.03, italic: false),
                       blockquote: .init(style: .bar(width: 2), italic: false), listMarker: .accent, inlineCode: .text,
                       link: .init(underline: false), syntax: .init(boldKeywords: false)),
        ]
        for (index, style) in variants.enumerated() {
            var document = try builtIn("dawn")
            document.id = "variant-\(index)"
            document.style = style
            out.append(try validated(document))
        }
        let fixtures = Bundle.module.url(forResource: "ThemeFixtures", withExtension: nil)!.appendingPathComponent("valid")
        for name in ["every-option.json", "edge-numbers.json"] {
            let report = ThemeValidator.validate(data: try Data(contentsOf: fixtures.appendingPathComponent(name)))
            out.append(try #require(report.theme, "\(name): \(report.issues)"))
        }
        return out
    }

    static let forbidden = ["\\", "url", "image-set", "image(", "cross-fade", "element(", "!important", "expression(", "javascript:", "</"]

    static func check(_ css: String, id: String) -> [String] {
        var problems: [String] = []
        let lower = css.lowercased()
        for token in forbidden where lower.contains(token) { problems.append("\(id): contains \(token)") }
        let withoutDarkQuery = css.replacingOccurrences(of: "@media (prefers-color-scheme: dark) {", with: "")
        if withoutDarkQuery.contains("@") { problems.append("\(id): an at-rule other than the palette's dark query") }
        var depth = 0
        var selector = ""
        for character in css {
            switch character {
            case "{":
                let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                let isDarkQuery = trimmed == "@media (prefers-color-scheme: dark)"
                let own = trimmed.hasPrefix("[data-theme=\"\(id)\"] ") || trimmed == ":root[data-theme=\"\(id)\"]"
                if !isDarkQuery && !own { problems.append("\(id): selector not scoped to its own theme: \(trimmed)") }
                if isDarkQuery && depth != 0 { problems.append("\(id): nested at-rule") }
                depth += 1
                selector = ""
            case "}":
                depth -= 1
                if depth < 0 { problems.append("\(id): unbalanced }") }
                selector = ""
            case ";":
                if depth == 0 { problems.append("\(id): a declaration outside any rule") }
                selector = ""
            default:
                selector.append(character)
            }
        }
        if depth != 0 { problems.append("\(id): braces don't balance") }
        return problems
    }

    @Test func everyThemesOutputStaysInsideTheAllowList() throws {
        let themes = try Self.themes()
        #expect(themes.count >= 13, "positive fixture: every option value is represented")
        var problems: [String] = []
        var total = 0
        for theme in themes {
            let css = try ThemeCSSGenerator.variables(for: theme) + "\n" + ThemeCSSGenerator.rules(for: theme).css
            total += css.count
            problems += Self.check(css, id: theme.id)
        }
        #expect(total > 10_000, "positive fixture: the generator produced real output")
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    /// The fragments themselves, whether or not any theme picks them.
    @Test func everyFragmentStaysInsideTheAllowList() throws {
        let fragments = try #require(ThemeStylesFile.shared?.fragments)
        var count = 0
        for (option, values) in fragments {
            for (value, entries) in values {
                for entry in entries {
                    for declaration in entry.declarations {
                        count += 1
                        // Placeholders come from a closed list (design §4.3: palette roles and numbers only).
                        var text = (entry.selector + " " + declaration.joined(separator: " ")).lowercased()
                        for placeholder in ["color", "from", "to", "colors", "width", "background", "text", "border"] {
                            text = text.replacingOccurrences(of: "{{\(placeholder)}}", with: "")
                        }
                        for token in Self.forbidden + ["@", "{", "}", ";"] {
                            #expect(!text.contains(token), "\(option).\(value): \(token) in \(entry.selector) \(declaration)")
                        }
                    }
                }
            }
        }
        #expect(count >= 30, "positive fixture: the fragment table was read (\(count) declarations)")
    }

    /// The instrument: each forbidden construct is caught.
    @Test func theCheckCatchesEachConstruct() {
        let good = ":root[data-theme=\"t\"] {\n  --bg: #FFFFFF;\n}\n[data-theme=\"t\"] h1 { color: var(--fg); }\n"
        #expect(Self.check(good, id: "t").isEmpty)
        for bad in [
            "[data-theme=\"t\"] h1 { color: red !important; }",
            "[data-theme=\"t\"] h1 { background: url(x); }",
            "[data-theme=\"t\"] h1 { content: \"\\41\"; }",
            "[data-theme=\"u\"] h1 { color: var(--fg); }",
            "h1 { color: var(--fg); }",
            "[data-theme=\"t\"] h1 { color: var(--fg); } }",
            "@import \"x.css\";",
            "[data-theme=\"t\"] h1 { color: var(--fg); ",
        ] {
            #expect(!Self.check(bad, id: "t").isEmpty, "missed: \(bad)")
        }
    }
}

// MARK: - L1: display strings

struct ThemeDisplayTextTests {
    @Test(arguments: [
        ("Sample \u{202E}nwaD", ThemeDisplayText.Problem.bidi), ("a\u{2066}b", .bidi), ("a\u{200F}b", .bidi), ("a\u{061C}b", .bidi),
        ("Tab\there", .control), ("Line\nbreak", .control), ("Bell\u{7}", .control), ("C1\u{85}", .control), ("a\u{2028}b", .control),
        ("a\u{FEFF}b", .invisible), ("a\u{200B}b", .invisible),
        ("Z\u{301}\u{302}\u{303}\u{304}\u{305}algo", .combining), ("q\u{30F}\u{311}\u{31B}\u{323}", .combining),
        ("see https://example.com", .url), ("WWW.example.com", .url),
        ("   ", .empty), ("", .empty),
        (String(repeating: "x", count: 49), .length),
    ])
    func rejected(_ text: String, _ problem: ThemeDisplayText.Problem) {
        #expect(ThemeDisplayText.check(text, limit: 48).problems.contains(problem), "\(problem) not found")
    }

    @Test(arguments: ["Dawn", "%@ %n", "奧林帕斯暮色", "Café", "Việt Nam", "O'Brien & Co.", "@janedoe", String(repeating: "x", count: 48)])
    func accepted(_ text: String) {
        #expect(ThemeDisplayText.check(text, limit: 48).problems.isEmpty, "\(text)")
    }

    @Test func textIsNormalisedToNFCAndCountedInScalars() {
        let decomposed = "Cafe\u{301}"
        let (normalized, problems) = ThemeDisplayText.check(decomposed, limit: 4)
        #expect(normalized == "Café")
        #expect(normalized.unicodeScalars.count == 4)
        #expect(problems.isEmpty)
        // Emoji and CJK count as the scalars they are.
        #expect(ThemeDisplayText.check("👩‍👩‍👧", limit: 4).problems == [.length])
    }
}

// MARK: - M4: repeating attacker text

struct ThemeMessageTextTests {
    @Test func controlsMentionsAndLinksAreEscaped() {
        let quoted = ThemeMessageText.quote("\u{1B}]0;pwned\u{7}@someuser [x](https://evil.test)")
        #expect(!quoted.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
        #expect(!quoted.contains("@"))
        #expect(!quoted.contains("://"))
        #expect(!quoted.contains("["))
        #expect(!quoted.contains("`"))
        #expect(quoted.hasPrefix("\\u{1B}"))
    }

    @Test func inputIsCapped() {
        let quoted = ThemeMessageText.quote(String(repeating: "a", count: 500))
        #expect(quoted == String(repeating: "a", count: ThemeMessageText.cap) + "...(436 more)")
    }

    @Test func plainTextPassesThrough() {
        #expect(ThemeMessageText.quote("accent") == "accent")
        #expect(ThemeMessageText.quote("zh-Hant") == "zh-Hant")
    }

    /// The whole report for a hostile key survives a JSON round trip unchanged.
    @Test func issuesRoundTripThroughJSON() throws {
        let data = Data(#"{"\u001b[31m@x [y](https://z.test)": 1}"#.utf8)
        let report = ThemeValidator.validate(data: data)
        let encoded = try JSONEncoder().encode(report.issues)
        #expect(try JSONDecoder().decode([ThemeIssue].self, from: encoded) == report.issues)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("\u{1B}"))
    }
}

// MARK: - L2 (validator side): duplicate keys and depth

struct JSONStructureScanTests {
    @Test func duplicateKeysAreFoundAtAnyDepth() {
        #expect(throws: JSONStructureScan.Failure.duplicateKey(path: [], key: "a")) {
            try JSONStructureScan.scan(Data(#"{"a": 1, "a": 2}"#.utf8))
        }
        #expect(throws: JSONStructureScan.Failure.duplicateKey(path: ["light"], key: "accent")) {
            try JSONStructureScan.scan(Data(##"{"light": {"accent": "#000000", "accent": "#FFFFFF"}}"##.utf8))
        }
        #expect(throws: JSONStructureScan.Failure.duplicateKey(path: ["x", "1"], key: "k")) {
            try JSONStructureScan.scan(Data(#"{"x": [{"k": 1}, {"k": 1, "k": 2}]}"#.utf8))
        }
    }

    @Test func escapedSpellingsOfOneKeyAreTheSameKey() {
        #expect(throws: JSONStructureScan.Failure.duplicateKey(path: [], key: "accent")) {
            try JSONStructureScan.scan(Data(#"{"accent": 1, "acc\u0065nt": 2}"#.utf8))
        }
        #expect(throws: JSONStructureScan.Failure.duplicateKey(path: [], key: "😀")) {
            try JSONStructureScan.scan(Data(#"{"😀": 1, "\ud83d\ude00": 2}"#.utf8))
        }
    }

    @Test func depthIsCapped() throws {
        func nested(_ depth: Int) -> Data {
            Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        }
        try JSONStructureScan.scan(nested(JSONStructureScan.maxDepth))
        #expect(throws: JSONStructureScan.Failure.tooDeep) { try JSONStructureScan.scan(nested(JSONStructureScan.maxDepth + 1)) }
        // Linear, no recursion: a million brackets is refused at once.
        #expect(throws: JSONStructureScan.Failure.tooDeep) { try JSONStructureScan.scan(nested(1_000_000)) }
    }

    @Test(arguments: [#"{"a": 1,}"#, #"{"a" 1}"#, #"[1,]"#, #"{"a": "b"#, #"{"a": "\x"}"#, "{\"a\": \"\u{1}\"}", #"{} {}"#, ""])
    func malformedJSONIsRefused(_ text: String) {
        #expect(throws: JSONStructureScan.Failure.malformed) { try JSONStructureScan.scan(Data(text.utf8)) }
    }

    @Test func everyBuiltInPassesTheScan() throws {
        for id in ["dawn", "classic", "modern", "vivid"] {
            let url = try #require(ThemeDocumentLoader.builtInURL(id: id))
            try JSONStructureScan.scan(try Data(contentsOf: url))
        }
    }
}

// MARK: - The built-ins against their own scenarios (design §4.5, issue #125 done-when)

struct BuiltInThemeValidationTests {
    @Test(arguments: ["dawn", "classic", "modern", "vivid"])
    func eachBuiltInPasses(_ id: String) throws {
        let report = ThemeValidator.validate(try builtIn(id))
        #expect(report.issues.isEmpty, "\(id): \(report.issues)")
        let data = try Data(contentsOf: try #require(ThemeDocumentLoader.builtInURL(id: id)))
        #expect(ThemeValidator.validate(data: data).issues.isEmpty)
    }

    /// Breaking a built-in's own scenario fails it, naming that scenario.
    @Test func breakingABuiltInsOwnScenarioFailsIt() throws {
        var dawn = try builtIn("dawn")
        dawn.dark.accent = "#8C4A2E" // agent-review checks accent in dark mode too
        #expect(ThemeValidator.validate(dawn).issues.contains { $0.rule == "contrast.scenario" && $0.message.hasPrefix("`agent-review`: dark `accent`") })

        var modern = try builtIn("modern")
        modern.light.syntax?.comment = "#9AA0A6"
        #expect(ThemeValidator.validate(modern).issues.contains { $0.rule == "contrast.scenario" && $0.message.hasPrefix("`technical-docs`: light `syntax.comment`") })

        var classic = try builtIn("classic")
        classic.light.accent = "#8C8C8C"
        #expect(ThemeValidator.validate(classic).issues.contains { $0.rule == "contrast.scenario" && $0.message.hasPrefix("`formal-output`: light `accent`") })

        var vivid = try builtIn("vivid")
        vivid.light.text = "#9A94A3"
        #expect(ThemeValidator.validate(vivid).issues.contains { $0.rule == "contrast.baseline" })
    }

    /// A scenario threshold is a real check, not only a restatement of a composed pair: with the
    /// pair table's `banner-button` gone, `formal-output` still catches a low accent.
    @Test func scenarioChecksStandOnTheirOwn() throws {
        let v = try validated(try builtIn("classic"))
        var light = v.light
        light.accent = "#8C8C8C"
        let issues = ThemeValidator.checkContrast(style: nil, scenarios: [.formalOutput], light: light, dark: v.dark)
        #expect(issues.contains { $0.rule == "contrast.scenario" })
        let without = ThemeValidator.checkContrast(style: nil, scenarios: [.notesSharing], light: light, dark: v.dark)
        #expect(!without.contains { $0.rule == "contrast.scenario" })
        #expect(without.contains { $0.rule == "contrast.pair" }, "a notes-sharing theme still fails the banner button pair")
    }
}

// MARK: - The target stays Foundation-only (plan S2 revision 4)

struct ThemeImportAllowListTests {
    @Test func everySourceImportsOnlyFoundation() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnThemes")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 8, "positive fixture: the sources were found (\(files))")
        var imports: [String: Set<String>] = [:]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in text.matches(of: /(?m)^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)/) {
                imports[file, default: []].insert(String(match.output.1))
            }
        }
        let offenders = imports.filter { !$0.value.isSubset(of: ["Foundation"]) }
        #expect(offenders.isEmpty, "MarsDawnThemes must import only Foundation: \(offenders)")
    }
}
