import Foundation
import MarsDawnKit
import Testing

/// The platform-neutral HTML golden corpus (kit #261): `Tests/Fixtures/html-golden/`.
///
/// Each fixture is `<name>.md` (the input), `<name>.html` (the renderer's exact output) and, when
/// it needs a renderer option, `<name>.options.json`. The format is described for implementers in
/// other languages in `Tests/Fixtures/html-golden/README.md`; this file is one implementation of it.
///
/// The directory sits outside every SwiftPM target, so it is found from this file's own path and
/// read straight from the source tree, never copied into a bundle.
///
/// `MARSDAWN_UPDATE_HTML_GOLDENS=1` rewrites every `.html` from the current renderer and fails each
/// fixture with "updated, not compared". A run without it never writes.
enum HTMLGoldenCorpus {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MarsDawnKitTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/html-golden", isDirectory: true)

    static let updateVariable = "MARSDAWN_UPDATE_HTML_GOLDENS"

    static var isUpdating: Bool {
        ProcessInfo.processInfo.environment[updateVariable] == "1"
    }

    /// Files in the directory that are documentation, not fixtures.
    static let nonFixtureFiles: Set<String> = ["README.md", ".gitattributes"]

    /// Every category #261 asks for, by the fixture-name prefix that covers it. A category with no
    /// fixture whose name starts with its prefix fails `everyCategoryHasAFixture`.
    static let requiredCategories: [(prefix: String, what: String)] = [
        ("headings-", "headings and heading ids"),
        ("headings-toc", "[TOC] table of contents"),
        ("lists-", "bullet and ordered lists"),
        ("lists-tasks", "task lists"),
        ("tables-", "GFM tables"),
        ("code-", "code blocks and code spans"),
        ("code-hackmd", "HackMD code-fence info strings (js=, js=101, js!, ...)"),
        ("mermaid-", "Mermaid blocks"),
        ("math-", "TeX math"),
        ("callouts-alerts", "GitHub alerts ([!NOTE] ...)"),
        ("callouts-foldable", "foldable alerts ([!note]- / [!tip]+)"),
        ("callouts-containers", "::: containers, spoiler included"),
        ("marks-", "==mark==, ^sup^, ~sub~"),
        ("images-", "images, with HackMD =WxH sizes"),
        ("embeds-", "HackMD {%embed %} tags as links"),
        ("frontmatter-", "front matter"),
        ("footnotes-", "footnotes"),
        ("cjk-", "CJK line breaking and hard-break mode"),
        ("safety-", "raw-HTML and URL safety: script, event handlers, javascript: URLs"),
    ]

    /// A fixture name: lowercase ASCII letters, digits and `-`, starting with a letter.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }

    /// Fixture names, from the `.md` files (README.md excluded).
    static func names() -> [String] {
        files().filter { $0.hasSuffix(".md") && !nonFixtureFiles.contains($0) }.map { String($0.dropLast(3)) }
    }

    static func url(_ name: String, _ suffix: String) -> URL {
        directory.appendingPathComponent(name + suffix)
    }

    // MARK: Options

    struct OptionsError: Error, CustomStringConvertible {
        let description: String
    }

    /// The option keys a fixture may set, and how each is applied. Anything else is an error.
    static let optionKeys: Set<String> = ["softBreaksAsLineBreaks", "frontMatterLabel", "footnoteBackLabel"]

