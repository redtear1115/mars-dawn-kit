import Foundation
import Testing
import WebKit
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

    // MARK: Traversal

    /// `resolve` serves only files under the handler's root: a `..` segment (spelled plainly or
    /// percent-encoded), or a sibling folder whose name merely starts with the root's, is
    /// refused, while a real file under the root is served (the positive control).
    @MainActor
    @Test func requestsOutsideTheRootAreRefusedAndOnesInsideAreServed() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Preview")
        let sibling = parent.appendingPathComponent("Preview2")
        for folder in [root, sibling] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("inside".utf8).write(to: root.appendingPathComponent("ok.css"))
        try Data("sibling".utf8).write(to: sibling.appendingPathComponent("secret.css"))
        try Data("above".utf8).write(to: parent.appendingPathComponent("secret.css"))

        let handler = PreviewSchemeHandler(rootURL: root)
        let webView = WKWebView(frame: .zero)
        func serve(_ path: String) -> FakeSchemeTask {
            let task = FakeSchemeTask(url: URL(string: "\(PreviewSchemeHandler.scheme)://preview\(path)")!)
            handler.webView(webView, start: task)
            return task
        }

        let ok = serve("/ok.css")
        #expect(ok.status == 200)
        #expect(ok.body == Data("inside".utf8))

        for path in ["/../secret.css", "/%2e%2e/secret.css", "/%2E%2E/secret.css", "/../Preview2/secret.css",
                     "/%2e%2e/Preview2/secret.css", "/sub/../../secret.css"] {
            let task = serve(path)
            #expect(task.response == nil && task.body.isEmpty, "served \(path)")
            #expect((task.error as? URLError)?.code == .fileDoesNotExist, "\(path)")
        }
    }
}
