#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
@testable import marsdawn

// The CLI's public contract, as README and the skill promise it and the published export.v1
// schema fixes it: the `--json` result of `open` and `export`, the exit status and error kind of
// each failure, the `--wait` bounds and `export --force`. Each assertion is a literal value, not
// a value read back out of the code under test.
//
// Nothing here can reach the real MarsDawn: in-process tests run `Open.run()` under
// `MarsDawnApp.$locateOverride` and `Open.$opener`; subprocess tests pin MARSDAWN_APP_PATH to a
// path that does not exist (see `CLIProcess`).

/// A fake app bundle with only the Info.plist the CLI reads.
private func makeFakeApp(opensFolders: Bool) throws -> URL {
    let app = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("marsdawn-contract-app-\(UUID().uuidString).app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "dev.southern-light.marsdawn.contract",
        MarsDawnApp.opensFoldersKey: opensFolders,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

// MARK: - open --json

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct OpenJSONContractTests {
    private struct Fixture {
        let root: URL
        let app: URL
        let recorder = OpenRecorder()
        let printed = PrintedLines()

        init(opensFolders: Bool = false) throws {
            root = try CLIProcess.scratch()
            app = try makeFakeApp(opensFolders: opensFolders)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: app)
        }

        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("# \(name)\n".utf8).write(to: url)
            return url
        }

        /// Runs `open` with the given arguments, with nothing able to reach the real app.
        func run(_ arguments: [String]) async throws {
            let app = app, printed = printed
            try await MarsDawnApp.$locateOverride.withValue(MarsDawnApp.LocateOverride({ app })) {
                try await MarsDawnCommand.Open.$opener.withValue(MarsDawnCommand.Open.Opener(recorder.opener)) {
                    try await OutputOptions.$sink.withValue(OutputOptions.Sink({ printed.add($0) })) {
                        try await MarsDawnCommand.Open.parse(arguments).run()
                    }
                }
            }
        }
    }

    @Test func aFileOpensWithOkAppAndItsPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = try fixture.file("notes.md")
        try await fixture.run([file.path, "--json"])

        let result = try fixture.printed.jsonObject()
        #expect(Set(result.keys) == ["ok", "app", "opened"], "\(result)")
        #expect(result["ok"] as? Bool == true)
        #expect(result["app"] as? String == fixture.app.path)
        let opened = try #require(result["opened"] as? [[String: Any]])
        #expect(opened.count == 1)
        #expect(opened.first.map { Set($0.keys) } == ["path"], "no line key without a line: \(opened)")
        #expect(opened.first?["path"] as? String == file.path)
        // And the app was handed that file, brought to the front.
        #expect(fixture.recorder.calls.map { $0.urls.map(\.path) } == [[file.path]])
        #expect(fixture.recorder.calls.first?.app == fixture.app)
        #expect(fixture.recorder.calls.first?.activates == true)
    }

    @Test func aLineIsReportedWithTheFilesResolvedPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = try fixture.file("notes.md")
        let other = try fixture.file("other.md")
        try await fixture.run(["\(file.path):120", other.path, "--json", "--background"])

        let result = try fixture.printed.jsonObject()
        let opened = try #require(result["opened"] as? [[String: Any]])
        #expect(opened.count == 2)
        // With a line the path travels resolved (the app matches it against open documents).
        #expect(opened[0]["path"] as? String == file.resolvingSymlinksInPath().path)
        #expect(opened[0]["line"] as? Int == 120)
        #expect(opened[1]["path"] as? String == other.path)
        #expect(opened[1]["line"] == nil, "the second file asked for no line: \(opened[1])")
        #expect(fixture.recorder.calls.count == 2, "different lines cannot share one event")
        #expect(fixture.recorder.calls.allSatisfy { !$0.activates }, "--background")
    }

    @Test func aFolderAddsItsRequestedObjectAndNothingMore() async throws {
        let fixture = try Fixture(opensFolders: true)
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await fixture.run(["--folder", folder.path, "--wait", "0", "--json"])

        let result = try fixture.printed.jsonObject()
        #expect(Set(result.keys) == ["ok", "app", "opened", "folder"], "\(result)")
        #expect(result["ok"] as? Bool == true)
        #expect((result["opened"] as? [Any])?.isEmpty == true)
        let reported = try #require(result["folder"] as? [String: Any])
        #expect(Set(reported.keys) == ["path", "requested"], "no status with --wait 0: \(reported)")
        #expect(reported["path"] as? String == folder.path)
        #expect(reported["requested"] as? Bool == true)
        #expect(fixture.recorder.calls.map { $0.urls.map(\.path) } == [[folder.path]], "sent through the stub")
    }

    @Test func textModeNamesTheFileAndTheLine() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = try fixture.file("notes.md")
        // Text mode may print the skill tip; a quiet hint keeps the test off the real home.
        try await HintTesting.withQuietHint { try await fixture.run(["\(file.path):7"]) }
        #expect(fixture.printed.all == ["Opened \(file.resolvingSymlinksInPath().path) at line 7"])
    }
}

