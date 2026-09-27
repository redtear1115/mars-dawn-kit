import Foundation
import Testing
@testable import MarsDawnThemes

/// The fixture set (design §6.2, kit #125): valid themes that must pass, and invalid themes named
/// `<rule>--<case>.json` that must fail with **exactly** that rule -- a fixture two rules catch
/// fails here, because it would not show that either rule works on its own.
struct ThemeFixtureTests {
    static let root = Bundle.module.url(forResource: "ThemeFixtures", withExtension: nil)!

    static func files(_ folder: String) -> [URL] {
        let url = root.appendingPathComponent(folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { url.appendingPathComponent($0) }
    }

    static let valid = files("valid")
    static let invalid = files("invalid")

    static func rule(of fixture: URL) -> String {
        String(fixture.deletingPathExtension().lastPathComponent.split(separator: "--", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    static let expectedMessages: [String: String] = {
        let url = root.appendingPathComponent("expected-messages.json")
        return (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }()

    @Test func theFixtureSetIsThere() {
        #expect(Self.valid.count >= 8, "positive fixture: valid themes found (\(Self.valid.count))")
        #expect(Self.invalid.count >= 50, "positive fixture: invalid themes found (\(Self.invalid.count))")
        #expect(Self.expectedMessages.count >= 6)
    }

    @Test(arguments: valid)
    func validFixturePasses(_ fixture: URL) throws {
        let report = ThemeValidator.validate(data: try Data(contentsOf: fixture))
        #expect(report.issues.isEmpty, "\(fixture.lastPathComponent): \(report.issues)")
        #expect(report.theme != nil)
    }

    @Test(arguments: invalid)
    func invalidFixtureFailsWithExactlyItsRule(_ fixture: URL) throws {
        let report = ThemeValidator.validate(data: try Data(contentsOf: fixture))
        let expected = Self.rule(of: fixture)
        let rules = Set(report.issues.map(\.rule))
        #expect(report.theme == nil, "\(fixture.lastPathComponent) validated")
        #expect(rules == [expected], "\(fixture.lastPathComponent): want only \(expected), got \(report.issues)")
        if let message = Self.expectedMessages[fixture.lastPathComponent] {
            #expect(report.issues.contains { $0.message == message }, "\(fixture.lastPathComponent): no issue says \(message); got \(report.issues.map(\.message))")
        }
    }

    /// Every rule id the validator can report has at least one fixture, apart from the ones that
    /// need something a file in a folder can't be (checked in `ThemeFileRuleTests` and the CLI's
    /// tests). The ids are read from the validator's own source, so a new rule without a fixture
    /// fails here.
    @Test func everyRuleHasAFixture() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnThemes")
        var rules = Set<String>()
        for name in ["ThemeValidator.swift", "ThemeText.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            // `rule: "…"` arguments and `case … = "…"` raw values (ThemeDisplayText.Problem).
            for match in text.matches(of: /(?:rule: |= )"([a-z]+\.[A-Za-z]+)"/) {
                rules.insert(String(match.output.1))
            }
        }
        #expect(rules.count >= 25, "positive fixture: rule ids found in the source (\(rules.sorted()))")
        let covered = Set(Self.invalid.map(Self.rule(of:)))
        let notFileShaped: Set<String> = ["file.tooLarge"]
        let missing = rules.subtracting(covered).subtracting(notFileShaped)
        #expect(missing.isEmpty, "rules without a fixture: \(missing.sorted())")
    }

    /// M4 fixtures: attacker text in an unknown key and in a name. Both are refused, and nothing
    /// the validator says repeats a control character, an escape sequence or more than
    /// `ThemeMessageText.cap` scalars of the input.
    @Test(arguments: files("hostile"))
    func hostileFixtureIsRefusedAndQuoted(_ fixture: URL) throws {
        let report = ThemeValidator.validate(data: try Data(contentsOf: fixture))
        #expect(report.theme == nil)
        #expect(!report.issues.isEmpty)
        for issue in report.issues {
            let text = issue.description
            #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .control }, "control character in: \(issue)")
            #expect(!text.contains("https://"), "a link survived: \(issue)")
            #expect(!text.contains("@someuser"), "a mention survived: \(issue)")
            #expect(!text.contains(String(repeating: "Z", count: ThemeMessageText.cap)), "more than the cap of the input: \(issue)")
        }
    }
}

/// The file-level rules that need data no fixture file should hold.
struct ThemeFileRuleTests {
    @Test func oversizeDataIsRefusedUnread() {
        let data = Data(repeating: UInt8(ascii: " "), count: ThemeValidator.maxFileBytes + 1)
        let report = ThemeValidator.validate(data: data)
        #expect(report.issues.map(\.rule) == ["file.tooLarge"])
    }

    /// The boundary itself is accepted: a valid theme padded to exactly the cap still validates.
    @Test func dataAtTheCapIsRead() throws {
        let fixture = ThemeFixtureTests.root.appendingPathComponent("valid/sample-dawn.json")
        var data = try Data(contentsOf: fixture)
        data.append(Data(repeating: UInt8(ascii: " "), count: ThemeValidator.maxFileBytes - data.count))
        #expect(data.count == ThemeValidator.maxFileBytes)
        #expect(ThemeValidator.validate(data: data).issues.isEmpty)
    }
}
