#if os(macOS)
import AppKit
import ArgumentParser
import Foundation
import MarsDawnKit
import Testing
@testable import marsdawn

@MainActor
struct CLITests {
    @Test func exportDefaultsToAPDFBesideTheInput() throws {
        let command = try MarsDawnCommand.Export.parse(["notes/plan.md"])
        let input = URL(fileURLWithPath: "/tmp/notes/plan.md")
        #expect(command.outputURL(for: input).path == "/tmp/notes/plan.pdf")
        #expect(command.paper == .a4)
        #expect(!command.force && !command.allowRemoteImages && !command.options.json)
    }

    @Test func exportParsesEveryOption() throws {
        let command = try MarsDawnCommand.Export.parse([
            "plan.md", "-o", "/tmp/out.pdf", "--theme", "Classic", "--paper", "letter",
            "--allow-remote-images", "--force", "--json",
        ])
        #expect(command.outputURL(for: URL(fileURLWithPath: "/x/plan.md")).path == "/tmp/out.pdf")
        #expect(command.resolvedTheme(environment: [:]).id == "classic")
        #expect(command.paper == .letter)
        #expect(command.force && command.allowRemoteImages && command.options.json)
    }

    @Test func themeFallsBackToEnvironmentThenDawn() throws {
        let command = try MarsDawnCommand.Export.parse(["plan.md"])
        #expect(command.resolvedTheme(environment: ["MARSDAWN_THEME": "vivid"]).id == "vivid")
        #expect(command.resolvedTheme(environment: ["MARSDAWN_THEME": "nope"]).id == "dawn")
        #expect(command.resolvedTheme(environment: [:]).id == "dawn")
    }

    @Test func rejectsUnknownThemesAndPapers() {
        #expect(throws: (any Error).self) { try MarsDawnCommand.Export.parse(["plan.md", "--theme", "neon"]) }
        #expect(throws: (any Error).self) { try MarsDawnCommand.Export.parse(["plan.md", "--paper", "a5"]) }
    }

    @Test func missingInputIsReportedBeforeAnythingElse() {
        #expect {
            _ = try existingFile("/definitely/not/here.md")
        } throws: { ($0 as? CLIFailure)?.code == .inputNotFound }
    }

}

// MARK: - the tool on its own

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StandaloneToolTests {
    /// `export` must not need MarsDawn.app: it is the same rendering the app does, it ships in
    /// this package, and Homebrew builds and tests the tool on machines that have no app at all.
    /// Before C0 this threw `app_not_installed` and wrote nothing.
    @Test func exportRendersAPDFWithNoAppInstalled() async throws {
        let original = MarsDawnApp.locate
        defer { MarsDawnApp.locate = original }
        MarsDawnApp.locate = { nil }

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("doc.md")
        try Data("# Title\n\nA paragraph.\n".utf8).write(to: input)
        let output = root.appendingPathComponent("out.pdf")

        try await MarsDawnCommand.Export.parse([input.path, "-o", output.path]).run()

        let pdf = try Data(contentsOf: output)
        #expect(pdf.prefix(5) == Data("%PDF-".utf8))
        #expect(pdf.count > 1000)
    }

    /// `open` keeps the check; that is deliberate, and exit code 3 is its alone now.
    @Test func openStillNeedsTheApp() {
        let original = MarsDawnApp.locate
        defer { MarsDawnApp.locate = original }
        MarsDawnApp.locate = { nil }
        #expect {
            _ = try MarsDawnApp.require()
        } throws: { ($0 as? CLIFailure)?.code == .appNotInstalled }
    }

    /// The Homebrew formula asserts `marsdawn --version` equals its own `version`, so this has
    /// to stay a plain release number with nothing around it.
    @Test func versionIsAPlainReleaseNumber() {
        #expect(MarsDawnCommand.configuration.version == MarsDawnCLI.version)
        #expect(MarsDawnCLI.version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
    }
}

// MARK: - $MARSDAWN_APP_PATH only stands in for MarsDawn itself (app #177)

