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

    /// `open`'s help and its not-installed error send people to the real listing, and the README
    /// says the same (#56). Fails while the held placeholder is still there.
    @Test func theStoreLinkIsTheRealListing() throws {
        #expect(MarsDawnApp.storeURL.wholeMatch(of: /https:\/\/apps\.apple\.com\/app\/id\d+/) != nil,
                "replace the placeholder with the listing's Apple ID: \(MarsDawnApp.storeURL)")
        #expect(CLIFailure.appNotInstalled().message.contains(MarsDawnApp.storeURL))
        let readme = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains(MarsDawnApp.storeURL), "the README links the same listing")
        #expect(!readme.contains("not publicly available"))
    }

    /// The Homebrew formula asserts `marsdawn --version` equals its own `version`, so this has
    /// to stay a plain release number with nothing around it.
    @Test func versionIsAPlainReleaseNumber() {
        #expect(MarsDawnCommand.configuration.version == MarsDawnCLI.version)
        #expect(MarsDawnCLI.version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
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

    @Test func aMissingFileIsReportedBeforeTheAppIsLookedFor() {
        #expect(exitCode { _ = try MarsDawnCommand.Open.parse(["/definitely/not/here.md:3"]).resolvedTargets() }
            == CLIFailure.Code.inputNotFound.rawValue)
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
#endif
