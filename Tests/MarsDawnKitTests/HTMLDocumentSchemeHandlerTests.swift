#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// A scheme task driven by the tests instead of WebKit. Only used on the main actor.
final class FakeSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private(set) var response: HTTPURLResponse?
    private(set) var body = Data()
    private(set) var finished = false
    private(set) var error: Error?
    private(set) var callbacks = 0

    var done: Bool { finished || error != nil }
    var status: Int? { response?.statusCode }
    func header(_ name: String) -> String? { response?.value(forHTTPHeaderField: name) }

    init(url: URL, range: String? = nil) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        callbacks += 1
        self.response = response as? HTTPURLResponse
    }

    func didReceive(_ data: Data) {
        callbacks += 1
        body.append(data)
    }

    func didFinish() {
        callbacks += 1
        finished = true
    }

    func didFailWithError(_ error: Error) {
        callbacks += 1
        self.error = error
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTMLDocumentSchemeHandlerTests {
    private typealias Handler = HTMLDocumentSchemeHandler

    /// <root>/site/pages/doc.html plus files around it.
    struct Tree {
        let root: URL
        var document: URL { root.appendingPathComponent("site/pages/doc.html") }
        func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    }

    private func makeTree() throws -> Tree {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("html-handler-\(UUID().uuidString)")
        let tree = Tree(root: root)
        for folder in ["site/pages/img", "site/shared", "site/pages/~", "site/pages/%2F"] {
            try fm.createDirectory(at: tree.url(folder), withIntermediateDirectories: true)
        }
        try Data("<p>doc</p>".utf8).write(to: tree.document)
        try RecordingServer.png.write(to: tree.url("site/pages/img/a.png"))
        try RecordingServer.png.write(to: tree.url("site/shared/logo.png"))
        try RecordingServer.png.write(to: tree.url("site/pages/~/tilde.png"))
        try RecordingServer.png.write(to: tree.url("site/pages/%2F/encoded.png"))
        try RecordingServer.png.write(to: tree.url("site/pages/%2F.png"))
        try Data("svg".utf8).write(to: tree.url("site/pages/img/i.svg"))
        try Data("p{}".utf8).write(to: tree.url("site/pages/s.css"))
        for name in ["x.js", "x.html", "x.json", "x.m3u8", "x.unknown"] {
            try Data("x".utf8).write(to: tree.url("site/pages/\(name)"))
        }
        return tree
    }

    private let webView = WKWebView(frame: .zero)

    /// Starts a request for `path` (raw, after the host) and waits for its answer.
    @discardableResult
    private func request(_ handler: Handler, _ page: URL, _ path: String, range: String? = nil, host: String? = nil) async throws -> FakeSchemeTask {
        let task = FakeSchemeTask(url: URL(string: "\(Handler.scheme)://\(host ?? page.host()!)\(path)")!, range: range)
        handler.webView(webView, start: task)
        try await waitUntil(timeout: .seconds(10)) { task.done }
        return task
    }

    private func begin(_ handler: Handler, _ tree: Tree, remote: Bool = false, document: String = "<p>page</p>") throws -> URL {
        try handler.beginLoad(document: Data(document.utf8), documentURL: tree.document, scopeRoot: tree.root, allowsRemoteContent: remote)
    }

    // MARK: Headers

    static let commonHeaders = [
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "Cache-Control": "no-store",
        "X-DNS-Prefetch-Control": "off",
    ]

    private func expectCommonHeaders(_ task: FakeSchemeTask, _ comment: String) {
        for (name, value) in Self.commonHeaders {
            #expect(task.header(name) == value, "\(name) on \(comment)")
        }
        #expect(task.header("Content-Length") == "\(task.body.count)", "length on \(comment)")
    }

    static let expectedBlockedCSP = "default-src 'none'; img-src marsdawn-html: data:; style-src marsdawn-html: 'unsafe-inline'; font-src marsdawn-html: data:; media-src marsdawn-html:; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; connect-src 'none'; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    static let expectedRemoteCSP = "default-src 'none'; img-src marsdawn-html: data: https:; style-src marsdawn-html: 'unsafe-inline' https:; font-src marsdawn-html: data: https:; media-src marsdawn-html: https:; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; connect-src 'none'; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"

    @Test func gateTestUsesTheProductionBlockedPolicy() {
        #expect(HTMLCSPHeaderGateTests.gateCSP == Handler.blockedCSP.replacingOccurrences(of: "marsdawn-html:", with: "h1-gate:"))
    }

    @Test(arguments: [false, true])
    func responsesCarryTheExpectedHeaders(remote: Bool) async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let handler = Handler()
        let page = try begin(handler, tree, remote: remote, document: "<p>page</p>")

        let main = try await request(handler, page, page.path(percentEncoded: true))
        #expect(main.status == 200)
        #expect(main.body == Data("<p>page</p>".utf8))
        #expect(main.header("Content-Type") == "text/html; charset=utf-8")
        #expect(main.header("Content-Security-Policy") == (remote ? Self.expectedRemoteCSP + "; upgrade-insecure-requests" : Self.expectedBlockedCSP))
        expectCommonHeaders(main, "page")

        let subresourceCSP = Self.expectedBlockedCSP + "; sandbox"
        for (path, type) in [("/%2F/%2F/img/i.svg", "image/svg+xml"), ("/%2F/%2F/s.css", "text/css"), ("/%2F/%2F/img/a.png", "image/png")] {
            let task = try await request(handler, page, path)
            #expect(task.status == 200, "\(path)")
            #expect(task.header("Content-Type") == type)
            #expect(task.header("Content-Security-Policy") == subresourceCSP, "\(path)")
            expectCommonHeaders(task, path)
        }
    }

    // MARK: URL mapping

    @Test func pageURLHoldsNoRealNames() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let handler = Handler()
        let page = try begin(handler, tree)
        let token = try #require(page.host())
        #expect(token.utf8.count == 32)
        #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(page.absoluteString == "marsdawn-html://\(token)/%2F/%2F/index.html")
        for name in ["site", "pages", "doc", tree.root.lastPathComponent] {
            #expect(!page.absoluteString.contains(name))
        }
        let again = try begin(handler, tree)
        #expect(again.host() != token)
    }

    @Test func mapsRawSegments() {
        let ancestors = ["site", "pages"]
        func map(_ path: String) -> Handler.Mapping { Handler.map(rawPath: path, ancestors: ancestors) }
        #expect(map("/%2F/%2F/index.html") == .page)
        #expect(map("/%2F/%2F/img/a.png") == .subresource(["site", "pages", "img", "a.png"]))
        #expect(map("/%2F/b.png") == .subresource(["site", "b.png"]))
        #expect(map("/c.png") == .subresource(["c.png"]))
        #expect(map("/%2F/%2F/a%20b.png") == .subresource(["site", "pages", "a b.png"]))
        #expect(map("/%2F/%2F/~/t.png") == .subresource(["site", "pages", "~", "t.png"]))
        #expect(map("/%2F/%2F/%252F.png") == .subresource(["site", "pages", "%2F.png"]))
        #expect(map("/%2F/%2F/%252F/e.png") == .subresource(["site", "pages", "%2F", "e.png"]))
        #expect(map("/%2F/%2F/caf%C3%A9.png") == .subresource(["site", "pages", "caf\u{E9}.png"]))
        #expect(map("/index.html") == .subresource(["index.html"]))
        #expect(map("/%2F/index.html") == .subresource(["site", "index.html"]))

        let refused: [String] = [
            "/sub/%2F/x.png",          // a placeholder after a real name
            "/%2F/%2F/%2F/x.png",      // more placeholders than folders
            "/%2F/%2F/..%2Fx.png", "/%2F/%2F/a%2Fb.png", "/%2F/%2F/a%2fb.png",
            "/%2F/%2F/%2e%2e/x.png", "/%2F/%2F/%2E/x.png", "/%2F/%2F/../x.png", "/%2F/%2F/./x.png",
            "/%2F/%2F/x%00.png", "/%2F/%2F/x%0A.png", "/%2F/%2F/x%7F.png", "/%2F/%2F/x%C2%85.png",
            "//x.png", "/%2F//x.png", "/%2F/%2F/img/", "/%2F/%2F/", "/", "",
            "/%2F/%2F/%FF.png", "/%2F/%2F/%C3.png", "/%2F/%2F/%ED%A0%80.png",
            "/%2F/%2F/%zz.png", "/%2F/%2F/x%2.png", "/%2F/%2F/x%",
            "%2F/%2F/x.png",
        ]
        for path in refused {
            guard case .refused = map(path) else {
                Issue.record("\(path) was not refused")
                continue
            }
        }
        #expect(Handler.map(rawPath: "/index.html", ancestors: []) == .page)
        #expect(Handler.map(rawPath: "/%2F/x.png", ancestors: []) != .subresource(["x.png"]))
    }

    @Test func refusesANonLeadingPlaceholderSegment() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try FileManager.default.createDirectory(at: tree.url("site/sub/pages/img"), withIntermediateDirectories: true)
        try RecordingServer.png.write(to: tree.url("site/sub/pages/x.png"))
        try RecordingServer.png.write(to: tree.url("site/sub/x.png"))
        let handler = Handler()
        let page = try begin(handler, tree)
        let task = try await request(handler, page, "/sub/%2F/x.png")
        #expect(task.error != nil)
        #expect(task.response == nil)
        #expect(handler.readLog.isEmpty)
        #expect(Handler.map(rawPath: "/sub/%2F/x.png", ancestors: ["site", "pages"]) == .refused("placeholder out of place"))
    }

    @Test func servesOddButRealNamesAndRefusesTricks() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let handler = Handler()
        let page = try begin(handler, tree)
        for path in ["/%2F/%2F/~/tilde.png", "/%2F/%2F/%252F/encoded.png", "/%2F/%2F/%252F.png",
                     "/%2F/shared/logo.png", "/%2F/%2F/img/a.png?cache=1"] {
            let task = try await request(handler, page, path)
            #expect(task.status == 200, "\(path)")
            #expect(task.body == RecordingServer.png, "\(path)")
        }
        for path in ["/%2F/%2F/..%2Fshared/logo.png", "/%2F/%2F/%2e%2e/shared/logo.png", "/%2F/%2F/img/a.png%00",
                     "/%2F/%2F//img/a.png", "/%2F/%2F/img/", "/%2F/%2F/img/a%FF.png", "/%2F/%2F/none.png",
                     "/%2F/%2F/doc.html", "/outside/a.png"] {
            let task = try await request(handler, page, path)
            #expect(task.error != nil && task.response == nil, "\(path)")
        }
    }

    // MARK: Page

    @Test func servesThePageOnceOnlyAtItsPathAndToken() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let handler = Handler()
        let page = try begin(handler, tree)
        let path = page.path(percentEncoded: true)

        let query = try await request(handler, page, path + "?x=1")
        #expect(query.error != nil)
        let emptyQuery = try await request(handler, page, path + "?")
        #expect(emptyQuery.error != nil)
        let first = try await request(handler, page, path)
        #expect(first.status == 200)
        let second = try await request(handler, page, path)
        #expect(second.error != nil)
        // The document's own file, asked for by name, is an HTML subresource.
        let byName = try await request(handler, page, "/%2F/%2F/doc.html")
        #expect(byName.error != nil)
        #expect(!handler.readLog.contains(["site", "pages", "doc.html"]))

        let stalePage = page
        let fresh = try begin(handler, tree)
        let stale = try await request(handler, stalePage, "/%2F/%2F/img/a.png")
        #expect(stale.error != nil && stale.response == nil)
        let staleMain = try await request(handler, stalePage, path)
        #expect(staleMain.error != nil)
        let current = try await request(handler, fresh, "/%2F/%2F/img/a.png")
        #expect(current.status == 200)
        let wrongCase = try await request(handler, fresh, "/%2F/%2F/img/a.png", host: fresh.host()!.uppercased())
        #expect(wrongCase.error != nil)
    }

    @Test func refusesDocumentsOutsideTheScopeOrTooLarge() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let handler = Handler()
        #expect(throws: Handler.LoadError.outsideScope) {
            try handler.beginLoad(document: Data(), documentURL: tree.document, scopeRoot: tree.url("site/shared"), allowsRemoteContent: false)
        }
        #expect(throws: Handler.LoadError.outsideScope) {
            try handler.beginLoad(document: Data(), documentURL: tree.root, scopeRoot: tree.root, allowsRemoteContent: false)
        }
        #expect(throws: Handler.LoadError.outsideScope) {
            try handler.beginLoad(document: Data(), documentURL: URL(string: "https://example.com/doc.html")!, scopeRoot: tree.root, allowsRemoteContent: false)
        }
        #expect(throws: Handler.LoadError.tooLarge) {
            try handler.beginLoad(document: Data(count: 16 << 20 + 1), documentURL: tree.document, scopeRoot: tree.root, allowsRemoteContent: false)
        }
        #expect(throws: Handler.LoadError.scopeUnavailable) {
            try handler.beginLoad(document: Data(), documentURL: tree.document, scopeRoot: tree.url("missing"), allowsRemoteContent: false)
        }
        _ = try handler.beginLoad(document: Data(count: 16 << 20), documentURL: tree.document, scopeRoot: tree.root, allowsRemoteContent: false)
    }

    @Test func aFailedLoadInvalidatesThePreviousOne() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let handler = Handler()
        let page = try begin(handler, tree)
        _ = try? handler.beginLoad(document: Data(), documentURL: tree.document, scopeRoot: tree.url("site/shared"), allowsRemoteContent: false)
        let task = try await request(handler, page, "/%2F/%2F/img/a.png")
        #expect(task.error != nil)
    }

    // MARK: Types

    @Test func typeTableServesOnlyListedExtensions() async throws {
        let expected: [String: String] = [
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
            "avif": "image/avif", "heic": "image/heic", "heif": "image/heif", "bmp": "image/bmp", "ico": "image/x-icon",
            "svg": "image/svg+xml", "css": "text/css", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf",
            "otf": "font/otf", "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "webm": "video/webm",
            "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "ogg": "audio/ogg",
            "oga": "audio/ogg", "opus": "audio/ogg", "flac": "audio/flac", "vtt": "text/vtt",
        ]
        #expect(Set(ServedFileType.table.keys) == Set(expected.keys))
        for (ext, mime) in expected {
            #expect(ServedFileType.entry(forFileName: "f.\(ext)")?.mimeType == mime, "\(ext)")
            #expect(ServedFileType.entry(forFileName: "f.\(ext.uppercased())")?.mimeType == mime, "\(ext)")
        }
        for name in ["f.js", "f.mjs", "f.html", "f.htm", "f.xhtml", "f.json", "f.xml", "f.pdf", "f.m3u8", "f.m3u",
                     "f.unknown", "png", ".png", "f.", "f.png.js", "f.p\u{0306}ng", "f.\u{FF50}ng", "f.PN\u{212A}"] {
            #expect(ServedFileType.entry(forFileName: name) == nil, "\(name)")
        }

        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let handler = Handler()
        let page = try begin(handler, tree)
        for name in ["x.js", "x.html", "x.json", "x.m3u8", "x.unknown"] {
            let task = try await request(handler, page, "/%2F/%2F/\(name)")
            #expect(task.error != nil && task.response == nil, "\(name)")
        }
        #expect(handler.readLog.isEmpty)
    }

    // MARK: Ranges

    @Test func parsesStrictRanges() {
        #expect(Handler.parseRange("bytes=0-99") == .from(0, through: 99))
        #expect(Handler.parseRange("bytes=5-") == .from(5, through: nil))
        #expect(Handler.parseRange("bytes=-7") == .suffix(7))
        #expect(Handler.parseRange("bytes=999999999999999999-") == .from(999_999_999_999_999_999, through: nil))
        for header in ["bytes=1-2,3-4", "bytes= 1-2", "bytes=1 -2", "bytes=+5-", "bytes=1-+5", "bytes=-", "bytes=",
                       "bytes=1000000000000000000-", "bytes=0-1000000000000000000", "bytes=-\(Int.max)",
                       "bytes=\(Int.max)-", "Bytes=0-1", "items=0-1", "bytes=0x1-2", "bytes=١-2", "bytes=1--2", "bytes=1-2-3"] {
            #expect(Handler.parseRange(header) == nil, "\(header)")
        }
    }

    @Test func resolvesRangesWithinTheFileAndChunk() {
        let chunk: Int64 = 8
        #expect(Handler.resolve(.from(0, through: 3), size: 20, chunk: chunk) == 0...3)
        #expect(Handler.resolve(.from(0, through: nil), size: 20, chunk: chunk) == 0...7)
        #expect(Handler.resolve(.from(15, through: 100), size: 20, chunk: chunk) == 15...19)
        #expect(Handler.resolve(.from(19, through: 19), size: 20, chunk: chunk) == 19...19)
        #expect(Handler.resolve(.suffix(5), size: 20, chunk: chunk) == 15...19)
        #expect(Handler.resolve(.suffix(10), size: 20, chunk: chunk) == 10...17)
        #expect(Handler.resolve(.suffix(25), size: 6, chunk: chunk) == 0...5)
        #expect(Handler.resolve(.suffix(0), size: 20, chunk: chunk) == nil)
        #expect(Handler.resolve(.from(20, through: nil), size: 20, chunk: chunk) == nil)
        #expect(Handler.resolve(.from(5, through: 4), size: 20, chunk: chunk) == nil)
        #expect(Handler.resolve(.from(0, through: nil), size: 0, chunk: chunk) == nil)
        #expect(Handler.resolve(.from(999_999_999_999_999_998, through: 999_999_999_999_999_999), size: Int64.max, chunk: chunk)
            == 999_999_999_999_999_998...999_999_999_999_999_999)
        #expect(Handler.resolve(.from(0, through: nil), size: Int64.max, chunk: Int64.max) == 0...(Int64.max - 1))
    }

    private func writeMedia(_ tree: Tree, name: String, size: Int) throws -> Data {
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: size, by: 4096) { buffer[index] = UInt8(truncatingIfNeeded: index / 4096) }
        }
        try bytes.write(to: tree.url("site/pages/\(name)"))
        return bytes
    }

    @Test func servesMediaInRanges() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let media = try writeMedia(tree, name: "v.mp4", size: 20 << 20)
        let handler = Handler()
        let page = try begin(handler, tree)
        let size = media.count

        let cases: [(String, Int, Int)] = [
            ("bytes=0-99", 0, 99), ("bytes=100-", 100, 100 + (8 << 20) - 1), ("bytes=-50", size - 50, size - 1),
            ("bytes=0-", 0, (8 << 20) - 1), ("bytes=\(size - 1)-", size - 1, size - 1),
        ]
        for (range, start, end) in cases {
            let task = try await request(handler, page, "/%2F/%2F/v.mp4", range: range)
            #expect(task.status == 206, "\(range)")
            #expect(task.header("Content-Range") == "bytes \(start)-\(end)/\(size)", "\(range)")
            #expect(task.header("Accept-Ranges") == "bytes")
            #expect(task.header("Content-Type") == "video/mp4")
            #expect(task.body == media[start...end], "\(range)")
            #expect(task.body.count <= 8 << 20)
            expectCommonHeaders(task, range)
        }

        for range in ["bytes=-0", "bytes=\(size)-", "bytes=\(size + 5)-", "bytes=9-8", "bytes= 0-1", "bytes=+5-",
                      "bytes=0-1,2-3", "bytes=1234567890123456789-", "bytes=\(Int.max)-", "bytes=-\(Int.max)"] {
            let task = try await request(handler, page, "/%2F/%2F/v.mp4", range: range)
            #expect(task.status == 416, "\(range)")
            #expect(task.header("Content-Range") == "bytes */\(size)", "\(range)")
            #expect(task.body.isEmpty)
            expectCommonHeaders(task, range)
        }

        let whole = try await request(handler, page, "/%2F/%2F/v.mp4")
        #expect(whole.error != nil && whole.response == nil)
    }

    @Test func servesWholeMediaOnlyUpToOneChunk() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let exact = try writeMedia(tree, name: "exact.mp3", size: 8 << 20)
        _ = try writeMedia(tree, name: "over.mp3", size: (8 << 20) + 1)
        let handler = Handler()
        let page = try begin(handler, tree)
        let ok = try await request(handler, page, "/%2F/%2F/exact.mp3")
        #expect(ok.status == 200)
        #expect(ok.body == exact)
        let over = try await request(handler, page, "/%2F/%2F/over.mp3")
        #expect(over.error != nil && over.response == nil)
        // Non-media files ignore Range and are sent whole.
        let image = try await request(handler, page, "/%2F/%2F/img/a.png", range: "bytes=0-1")
        #expect(image.status == 200)
        #expect(image.body == RecordingServer.png)
    }

    @Test func refusesFilesOverTheirCap() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try Data(count: 11).write(to: tree.url("site/pages/big.png"))
        try Data(count: 11).write(to: tree.url("site/pages/big.webm"))
        var limits = Handler.Limits()
        limits.fileBytes = 10
        limits.mediaFileBytes = 10
        let handler = Handler(limits: limits)
        let page = try begin(handler, tree)
        let image = try await request(handler, page, "/%2F/%2F/big.png")
        #expect(image.error != nil)
        let media = try await request(handler, page, "/%2F/%2F/big.webm", range: "bytes=0-1")
        #expect(media.error != nil && media.response == nil)
        #expect(handler.requestLog.suffix(2).map(\.outcome) == [.failed(.tooLarge), .failed(.tooLarge)])
    }

    // MARK: Limits

    @Test func refusesRequestsPastTheRequestBudget() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        var limits = Handler.Limits()
        limits.requestsPerLoad = 3
        let handler = Handler(limits: limits)
        let page = try begin(handler, tree)
        _ = try await request(handler, page, page.path(percentEncoded: true)) // the page isn't counted
        _ = try await request(handler, page, "/%2F/%2F/x.js")                  // refused ones are
        for _ in 0..<2 {
            #expect(try await request(handler, page, "/%2F/%2F/img/a.png").status == 200)
        }
        let past = try await request(handler, page, "/%2F/%2F/img/a.png")
        #expect(past.error != nil && past.response == nil)
        #expect(handler.readLog.count == 2)
        // A new load gets a new budget.
        let fresh = try begin(handler, tree)
        #expect(try await request(handler, fresh, "/%2F/%2F/img/a.png").status == 200)
    }

    @Test func refusesBytesPastTheByteBudget() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let size = RecordingServer.png.count
        var limits = Handler.Limits()
        limits.bytesPerLoad = Int64(size * 2 + 1)
        let handler = Handler(limits: limits)
        let page = try begin(handler, tree)
        #expect(try await request(handler, page, "/%2F/%2F/img/a.png").status == 200)
        #expect(try await request(handler, page, "/%2F/%2F/img/a.png").status == 200)
        let past = try await request(handler, page, "/%2F/%2F/img/a.png")
        #expect(past.error != nil && past.response == nil)
        #expect(handler.requestLog.last?.outcome == .refused("byte budget"))
        // Once the budget is used up, requests fail before any read.
        limits.bytesPerLoad = Int64(size)
        let exact = Handler(limits: limits)
        let page2 = try begin(exact, tree)
        #expect(try await request(exact, page2, "/%2F/%2F/img/a.png").status == 200)
        let after = try await request(exact, page2, "/%2F/%2F/img/a.png")
        #expect(after.error != nil)
        #expect(exact.readLog.count == 1)
    }

    @Test func refusesRequestsPastTheQueueAndNeverAnswersStoppedOnes() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        var limits = Handler.Limits()
        limits.concurrentReads = 1
        limits.queuedReads = 1
        let handler = Handler(limits: limits)
        let page = try begin(handler, tree)
        func task(_ path: String) -> FakeSchemeTask {
            FakeSchemeTask(url: URL(string: "\(Handler.scheme)://\(page.host()!)\(path)")!)
        }
        let running = task("/%2F/%2F/img/a.png")
        let queued = task("/%2F/shared/logo.png")
        let overflow = task("/%2F/%2F/~/tilde.png")
        // All three start in one main-actor turn, so the first read can't finish in between.
        handler.webView(webView, start: running)
        handler.webView(webView, start: queued)
        handler.webView(webView, start: overflow)
        #expect(overflow.error != nil && overflow.response == nil)
        handler.webView(webView, stop: queued)
        try await waitUntil(timeout: .seconds(5)) { running.done }
        #expect(running.status == 200)

        // Stopping the running read: it is never answered either.
        let stoppedWhileReading = task("/%2F/%2F/img/a.png")
        handler.webView(webView, start: stoppedWhileReading)
        handler.webView(webView, stop: stoppedWhileReading)
        let after = task("/%2F/%2F/%252F.png")
        handler.webView(webView, start: after)
        try await waitUntil(timeout: .seconds(5)) { after.done }
        try await Task.sleep(for: .milliseconds(200))
        #expect(after.status == 200)

        #expect(queued.callbacks == 0)
        #expect(stoppedWhileReading.callbacks == 0)
        #expect(handler.readLog == [["site", "pages", "img", "a.png"], ["site", "pages", "img", "a.png"], ["site", "pages", "%2F.png"]])
    }

    // MARK: WebKit resolution

    /// WebKit must keep the raw `%2F` segments when it resolves relative references, so each
    /// one still stands for a real folder when the request arrives.
    @Test func webKitKeepsPlaceholdersWhenResolvingReferences() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try Data("#b{background:url(../../shared/logo.png)} #c{background:url(img/a.png)}".utf8)
            .write(to: tree.url("site/pages/img/s.css"))
        let html = """
        <!doctype html><link rel=stylesheet href="img/s.css"><div id=b>b</div><div id=c>c</div>
        <img src="img/a.png"><img src="../shared/logo.png"><img src="../../shared/logo.png"><img src="/shared/logo.png">
        <img src="./~/tilde.png"><img src="%252F.png"><img src="x/../%252F/encoded.png"><img src="%2F/nope.png">
        """
        let handler = Handler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: Handler.scheme)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: configuration)
        let page = try begin(handler, tree, document: html)
        let navigation = TestNavigationDelegate()
        try await navigation.load(URLRequest(url: page), in: view)
        let expected: Set<[String]> = [
            ["site", "pages", "img", "s.css"], ["site", "pages", "img", "a.png"], ["site", "shared", "logo.png"],
            ["site", "pages", "~", "tilde.png"], ["site", "pages", "%2F.png"], ["site", "pages", "%2F", "encoded.png"],
        ]
        func served() -> Set<[String]> {
            Set(handler.requestLog.compactMap { entry -> [String]? in
                if case .served = entry.outcome { return entry.components }
                return nil
            })
        }
        try await waitUntil(timeout: .seconds(5)) { served() == expected }
        #expect(served() == expected)
        // `/shared/logo.png` and `../../shared/logo.png` resolve to the scope root, which has no `shared`.
        #expect(handler.requestLog.contains { $0.components == ["shared", "logo.png"] && $0.outcome == .failed(.notFound) })
        // `%2F/nope.png` adds a third placeholder at depth two: refused before any read.
        #expect(handler.requestLog.contains { $0.outcome == .refused("placeholder out of place") })
    }
}
#endif