// MARK: - export --json

@Suite(.timeLimit(.minutes(3)))
struct ExportJSONContractTests {
    /// A document that really has two pages: a page break between two headings.
    static let twoPages = "# First\n\nThe first page.\n\n<!--BREAK-->\n\n# Second\n\nThe second page.\n"

    @Test func theResultCarriesTheValuesOfTheRunThatMadeIt() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("two.md")
        try Data(Self.twoPages.utf8).write(to: input)
        let output = root.appendingPathComponent("two.pdf")

        let run = try CLIProcess.run(["export", input.path, "-o", output.path, "--json"], in: root)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stderr.isEmpty, "\(run.stderr)")
        let result = try run.jsonObject()
        #expect(Set(result.keys) == ["ok", "output", "pages", "theme", "paper", "diagramErrors", "diagramErrorDetails"], "\(result)")
        #expect(result["ok"] as? Bool == true)
        #expect(result["pages"] as? Int == 2)
        #expect(result["output"] as? String == output.path)
        #expect((result["output"] as? String)?.hasPrefix("/") == true)
        #expect(result["theme"] as? String == "dawn")
        #expect(result["paper"] as? String == "a4")
        #expect((result["diagramErrors"] as? [Any])?.isEmpty == true)
        #expect((result["diagramErrorDetails"] as? [Any])?.isEmpty == true)

        // Independent of the CLI: the file it names is a PDF with the pages it reports.
        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.pageCount == 2)
    }

    @Test func theThemeAndPaperAreTheOnesUsed() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("one.md")
        try Data("# Only\n\nOne page.\n".utf8).write(to: input)
        let output = root.appendingPathComponent("one.pdf")

        let run = try CLIProcess.run(
            ["export", input.path, "-o", output.path, "--theme", "classic", "--paper", "letter", "--json"], in: root
        )
        #expect(run.status == 0 && run.stderr.isEmpty, "\(run.stderr)")
        let result = try run.jsonObject()
        #expect(result["theme"] as? String == "classic")
        #expect(result["paper"] as? String == "letter")
        #expect(result["pages"] as? Int == 1)
        #expect(result["output"] as? String == output.path)
    }

    @Test func withoutDashOTheOutputIsBesideTheInputAsAnAbsolutePath() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Only\n".utf8).write(to: root.appendingPathComponent("beside.md"))

        // A relative input, run from the scratch folder: the reported path is still absolute.
        let run = try CLIProcess.run(["export", "beside.md", "--json"], in: root)
        #expect(run.status == 0, "\(run.stderr)")
        let result = try run.jsonObject()
        let reported = try #require(result["output"] as? String)
        #expect(reported.hasPrefix("/"))
        #expect(reported.hasSuffix("/beside.pdf"))
        #expect(FileManager.default.fileExists(atPath: reported))
        #expect(URL(fileURLWithPath: reported).resolvingSymlinksInPath().path
                == root.appendingPathComponent("beside.pdf").resolvingSymlinksInPath().path)
    }
}

// MARK: - failures through main.swift's finish()

/// `finish()` turns each error type into stderr text or `{"ok":false,"error","message"}` JSON and
/// the exit status. Only a subprocess runs it. Kinds and codes are literals.
@Suite(.timeLimit(.minutes(3)))
struct ProcessFailureContractTests {
    /// What `locate` prints to stderr whenever MARSDAWN_APP_PATH is set, which the pinned
    /// environment always does. It is the override notice, not an error.
    static let overrideNotice = "marsdawn: using $MARSDAWN_APP_PATH override: /nonexistent\n"

