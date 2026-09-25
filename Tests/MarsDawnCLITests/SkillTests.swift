#if os(macOS)
import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import marsdawn

/// `marsdawn skill` (#60): the agent skill printed by the CLI it describes, so it can never name an
/// option the installed version lacks.
///
/// `.serialized` (#120 verifier round 3): several tests here mutate `SkillInstaller.defaultDirectory`
/// and `$HOME` — shared, process-wide state — and restore it afterward; without `.serialized`,
/// Swift Testing's default parallel execution could interleave two of them and have one test
/// restore the other's override, or observe it mid-change. `.timeLimit` is a backstop for the
/// same round: the previous attempt at this fix (raw `dup2` of the process's real stdout,
/// concurrently, across tests) didn't just flake, it *hung* — the verifier caught
/// `nonJSONTextNamesTheAction` blocked forever in a pipe read waiting for an EOF that would never
/// come, because another test held a second write end of the same pipe open. That specific bug is
/// fixed by not touching fd 1 at all any more (see `MarsDawnCommand.Skill.run`'s injectable
/// `write` parameter, and `itPrintsTheSkillAndNothingElse` / `jsonReportsPathAndEachAction` /
/// `nonJSONTextNamesTheAction` / `aDifferingInstallExitsSixtyFour` below), but a time limit means
/// any *other* hang here fails loudly instead of blocking a whole run.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SkillTests {
    /// Swift Testing makes a fresh `SkillTests` instance per test, so this runs before every one
    /// of them and poisons `SkillInstaller.defaultDirectory` (#120 verifier round 2): any test
    /// that reaches it without first installing its own override — the point of the seam in the
    /// first place — fails loudly instead of silently writing into the real `~/.claude`. The one
    /// test that legitimately exercises the default (`withoutDirItWritesTheDefaultDirectory`)
    /// installs its own override before calling `install(dir: nil, …)`, same as every other test
    /// here installs its own fakes for `MarsDawnApp.locate` elsewhere in this target.
    init() {
        SkillInstaller.defaultDirectory = {
            Issue.record("SkillInstaller.defaultDirectory was called with no test override in place — this would have touched the real ~/.claude/skills/marsdawn")
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("marsdawn-skill-install-UNGUARDED-\(UUID().uuidString)", isDirectory: true)
        }
    }

    /// Fails the test if `path` is anywhere under the real home directory — belt and suspenders
    /// alongside the `init()` poisoning above, for the one test that legitimately calls the
    /// default-directory seam.
    static func assertNeverTheRealHome(_ path: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(!path.hasPrefix(realHome + "/"), "must never resolve inside the real home directory during tests: \(path)", sourceLocation: sourceLocation)
    }

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

    /// No raw stdout redirection (#120 verifier round 3 — see the suite's own doc comment above):
    /// `MarsDawnCommand.Skill.run(…)`'s `write` parameter is captured directly, a plain local
    /// closure over a local array, nothing shared or global. `print`'s own "\n" terminator is what
    /// would land on real stdout; `write` itself is called with just the text, so the expectation
    /// compares against `MarsDawnSkill.text` with no appended newline.
    @Test func itPrintsTheSkillAndNothingElse() throws {
        var captured: [String] = []
        try MarsDawnCommand.Skill.run(install: false, dir: nil, force: false, json: false) { captured.append($0) }
        #expect(captured == [MarsDawnSkill.text])
    }

    // MARK: - --install (#120)

    /// Runs `MarsDawnCommand.Skill.run` with `arguments` parsed first (so parsing/validation
    /// still goes through the same path a real invocation would), capturing what it writes via a
    /// local closure over a local array — never a shared global, so this is safe under Swift
    /// Testing's default parallel execution regardless of what else is running at the same time
    /// (#120 verifier round 3; see the suite's own doc comment for what the previous, fd-based
    /// version of this actually did: a deadlock, not just a flake).
    static func runSkillCapturingOutput(_ arguments: [String]) throws -> [String] {
        let command = try MarsDawnCommand.Skill.parse(arguments)
        var captured: [String] = []
        try MarsDawnCommand.Skill.run(install: command.install, dir: command.dir, force: command.force, json: command.output.json) {
            captured.append($0)
        }
        return captured
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

    /// Also the "target exists and the replace succeeds" case the atomic `rename(2)` swap needs
    /// covered (verifier round 3): this goes through exactly the same `install` call as every
    /// other successful replace here, so it's covered by the same code path as
    /// `aSymlinkInsideTheTargetFolderIsReplacedNormally` and the `--force` half of
    /// `anUnreadableFileIsRefusedWithoutForceAndReplacedWithForce`.
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

    /// Verifier round 3: a failed `rename(2)` must never lose what was at `target` — that's the
    /// whole point of using `rename(2)` instead of deleting `target` and then moving the
    /// replacement in. `UF_IMMUTABLE` (`chflags`) makes the kernel refuse to rename *over* an
    /// existing file without touching it first, which is exactly the shape of failure that
    /// matters here: the temp file still gets written into the same directory (that write isn't
    /// blocked by the flag — it's a new path, not `target`), and then the swap itself fails.
    @Test func aFailedRenameNeverLosesTheExistingFile() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("SKILL.md")
        let original = Data("stale, and about to be made immutable\n".utf8)
        try original.write(to: target)
        #expect(chflags(target.path, UInt32(UF_IMMUTABLE)) == 0, "positive fixture: the immutable flag was actually set")
        defer { chflags(target.path, 0) } // always clear it, even if an assertion below fails

        #expect(throws: (any Error).self) {
            _ = try SkillInstaller.install(dir: dir.path, force: true)
        }

        chflags(target.path, 0) // must be clear again to read it back
        #expect(try Data(contentsOf: target) == original, "a failed rename must leave the original file exactly as it was")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "the temp file must be cleaned up even when the rename it was for fails")
    }

    /// Verifier round 2, claim (1): the target being anything other than a plain file — most
    /// concretely a folder — must refuse unconditionally, `--force` included, and must never
    /// delete it. `--force` means "replace the differing SKILL.md I asked about," not "delete
    /// whatever's in the way."
    @Test func aDirectoryAtTheTargetIsRefusedEvenWithForce() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let canary = target.appendingPathComponent("dont-delete-me.txt")
        try Data("precious".utf8).write(to: canary)

        for force in [false, true] {
            #expect {
                _ = try SkillInstaller.install(dir: dir.path, force: force)
            } throws: { ($0 as? SkillInstallFailure)?.kind == .notAFile }
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue, "the folder must still be there")
        #expect(try Data(contentsOf: canary) == Data("precious".utf8), "must never delete what's inside it")
    }

    /// Verifier round 2, claim (2): a plain file already at the target that can't be read (here,
    /// no read permission) must be treated as differing — refused without `--force`, not silently
    /// overwritten and reported "installed".
    @Test func anUnreadableFileIsRefusedWithoutForceAndReplacedWithForce() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("SKILL.md")
        let original = Data("# my own notes, unreadable on purpose\n".utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path) }

        #expect {
            _ = try SkillInstaller.install(dir: dir.path, force: false)
        } throws: { ($0 as? SkillInstallFailure)?.kind == .unreadable }
        // Still unreadable and untouched: restore permission only to check its size didn't change,
        // never its content changed underneath us (that would defeat the point of this test).
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        #expect(try Data(contentsOf: target) == original, "a refused install must not touch the existing file")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)

        let result = try SkillInstaller.install(dir: dir.path, force: true)
        #expect(result.action == .replaced)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        #expect(try Data(contentsOf: target) == Data((MarsDawnSkill.text + "\n").utf8))
    }

    @Test func dirWritesToThatFolderInsteadOfTheDefault() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("agents/other")
        // A fake "default" of our own, under the same scratch root, just to prove --dir never
        // touches it — never the poisoned seam `init()` installs, and never the real one.
        let fakeDefault = root.appendingPathComponent(".claude/skills/marsdawn", isDirectory: true)
        let original = SkillInstaller.defaultDirectory
        defer { SkillInstaller.defaultDirectory = original }
        SkillInstaller.defaultDirectory = { fakeDefault }

        let result = try SkillInstaller.install(dir: dir.path, force: false)

        #expect(result.path == dir.appendingPathComponent("SKILL.md").path)
        #expect(!FileManager.default.fileExists(atPath: fakeDefault.appendingPathComponent("SKILL.md").path), "must not also write the default location")
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
        Self.assertNeverTheRealHome(result.path)
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

        let installedOut = try Self.runSkillCapturingOutput(["--install", "--dir", dir.path, "--json"])
        #expect(installedOut.count == 1)
        let installed = try #require(try JSONSerialization.jsonObject(with: Data(installedOut[0].utf8)) as? [String: Any])
        #expect(installed["ok"] as? Bool == true)
        #expect(installed["action"] as? String == "installed")
        #expect(installed["path"] as? String == dir.appendingPathComponent("SKILL.md").path)

        let unchangedOut = try Self.runSkillCapturingOutput(["--install", "--dir", dir.path, "--json"])
        #expect(unchangedOut.count == 1)
        let unchanged = try #require(try JSONSerialization.jsonObject(with: Data(unchangedOut[0].utf8)) as? [String: Any])
        #expect(unchanged["action"] as? String == "unchanged")

        try Data("stale\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        let replacedOut = try Self.runSkillCapturingOutput(["--install", "--dir", dir.path, "--force", "--json"])
        #expect(replacedOut.count == 1)
        let replaced = try #require(try JSONSerialization.jsonObject(with: Data(replacedOut[0].utf8)) as? [String: Any])
        #expect(replaced["action"] as? String == "replaced")
    }

    @Test func nonJSONTextNamesTheAction() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("skill")
        let target = dir.appendingPathComponent("SKILL.md")

        let installedOut = try Self.runSkillCapturingOutput(["--install", "--dir", dir.path])
        #expect(installedOut.count == 1)
        #expect(installedOut[0].contains("Installed") && installedOut[0].contains(target.path))

        let unchangedOut = try Self.runSkillCapturingOutput(["--install", "--dir", dir.path])
        #expect(unchangedOut.count == 1)
        #expect(unchangedOut[0].contains("Already installed") && unchangedOut[0].contains(target.path))
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
            _ = try Self.runSkillCapturingOutput(["--install", "--dir", dir.path])
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

    /// Verifier round 3: `homeDirectoryForCurrentUser` ignores `$HOME`, so `productionDefaultDirectory`
    /// reads `$HOME` itself first — a run under a temp `$HOME` (this test's own fake one, restored
    /// in the `defer`) never falls through to the real home. Calls `productionDefaultDirectory`
    /// directly, bypassing the mutable `defaultDirectory` seam (poisoned by `init()` above) on
    /// purpose: this checks the `$HOME` logic itself, and building a `URL` touches no filesystem.
    @Test func productionDefaultDirectoryHonoursHOME() {
        let originalHOME = ProcessInfo.processInfo.environment["HOME"]
        let fakeHome = "/tmp/marsdawn-fake-home-\(UUID().uuidString)"
        setenv("HOME", fakeHome, 1)
        defer {
            if let originalHOME { setenv("HOME", originalHOME, 1) } else { unsetenv("HOME") }
        }

        #expect(SkillInstaller.productionDefaultDirectory().path == "\(fakeHome)/.claude/skills/marsdawn")
    }

    /// Unset `$HOME` falls back to `homeDirectoryForCurrentUser`, not to some other default.
    @Test func productionDefaultDirectoryFallsBackWithoutHOME() {
        let originalHOME = ProcessInfo.processInfo.environment["HOME"]
        unsetenv("HOME")
        defer {
            if let originalHOME { setenv("HOME", originalHOME, 1) }
        }

        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/marsdawn", isDirectory: true)
        #expect(SkillInstaller.productionDefaultDirectory().path == expected.path)
    }
}
#endif