/// `resolveOverride` is a pure function of its arguments (no `ProcessInfo`/`MarsDawnApp.locate`
/// mutation, no `setenv`, no `dup2` of a real file descriptor), so these tests call it directly
/// with fixed inputs and can run safely alongside every other suite, including the ones that swap
/// `MarsDawnApp.locate` itself (`StandaloneToolTests`, `FolderCapabilityTests`).
///
/// The override is spoofable by anyone who can already fake `marsdawn` on `PATH`, so this isn't a
/// security boundary — it only catches an override left pointing at a deleted test copy or another
/// app by accident. A throwaway verification copy's bundle id must still work; the bare id with a
/// trailing dot and nothing after it must not.
struct AppPathOverrideTests {
    /// An empty file or folder that exists on disk, so `resolveOverride`'s own `fileExists` check
    /// passes; what's read from it is entirely decided by the stubbed `bundleIdentifier` closure
    /// below, never by anything actually written here.
    private func existingPath() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-override-\(UUID().uuidString)")
        try Data().write(to: url)
        return url
    }

    /// Collects everything written through the `stderr` sink, in call order.
    private final class StderrSpy {
        private(set) var lines: [String] = []
        func write(_ text: String) { lines.append(text) }
    }

    private func resolve(
        _ environment: [String: String],
        identifier: String?,
        stderr: StderrSpy
    ) throws -> MarsDawnApp.OverrideOutcome? {
        try MarsDawnApp.resolveOverride(
            environment: environment,
            bundleIdentifier: { _ in identifier },
            stderr: stderr.write
        )
    }

    @Test func aVariableThatIsntSetFallsThroughWithNoNotice() throws {
        let stderr = StderrSpy()
        let outcome = try resolve([:], identifier: "dev.southern-light.marsdawn", stderr: stderr)
        #expect(outcome == nil)
        #expect(stderr.lines.isEmpty, "nothing was overridden, so nothing should be printed")
    }

    @Test func aPathThatDoesntExistIsNotFound() throws {
        let stderr = StderrSpy()
        let missing = "/definitely/not/here/MarsDawn.app"
        let outcome = try resolve(["MARSDAWN_APP_PATH": missing], identifier: "dev.southern-light.marsdawn", stderr: stderr)
        #expect(outcome == .notFound)
        #expect(stderr.lines.contains { $0.contains("MARSDAWN_APP_PATH") }, "a notice is printed whenever the override is used")
    }

    @Test func aForeignBundleIdIsRefused() throws {
        let path = try existingPath()
        defer { try? FileManager.default.removeItem(at: path) }
        let stderr = StderrSpy()
        #expect {
            _ = try resolve(["MARSDAWN_APP_PATH": path.path], identifier: "com.example.NotMarsDawn", stderr: stderr)
        } throws: { error in
            guard let failure = error as? CLIFailure else { return false }
            return failure.code == .appNotInstalled && failure.message.contains("com.example.NotMarsDawn")
        }
        #expect(stderr.lines.contains { $0.contains("MARSDAWN_APP_PATH") }, "a notice is printed whenever the override is used")
    }

    @Test func aThrowawayVerificationCopyIsAccepted() throws {
        let path = try existingPath()
        defer { try? FileManager.default.removeItem(at: path) }
        let stderr = StderrSpy()
        let outcome = try resolve(["MARSDAWN_APP_PATH": path.path], identifier: "dev.southern-light.marsdawn.verify-x", stderr: stderr)
        #expect(outcome == .app(path))
        #expect(stderr.lines.contains { $0.contains("MARSDAWN_APP_PATH") })
    }

    @Test func theExactBundleIdIsAccepted() throws {
        let path = try existingPath()
        defer { try? FileManager.default.removeItem(at: path) }
        let stderr = StderrSpy()
        let outcome = try resolve(["MARSDAWN_APP_PATH": path.path], identifier: "dev.southern-light.marsdawn", stderr: stderr)
        #expect(outcome == .app(path))
        #expect(stderr.lines.contains { $0.contains("MARSDAWN_APP_PATH") })
    }

    /// The bare id with a trailing dot and nothing after it is not a `.*` copy: `hasPrefix` would
    /// accept it, so the length check has to be there for real.
    @Test func theBareIdWithATrailingDotIsRefused() throws {
        let path = try existingPath()
        defer { try? FileManager.default.removeItem(at: path) }
        let stderr = StderrSpy()
        #expect {
            _ = try resolve(["MARSDAWN_APP_PATH": path.path], identifier: "dev.southern-light.marsdawn.", stderr: stderr)
        } throws: { error in
            (error as? CLIFailure)?.code == .appNotInstalled
        }
        #expect(stderr.lines.contains { $0.contains("MARSDAWN_APP_PATH") })
    }

    @Test func aMissingInfoPlistIsRefused() throws {
        let path = try existingPath()
        defer { try? FileManager.default.removeItem(at: path) }
        let stderr = StderrSpy()
        #expect {
            _ = try resolve(["MARSDAWN_APP_PATH": path.path], identifier: nil, stderr: stderr)
        } throws: { error in
            (error as? CLIFailure)?.code == .appNotInstalled
        }
        #expect(stderr.lines.contains { $0.contains("MARSDAWN_APP_PATH") })
    }
}