    private func expectFailure(
        _ run: CLIProcess.Run, status: Int32, kind: String, messageContains fragment: String,
        stderr expectedStderr: String = "", sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(run.status == status, "exit status; stdout \(run.stdout) stderr \(run.stderr)", sourceLocation: sourceLocation)
        #expect(run.stderr == expectedStderr, "stderr in JSON mode", sourceLocation: sourceLocation)
        let object = try run.jsonObject()
        #expect(Set(object.keys) == ["ok", "error", "message"], "\(object)", sourceLocation: sourceLocation)
        #expect(object["ok"] as? Bool == false, sourceLocation: sourceLocation)
        #expect(object["error"] as? String == kind, sourceLocation: sourceLocation)
        let message = object["message"] as? String ?? ""
        #expect(message.contains(fragment), "message \(message)", sourceLocation: sourceLocation)
        #expect(run.stdout.hasSuffix("\n") && run.stdout.filter { $0 == "\n" }.count == 1, "one JSON line: \(run.stdout)", sourceLocation: sourceLocation)
    }

    @Test func aMissingInputExitsTwoWithInputNotFound() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("nope.md").path
        let run = try CLIProcess.run(["export", missing, "--json"], in: root)
        try expectFailure(run, status: 2, kind: "input_not_found", messageContains: "No such file: \(missing)")
    }

    @Test func exportingOverAnExistingFileExitsFourAndLeavesItAlone() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("a.md")
        try Data("# A\n".utf8).write(to: input)
        let output = root.appendingPathComponent("a.pdf")
        try Data("OLD".utf8).write(to: output)
        let run = try CLIProcess.run(["export", input.path, "-o", output.path, "--json"], in: root)
        try expectFailure(run, status: 4, kind: "output_exists", messageContains: "\(output.path) already exists. Pass --force")
        #expect(try Data(contentsOf: output) == Data("OLD".utf8))
    }

    /// The real `locate`, not a stub: MARSDAWN_APP_PATH names nothing, so `open` refuses with 3
    /// rather than falling through to the installed app. It also covers README's "refused with
    /// exit code 3" end to end.
    @Test func openWithNoAppExitsThreeWithAppNotInstalled() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("x.md")
        try Data("# X\n".utf8).write(to: input)
        let run = try CLIProcess.run(["open", input.path, "--json"], in: root)
        try expectFailure(
            run, status: 3, kind: "app_not_installed", messageContains: "MarsDawn is not installed",
            stderr: Self.overrideNotice
        )
    }

    @Test func aDifferingSkillExitsSixtyFourWithSkillDiffers() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("skill", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("SKILL.md")
        try Data("my own edit\n".utf8).write(to: target)
        let run = try CLIProcess.run(["skill", "--install", "--dir", folder.path, "--json"], in: root)
        try expectFailure(run, status: 64, kind: "skill_differs", messageContains: target.path)
        #expect(try Data(contentsOf: target) == Data("my own edit\n".utf8), "left as it was")
    }

    @Test func aWaitOfThirtyOneExitsSixtyFourWithWaitOutOfRange() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("x.md")
        try Data("# X\n".utf8).write(to: input)
        let run = try CLIProcess.run(["open", "--wait", "31", input.path, "--json"], in: root)
        try expectFailure(
            run, status: 64, kind: "wait_out_of_range",
            messageContains: "--wait must be between 0 and 30 seconds, but 31 was given."
        )
    }

    /// `--wait -1` is ArgumentParser's own failure: exit 64, but no JSON `error` kind.
    @Test func aNegativeWaitWithASpaceIsAPlainUsageError() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("x.md")
        try Data("# X\n".utf8).write(to: input)
        let run = try CLIProcess.run(["open", input.path, "--wait", "-1", "--json"], in: root)
        #expect(run.status == 64)
        #expect(run.stdout.isEmpty, "no JSON result for ArgumentParser's own error: \(run.stdout)")
        #expect(run.stderr.contains("Error:"), "\(run.stderr)")
        #expect(!run.stderr.contains("wait_out_of_range"))
    }

    /// Without `--json`: the text on stderr, nothing on stdout, same exit status.
    @Test func withoutJSONTheFailureIsOneLineOnStderr() throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("nope.md").path
        let run = try CLIProcess.run(["export", missing], in: root)
        #expect(run.status == 2)
        #expect(run.stdout.isEmpty, "\(run.stdout)")
        #expect(run.stderr == "marsdawn: No such file: \(missing)\n")
    }
}

