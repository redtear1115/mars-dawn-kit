import Foundation
import Testing
@testable import MarsDawnKit

/// What `PreviewSchemeHandler` says a file is (S5-6).
///
/// A fixed table rather than `UTType(filenameExtension:)`, which has no MIME type for `woff2`
/// at all, plus `X-Content-Type-Options: nosniff` so WebKit takes the table's word for it.
struct PreviewServingTests {
    @Test(arguments: [
        ("html", "text/html"),
        ("css", "text/css"),
        ("js", "text/javascript"),
        ("woff2", "font/woff2"),
        // The extension as the URL spells it, whatever its case.
        ("WOFF2", "font/woff2"),
        ("Css", "text/css"),
        // Nothing else is served as anything the page could use.
        ("txt", "application/octet-stream"),
        ("woff", "application/octet-stream"),
        ("ttf", "application/octet-stream"),
        ("svg", "application/octet-stream"),
        ("", "application/octet-stream"),
    ])
    func contentTypesComeFromTheFixedTable(pathExtension: String, expected: String) {
        #expect(PreviewSchemeHandler.contentType(forPathExtension: pathExtension) == expected)
    }

    /// Every file the Preview folder actually holds has a type, or is a licence text that the
    /// page never asks for.
    @Test func everyServedFileKindIsInTheTable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath }
        #expect(files.count > 5)
        for file in files {
            let type = PreviewSchemeHandler.contentType(forPathExtension: file.pathExtension)
            if type == "application/octet-stream" {
                #expect(file.lastPathComponent.hasPrefix("LICENSE-"), "no content type for \(file.lastPathComponent)")
            }
        }
    }
}
