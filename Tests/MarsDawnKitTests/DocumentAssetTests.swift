import Foundation
import Testing
@testable import MarsDawnKit

struct DocumentAssetTests {
    private typealias Handler = DocumentAssetSchemeHandler

    @Test func mapsRelativeAndAbsoluteImageSources() {
        #expect(Handler.previewURL(forImageSource: "img/a b.png", hasBaseDirectory: true) == "marsdawn-asset://doc/img/a%20b.png")
        #expect(Handler.previewURL(forImageSource: "./img/a%20b.png?x=1#y", hasBaseDirectory: true) == "marsdawn-asset://doc/./img/a%20b.png")
        #expect(Handler.previewURL(forImageSource: "../shared/logo.svg", hasBaseDirectory: true) == "marsdawn-asset://doc/../shared/logo.svg")
        #expect(Handler.previewURL(forImageSource: "/Users/me/pic.jpg", hasBaseDirectory: false) == "marsdawn-asset://abs/Users/me/pic.jpg")
    }

    @Test func leavesRemoteAndUnresolvableSourcesAlone() {
        #expect(Handler.previewURL(forImageSource: "https://example.com/a.png", hasBaseDirectory: true) == nil)
        #expect(Handler.previewURL(forImageSource: "data:image/png;base64,AA", hasBaseDirectory: true) == nil)
        #expect(Handler.previewURL(forImageSource: "img/a.png", hasBaseDirectory: false) == nil)
        #expect(Handler.previewURL(forImageSource: "", hasBaseDirectory: true) == nil)
    }

