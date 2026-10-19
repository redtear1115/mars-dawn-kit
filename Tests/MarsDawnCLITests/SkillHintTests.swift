#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import marsdawn

// MARK: - Support

/// A stderr sink a test can read back; the hint runner may call it from any task.
final class HintSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func write(_ text: String) { lock.lock(); storage.append(text); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// A throwaway home: the skill folder and the cache folder both live under it, so nothing a test
/// does with a hint can reach the real `~/.claude` or `~/Library/Caches`.
final class HintSandbox {
    let root: URL
    let sink = HintSink()
    var tty = true
    var version = "0.7.0"
    var environment: [String: String] = [:]

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-hint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HintTesting.installViolationHandler()
    }

    deinit {
        // Permissions a test took away would stop the cleanup.
        for path in [cache.path, skill.path] { chmod(path, 0o700) }
        try? FileManager.default.removeItem(at: root)
    }

    var skill: URL { root.appendingPathComponent("home/.claude/skills/marsdawn", isDirectory: true) }
    var cache: URL { root.appendingPathComponent("home/Library/Caches/marsdawn", isDirectory: true) }
    var cacheFile: URL { cache.appendingPathComponent("skill-hint") }
    var skillFile: URL { skill.appendingPathComponent("SKILL.md") }

    func writeSkill(_ text: String) throws {
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: skillFile)
    }

    func installEqualSkill() throws { try writeSkill(MarsDawnSkill.text + "\n") }

    var stub: SkillHint.Environment {
        let sink = sink, tty = tty
        return SkillHint.Environment(
            cacheDirectory: cache, skillDirectory: skill, isTTY: { tty }, stderr: { sink.write($0) },
            environment: environment, version: version
        )
    }

    /// Runs `body` with this sandbox as the hint's environment, for this task only.
    func run<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        try await SkillHint.$override.withValue(stub, operation: body, isolation: isolation)
    }

    func emit(json: Bool = false) {
        SkillHint.$override.withValue(stub) { SkillHint.emitAfterSuccess(json: json) }
    }

    var storedRecord: String? { try? String(contentsOf: cacheFile, encoding: .utf8) }
}

enum HintTesting {
    /// Makes the production runner reached inside a test fail that test.
    static func installViolationHandler() { _ = installed }

    /// A test that expects the violation sets this for its own task; any other task's violation
    /// is an Issue. Installed once, so no test replaces another's handler.
    @TaskLocal static var expectedViolations: HintSink?

    private static let installed: Void = {
        SkillHint.underTestViolation = { message in
            if let expected = HintTesting.expectedViolations {
                expected.write(message)
            } else {
                Issue.record(Comment(rawValue: message))
            }
        }
    }()

    /// Runs `body` with the hint pointed at a sandbox that says "not a terminal", so a success
    /// path under test can never read or write the real home. For tests not about the hint.
    static func withQuietHint<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async throws -> T {
        let sandbox = try HintSandbox()
        sandbox.tty = false
        return try await sandbox.run(isolation: isolation, body)
    }

    /// Everything written to file descriptor 1 while `body` runs.
    static func captureStdout(_ body: () throws -> Void) rethrows -> Data {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hint-stdout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        fflush(stdout)
        let saved = dup(1)
        let capture = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        dup2(capture, 1)
        close(capture)
        defer { dup2(saved, 1); close(saved) }
        try body()
        fflush(stdout)
        dup2(saved, 1)
        return (try? Data(contentsOf: file)) ?? Data()
    }

    static func marsDawnProcesses() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .filter { ($0.bundleIdentifier ?? "").hasPrefix("dev.southern-light.marsdawn") }
            .map(\.processIdentifier))
    }
}

// MARK: - The pure decision (H1)

struct SkillHintDecisionTests {
    /// Every cell of states x terminal x json x opt-out x stored, with the exact message or nil.
    @Test func theWholeMatrix() {
        let states: [SkillHint.State?] = [.missing, .differs, .equal, nil]
        let optOuts: [String?] = [nil, "", "1", "yes"]
        for state in states {
            for tty in [true, false] {
                for json in [true, false] {
                    for optOut in optOuts {
                        let env = optOut.map { [SkillHint.optOutVariable: $0] } ?? [:]
                        let current = state.map { SkillHint.record(version: "0.7.0", state: $0) }
                        for stored in [nil, current, "0.6.0 \(state?.rawValue ?? "missing")", "0.7.0 other", ""] {
                            let got = SkillHint.decide(state: state, isTTY: tty, json: json, env: env, stored: stored, version: "0.7.0")
                            let optedOut = !(optOut ?? "").isEmpty
                            var expected: String?
                            if tty, !json, !optedOut, stored != current {
                                switch state {
                                case .missing: expected = "Tip: run \"marsdawn skill --install\" so your agent knows how to use marsdawn."
                                case .differs:
                                    expected = "Tip: your agent skill differs from this version of marsdawn. Run \"marsdawn skill --install --force\" to update it (this replaces any local edits)."
                                default: expected = nil
                                }
                            }
                            #expect(got == expected, "state \(String(describing: state)) tty \(tty) json \(json) optOut \(String(describing: optOut)) stored \(String(describing: stored))")
                        }
                    }
                }
            }
        }
    }

