import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// The image handler on `ScopedFileReader`: lexical mapping, both root spellings, the explicit
/// image table and no symlinks.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DocumentAssetScopeTests {
    private typealias Handler = DocumentAssetSchemeHandler

    private func makeFolder(parent: String) throws -> URL {
        let folder = URL(fileURLWithPath: parent).appendingPathComponent("asset-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try RecordingServer.png.write(to: folder.appendingPathComponent("project/img.png"))
        try Data("<svg/>".utf8).write(to: folder.appendingPathComponent("shared/logo.svg"))
        return folder
    }

    private func load(_ url: String, base: URL?, scope: URL?) -> Data? {
        try? Handler.loadImage(for: URL(string: url)!, baseDirectory: base, scopeRoot: scope).get().data
    }

    /// Runs a request through the handler's `WKURLSchemeHandler` entry point.
    private func serve(_ handler: Handler, _ url: String) async throws -> FakeSchemeTask {
        let task = FakeSchemeTask(url: URL(string: url)!)
        handler.webView(WKWebView(frame: .zero), start: task)
        try await waitUntil(timeout: .seconds(5)) { task.done }
        return task
    }

    @Test func absoluteRequestsMatchEitherTmpSpelling() async throws {
        let folder = try makeFolder(parent: "/private/tmp")
        defer { try? FileManager.default.removeItem(at: folder) }
        let privateSpelling = folder.path
        #expect(privateSpelling.hasPrefix("/private/tmp/"))
        let tmpSpelling = String(privateSpelling.dropFirst("/private".count))

        let handler = Handler()
        handler.scopeRoot = URL(fileURLWithPath: privateSpelling)
        let served = try await serve(handler, "marsdawn-asset://abs\(tmpSpelling)/project/img.png")
        #expect(served.status == 200)
        #expect(served.body == RecordingServer.png)
        #expect(served.header("Content-Type") == "image/png")

        handler.scopeRoot = URL(fileURLWithPath: tmpSpelling)
        let reverse = try await serve(handler, "marsdawn-asset://abs\(privateSpelling)/project/img.png")
        #expect(reverse.status == 200)
        #expect(load("marsdawn-asset://abs\(privateSpelling)/project/img.png", base: nil, scope: URL(fileURLWithPath: tmpSpelling)) == RecordingServer.png)
    }

    @Test func absoluteRequestsMatchEitherVarSpelling() async throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        try #require(temporary.hasPrefix("/var/"))
        let folder = try makeFolder(parent: temporary)
        defer { try? FileManager.default.removeItem(at: folder) }
        let varSpelling = folder.path
        let privateSpelling = "/private" + varSpelling

        let handler = Handler()
        handler.scopeRoot = URL(fileURLWithPath: privateSpelling)
        #expect(try await serve(handler, "marsdawn-asset://abs\(varSpelling)/project/img.png").status == 200)
        handler.scopeRoot = URL(fileURLWithPath: varSpelling)
        #expect(try await serve(handler, "marsdawn-asset://abs\(privateSpelling)/project/img.png").status == 200)
        #expect(load("marsdawn-asset://abs\(varSpelling)/project/img.png", base: nil, scope: URL(fileURLWithPath: privateSpelling)) == RecordingServer.png)
    }

    @Test func parentReferenceIsServedWithAGrantedParent() async throws {
        let folder = try makeFolder(parent: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("project")
        let handler = Handler()
        handler.baseDirectory = project
        let refused = try await serve(handler, "marsdawn-asset://doc/../shared/logo.svg")
        #expect(refused.error != nil && refused.response == nil)
        handler.scopeRoot = folder
        let served = try await serve(handler, "marsdawn-asset://doc/../shared/logo.svg")
        #expect(served.status == 200)
        #expect(served.header("Content-Type") == "image/svg+xml")
        #expect(served.body == Data("<svg/>".utf8))
    }

    @Test func refusesImageTypesOutsideTheTable() async throws {
        let folder = try makeFolder(parent: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("project")
        for name in ["photo.cr2", "photo.dng", "layers.psd", "hdr.exr", "old.tga", "page.pdf", "x.js"] {
            try RecordingServer.png.write(to: project.appendingPathComponent(name))
            #expect(Handler.fileURL(for: URL(string: "marsdawn-asset://doc/\(name)")!, baseDirectory: project, scopeRoot: nil) == nil, "\(name)")
        }
        let handler = Handler()
        handler.baseDirectory = project
        let psd = try await serve(handler, "marsdawn-asset://doc/layers.psd")
        #expect(psd.error != nil && psd.response == nil)
        #expect((psd.error as? URLError)?.code == .noPermissionsToReadFile)
        try RecordingServer.png.write(to: project.appendingPathComponent("UPPER.PNG"))
        #expect(try await serve(handler, "marsdawn-asset://doc/UPPER.PNG").status == 200)
    }

    @Test func refusesSymlinksInsideTheScope() async throws {
        let folder = try makeFolder(parent: NSTemporaryDirectory())
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("alias.png").path, withDestinationPath: "img.png")
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("linked").path, withDestinationPath: ".")
        #expect(Handler.fileURL(for: URL(string: "marsdawn-asset://doc/img.png")!, baseDirectory: project, scopeRoot: nil) != nil)
        #expect(Handler.fileURL(for: URL(string: "marsdawn-asset://doc/alias.png")!, baseDirectory: project, scopeRoot: nil) == nil)
        #expect(Handler.fileURL(for: URL(string: "marsdawn-asset://doc/linked/img.png")!, baseDirectory: project, scopeRoot: nil) == nil)
        let handler = Handler()
        handler.baseDirectory = project
        let alias = try await serve(handler, "marsdawn-asset://doc/alias.png")
        #expect(alias.error != nil && alias.response == nil)
        #expect((alias.error as? URLError)?.code == .fileDoesNotExist)
        #expect(Handler.readImage(at: project.appendingPathComponent("alias.png")) == nil)
    }
}