// MARK: - $MARSDAWN_APP_PATH's default `locate` reads the real Info.plist (app #177)

/// `resolveOverride` above is exercised with a stubbed bundle-id reader; this checks the reader
/// `locate`'s default actually wires in, `MarsDawnApp.bundleIdentifier(at:)`, against a real
/// Info.plist on disk. No environment or `locate` mutation, so it runs safely alongside every
/// other suite too.
struct BundleIdentifierReadingTests {
    private func fakeApp(identifier: String?, writePlist: Bool = true) throws -> URL {
        let app = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-bundle-id-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if writePlist {
            var info: [String: Any] = [:]
            if let identifier { info["CFBundleIdentifier"] = identifier }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return app
    }

    @Test func readsTheRealCFBundleIdentifier() throws {
        let app = try fakeApp(identifier: "dev.southern-light.marsdawn.verify-x")
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(MarsDawnApp.bundleIdentifier(at: app) == "dev.southern-light.marsdawn.verify-x")
    }

    @Test func aMissingInfoPlistReadsAsNil() throws {
        let app = try fakeApp(identifier: nil, writePlist: false)
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(MarsDawnApp.bundleIdentifier(at: app) == nil)
    }

    @Test func noCFBundleIdentifierKeyReadsAsNil() throws {
        let app = try fakeApp(identifier: nil)
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(MarsDawnApp.bundleIdentifier(at: app) == nil)
    }
}

// MARK: - open: files, lines and the event they travel in

/// Files on disk for one test, deleted with the suite instance.
private final class Sandbox {
    let root: URL

