#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import marsdawn

/// The handout through the CLI (mars-dawn#432 S3): the display name is the file's name without
/// its extension, never a path. Runs the built `marsdawn` like `LayoutDeprecationTests`, with
/// MARSDAWN_APP_PATH pinned to a path that doesn't exist and a scratch HOME.
@Suite(.timeLimit(.minutes(3)))
struct HandoutCLITests {
    static let parent = "secretparentXQ7"

    /// Exports `markdown` from `<scratch>/secretparentXQ7/inner dir/notes.md` and returns the
    /// PDF's bytes and text.
    static func export(_ markdown: String) throws -> (data: Data, text: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-handout-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(parent, isDirectory: true).appendingPathComponent("inner dir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = folder.appendingPathComponent("notes.md")
        try Data(markdown.utf8).write(to: input)
        let output = root.appendingPathComponent("out.pdf")
        let process = Process()
        process.executableURL = try LayoutDeprecationTests.binary()
        process.currentDirectoryURL = folder
        process.arguments = ["export", input.path, "-o", output.path, "--layout", "handout"]
        process.environment = ["MARSDAWN_APP_PATH": "/nonexistent", "HOME": root.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        // Read to the end before waiting, so a chatty child cannot fill the pipe and stall.
        let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "export exited \(process.terminationStatus), stderr: \(errorText)")
        let data = try Data(contentsOf: output)
        let document = try #require(PDFDocument(data: data))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        return (data, text)
    }

    /// Whether the file's bytes hold `needle`, ASCII letters in any case (a URL's host comes
    /// out lowercased).
    static func rawContains(_ data: Data, _ needle: String) -> Bool {
        let lower = Data(data.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 })
        return lower.range(of: Data(needle.lowercased().utf8)) != nil
    }

    @Test func theNameIsTheFileNameAndNoFolderReachesThePDF() throws {
        let run = try Self.export("---\ndate: 2026-10-01\n---\n\nBody text.\n")
        #expect(run.text.contains("notes · 2026-10-01 · 1 / 1"), "\(run.text)")
        #expect(run.text.hasPrefix("notes\n2026-10-01"), "the header shows the name: \(run.text)")
        for word in [Self.parent, "inner dir", "notes.md", NSTemporaryDirectory()] {
            #expect(!run.text.contains(word), "\(word) is in the PDF's text")
            #expect(!Self.rawContains(run.data, word), "\(word) is in the PDF's bytes")
        }
    }

    /// Control: the parent folder's name planted in the body shows in the text, and in a link
    /// (an uncompressed annotation) shows in the raw bytes, so both probes can find it.
    @Test func controlAPlantedFolderNameIsFound() throws {
        let run = try Self.export("Planted \(Self.parent) here, and [a link](https://example.com/\(Self.parent)/).\n")
        #expect(run.text.contains(Self.parent))
        #expect(Self.rawContains(run.data, Self.parent))
    }
}
#endif