    @Test func theMessagesNeverClaimNotInstalledAsFact() {
        #expect(!SkillHint.missingMessage.lowercased().contains("not installed"))
        #expect(!SkillHint.differsMessage.lowercased().contains("not installed"))
    }

    @Test func homeFollowsTheInstallersRule() {
        let fallback = URL(fileURLWithPath: "/fallback/home", isDirectory: true)
        #expect(SkillHint.home(environment: ["HOME": "/Users/x"], fallback: fallback).path == "/Users/x")
        for bad in [nil, "", "   ", "relative/path", "~"] {
            let env = bad.map { ["HOME": $0] } ?? [:]
            #expect(SkillHint.home(environment: env, fallback: fallback).path == "/fallback/home", "\(String(describing: bad))")
        }
    }
}

// MARK: - The runner against a sandbox (H1 to H4)

@Suite(.timeLimit(.minutes(1)))
struct SkillHintRunnerTests {
    @Test func missingSkillPrintsTheTipOnStderrAndNothingOnStdout() throws {
        let sandbox = try HintSandbox()
        let stdout = HintTesting.captureStdout { sandbox.emit() }
        #expect(sandbox.sink.lines == [SkillHint.missingMessage + "\n"])
        #expect(!String(decoding: stdout, as: UTF8.self).contains("Tip:"), "the hint wrote to stdout")
        #expect(sandbox.storedRecord == "0.7.0 missing\n")
    }

    @Test func aDifferingSkillPrintsTheUpdateTip() throws {
        let sandbox = try HintSandbox()
        try sandbox.writeSkill("my own edits\n")
        sandbox.emit()
        #expect(sandbox.sink.lines == [SkillHint.differsMessage + "\n"])
    }

    @Test func anEqualSkillPrintsNothing() throws {
        let sandbox = try HintSandbox()
        try sandbox.installEqualSkill()
        sandbox.emit()
        #expect(sandbox.sink.lines.isEmpty)
    }

    @Test func jsonNonTerminalAndOptOutPrintNothingAndTouchNothing() throws {
        let sandbox = try HintSandbox()
        sandbox.emit(json: true)
        sandbox.tty = false
        sandbox.emit()
        sandbox.tty = true
        sandbox.environment[SkillHint.optOutVariable] = "1"
        sandbox.emit()
        #expect(sandbox.sink.lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.cache.path), "a gated run must not even create the cache")
        sandbox.environment[SkillHint.optOutVariable] = ""
        sandbox.emit()
        #expect(sandbox.sink.lines.count == 1, "an empty opt-out is not an opt-out")
    }

    // H2

    @Test func oncePerVersionAndState() throws {
        let sandbox = try HintSandbox()
        sandbox.emit()
        sandbox.emit()
        #expect(sandbox.sink.lines.count == 1, "same version, same state: once")
        sandbox.version = "0.7.1"
        sandbox.emit()
        #expect(sandbox.sink.lines.count == 2, "a new version shows it again")
        sandbox.emit()
        #expect(sandbox.sink.lines.count == 2)
        try sandbox.writeSkill("edited\n")
        sandbox.emit()
        #expect(sandbox.sink.lines.count == 3, "a changed state shows it again")
        try sandbox.installEqualSkill()
        sandbox.emit()
        #expect(sandbox.sink.lines.count == 3, "equal prints nothing")
        try FileManager.default.removeItem(at: sandbox.skillFile)
        sandbox.emit()
        #expect(sandbox.sink.lines.count == 4, "removed after being equal is a changed state")
    }

    @Test func theCacheFolderIsPrivate() throws {
        let sandbox = try HintSandbox()
        sandbox.emit()
        let mode = try #require(FileManager.default.attributesOfItem(atPath: sandbox.cache.path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o700)
    }