    init(_ names: [String]) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try Data("# hi\n".utf8).write(to: root.appendingPathComponent(name))
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The path an argument names.
    func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    /// The path `open` sends: symlinks resolved, standardized. The temporary directory lives
    /// under a symlink (`/var` → `/private/var`), so this really differs from `path(_:)`.
    func sent(_ name: String) -> String {
        root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

@MainActor
struct OpenCommandTests {
    private let files = try! Sandbox(["a.md", "weird:12"])

    /// `--background` is accepted, alone and with the other options (#59).
    @Test func backgroundIsAnOption() throws {
        let a = files.path("a.md")
        _ = try MarsDawnCommand.Open.parse([a, "--background"])
        _ = try MarsDawnCommand.Open.parse(["--background", "--line", "3", a])
        #expect(exitCode { _ = try MarsDawnCommand.parseAsRoot(["open", "--background", a]) } == nil)
    }

    /// The app comes to the front by default, as before, and stays behind with `--background`:
    /// the files and the folder are opened with the same configuration.
    @Test func backgroundOpensWithoutActivating() throws {
        let a = files.path("a.md")
        #expect(try MarsDawnCommand.Open.parse([a]).openConfiguration().activates == true)
        #expect(try MarsDawnCommand.Open.parse([a, "--background"]).openConfiguration().activates == false)
    }

    private func targets(_ arguments: [String]) throws -> [(path: String, line: Int?)] {
        try MarsDawnCommand.Open.parse(arguments).resolvedTargets().map { ($0.url.path, $0.line) }
    }

    /// The status `marsdawn` would end with, or nil when the call succeeds.
    private func exitCode(_ body: () throws -> Void) -> Int32? {
        do {
            try body()
            return nil
        } catch {
            return cliExitCode(for: error)
        }
    }

    @Test func aTrailingLineAndColumnSplitOffTheArgument() throws {
        let a = files.path("a.md")
        #expect(try targets([a]).map(\.line) == [nil])
        #expect(try targets([a]) .map(\.path) == [files.path("a.md")])
        #expect(try targets(["\(a):12"]).map { $0.line } == [12])
        // A column is accepted and ignored.
        #expect(try targets(["\(a):12:5"]).map { $0.line } == [12])
        // What travels is the resolved, standardized path, not the one typed.
        #expect(try targets(["\(a):12"]).map(\.path) == [files.sent("a.md")])
    }

    @Test func aFileReallyNamedWithAColonAndDigitsStaysAFilename() throws {
        let weird = files.path("weird:12")
        #expect(try targets([weird]) .map(\.path) == [weird])
        #expect(try targets([weird]).map(\.line) == [nil])
        // …and a line can still be written after it.
        let parsed = try targets(["\(weird):4"])
        #expect(parsed.map(\.path) == [files.sent("weird:12")])
        #expect(parsed.map(\.line) == [4])
    }

    @Test func lineAppliesToASingleFileOnly() throws {
        let a = files.path("a.md")
        #expect(try targets(["--line", "9", a]).map { $0.line } == [9])
        #expect(exitCode { _ = try MarsDawnCommand.parseAsRoot(["open", "--line", "9", a, a]) } == 64)
        #expect(ExitCode.validationFailure.rawValue == 64)
    }

    @Test func aLineOutOfRangeIsAUsageErrorAndNothingIsSent() throws {
        let a = files.path("a.md")
        for argument in [["--line", "0", a], ["--line", "1234567890", a], ["--line", "-3", a]] {
            #expect(exitCode { _ = try MarsDawnCommand.Open.parse(argument).resolvedTargets() } == 64)
        }
        // Written on the argument, line 0 splits off and is rejected the same way.
        #expect(exitCode { _ = try MarsDawnCommand.Open.parse(["\(a):0"]).resolvedTargets() } == 64)
        // A ten-digit line never splits off at all, so the whole argument is a filename.
        #expect(exitCode { _ = try MarsDawnCommand.Open.parse(["\(a):1234567890"]).resolvedTargets() }
            == CLIFailure.Code.inputNotFound.rawValue)
    }

    // MARK: Folders (S1)

    /// The folder's own sandbox, made per test so a directory argument has somewhere real to point.
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func folders(_ arguments: [String]) throws -> [String] {
        try MarsDawnCommand.Open.parse(arguments).resolvedFolders().map(\.path)
    }

    @Test func aDirectoryArgumentOpensAsAFolderNotAFile() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try targets([dir.path]).isEmpty)
        #expect(try folders([dir.path]) == [dir.standardizedFileURL.path])
    }

