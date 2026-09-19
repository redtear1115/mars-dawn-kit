#if os(macOS)
import ArgumentParser
import Foundation
import Testing
@testable import marsdawn

/// `marsdawn skill` (#60): the agent skill printed by the CLI it describes, so it can never name an
/// option the installed version lacks.
struct SkillTests {
    /// Everything the CLI's own help lists, across the command and its subcommands.
    static let helpText = [
        MarsDawnCommand.helpMessage(),
        MarsDawnCommand.helpMessage(for: MarsDawnCommand.Export.self),
        MarsDawnCommand.helpMessage(for: MarsDawnCommand.Open.self),
        MarsDawnCommand.helpMessage(for: MarsDawnCommand.Skill.self),
    ].joined(separator: "\n")

    /// Long options in `text` that the help doesn't list.
    static func unknownFlags(in text: String) -> [String] {
        let flags = Set(text.matches(of: /--[a-z][a-z-]*[a-z]/).map { String($0.output) })
        return flags.filter { !helpText.contains($0) }.sorted()
    }

    /// The code in `text`: fenced blocks and inline code spans, where commands are written.
    static func code(in text: String) -> String {
        var code: [String] = []
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { fenced.toggle(); continue }
            if fenced { code.append(line) } else { code += line.matches(of: /`([^`]+)`/).map { String($0.output.1) } }
        }
        return code.joined(separator: "\n")
    }

    /// `marsdawn <word>` commands written as code in `text` that aren't subcommands.
    static func unknownCommands(in text: String) -> [String] {
        let known = MarsDawnCommand.configuration.subcommands.map { $0._commandName }
        let named = Set(code(in: text).matches(of: /marsdawn ([a-z]+)\b/).map { String($0.output.1) })
        return named.filter { !known.contains($0) }.sorted()
    }

    @Test func itIsFrontmatterThenMarkdown() throws {
        let text = MarsDawnSkill.text
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "---")
        let close = try #require(lines.dropFirst().firstIndex(of: "---"), "the frontmatter is closed")
        let front = lines[1..<close]
        #expect(front.contains("name: marsdawn"))
        let description = front.first { $0.hasPrefix("description: ") }?.dropFirst("description: ".count)
        #expect((description?.count ?? 0) > 40, "a description an agent can match on")
        #expect(lines[(close + 1)...].first { !$0.isEmpty } == "# marsdawn")
    }

    @Test func itNamesOnlyOptionsAndCommandsTheCLIHas() {
        let flags = Set(MarsDawnSkill.text.matches(of: /--[a-z][a-z-]*[a-z]/).map { String($0.output) })
        #expect(flags.contains("--json") && flags.contains("--folder"), "positive fixture: the check sees the skill's flags")
        #expect(Self.unknownFlags(in: MarsDawnSkill.text).isEmpty, "\(Self.unknownFlags(in: MarsDawnSkill.text))")
        #expect(Self.code(in: MarsDawnSkill.text).contains("marsdawn open plan.md:42"), "positive fixture: the check reads the skill's code")
        #expect(Self.unknownCommands(in: MarsDawnSkill.text).isEmpty, "\(Self.unknownCommands(in: MarsDawnSkill.text))")
    }

    /// The check itself: a flag or command the CLI doesn't have is caught.
    @Test func theCheckCatchesWhatTheCLILacks() {
        #expect(Self.unknownFlags(in: "use `marsdawn export a.md --frobnicate`") == ["--frobnicate"])
        #expect(Self.unknownCommands(in: "run `marsdawn publish a.md`") == ["publish"])
        #expect(Self.unknownCommands(in: "then marsdawn asked the app") == [], "prose isn't a command")
    }

    /// The exit-code table agrees with the codes and kinds the CLI returns.
    @Test func theExitCodeTableMatchesTheCLI() {
        let rows = MarsDawnSkill.text.matches(of: /\| (\d+) \| `([a-z_]+)` \|/)
        #expect(rows.count == 4, "positive fixture: the four failure rows")
        for row in rows {
            let code = CLIFailure.Code(rawValue: Int32(row.output.1)!)
            #expect(code?.kind == String(row.output.2), "row \(row.output.1)")
        }
    }

    /// One source: the repository's `skill/SKILL.md` is what `marsdawn skill` prints, byte for
    /// byte, so the website can check its copy against the file at a tag without building Swift.
    @Test func theEmbeddedTextIsTheSkillFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skill/SKILL.md")
        let data = try Data(contentsOf: file)
        #expect(data.count > 1000, "positive fixture: the file has the skill in it")
        #expect(data == Data((MarsDawnSkill.text + "\n").utf8))
    }

    @Test func itPrintsTheSkillAndNothingElse() throws {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        try MarsDawnCommand.Skill.parse([]).run()
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(out == MarsDawnSkill.text + "\n")
    }
}
#endif
