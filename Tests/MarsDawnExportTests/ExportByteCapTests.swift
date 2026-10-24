#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// Export refuses a document over the renderer's byte cap before anything is printed (kit #150,
/// owner decision BC-1), instead of paginating its escaped source.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportByteCapTests {
    static let cap = ParseLimits.defaultMaxBytes

    static func document(bytes: Int) -> String {
        let line = String(repeating: "a", count: 1_023) + "\n"
        var text = "# Big\n\n"
        text += String(repeating: line, count: (bytes - text.utf8.count) / line.utf8.count)
        text += String(repeating: "b", count: bytes - text.utf8.count)
        precondition(text.utf8.count == bytes)
        return text
    }

    @Test func oneByteOverTheCapIsRefusedAndNothingIsWritten() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-bytecap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out.pdf")
        // The refusal comes from the renderer's default cap; without it this would export 16 MiB.
        try #require(MarkdownRenderer.Options.preview(baseDirectory: nil).maxBytes == Self.cap)

        var thrown: Error?
        do {
            _ = try await DocumentExporter.exportPDF(
                markdown: Self.document(bytes: Self.cap + 1), to: output, theme: .dawn,
                baseDirectory: root, allowRemoteImages: false
            )
        } catch {
            thrown = error
        }
        guard case .inputTooLarge(let limit)? = thrown as? DocumentExporter.ExportError else {
            Issue.record("expected inputTooLarge, got \(String(describing: thrown))")
            return
        }
        #expect(limit == Self.cap)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "no file written at all")
    }

    @Test func theRefusalIsExactAtTheCap() throws {
        let options = MarkdownRenderer.Options.preview(baseDirectory: nil)
        try DocumentExporter.refuseOverTheByteCap(Self.document(bytes: Self.cap), options: options)
        #expect(throws: DocumentExporter.ExportError.self) {
            try DocumentExporter.refuseOverTheByteCap(Self.document(bytes: Self.cap + 1), options: options)
        }
        // A renderer with no cap would never refuse.
        try DocumentExporter.refuseOverTheByteCap(Self.document(bytes: Self.cap + 1), options: MarkdownRenderer.Options(maxBytes: nil))
    }

    @Test func theMessageNamesTheLimit() {
        let message = DocumentExporter.ExportError.inputTooLarge(limit: Self.cap).errorDescription ?? ""
        #expect(message.contains("16 MB"), "\(message)")
    }
}
#endif