    @Test func aFileAndAFolderTravelTogether() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let command = try MarsDawnCommand.Open.parse([files.path("a.md"), "--folder", dir.path])
        #expect(try command.resolvedTargets().map(\.url.lastPathComponent) == ["a.md"])
        #expect(try command.resolvedFolders().map(\.path) == [dir.standardizedFileURL.path])
    }

    /// #104 review: this used to be a usage error (any directory argument alongside `--line`
    /// triggered "--line needs a file, but ... is a folder", even with a real file argument doing
    /// the line's job). The #104 fix to that message only fires when there's no file at all
    /// (`fileArguments == 0`), so a file argument, a directory argument, and `--line` together are
    /// now accepted — matching what `<file> --folder <dir> --line <n>` already did on main. Declared
    /// intended: a directory argument and `--folder` are the same kind of thing, and there is no
    /// reason `--line` should treat them differently once a real file is present to take the line.
    @Test func aFileAndADirectoryArgumentTogetherAcceptLineOnTheFile() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = files.path("a.md")
        let command = try MarsDawnCommand.Open.parse([a, dir.path, "--line", "3"])
        let resolved = try command.resolvedTargets()
        #expect(resolved.map(\.url.lastPathComponent) == ["a.md"])
        #expect(resolved.map(\.line) == [3])
        #expect(try command.resolvedFolders().map(\.path) == [dir.standardizedFileURL.path])
        // Matches the --folder spelling of the same request.
        let viaFolder = try MarsDawnCommand.Open.parse([a, "--folder", dir.path, "--line", "3"])
        let resolvedViaFolder = try viaFolder.resolvedTargets()
        #expect(resolvedViaFolder.map(\.url.lastPathComponent) == resolved.map(\.url.lastPathComponent))
        #expect(resolvedViaFolder.map(\.line) == resolved.map(\.line))
    }

    /// The same folder named twice is one folder, not two: asking for it as an argument and
    /// again with --folder is a reasonable thing for a script to do.
    @Test func thesameFolderNamedTwiceIsOneFolder() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try folders([dir.path, "--folder", dir.path]) == [dir.standardizedFileURL.path])
    }

    @Test func twoDifferentFoldersAreAUsageError() throws {
        let one = try makeFolder(), two = try makeFolder()
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        #expect(exitCode { _ = try MarsDawnCommand.Open.parse([one.path, "--folder", two.path]).resolvedFolders() } == 64)
        #expect(exitCode { _ = try MarsDawnCommand.parseAsRoot(["open", "--folder", one.path, "--folder", two.path]) } == 64)
    }

    /// #104: two folders, given either as two directory arguments or as a directory argument plus
    /// `--folder`, must print `open`'s own usage line rather than the top-level
    /// `Usage: marsdawn <subcommand>`. The bug was that the duplicate check lived only in
    /// `resolvedFolders()`, called from `run()`, where ArgumentParser has already lost the
    /// subcommand context by the time the error reaches it; `--folder <dir1> --folder <dir2>`
    /// (caught earlier, in `validate()`'s `folder.count` check) already printed correctly, which
    /// is why that case alone didn't catch this.
    @Test func twoFoldersPrintOpensOwnUsageLine() throws {
        let one = try makeFolder(), two = try makeFolder()
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        for arguments in [["open", one.path, two.path], ["open", one.path, "--folder", two.path]] {
            do {
                _ = try MarsDawnCommand.parseAsRoot(arguments)
                Issue.record("expected a usage error for \(arguments)")
                continue
            } catch {
                let message = MarsDawnCommand.fullMessage(for: error)
                #expect(message.contains("Usage: marsdawn open"), "\(arguments): \(message)")
                #expect(!message.contains("Usage: marsdawn <subcommand>"), "\(arguments): \(message)")
            }
        }
    }

    /// #104: `--folder <dir> --line <n>`, with no other file argument, must name the folder the
    /// same way `<dir> --line <n>` (the folder as a positional argument) already does — not fall
    /// through to the generic "--line needs exactly one file, but 0 were given" wording, which
    /// never says a folder was involved.
    @Test func lineOnAFolderGivenViaDashDashFolderNamesTheFolder() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try MarsDawnCommand.parseAsRoot(["open", "--folder", dir.path, "--line", "3"])
            Issue.record("expected a usage error")
        } catch {
            let message = MarsDawnCommand.fullMessage(for: error)
            #expect(message.contains(dir.path), "\(message)")
            #expect(message.contains("is a folder"), "\(message)")
            #expect(!message.contains("0 were given"), "\(message)")
        }
        #expect(exitCode { _ = try MarsDawnCommand.parseAsRoot(["open", "--folder", dir.path, "--line", "3"]) } == 64)
    }

    @Test func aLineCannotBeAskedForOnAFolder() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(exitCode { _ = try MarsDawnCommand.parseAsRoot(["open", "--line", "9", dir.path]) } == 64)
    }

    @Test func openWithNothingToOpenIsAUsageError() {
        #expect(exitCode { _ = try MarsDawnCommand.parseAsRoot(["open"]) } == 64)
    }

    /// VS Code's muscle memory lands here, so the error names the flag we do have.
    @Test func dashAIsRefusedByName() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(exitCode { _ = try MarsDawnCommand.parseAsRoot(["open", "-a", dir.path]) } == 64)
        #expect(MarsDawnCommand.Open.noDashA.contains("--folder"))
        #expect(MarsDawnCommand.Open.noDashA.contains("one folder"))
    }

    @Test func aFolderThatIsntThereOrIsntAFolderIsReported() throws {
        #expect(exitCode { _ = try MarsDawnCommand.Open.parse(["--folder", "/definitely/not/here"]).resolvedFolders() }
            == CLIFailure.Code.inputNotFound.rawValue)
        // A file passed where a folder belongs is named as such, not reported as missing.
        #expect(exitCode { _ = try MarsDawnCommand.Open.parse(["--folder", files.path("a.md")]).resolvedFolders() }
            == CLIFailure.Code.inputNotFound.rawValue)
    }

    /// #104 review: with a real folder and a second, nonexistent one, this used to be exit 2
    /// (`input_not_found`, from `resolvedFolders()` hitting the missing one while resolving each
    /// candidate in turn) and is now exit 64 ("More than one folder was given"), because
    /// `validate()`'s new multiplicity check runs before either folder's existence is checked.
    /// Declared intended: two folders is a usage error regardless of whether either one exists —
    /// telling the person to pick one is more useful than telling them one of the two is missing,
    /// and it matches `--folder <dir1> --folder <dir2>`, which was already a usage error (64) before
    /// existence was ever checked, on main.
    @Test func twoFoldersIsAUsageErrorEvenWhenOneDoesntExist() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exit = exitCode { _ = try MarsDawnCommand.parseAsRoot(["open", dir.path, "--folder", "/definitely/not/here"]) }
        #expect(exit == 64)
        #expect(exit != CLIFailure.Code.inputNotFound.rawValue)
    }

    @Test func aMissingFileIsReportedBeforeTheAppIsLookedFor() {
        #expect(exitCode { _ = try MarsDawnCommand.Open.parse(["/definitely/not/here.md:3"]).resolvedTargets() }
            == CLIFailure.Code.inputNotFound.rawValue)
    }

    // MARK: - `--json`'s `folder` field (#103)
    //
    // The skill (`Skill.swift` / `skill/SKILL.md`) and the README both teach agents that
    // `open --folder <path> --json` returns `"folder": {"path": ..., "requested": true}`. Nothing
    // in the suite pinned that shape before this. `Open.folderFields(path:result:)` is the exact,
    // pure code `run()` uses to build the `"folder"` JSON object (`result: nil` is what an app that
    // hasn't answered, or doesn't report back at all, gives — today's whole story before slice B's
    // `--wait`), so these tests pin it without launching anything.

    @Test func aFolderGivesPathAndRequestedTrueWithNoOtherFields() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = MarsDawnCommand.Open.folderFields(path: dir.path, result: nil)
        #expect(folder["path"] as? String == dir.path)
        #expect(folder["requested"] as? Bool == true)
        #expect(folder.count == 2, "no extra fields: \(folder)")
    }

    @Test func theFolderLineNamesThePathAndAsksToShowIt() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MarsDawnCommand.Open.folderLine(path: dir.path, result: nil)
            == "Asked MarsDawn to show \(dir.path) in the sidebar")
    }

    /// The same folder given as a positional argument and again with `--folder` resolves to one
    /// folder (`resolvedFolders()`'s own dedup, tested separately in
    /// `thesameFolderNamedTwiceIsOneFolder`), so `run()` only ever builds one `folder` object for
    /// it, not two — pinned here at the point `resolvedFolders()` hands off to `folderFields`.
    @Test func theSameFolderNamedTwiceGivesOneFolderObject() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = try MarsDawnCommand.Open.parse([dir.path, "--folder", dir.path]).resolvedFolders()
        #expect(resolved.count == 1)
        let folder = MarsDawnCommand.Open.folderFields(path: resolved[0].path, result: nil)
        #expect(folder["path"] as? String == dir.standardizedFileURL.path)
    }

    /// Red-control shape: the field name and the `requested` key are exactly what the skill and
    /// README promise. Renaming either, or dropping `requested`, must fail this test.
    @Test func theFolderFieldShapeIsPathAndRequestedOnly() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = MarsDawnCommand.Open.folderFields(path: dir.path, result: nil)
        #expect(Set(folder.keys) == ["path", "requested"])
    }

    @Test func theEventCarriesTheFileListAndTheLineTwice() throws {
        let url = URL(fileURLWithPath: "/Users/me/notes/plan one.md")
        let event = try #require(RevealEvent.openDocuments(urls: [url], line: 120))
        #expect(event.eventClass == AEEventClass(kCoreEventClass))
        #expect(event.eventID == AEEventID(kAEOpenDocuments))
        #expect(RevealEvent.lineKeyword == 0x6D64_4C6E)  // 'mdLn'

        let direct = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        #expect(direct.descriptorType == typeAEList)
        #expect(direct.numberOfItems == 1)
        #expect(direct.atIndex(1)?.fileURLValue?.path == url.path)

        let position = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyAEPosition)))
        #expect(position.descriptorType == typeSInt32)
        #expect(position.int32Value == 120)
        let ours = try #require(event.paramDescriptor(forKeyword: RevealEvent.lineKeyword))
        #expect(ours.descriptorType == typeSInt32)
        #expect(ours.int32Value == 120)
    }

    @Test func withNoLineThereIsNoEventOfOurs() {
        // AppKit then builds the open-documents event itself, exactly as it did before S7.
        #expect(RevealEvent.openDocuments(urls: [URL(fileURLWithPath: "/a.md")], line: nil) == nil)
    }

    @Test func neighboursAskingForTheSameLineShareOneEvent() {
        let a = URL(fileURLWithPath: "/a.md")
        let b = URL(fileURLWithPath: "/b.md")
        #expect(RevealEvent.groups(for: []) == [])
        #expect(
            RevealEvent.groups(for: [OpenTarget(url: a, line: nil), OpenTarget(url: b, line: nil)])
                == [RevealEvent.Group(urls: [a, b], line: nil)]
        )
        #expect(
            RevealEvent.groups(for: [OpenTarget(url: a, line: 5), OpenTarget(url: b, line: 5)])
                == [RevealEvent.Group(urls: [a, b], line: 5)]
        )
        // Different lines can't share one event: the line applies to every file in it.
        #expect(
            RevealEvent.groups(for: [OpenTarget(url: a, line: 1), OpenTarget(url: b, line: 99)])
                == [RevealEvent.Group(urls: [a], line: 1), RevealEvent.Group(urls: [b], line: 99)]
        )
    }
}

