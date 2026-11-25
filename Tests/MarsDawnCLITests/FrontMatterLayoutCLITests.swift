#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import marsdawn

/// The front matter's `layout:` through the CLI (mars-dawn#668): it picks the layout when
/// `--layout` is absent, and `--layout` wins. Runs the built `marsdawn` like `HandoutCLITests`.
/// The handout's footer ("name · date · n / N") tells which layout was used.
@Suite(.timeLimit(.minutes(3)))
struct FrontMatterLayoutCLITests {
    static let document = "---\nlayout: handout\ndate: 2026-10-01\n---\n\nBody text.\n"
    static let footer = "notes · 2026-10-01 · 1 / 1"

    static func exportedText(_ markdown: String, arguments: [String] = []) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-fm-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("notes.md")
        try Data(markdown.utf8).write(to: input)
        let output = root.appendingPathComponent("out.pdf")
        let process = Process()
        process.executableURL = try LayoutDeprecationTests.binary()
        process.currentDirectoryURL = root
        process.arguments = ["export", input.path, "-o", output.path] + arguments
        process.environment = ["MARSDAWN_APP_PATH": "/nonexistent", "HOME": root.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "export exited \(process.terminationStatus), stderr: \(errorText)")
        let pdf = try #require(PDFDocument(url: output))
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
    }

    @Test func withoutTheFlagTheFrontMatterPicksTheLayout() throws {
        #expect(try Self.exportedText(Self.document).contains(Self.footer))
    }

    /// And the flag wins: the same file with `--layout document` has no handout footer.
    @Test func theFlagWinsOverTheFrontMatter() throws {
        #expect(!(try Self.exportedText(Self.document, arguments: ["--layout", "document"])).contains(Self.footer))
    }

    /// An unknown value is ignored: the document layout, no footer.
    @Test func anUnknownValueIsIgnored() throws {
        let unknown = Self.document.replacingOccurrences(of: "layout: handout", with: "layout: brochure")
        #expect(!(try Self.exportedText(unknown)).contains(Self.footer))
    }
}
#endif