    /// The options for `name`: the pinned defaults, changed by its `.options.json` if there is one.
    ///
    /// Every option is set here explicitly rather than left to `Options()`'s defaults, so the
    /// corpus says what it renders with: in particular the two labels are fixed English strings,
    /// never a localised string from the test machine.
    static func options(for name: String) throws -> MarkdownRenderer.Options {
        let file = url(name, ".options.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return pinnedDefaults }
        return try options(json: Data(contentsOf: file), name: name)
    }

    /// The options every fixture starts from.
    static var pinnedDefaults: MarkdownRenderer.Options {
        MarkdownRenderer.Options(
            maxBytes: ParseLimits.defaultMaxBytes,
            maxNodes: ParseLimits.defaultMaxNodes,
            frontMatterLabel: "Document info",
            footnoteBackLabel: "Back to reference",
            softBreaksAsLineBreaks: false,
            resolveImageSource: { $0 }
        )
    }

    /// `pinnedDefaults` changed by the options file `data` of fixture `name`.
    static func options(json data: Data, name: String) throws -> MarkdownRenderer.Options {
        var options = pinnedDefaults
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OptionsError(description: "\(name).options.json: the top level must be a JSON object")
        }
        let unknown = Set(object.keys).subtracting(optionKeys).sorted()
        guard unknown.isEmpty else {
            throw OptionsError(description: "\(name).options.json: unknown key(s) \(unknown); known keys are \(optionKeys.sorted())")
        }
        for (key, value) in object {
            switch key {
            case "softBreaksAsLineBreaks":
                // JSONSerialization gives NSNumber for both numbers and booleans; accept only a real boolean.
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw OptionsError(description: "\(name).options.json: \(key) must be true or false")
                }
                options.softBreaksAsLineBreaks = number.boolValue
            case "frontMatterLabel", "footnoteBackLabel":
                guard let string = value as? String else {
                    throw OptionsError(description: "\(name).options.json: \(key) must be a string")
                }
                if key == "frontMatterLabel" { options.frontMatterLabel = string } else { options.footnoteBackLabel = string }
            default:
                break
            }
        }
        return options
    }

    // MARK: Rendering and comparing

    /// The input as the renderer receives it: the file's bytes, which must be valid UTF-8, unchanged.
    static func input(_ name: String) throws -> String {
        let data = try Data(contentsOf: url(name, ".md"))
        guard let string = String(data: data, encoding: .utf8), Data(string.utf8) == data else {
            throw OptionsError(description: "\(name).md is not valid UTF-8")
        }
        return string
    }

    static func render(_ name: String) throws -> Data {
        Data(MarkdownRenderer.render(try input(name), options: try options(for: name)).utf8)
    }

    /// A readable account of the first difference between `expected` and `actual`, or nil when
    /// they are the same bytes.
    static func difference(fixture: String, expected: Data, actual: Data) -> String? {
        guard expected != actual else { return nil }
        let firstByte = zip(expected, actual).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(expected.count, actual.count)
        let expectedLines = String(decoding: expected, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let actualLines = String(decoding: actual, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        var line = 0
        while line < expectedLines.count, line < actualLines.count, expectedLines[line] == actualLines[line] { line += 1 }
        func show(_ lines: [Substring], _ index: Int) -> String {
            index < lines.count ? String(reflecting: String(lines[index])) : "<no line: the output ends before it>"
        }
        return """
        HTML golden mismatch in fixture '\(fixture)' (\(fixture).html)
          first differing line: \(line + 1), first differing byte offset: \(firstByte)
          expected: \(show(expectedLines, line))
          actual:   \(show(actualLines, line))
          sizes: expected \(expected.count) bytes, actual \(actual.count) bytes
          If the renderer change is intended, run with \(updateVariable)=1 and review the diff of the .html files.
        """
    }
}

@Suite("HTML golden corpus (kit #261)", .serialized)
struct HTMLGoldenCorpusTests {
    @Test("Fixture renders to its golden, byte for byte, the same twice", arguments: HTMLGoldenCorpus.names())
    func fixtureMatchesGolden(_ name: String) throws {
        let first = try HTMLGoldenCorpus.render(name)
        let second = try HTMLGoldenCorpus.render(name)
        if let difference = HTMLGoldenCorpus.difference(fixture: name, expected: first, actual: second) {
            Issue.record("Unstable output: two renders in one process differ.\n\(difference)")
        }
        let golden = HTMLGoldenCorpus.url(name, ".html")
        if HTMLGoldenCorpus.isUpdating {
            let old = try? Data(contentsOf: golden)
            try first.write(to: golden, options: .atomic)
            let state = old == nil ? "created" : (old == first ? "unchanged" : "CHANGED")
            Issue.record("\(HTMLGoldenCorpus.updateVariable)=1: wrote \(name).html (\(state)); updated, not compared. Run again without it to compare.")
            return
        }
        guard let expected = try? Data(contentsOf: golden) else {
            Issue.record("Fixture '\(name)' has no \(name).html. Create it with \(HTMLGoldenCorpus.updateVariable)=1 and review it.")
            return
        }
        if let difference = HTMLGoldenCorpus.difference(fixture: name, expected: expected, actual: first) {
            Issue.record(Comment(rawValue: difference))
        }
    }

    @Test func directoryIsNotEmpty() {
        #expect(!HTMLGoldenCorpus.names().isEmpty, "No fixtures found in \(HTMLGoldenCorpus.directory.path)")
    }

    /// Every file is part of a fixture (or the README), every `.md` has its `.html`, every `.html`
    /// and `.options.json` has its `.md`, and every name is in the allowed alphabet.
    @Test func everyFileBelongsToACompleteFixture() {
        let files = HTMLGoldenCorpus.files()
        let names = Set(HTMLGoldenCorpus.names())
        for file in files where !HTMLGoldenCorpus.nonFixtureFiles.contains(file) {
            let base: String
            if file.hasSuffix(".options.json") {
                base = String(file.dropLast(".options.json".count))
            } else if file.hasSuffix(".html") {
                base = String(file.dropLast(".html".count))
            } else if file.hasSuffix(".md") {
                base = String(file.dropLast(".md".count))
            } else {
                Issue.record("\(file): not a fixture file (.md, .html or .options.json)")
                continue
            }
            #expect(HTMLGoldenCorpus.isValidName(base), "\(file): a fixture name is lowercase a-z, 0-9 and '-', starting with a letter")
            #expect(names.contains(base), "\(file) has no \(base).md")
        }
        for name in names.sorted() {
            #expect(files.contains(name + ".html"), "\(name).md has no \(name).html")
        }
    }

    @Test func everyOptionsFileIsValid() {
        for name in HTMLGoldenCorpus.names() {
            #expect(throws: Never.self, "\(name).options.json") { _ = try HTMLGoldenCorpus.options(for: name) }
        }
    }

    @Test func everyCategoryHasAFixture() {
        let names = HTMLGoldenCorpus.names()
        for category in HTMLGoldenCorpus.requiredCategories {
            #expect(names.contains { $0.hasPrefix(category.prefix) },
                    "No fixture for \(category.what): add one named \(category.prefix)…")
        }
    }

    /// The checks above must catch what they claim to: an unknown option key, a bad value type, a
    /// mismatch report that names the fixture and line.
    @Test func checksCatchWhatTheyClaim() throws {
        #expect(throws: HTMLGoldenCorpus.OptionsError.self) { try Self.parse(#"{"softBreakAsLineBreaks": true}"#) }
        #expect(throws: HTMLGoldenCorpus.OptionsError.self) { try Self.parse(#"{"softBreaksAsLineBreaks": 1}"#) }
        #expect(throws: HTMLGoldenCorpus.OptionsError.self) { try Self.parse(#"{"frontMatterLabel": 3}"#) }
        #expect(throws: HTMLGoldenCorpus.OptionsError.self) { try Self.parse(#"[]"#) }
        let parsed = try Self.parse(#"{"softBreaksAsLineBreaks": true, "footnoteBackLabel": "x"}"#)
        #expect(parsed.softBreaksAsLineBreaks && parsed.footnoteBackLabel == "x" && parsed.frontMatterLabel == "Document info")

        let report = try #require(HTMLGoldenCorpus.difference(fixture: "f", expected: Data("a\nb\nc".utf8), actual: Data("a\nB\nc".utf8)))
        #expect(report.contains("'f'") && report.contains("line: 2") && report.contains(#""b""#) && report.contains(#""B""#))
        #expect(HTMLGoldenCorpus.difference(fixture: "f", expected: Data("a".utf8), actual: Data("a".utf8)) == nil)
    }

    private static func parse(_ json: String) throws -> MarkdownRenderer.Options {
        try HTMLGoldenCorpus.options(json: Data(json.utf8), name: "probe")
    }

    /// The goldens must not depend on the machine's language (kit #187's area). Overrides the
    /// process's preferred languages in memory (the argument domain, never written to disk), checks
    /// the override really reached `Locale.preferredLanguages` and the kit's own localised strings,
    /// and requires every fixture to render to the same bytes as without it.
    @Test func goldensDoNotDependOnTheMachineLanguage() throws {
        let baseline = try HTMLGoldenCorpus.names().map { ($0, try HTMLGoldenCorpus.render($0)) }
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for languages in [["ja"], ["zh-Hant"], ["de"]] {
            var domain = previous
            domain["AppleLanguages"] = languages
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
            // Proof the override is live for the process, not just stored: the system's preferred
            // languages and the kit's own language-dependent strings both follow it.
            let seen = Locale.preferredLanguages
            #expect(seen.first?.hasPrefix(languages[0]) == true, "the language override did not take effect: \(seen)")
            #expect(CalloutTitles.preferred() != CalloutTitles.english,
                    "under \(languages[0]) the kit's callout titles should be translated, or this test proves nothing")
            for (name, expected) in baseline {
                let actual = try HTMLGoldenCorpus.render(name)
                if let difference = HTMLGoldenCorpus.difference(fixture: name, expected: expected, actual: actual) {
                    Issue.record("Output depends on the preferred language (\(languages[0])).\n\(difference)")
                }
            }
        }
    }
}