    /// A real folder tree: <root>/project/doc folder, <root>/shared, <root>/outside, plus symlinks.
    private func makeTree() throws -> (root: URL, project: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("asset-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let project = root.appendingPathComponent("granted/project")
        try fm.createDirectory(at: project.appendingPathComponent("img"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("granted/shared"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try Data([1]).write(to: project.appendingPathComponent("img/a b.png"))
        try Data([1]).write(to: root.appendingPathComponent("granted/shared/logo.svg"))
        try Data([1]).write(to: root.appendingPathComponent("outside/other.png"))
        try "secret".write(to: project.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: project.appendingPathComponent("img/fake.png"), withDestinationURL: project.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("img/escape.png"), withDestinationURL: root.appendingPathComponent("outside/other.png"))
        return (root, project)
    }

    @Test func servesImagesInsideTheScopeOnly() throws {
        let (root, project) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let granted = root.appendingPathComponent("granted")
        func file(_ string: String, scope: URL? = nil) -> String? {
            Handler.fileURL(for: URL(string: string)!, baseDirectory: project, scopeRoot: scope)?.path
        }

        #expect(file("marsdawn-asset://doc/img/a%20b.png") == project.appendingPathComponent("img/a b.png").path)
        // Parent folders need a granted scope that contains them.
        #expect(file("marsdawn-asset://doc/../shared/logo.svg") == nil)
        #expect(file("marsdawn-asset://doc/../shared/logo.svg", scope: granted) == granted.appendingPathComponent("shared/logo.svg").path)
        #expect(file("marsdawn-asset://doc/../../outside/other.png", scope: granted) == nil)
        #expect(file("marsdawn-asset://abs\(root.path)/outside/other.png", scope: granted) == nil)
        #expect(file("marsdawn-asset://abs\(project.path)/img/a%20b.png") != nil)
    }

    @Test func rejectsNonImagesSymlinkTricksAndControlCharacters() throws {
        let (root, project) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ string: String) -> URL? {
            Handler.fileURL(for: URL(string: string)!, baseDirectory: project, scopeRoot: root.appendingPathComponent("granted"))
        }
        #expect(file("marsdawn-asset://doc/notes.txt") == nil)
        #expect(file("marsdawn-asset://doc/img/fake.png") == nil)       // image name, text target
        #expect(file("marsdawn-asset://doc/img/escape.png") == nil)     // image target outside the scope
        #expect(file("marsdawn-asset://doc/notes.txt%00.png") == nil)
        #expect(file("marsdawn-asset://other/img/a%20b.png") == nil)
        #expect(Handler.fileURL(for: URL(string: "marsdawn-asset://doc/a.png")!, baseDirectory: nil, scopeRoot: nil) == nil)
    }

    // MARK: `..` sources (mars-dawn#8)

    /// A `..` source maps to the absolute path it names; WebKit would remove the dot segments
    /// from a `doc/../…` URL before the handler saw it. Everything else maps as the old overload.
    @Test func aParentRelativeSourceMapsToTheAbsolutePathItNames() {
        let base = URL(fileURLWithPath: "/root/doc", isDirectory: true)
        func url(_ source: String) -> String? { Handler.previewURL(forImageSource: source, baseDirectory: base) }
        // Resolved, with the path as the document has it (decoded, as placeholders show it) in the fragment.
        #expect(url("../shared/logo.png") == "marsdawn-asset://abs/root/shared/logo.png#../shared/logo.png")
        #expect(url("img/../b.png") == "marsdawn-asset://abs/root/doc/b.png#img/../b.png")
        #expect(url("%2e%2e/x.png") == "marsdawn-asset://abs/root/x.png#../x.png")
        #expect(url("..%2fx.png") == "marsdawn-asset://abs/root/x.png#../x.png")
        #expect(url("../my folder/a b.png?v=1#f") == "marsdawn-asset://abs/root/my%20folder/a%20b.png#../my%20folder/a%20b.png")
        #expect(url("../%3Cscript%3E.png") == "marsdawn-asset://abs/root/%3Cscript%3E.png#../%3Cscript%3E.png")
        // Too long to carry: resolved, without the fragment.
        let long = "../" + String(repeating: "a", count: 5000) + ".png"
        #expect(url(long) == "marsdawn-asset://abs/root/" + String(repeating: "a", count: 5000) + ".png")
        for source in ["img/a.png", "/abs/x.png", "https://example.com/a.png", "data:image/png;base64,AA", "#x",
                       "a..b/c.png", "%252e%252e/x.png", "..\\x.png", "../../../../x.png", ""] {
            #expect(url(source) == Handler.previewURL(forImageSource: source, hasBaseDirectory: true), "\(source)")
        }
        #expect(Handler.previewURL(forImageSource: "../x.png", baseDirectory: nil) == nil)
    }

    /// The scope rule is unchanged, and every way a `..` source might try to leave the scope is
    /// refused. Each URL goes through `standardized` first, as WebKit removes dot segments.
    @Test func parentRelativeSourcesStayInsideTheScope() throws {
        let (root, project) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let granted = root.appendingPathComponent("granted")
        func served(_ source: String, scope: URL?) -> String? {
            guard let mapped = Handler.previewURL(forImageSource: source, baseDirectory: project),
                  let url = URL(string: mapped)?.standardized else { return nil }
            return Handler.fileURL(for: url, baseDirectory: project, scopeRoot: scope)?.path
        }
        let logo = granted.appendingPathComponent("shared/logo.svg").path
        // Inside the granted parent: served. Without the grant (scope = the document's folder): not.
        #expect(served("../shared/logo.svg", scope: granted) == logo)
        #expect(served("..%2fshared/logo.svg", scope: granted) == logo)
        #expect(served("../shared/logo.svg", scope: nil) == nil)
        // Escaping the granted parent, however it's spelled: never served.
        #expect(served("../../outside/other.png", scope: granted) == nil)
        #expect(served("..%2f..%2foutside/other.png", scope: granted) == nil)
        #expect(served("%2e%2e/%2e%2e/outside/other.png", scope: granted) == nil)
        #expect(served("%252e%252e/%252e%252e/outside/other.png", scope: granted) == nil)
        #expect(served("..\\..\\outside\\other.png", scope: granted) == nil)
        // Through a symbolic link inside the scope that points out of it: never followed.
        #expect(served("../project/img/escape.png", scope: granted) == nil)
        #expect(served("img/../img/escape.png", scope: granted) == nil)
        // The twin: a plain image through a `..` round trip inside the document's folder.
        #expect(served("img/../img/a b.png", scope: nil) == project.appendingPathComponent("img/a b.png").path)
    }

    @Test func readsRegularFilesWithinTheSizeLimit() throws {
        let (root, project) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Handler.readImage(at: project.appendingPathComponent("img/a b.png")) == Data([1]))
        #expect(Handler.readImage(at: project.appendingPathComponent("img")) == nil)
        #expect(Handler.readImage(at: project.appendingPathComponent("img/none.png")) == nil)
    }

    @Test func rendererRoutesImagesThroughResolver() {
        let options = MarkdownRenderer.Options { Handler.previewURL(forImageSource: $0, hasBaseDirectory: true) ?? $0 }
        let html = MarkdownRenderer.render("![logo](img/logo.png) ![remote](https://x.io/a.png)", options: options)
        #expect(html.contains(#"src="marsdawn-asset://doc/img/logo.png""#))
        #expect(html.contains(#"src="https://x.io/a.png""#))
    }

    @Test func assetStateScriptIsJSON() {
        let script = PreviewWebView.assetStateScript(needsAccess: true, grantLabel: "授權\"", missingLabel: "m", blockedLabel: "b")
        #expect(script.hasPrefix("window.MarsDawn && MarsDawn.setAssetState({"))
        #expect(script.contains(#""needsAccess":true"#))
        #expect(script.contains(#"授權\""#))
    }
}

struct RemoteImagePolicyTests {
    private let template = Data("img-src marsdawn-app: data: __REMOTE_IMAGE_SOURCES__;".utf8)

    @Test func pageBlocksRemoteImagesByDefault() {
        let url = PreviewSchemeHandler.pageURL(theme: .dawn)
        #expect(!url.absoluteString.contains("remote-images"))
        let page = String(decoding: PreviewSchemeHandler.page(template, for: url), as: UTF8.self)
        #expect(page == "img-src marsdawn-app: data: ;")
    }

    @Test func pageAllowsHTTPSImagesWhenAsked() {
        let url = PreviewSchemeHandler.pageURL(theme: .classic, allowRemoteImages: true)
        #expect(url.absoluteString == "marsdawn-app://preview/index.html?theme=classic&remote-images=1")
        let page = String(decoding: PreviewSchemeHandler.page(template, for: url), as: UTF8.self)
        #expect(page == "img-src marsdawn-app: data: https:;")
    }

    @Test func bundledTemplateCarriesTheToken() throws {
        let index = try #require(Bundle.module.url(forResource: "Preview/index", withExtension: "html"))
        let html = try String(contentsOf: index, encoding: .utf8)
        #expect(html.contains("img-src marsdawn-app: marsdawn-asset: data: __REMOTE_IMAGE_SOURCES__"))
        #expect(!html.contains(" https:"))
    }

    @Test func remoteImagesScriptIsJSON() {
        let script = PreviewWebView.remoteImagesScript(blocked: true, message: "遠端\"", buttonLabel: "Load", placeholderLabel: "Remote")
        #expect(script.hasPrefix("window.MarsDawn && MarsDawn.setRemoteImageState({"))
        #expect(script.contains(#""blocked":true"#))
    }
}