    // H3

    @Test func anEscapingSymlinkIsNeverFollowed() throws {
        let sandbox = try HintSandbox()
        let outside = sandbox.root.appendingPathComponent("outside.md")
        try Data("secret, and different from the skill\n".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: sandbox.skill, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sandbox.skillFile, withDestinationURL: outside)
        sandbox.emit()
        #expect(sandbox.sink.lines.isEmpty, "following it would read outside and say 'differs'")
        #expect(SkillHint.inspect(directory: sandbox.skill) == nil)
    }

    @Test func aSymlinkInsideTheFolderIsRead() throws {
        let sandbox = try HintSandbox()
        try FileManager.default.createDirectory(at: sandbox.skill, withIntermediateDirectories: true)
        try Data("edited\n".utf8).write(to: sandbox.skill.appendingPathComponent("real.md"))
        try FileManager.default.createSymbolicLink(at: sandbox.skillFile, withDestinationURL: sandbox.skill.appendingPathComponent("real.md"))
        #expect(SkillHint.inspect(directory: sandbox.skill) == .differs)
        try FileManager.default.removeItem(at: sandbox.skill.appendingPathComponent("real.md"))
        #expect(SkillHint.inspect(directory: sandbox.skill) == nil, "dangling: nothing to read, so no tip")
    }

    @Test func aFIFOAFolderAndAnUnreadableFileAreSilentAndNeverHang() throws {
        let sandbox = try HintSandbox()
        try FileManager.default.createDirectory(at: sandbox.skill, withIntermediateDirectories: true)
        #expect(mkfifo(sandbox.skillFile.path, 0o600) == 0)
        sandbox.emit()
        #expect(SkillHint.inspect(directory: sandbox.skill) == nil)
        try FileManager.default.removeItem(at: sandbox.skillFile)

        try FileManager.default.createDirectory(at: sandbox.skillFile, withIntermediateDirectories: true)
        #expect(SkillHint.inspect(directory: sandbox.skill) == nil)
        try FileManager.default.removeItem(at: sandbox.skillFile)

        try sandbox.writeSkill("x\n")
        chmod(sandbox.skillFile.path, 0)
        #expect(SkillHint.inspect(directory: sandbox.skill) == nil)
        sandbox.emit()
        chmod(sandbox.skillFile.path, 0o600)
        #expect(sandbox.sink.lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.cache.path))
    }

    @Test func aHugeFileCountsAsDifferingWithoutBeingReadWhole() throws {
        let sandbox = try HintSandbox()
        try sandbox.writeSkill(String(repeating: "a", count: SkillHint.readCap + 10))
        #expect(SkillHint.inspect(directory: sandbox.skill) == .differs)
    }

    @Test func anUnwritableCacheStillPrintsAndNeverCrashes() throws {
        let sandbox = try HintSandbox()
        try FileManager.default.createDirectory(at: sandbox.cache, withIntermediateDirectories: true)
        chmod(sandbox.cache.path, 0o500)
        sandbox.emit()
        sandbox.emit()
        chmod(sandbox.cache.path, 0o700)
        #expect(sandbox.sink.lines.count == 2, "nothing remembered, so it shows again")
        #expect(!FileManager.default.fileExists(atPath: sandbox.cacheFile.path))

        // The cache folder's parent is a file: creating the folder fails.
        let blocked = try HintSandbox()
        try FileManager.default.createDirectory(at: blocked.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: blocked.cache)
        blocked.emit()
        #expect(blocked.sink.lines.count == 1)
    }

    @Test func onlyTheCacheFileIsEverWritten() throws {
        let sandbox = try HintSandbox()
        try sandbox.writeSkill("edited\n")
        func listing() -> [String] {
            (FileManager.default.enumerator(atPath: sandbox.root.path)?.allObjects as? [String] ?? []).sorted()
        }
        let before = listing()
        sandbox.emit()
        let added = Set(listing()).subtracting(before)
        #expect(added == ["home/Library", "home/Library/Caches", "home/Library/Caches/marsdawn", "home/Library/Caches/marsdawn/skill-hint"])
        #expect(try Data(contentsOf: sandbox.skillFile) == Data("edited\n".utf8))
    }

    // The production runner under test