// MARK: - open: folders need an app that can take them (#165)

/// An app that shows an error for a folder must not be sent one, and the CLI must not report
/// success for it. Whether the app can is read from its own Info.plist, not guessed from a version.
@MainActor
@Suite(.serialized)
struct FolderCapabilityTests {
    /// A fake app bundle: only the Info.plist the CLI reads. `key` nil leaves the key out.
    private func fakeApp(key: Any?) throws -> URL {
        let app = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-fake-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "dev.southern-light.marsdawn.fake"]
        if let key { info[MarsDawnApp.opensFoldersKey] = key }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theAppsOwnInfoPlistDecides() throws {
        let yes = try fakeApp(key: true), no = try fakeApp(key: false), absent = try fakeApp(key: nil)
        defer { [yes, no, absent].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(MarsDawnApp.opensFolders(yes), "positive fixture: an app that declares it")
        #expect(!MarsDawnApp.opensFolders(no))
        #expect(!MarsDawnApp.opensFolders(absent))
        #expect(!MarsDawnApp.opensFolders(URL(fileURLWithPath: "/nonexistent/MarsDawn.app")))
    }

    @Test func foldersAreRefusedByAnAppThatCantTakeThem() throws {
        let capable = try fakeApp(key: true), incapable = try fakeApp(key: nil), dir = try folder()
        defer { [capable, incapable, dir].forEach { try? FileManager.default.removeItem(at: $0) } }

        let refusal = try #require(MarsDawnCommand.Open.folderRefusal(folders: [dir], app: incapable))
        #expect(refusal.code == .appCannotOpenFolders && refusal.code.rawValue == 6)
        #expect(refusal.code.kind == "app_cannot_open_folders")
        #expect(refusal.message.contains("Nothing was opened"))
        // An app that declares it goes ahead; files alone never ask.
        #expect(MarsDawnCommand.Open.folderRefusal(folders: [dir], app: capable) == nil)
        #expect(MarsDawnCommand.Open.folderRefusal(folders: [], app: incapable) == nil)
    }

    /// The whole command, for both spellings: it stops with the refusal, before anything is sent.
    @Test func openStopsBeforeSendingAnything() async throws {
        let incapable = try fakeApp(key: nil), dir = try folder()
        defer { [incapable, dir].forEach { try? FileManager.default.removeItem(at: $0) } }
        let original = MarsDawnApp.locate
        defer { MarsDawnApp.locate = original }
        MarsDawnApp.locate = { incapable }
        for arguments in [["--folder", dir.path], [dir.path]] {
            await #expect {
                try await MarsDawnCommand.Open.parse(arguments).run()
            } throws: { ($0 as? CLIFailure)?.code == .appCannotOpenFolders }
        }
    }
}
#endif
