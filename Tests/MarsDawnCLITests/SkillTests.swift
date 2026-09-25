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
        #expect(flags.contains("--json") && flags.contains("--force"), "positive fixture: the check sees the skill's flags")
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

    /// The exit-code table agrees with the codes and kinds the CLI returns, and lists every one:
    /// a hard-coded row count let 0.5.2's exit 6 go missing from the skill.
    @Test func theExitCodeTableMatchesTheCLI() {
        let rows = MarsDawnSkill.text.matches(of: /\| (\d+) \| `([a-z_]+)` \|/)
        let cliCodes = (Int32(1)...Int32(63)).compactMap(CLIFailure.Code.init(rawValue:)).map(\.rawValue)
        #expect(cliCodes.count >= 5, "positive fixture: the CLI's failure codes")
        #expect(rows.map { Int32($0.output.1)! } == cliCodes, "one row per failure code, in order")
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

    // MARK: - --install (#120)

    /// Redirects stdout for `body`, always restoring it even if `body` throws, and returns what
    /// was written.
    static func captureStdout(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var caught: Error?
        do { try body() } catch { caught = error }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if let caught { throw caught }
        return out
    }

    /// A fresh, empty folder under a per-test temporary root, never `~/.claude` — #120's tests
    /// "must use a temp HOME/dir and never touch the real ~/.claude".
    static func tempRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-skill-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func installParsesFlagsTogether() throws {
        let command = try MarsDawnCommand.Skill.parse(["--install", "--dir", "/tmp/x", "--force", "--json"])
        #expect(command.install && command.force && command.output.json)
        #expect(command.dir == "/tmp/x")
        #expect(!(try MarsDawnCommand.Skill.parse([])).install)
    }

    /// `--dir`, `--force` and `--json` describe what `--install` does, so each is a usage error on
    /// its own — the plain, unchanged `marsdawn skill` never silently ignores one.
    @Test func installOnlyOptionsRequireInstall() {
        #expect(throws: (any Error).self) { try MarsDawnCommand.Skill.parse(["--dir", "/tmp/x"]) }
        #expect(throws: (any Error).self) { try MarsDawnCommand.Skill.parse(["--force"]) }
        #expect(throws: (any Error).self) { try MarsDawnCommand.Skill.parse(["--json"]) }
    }

    @Test func freshInstallWritesTheSkillAndCreatesFolders() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("nested/skills/marsdawn")

        let result = try SkillInstaller.install(dir: dir.path, force: false)

        #expect(result.action == .installed)
        #expect(result.path == dir.appendingPathComponent("SKILL.md").path)
        let written = try Data(contentsOf: dir.appendingPathComponent("SKILL.md"))
        #expect(written == Data((MarsDawnSkill.text + "\n").utf8))
    }

    @Test func aByteIdenticalFileIsReportedUnchangedAndNeverRewritten() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        _ = try SkillInstaller.install(dir: dir.path, force: false)
        let target = dir.appendingPathComponent("SKILL.md")
        let before = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date

        let result = try SkillInstaller.install(dir: dir.path, force: false)

        #expect(result.action == .unchanged)
        let after = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        #expect(before == after, "unchanged must mean nothing was written, not just the same bytes")
    }

    /// The no-overwrite rule (#120): a `SKILL.md` that already exists and differs is refused
    /// without `--force`, and the refused install must not touch it.
    @Test func aDifferingFileIsRefusedWithoutForceAndLeftUntouched() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("SKILL.md")
        let original = Data("# my own notes\n".utf8)
        try original.write(to: target)

        #expect {
            _ = try SkillInstaller.install(dir: dir.path, force: false)
        } throws: { ($0 as? SkillInstallFailure)?.kind == .differs }
        #expect(cliExitCode(for: SkillInstallFailure(kind: .differs, message: "")) == 64)
        #expect(try Data(contentsOf: target) == original, "a refused install must not touch the existing file")
    }

    @Test func forceReplacesADifferingFile() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("SKILL.md")
        try Data("stale\n".utf8).write(to: target)

        let result = try SkillInstaller.install(dir: dir.path, force: true)

        #expect(result.action == .replaced)
        #expect(try Data(contentsOf: target) == Data((MarsDawnSkill.text + "\n").utf8))
    }

    @Test func dirWritesToThatFolderInsteadOfTheDefault() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("agents/other")

        let result = try SkillInstaller.install(dir: dir.path, force: false)

        #expect(result.path == dir.appendingPathComponent("SKILL.md").path)
        #expect(!FileManager.default.fileExists(atPath: SkillInstaller.defaultDirectory().path), "must not also write the default location")
    }

    @Test func withoutDirItWritesTheDefaultDirectory() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeHome = root.appendingPathComponent(".claude/skills/marsdawn", isDirectory: true)
        let original = SkillInstaller.defaultDirectory
        defer { SkillInstaller.defaultDirectory = original }
        SkillInstaller.defaultDirectory = { fakeHome }

        let result = try SkillInstaller.install(dir: nil, force: false)

        #expect(result.path == fakeHome.appendingPathComponent("SKILL.md").path)
    }

    /// A symlink at the target path is only ever written through when its resolved destination
    /// stays inside the folder `--install` was asked to write to — never followed to overwrite
    /// something elsewhere on disk, `--force` or not.
    @Test func aSymlinkEscapingTheTargetFolderIsRefusedEvenWithForce() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("elsewhere.txt")
        let outsideContent = Data("not the skill".utf8)
        try outsideContent.write(to: outside)
        let target = dir.appendingPathComponent("SKILL.md")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)

        #expect {
            _ = try SkillInstaller.install(dir: dir.path, force: true)
        } throws: { ($0 as? SkillInstallFailure)?.kind == .unsafeSymlink }
        #expect(try Data(contentsOf: outside) == outsideContent, "must never write through a symlink that escapes the folder")
    }

    @Test func aSymlinkInsideTheTargetFolderIsReplacedNormally() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("real-skill.md")
        try Data("stale\n".utf8).write(to: real)
        let target = dir.appendingPathComponent("SKILL.md")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: real)

        let result = try SkillInstaller.install(dir: dir.path, force: true)

        #expect(result.action == .replaced)
    }

    @Test func jsonReportsPathAndEachAction() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")

        let installedOut = try Self.captureStdout {
            try MarsDawnCommand.Skill.parse(["--install", "--dir", dir.path, "--json"]).run()
        }
        let installed = try #require(try JSONSerialization.jsonObject(with: Data(installedOut.utf8)) as? [String: Any])
        #expect(installed["ok"] as? Bool == true)
        #expect(installed["action"] as? String == "installed")
        #expect(installed["path"] as? String == dir.appendingPathComponent("SKILL.md").path)

        let unchangedOut = try Self.captureStdout {
            try MarsDawnCommand.Skill.parse(["--install", "--dir", dir.path, "--json"]).run()
        }
        let unchanged = try #require(try JSONSerialization.jsonObject(with: Data(unchangedOut.utf8)) as? [String: Any])
        #expect(unchanged["action"] as? String == "unchanged")

        try Data("stale\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        let replacedOut = try Self.captureStdout {
            try MarsDawnCommand.Skill.parse(["--install", "--dir", dir.path, "--force", "--json"]).run()
        }
        let replaced = try #require(try JSONSerialization.jsonObject(with: Data(replacedOut.utf8)) as? [String: Any])
        #expect(replaced["action"] as? String == "replaced")
    }

    @Test func nonJSONTextNamesTheAction() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        let target = dir.appendingPathComponent("SKILL.md")

        let installedOut = try Self.captureStdout {
            try MarsDawnCommand.Skill.parse(["--install", "--dir", dir.path]).run()
        }
        #expect(installedOut.contains("Installed") && installedOut.contains(target.path))

        let unchangedOut = try Self.captureStdout {
            try MarsDawnCommand.Skill.parse(["--install", "--dir", dir.path]).run()
        }
        #expect(unchangedOut.contains("Already installed") && unchangedOut.contains(target.path))
    }

    /// Errors from `run()` exit `64`, `SkillInstallFailure`'s own code, not one of
    /// `CLIFailure.Code`'s runtime failure numbers.
    @Test func aDifferingInstallExitsSixtyFour() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("stale\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))

        do {
            _ = try Self.captureStdout {
                try MarsDawnCommand.Skill.parse(["--install", "--dir", dir.path]).run()
            }
            Issue.record("expected a SkillInstallFailure")
        } catch {
            #expect(cliExitCode(for: error) == 64)
            #expect((error as? SkillInstallFailure)?.kind == .differs)
        }
    }

    /// `versionHint` reads a version mentioned near the top of an existing file, for the conflict
    /// message (#120: "the version line if the file has one"), and finds nothing when there isn't
    /// one — today's canonical `SKILL.md` has no such line.
    @Test func versionHintFindsAMentionOrNothing() {
        #expect(SkillInstaller.versionHint(in: "---\nname: marsdawn\n---\ninstalled by marsdawn 0.4.2\n") == "marsdawn 0.4.2")
        #expect(SkillInstaller.versionHint(in: MarsDawnSkill.text) == nil)
        #expect(SkillInstaller.versionHint(in: "nothing here") == nil)
    }
}
#endif