// MARK: - --wait bounds

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct WaitBoundsContractTests {
    private func run(_ arguments: [String], recorder: OpenRecorder) async throws {
        let app = try makeFakeApp(opensFolders: false)
        defer { try? FileManager.default.removeItem(at: app) }
        try await MarsDawnApp.$locateOverride.withValue(MarsDawnApp.LocateOverride({ app })) {
            try await MarsDawnCommand.Open.$opener.withValue(MarsDawnCommand.Open.Opener(recorder.opener)) {
                try await OutputOptions.$sink.withValue(OutputOptions.Sink({ _ in })) {
                    try await MarsDawnCommand.Open.parse(arguments).run()
                }
            }
        }
    }

    private func scratchFile() throws -> (root: URL, file: URL) {
        let root = try CLIProcess.scratch()
        let file = root.appendingPathComponent("x.md")
        try Data("# X\n".utf8).write(to: file)
        return (root, file)
    }

    @Test func zeroAndThirtyAreAccepted() async throws {
        let (root, file) = try scratchFile()
        defer { try? FileManager.default.removeItem(at: root) }
        for value in ["0", "30"] {
            let recorder = OpenRecorder()
            try await run(["--wait", value, file.path, "--json"], recorder: recorder)
            #expect(recorder.calls.map { $0.urls.map(\.path) } == [[file.path]], "--wait \(value) opened the file")
        }
    }

    @Test func thirtyOneAndMinusOneAreRefusedBeforeAnythingIsSent() async throws {
        let (root, file) = try scratchFile()
        defer { try? FileManager.default.removeItem(at: root) }
        for argument in ["--wait=31", "--wait=-1"] {
            let recorder = OpenRecorder()
            var thrown: Error?
            do { try await run([argument, file.path, "--json"], recorder: recorder) } catch { thrown = error }
            let failure = try #require(thrown as? WaitRangeFailure, "\(argument): \(String(describing: thrown))")
            #expect(cliExitCode(for: failure) == 64)
            #expect(WaitRangeFailure.kind == "wait_out_of_range")
            #expect(recorder.calls.isEmpty, "\(argument): nothing sent")
        }
    }
}

// MARK: - export --force

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct ExportForceContractTests {
    @Test func withoutForceTheOldFileStaysByteIdenticalAndWithForceItIsReplaced() async throws {
        let root = try CLIProcess.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("doc.md")
        try Data("# Title\n\nA paragraph.\n".utf8).write(to: input)
        let output = root.appendingPathComponent("doc.pdf")
        let old = Data("OLD PDF, NOT REALLY".utf8)
        try old.write(to: output)
        let printed = PrintedLines()

        try await HintTesting.withQuietHint {
            // No --force: exit 4, and the old bytes stay.
            var thrown: Error?
            do { try await MarsDawnCommand.Export.parse([input.path, "-o", output.path, "--json"]).run() } catch { thrown = error }
            let failure = try #require(thrown as? CLIFailure, "\(String(describing: thrown))")
            #expect(failure.kind == "output_exists" && cliExitCode(for: failure) == 4)
            #expect(try Data(contentsOf: output) == old, "byte-identical without --force")

            // --force: succeeds and replaces it.
            try await OutputOptions.$sink.withValue(OutputOptions.Sink({ printed.add($0) })) {
                try await MarsDawnCommand.Export.parse([input.path, "-o", output.path, "--force", "--json"]).run()
            }
        }

        let replaced = try Data(contentsOf: output)
        #expect(replaced != old)
        #expect(replaced.prefix(5) == Data("%PDF-".utf8))
        #expect(PDFDocument(data: replaced)?.pageCount == 1)
        let result = try printed.jsonObject()
        #expect(result["ok"] as? Bool == true)
        #expect(result["output"] as? String == output.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["doc.md", "doc.pdf"], "no temporary file left")
    }
}
#endif