    @Test func theProductionRunnerInATestRecordsAndTouchesNothing() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/marsdawn").path
        func stat(_ path: String) -> String {
            var info = Darwin.stat()
            return lstat(path, &info) == 0 ? "\(info.st_ino) \(info.st_mtimespec.tv_sec) \(info.st_mtimespec.tv_nsec)" : "absent"
        }
        let before = stat(real)
        HintTesting.installViolationHandler()
        let violations = HintSink()
        HintTesting.$expectedViolations.withValue(violations) { SkillHint.emitAfterSuccess(json: false) }
        #expect(violations.lines.count == 1)
        #expect(stat(real) == before)
    }
}

// MARK: - Call sites (H1, H4, H5)

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SkillHintCallSiteTests {
    private func makeInput(in sandbox: HintSandbox) throws -> (input: URL, output: URL) {
        let dir = sandbox.root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("doc.md")
        try Data("# Title\n\nText.\n".utf8).write(to: input)
        return (input, dir.appendingPathComponent("out.pdf"))
    }

    @Test func exportPrintsTheTipOnStderrAfterSuccessAndJSONNeverDoes() async throws {
        let sandbox = try HintSandbox()
        let (input, output) = try makeInput(in: sandbox)
        try await sandbox.run {
            try await MarsDawnCommand.Export.parse([input.path, "-o", output.path]).run()
        }
        #expect(sandbox.sink.lines == [SkillHint.missingMessage + "\n"])
        #expect(try Data(contentsOf: output).prefix(5) == Data("%PDF-".utf8))

        let json = try HintSandbox()
        let (jsonInput, jsonOutput) = try makeInput(in: json)
        try await json.run {
            try await MarsDawnCommand.Export.parse([jsonInput.path, "-o", jsonOutput.path, "--json"]).run()
        }
        #expect(json.sink.lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: json.cache.path))
    }

    @Test func exportWithTheSkillInstalledPrintsNoTip() async throws {
        let sandbox = try HintSandbox()
        try sandbox.installEqualSkill()
        let (input, output) = try makeInput(in: sandbox)
        try await sandbox.run { try await MarsDawnCommand.Export.parse([input.path, "-o", output.path]).run() }
        #expect(sandbox.sink.lines.isEmpty)
    }

    @Test func aFailedExportPrintsNoTip() async throws {
        let sandbox = try HintSandbox()
        let (input, output) = try makeInput(in: sandbox)
        try Data("existing".utf8).write(to: output)
        await sandbox.run {
            await #expect(throws: CLIFailure.self) {
                try await MarsDawnCommand.Export.parse([input.path, "-o", output.path]).run() // exists, no --force
            }
            await #expect(throws: CLIFailure.self) {
                try await MarsDawnCommand.Export.parse([sandbox.root.appendingPathComponent("nope.md").path]).run()
            }
        }
        #expect(sandbox.sink.lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.cache.path))
    }

    private final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[URL]] = []
        func add(_ urls: [URL]) { lock.lock(); storage.append(urls); lock.unlock() }
        var all: [[URL]] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test func openPrintsTheTipAfterHandingOverAndNeverLaunchesTheApp() async throws {
        let sandbox = try HintSandbox()
        let (input, _) = try makeInput(in: sandbox)
        let opened = Opened()
        let before = HintTesting.marsDawnProcesses()
        let fakeApp = sandbox.root.appendingPathComponent("Fake.app")
        try await MarsDawnApp.$locateOverride.withValue({ fakeApp }) {
            try await MarsDawnCommand.Open.$opener.withValue({ urls, _, _ in opened.add(urls) }) {
                try await sandbox.run { try await MarsDawnCommand.Open.parse([input.path]).run() }
                let json = try HintSandbox()
                try await json.run { try await MarsDawnCommand.Open.parse([input.path, "--json"]).run() }
                #expect(json.sink.lines.isEmpty)
            }
        }
        #expect(opened.all.count == 2)
        #expect(sandbox.sink.lines == [SkillHint.missingMessage + "\n"])
        #expect(HintTesting.marsDawnProcesses() == before, "no MarsDawn process may appear")
    }

    @Test func aFailedOpenPrintsNoTip() async throws {
        let sandbox = try HintSandbox()
        let (input, _) = try makeInput(in: sandbox)
        let opened = Opened()
        try await MarsDawnApp.$locateOverride.withValue({ nil }) {
            try await MarsDawnCommand.Open.$opener.withValue({ urls, _, _ in opened.add(urls) }) {
                await sandbox.run {
                    await #expect(throws: CLIFailure.self) { try await MarsDawnCommand.Open.parse([input.path]).run() }
                }
            }
        }
        #expect(opened.all.isEmpty)
        #expect(sandbox.sink.lines.isEmpty)
    }
}
#endif
