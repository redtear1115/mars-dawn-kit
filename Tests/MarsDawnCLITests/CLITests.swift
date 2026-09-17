#if os(macOS)
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

    @Test func exportRequiresTheAppToBeInstalled() {
        let original = MarsDawnApp.locate
        defer { MarsDawnApp.locate = original }
        MarsDawnApp.locate = { nil }
        #expect {
            _ = try MarsDawnApp.require()
        } throws: { ($0 as? CLIFailure)?.code == .appNotInstalled }
    }
}
#endif
