#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import marsdawn

/// `export --details expand|as-written` (redtear1115/mars-dawn#300) through the built `marsdawn`,
/// like `HandoutCLITests`, on the export tests' collapsible fixture.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DetailsCLITests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MarsDawnExportTests/Fixtures/collapsible-fixture.md")

    struct Run {
        var status: Int32
        var stdout: String
        var stderr: String
        var text: String?
    }

    static func export(_ arguments: [String]) throws -> Run {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-details-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("notes.md")
        try FileManager.default.copyItem(at: fixture, to: input)
        let output = root.appendingPathComponent("out.pdf")
        let process = Process()
        process.executableURL = try LayoutDeprecationTests.binary()
        process.currentDirectoryURL = root
        process.arguments = ["export", input.path, "-o", output.path] + arguments
        process.environment = ["MARSDAWN_APP_PATH": "/nonexistent", "HOME": root.path, "PATH": "/usr/bin:/bin"]
        let outPipe = Pipe(), errorPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = PDFDocument(url: output).map { document in
            (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        }
        return Run(
            status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self), text: text
        )
    }

    @Test func noFlagIsExpandAndAsWrittenLeavesClosedBlocksOut() throws {
        let plain = try Self.export([])
        let expand = try Self.export(["--details", "expand"])
        let written = try Self.export(["--details", "as-written"])
        for run in [plain, expand, written] {
            try #require(run.status == 0, "stderr: \(run.stderr)")
        }
        let plainText = try #require(plain.text), expandText = try #require(expand.text), writtenText = try #require(written.text)
        #expect(plainText == expandText, "no flag is --details expand")
        #expect(expandText.contains("BODY-A first") && expandText.contains("BODY-G-INNER"))
        #expect(writtenText != expandText)
        for part in ["SUMMARY-A", "BODY-C", "SUMMARY-G-OUTER", "END-OF-FIXTURE"] {
            #expect(writtenText.contains(part), "as-written holds \(part)")
        }
        for part in ["BODY-A first", "BODY-G-OUTER", "BODY-G-INNER", "FM-TITLE-SECRET"] {
            #expect(!writtenText.contains(part), "as-written leaves out \(part)")
        }
    }

    /// The `--json` result is the published export.v1 schema (`additionalProperties: false`), so
    /// the mode is not reported, as the layout isn't.
    @Test func theJSONResultKeepsItsFields() throws {
        let run = try Self.export(["--details", "as-written", "--json"])
        try #require(run.status == 0, "stderr: \(run.stderr)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["ok", "output", "pages", "theme", "paper", "diagramErrors", "diagramErrorDetails"])
    }

    @Test func anUnknownModeIsAUsageErrorNamingTheChoices() throws {
        let run = try Self.export(["--details", "collapse"])
        #expect(run.status == 64)
        #expect(run.stderr.contains("'collapse' is invalid for '--details <mode>'"), "\(run.stderr)")
        #expect(run.stderr.contains("'expand' and 'as-written'"), "\(run.stderr)")
        #expect(run.text == nil, "nothing was written")
    }
}
#endif
