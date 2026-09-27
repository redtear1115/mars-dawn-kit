#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnKit

/// kit #124, plan S1 item 5: a golden of computed styles for the four built-in themes, rendering
/// the fixed sample document in `ThemeGoldenDocument`. Generated on **unchanged** code (kit
/// `30d323c`) as commit 1 of the theme-params-124 branch, before any refactor commit -- the
/// refactor (moving the per-theme rules in `preview.css` into generated, data-driven CSS) must
/// keep this passing, unchanged, or it has changed what a reader sees.
///
/// To regenerate (only meaningful re-run on `30d323c`, or after a deliberate, reviewed CSS
/// change): `MARSDAWN_WRITE_THEME_GOLDEN=1 swift test --filter ThemeGoldenTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ThemeGoldenTests {
    static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("ThemeGolden/golden.json")

    @Test func computedStylesMatchGolden() async throws {
        let captured = try await ThemeGoldenHarness.capture()

        if ProcessInfo.processInfo.environment["MARSDAWN_WRITE_THEME_GOLDEN"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(captured).write(to: Self.goldenURL)
            Issue.record("Wrote \(Self.goldenURL.path); re-run without MARSDAWN_WRITE_THEME_GOLDEN to verify it.")
            return
        }

        let golden = try JSONDecoder().decode(GoldenSnapshot.self, from: Data(contentsOf: Self.goldenURL))
        #expect(captured.entries.count == golden.entries.count, "positive fixture: both sides cover every theme/mode/selector")
        #expect(captured.entries.count >= 4 * 2 * ThemeGoldenDocument.selectors.count)

        var mismatches: [String] = []
        for entry in golden.entries {
            let key = GoldenKey(theme: entry.theme, mode: entry.mode, selector: entry.selector)
            guard let actual = captured[key] else {
                mismatches.append("\(entry.theme)/\(entry.mode)/\(entry.selector): missing from the capture")
                continue
            }
            for (property, expected) in entry.properties where actual[property] != expected {
                mismatches.append("\(entry.theme)/\(entry.mode)/\(entry.selector) \(property): got \(actual[property] ?? "<nil>"), want \(expected)")
            }
        }
        #expect(mismatches.isEmpty, Comment(rawValue: mismatches.joined(separator: "\n")))
    }
}

/// The selectors the removed 0.5.4 per-theme rules used (plan S1 item 4), extracted once from
/// `Sources/MarsDawnKit/Resources/Preview/preview.css` lines 301-383 at kit `30d323c` into
/// `ThemeGolden/original-per-theme-rules.css` (commit 1, unchanged code). A later commit's
/// `ThemeCSSGenerator` output must produce exactly this set of selectors -- see
/// `ThemeGeneratedCSSTests.generatedSelectorsMatchTheOriginalBlocks`, added once the generator
/// exists; this test only pins down what "the original selectors" are, so that later test can't
/// silently drift from the fixture.
struct OriginalPerThemeSelectorFixtureTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("ThemeGolden/original-per-theme-rules.css")

    @Test func fixtureParsesToTheExpectedSelectors() throws {
        let css = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        let selectors = CSSSelectorExtractor.selectors(in: css)
        // Positive fixture: enough rules were actually found (not an empty/garbled file).
        #expect(selectors.count == 28, "the fixture's own rule count changed: \(selectors.sorted())")
        for expected in [
            #"[data-theme="classic"] h1"#, #"[data-theme="classic"] h1::after"#,
            #"[data-theme="vivid"] h2::before"#, #"[data-theme="modern"] li::marker"#,
            #"[data-theme="dawn"] hr"#, #"[data-theme="classic"] td"#,
            #"[data-theme="classic"] .hljs-title"#,
        ] {
            #expect(selectors.contains(expected), "missing: \(expected)")
        }
    }
}

/// Extracts every rule's selector(s) from a flat (no nested at-rules) CSS text, splitting a
/// comma-separated selector list into its individual selectors -- so `"a, b { … }"` and two
/// separate rules `"a { … }"` `"b { … }"` count the same, which is also how
/// `ThemeCSSGenerator` emits its rules (kit #124: specificity is per simple selector, so writing
/// them separately changes nothing the cascade can see).
enum CSSSelectorExtractor {
    static func selectors(in css: String) -> Set<String> {
        let withoutComments = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var result = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"([^{}]+)\{[^{}]*\}"#, options: [])
        let text = withoutComments as NSString
        for match in pattern.matches(in: withoutComments, range: NSRange(location: 0, length: text.length)) {
            let selectorText = text.substring(with: match.range(at: 1))
            for part in selectorText.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.insert(trimmed) }
            }
        }
        return result
    }
}
#endif
