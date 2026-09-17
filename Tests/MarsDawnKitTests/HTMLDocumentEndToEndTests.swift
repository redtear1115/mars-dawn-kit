#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// The HTML serving core end to end: `PreviewWKWebView` + `HTMLDocumentSchemeHandler` +
/// `HTMLContentRules`, JavaScript off, a non-persistent store, no message handlers, and a
/// navigation delegate that cancels everything but the page load.
///
/// Pages are fed without `HTMLDocumentText` preparation, so the `<link>`/`<iframe>` vectors
/// exercise the CSP and the rule lists rather than the rename. Observations come from the
/// handler's request log, a second logging scheme (`h1-other:`) and local listeners.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct HTMLDocumentEndToEndTests {
    typealias Handler = HTMLDocumentSchemeHandler

    @MainActor
    struct Harness {
        let root: URL
        let handler: Handler
        let other: RecordingSchemeHandler
        let webView: PreviewWKWebView
        let navigation: TestNavigationDelegate
        let pageURL: URL
        let window: NSWindow

        func served() -> Set<[String]> {
            Set(handler.requestLog.compactMap { entry -> [String]? in
                if case .served = entry.outcome { return entry.components }
                return nil
            })
        }

        func remove() {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Writes `files` below a fresh root (`site/pages/index.html` is the document) and loads `html`.
    private func load(
        html: String,
        files: [String: Data] = [:],
        remote: Bool = false,
        javaScript: Bool = false,
        trusting certificate: SecCertificate? = nil,
        prepare: (URL) throws -> Void = { _ in }
    ) async throws -> Harness {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("html-e2e-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("site/pages"), withIntermediateDirectories: true)
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try prepare(root)

        let handler = Handler()
        let other = RecordingSchemeHandler()
        other.resources["/i.png"] = .init(headers: ["Content-Type": "image/png"], body: RecordingServer.png)
        other.resources["/s.css"] = .init(headers: ["Content-Type": "text/css"], body: Data("p{}".utf8))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScript
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.setURLSchemeHandler(handler, forURLScheme: Handler.scheme)
        configuration.setURLSchemeHandler(other, forURLScheme: "h1-other")
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = Self.host(webView)
        webView.applyContentRuleList(try await HTMLContentRules.ruleList(allowsRemoteContent: remote))

        let pageURL = try handler.beginLoad(
            document: Data(html.utf8),
            documentURL: root.appendingPathComponent("site/pages/index.html"),
            scopeRoot: root,
            allowsRemoteContent: remote
        )
        let navigation = TestNavigationDelegate()
        navigation.trustedCertificate = certificate
        var allowed = false
        navigation.policy = { action in
            guard !allowed, action.targetFrame?.isMainFrame == true, action.request.url == pageURL else { return false }
            allowed = true
            return true
        }
        try await navigation.load(URLRequest(url: pageURL), in: webView)
        return Harness(root: root, handler: handler, other: other, webView: webView, navigation: navigation, pageURL: pageURL, window: window)
    }

    /// Puts `webView` in an on-screen but unobtrusive window: WebKit defers media loading for
    /// web views that aren't visible.
    static func host(_ webView: WKWebView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderFrontRegardless()
        return window
    }

    // MARK: 1. Serving

    @Test func servesOnlyAllowedFilesInsideTheScope() async throws {
        let png = RecordingServer.png
        let font = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf"))
        let css = Data("@font-face{font-family:e2e;src:url(../fonts/f.ttf)} p{font-family:e2e;background:url(../../shared/bg.png)}".utf8)
        let files: [String: Data] = [
            "site/pages/img/a.png": png, "site/pages/css/s.css": css, "site/pages/fonts/f.ttf": font,
            "site/shared/bg.png": png, "site/up.png": png,
            "site/pages/x.js": Data("x".utf8), "site/pages/x.html": Data("x".utf8),
            "site/pages/x.json": Data("{}".utf8), "site/pages/x.m3u8": Data("x".utf8),
            "site/pages/img/real.png": png,
        ]
        let html = """
        <!doctype html><html><head><link rel=stylesheet href="css/s.css"></head><body><p>text</p>
        <img src="img/a.png"><img src="../up.png">
        <img src="x.js"><img src="x.html"><img src="x.json"><img src="x.m3u8"><img src="index.html">
        <img src="img/link.png"><img src="linkdir/real.png">
        <img src="..%2Fup.png"><img src="%2e%2e/%2e%2e/%2e%2e/%2e%2e/outside.png"><img src="img/a.png%00">
        <img src="img//a.png"><img src="img/"><video src="img/"></video>
        </body></html>
        """
        let harness = try await load(html: html, files: files) { root in
            let fm = FileManager.default
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("site/pages/img/link.png").path, withDestinationPath: "a.png")
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("site/pages/linkdir").path, withDestinationPath: "img")
        }
        defer { harness.remove() }
        let expected: Set<[String]> = [
            ["site", "pages", "css", "s.css"], ["site", "pages", "img", "a.png"], ["site", "up.png"],
            ["site", "pages", "fonts", "f.ttf"], ["site", "shared", "bg.png"],
        ]
        try await waitUntil(timeout: .seconds(5)) { harness.served() == expected }
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.served() == expected)

        let url = harness.pageURL.absoluteString
        #expect(url.hasSuffix("/%2F/%2F/index.html"))
        for name in ["site", "pages", harness.root.lastPathComponent] { #expect(!url.contains(name)) }

        let log = harness.handler.requestLog
        #expect(log.filter { $0.outcome == .page }.count == 1)
        // The page's own URL, requested again, is refused: it is served once per token.
        #expect(log.contains { $0.outcome == .refused("page already served") })
        for name in ["x.js", "x.html", "x.json", "x.m3u8"] {
            #expect(log.contains { $0.components?.last == name && $0.outcome == .refused("type") }, "\(name)")
        }
        #expect(log.contains { $0.components == ["site", "pages", "img", "link.png"] && $0.outcome == .failed(.notAllowed) })
        #expect(log.contains { $0.components == ["site", "pages", "linkdir", "real.png"] && $0.outcome == .failed(.notAllowed) })
        // `..` above the root collapses at the token host: the request stays inside the scope.
        #expect(log.contains { $0.components == ["outside.png"] && $0.outcome == .failed(.notFound) })
        #expect(log.filter { $0.outcome == .refused("invalid segment") || $0.outcome == .refused("empty segment") }.count >= 3)
        #expect(!harness.handler.readLog.contains { $0.last == "x.js" || $0.last == "index.html" })
    }

    // MARK: 2. Blocked state

    enum Vector: String, CaseIterable, Sendable {
        case httpImage, httpsImage, preconnect, srcdocPreconnect, svgUse, dnsPrefetchLink, cssBackground,
             fontFace, video, ping, form, metaRefresh

        /// Markup that would reach `base` (`http://127.0.0.1:port`) without the protections.
        func markup(_ base: String) -> String {
            let secure = base.replacingOccurrences(of: "http:", with: "https:")
            switch self {
            case .httpImage: return "<img src=\"\(base)/img.png\">"
            case .httpsImage: return "<img src=\"\(secure)/img.png\">"
            case .preconnect: return "<link rel=preconnect href=\"\(base)/\">"
            case .srcdocPreconnect: return "<iframe srcdoc=\"&lt;link rel=preconnect href=&quot;\(base)/&quot;&gt;\"></iframe>"
            case .svgUse: return "<svg><use href=\"\(base)/x.svg#a\"/></svg>"
            case .dnsPrefetchLink: return "<meta http-equiv=x-dns-prefetch-control content=on><a href=\"\(base)/page\">link</a>"
            case .cssBackground: return "<div style=\"width:10px;height:10px;background:url(\(base)/bg.png)\"></div>"
            case .fontFace: return "<style>@font-face{font-family:remote;src:url(\(base)/f.woff2)} .r{font-family:remote}</style><p class=r>x</p>"
            case .video: return "<video src=\"\(base)/v.mp4\" preload=auto></video>"
            case .ping: return "<a href=\"x.html\" ping=\"\(base)/ping\">ping</a>"
            case .form: return "<form action=\"\(base)/form\" method=post><input name=a value=b></form><script>document.forms[0].submit()</script>"
            case .metaRefresh: return "<meta http-equiv=refresh content=\"0;url=\(base)/refresh\">"
            }
        }

        /// Whether a plain web view with no protections connects (the control).
        var connectsWithoutProtection: Bool {
            switch self {
            // Recorded on macOS 26.6: an external `<use>` never connects (WebKit only follows
            // same-origin ones), and ping, form, meta refresh and DNS prefetch make no connection
            // here without a click, a navigation or a host name.
            case .httpImage, .preconnect, .srcdocPreconnect, .cssBackground, .fontFace, .video: true
            default: false
            }
        }
    }

    private static let window: Duration = .seconds(3)

    @Test func blockedStateMakesNoConnections() async throws {
        var servers: [Vector: RecordingServer] = [:]
        for vector in Vector.allCases { servers[vector] = try await RecordingServer.start() }
        defer { servers.values.forEach { $0.stop() } }
        let body = Vector.allCases.map { $0.markup("http://127.0.0.1:\(servers[$0]!.port)") }.joined(separator: "\n")
        let csponly = "<img src=\"h1-other://x/i.png\"><link rel=stylesheet href=\"h1-other://x/s.css\">"
        let harness = try await load(html: "<!doctype html><html><head>\(csponly)</head><body>\(body)</body></html>")
        defer { harness.remove() }
        try await Task.sleep(for: Self.window)
        for vector in Vector.allCases {
            #expect(servers[vector]!.accepts == 0, "\(vector) connected")
        }
        // CSP-only vectors: the rule lists don't cover custom schemes.
        #expect(harness.other.requests.isEmpty, "h1-other saw \(harness.other.paths)")
        // Meta refresh was cancelled, not followed.
        #expect(harness.webView.url == harness.pageURL)
    }

    /// Control: the same vectors connect in a plain web view without CSP or rule lists.
    @Test func withoutProtectionTheVectorsConnect() async throws {
        var servers: [Vector: RecordingServer] = [:]
        for vector in Vector.allCases { servers[vector] = try await RecordingServer.start() }
        defer { servers.values.forEach { $0.stop() } }
        let body = Vector.allCases.map { $0.markup("http://127.0.0.1:\(servers[$0]!.port)") }.joined(separator: "\n")
        let csponly = "<img src=\"h1-other://x/i.png\"><link rel=stylesheet href=\"h1-other://x/s.css\">"
        let page = RecordingSchemeHandler()
        page.resources["/index.html"] = .init(headers: ["Content-Type": "text/html"],
                                              body: Data("<!doctype html><html><head>\(csponly)</head><body>\(body)</body></html>".utf8))
        let other = RecordingSchemeHandler()
        other.resources["/i.png"] = .init(headers: ["Content-Type": "image/png"], body: RecordingServer.png)
        other.resources["/s.css"] = .init(headers: ["Content-Type": "text/css"], body: Data("p{}".utf8))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Script on here only, so the control shows each vector at its most capable.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(page, forURLScheme: "h1-page")
        configuration.setURLSchemeHandler(other, forURLScheme: "h1-other")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = Self.host(webView)
        defer { window.orderOut(nil) }
        let navigation = TestNavigationDelegate()
        navigation.policy = { action in
            print("H1e-record control navigation: \(action.request.url?.absoluteString ?? "nil") main=\(action.targetFrame?.isMainFrame ?? false)")
            return action.request.url?.scheme == "h1-page" || action.request.url?.scheme == "about"
        }
        try await navigation.load(URLRequest(url: URL(string: "h1-page://x/index.html")!), in: webView)
        let deadline = ContinuousClock.now + Self.window
        while ContinuousClock.now < deadline,
              !Vector.allCases.filter(\.connectsWithoutProtection).allSatisfy({ servers[$0]!.accepts > 0 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        for vector in Vector.allCases {
            print("H1e-record control \(vector): accepts=\(servers[vector]!.accepts) paths=\(servers[vector]!.paths)")
        }
        for vector in Vector.allCases where vector.connectsWithoutProtection {
            #expect(servers[vector]!.accepts > 0, "\(vector) didn't connect even without protection")
        }
        #expect(Set(other.paths) == ["/i.png", "/s.css"])
    }

    // MARK: 3. Remote-allowed state

    @Test func remoteStateLoadsOnlyImagesStylesFontsAndMedia() async throws {
        guard #available(macOS 26, *) else {
            Issue.record("Needs macOS 26 (in-memory TLS identity)")
            return
        }
        let tls = try TestTLSIdentity.make()
        let allowed = try await RecordingServer.start(identity: tls.identity) { request in
            switch request.path {
            case "/style.css":
                return .init(contentType: "text/css", body: Data("@import url(/imported.css); p{color:red}".utf8))
            case "/imported.css":
                return .init(contentType: "text/css", body: Data("p{margin:1px}".utf8))
            default:
                return .init(contentType: "image/png", body: RecordingServer.png)
            }
        }
        defer { allowed.stop() }
        let forbiddenNames = ["preconnect", "srcdoc", "svgUse", "preloadFetch", "prefetch", "ping", "plainHTTPImage"]
        var forbidden: [String: RecordingServer] = [:]
        for name in forbiddenNames { forbidden[name] = try await RecordingServer.start(identity: tls.identity) }
        defer { forbidden.values.forEach { $0.stop() } }
        let plain = try await RecordingServer.start()
        defer { plain.stop() }

        let base = "https://127.0.0.1:\(allowed.port)"
        func url(_ name: String) -> String { "https://127.0.0.1:\(forbidden[name]!.port)" }
        let html = """
        <!doctype html><html><head>
        <link rel=stylesheet href="\(base)/style.css">
        <link rel=preconnect href="\(url("preconnect"))/">
        <link rel=preload as=fetch crossorigin href="\(url("preloadFetch"))/fetch">
        <link rel=prefetch href="\(url("prefetch"))/next">
        <style>@font-face{font-family:remote;src:url(\(base)/font.woff2)} .r{font-family:remote}</style>
        </head><body><p class=r>text</p>
        <img src="\(base)/img.png">
        <video src="\(base)/video.mp4" preload=auto></video>
        <iframe srcdoc="&lt;link rel=preconnect href=&quot;\(url("srcdoc"))/&quot;&gt;"></iframe>
        <svg><use href="\(url("svgUse"))/x.svg#a"/></svg>
        <a href="x.html" ping="\(url("ping"))/ping">ping</a>
        <img src="http://127.0.0.1:\(plain.port)/plain.png">
        </body></html>
        """
        let harness = try await load(html: html, remote: true, trusting: tls.certificate)
        defer { harness.remove() }
        let expected: Set<String> = ["/style.css", "/imported.css", "/font.woff2", "/img.png", "/video.mp4"]
        try await waitUntil(timeout: .seconds(8)) { expected.isSubset(of: Set(allowed.paths)) }
        try await Task.sleep(for: Self.window)
        print("H1e-record remote allowed paths: \(allowed.paths); plain http accepts=\(plain.accepts) paths=\(plain.paths)")
        #expect(expected.isSubset(of: Set(allowed.paths)), "arrived: \(allowed.paths)")
        #expect(Set(allowed.paths).subtracting(expected).isEmpty, "unexpected: \(allowed.paths)")
        for name in forbiddenNames {
            #expect(forbidden[name]!.accepts == 0, "\(name) connected")
        }
        if Handler.upgradesInsecureRequests {
            // Upgraded to https on the plain listener: a TLS handshake arrives, no HTTP request.
            #expect(plain.accepts > 0)
            #expect(plain.paths.isEmpty)
        } else {
            #expect(plain.accepts == 0, "plain http image connected")
        }
        #expect(harness.other.requests.isEmpty)
    }

    // MARK: 4. Media

    /// Recorded on macOS 26.6 under `swift test`: WebKit never decodes a frame here
    /// (`totalVideoFrames` stays 0), and `currentTime` advances even for a copy truncated to
    /// 3 MB, so `currentTime > 0` alone doesn't show media data was served. The fixture's
    /// movie header sits past the first 8 MB, so a known duration and frame size show the
    /// player reached it through ranged responses. Frame delivery needs the app (H2).
    @Test func playsMediaServedInRanges() async throws {
        let movie = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("e2e-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await HTMLMediaFixture.writeNoiseMovie(to: movie, minimumBytes: 20 << 20)
        let bytes = try Data(contentsOf: movie)
        let moov = try #require(HTMLMediaFixture.topLevelBoxes(in: bytes).first { $0.type == "moov" })
        #expect(moov.offset > 8 << 20)
        let harness = try await load(
            html: "<!doctype html><video id=v src=\"media/v.mp4\" muted playsinline preload=auto></video>",
            javaScript: true
        ) { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("site/pages/media"), withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("site/pages/media/v.mp4"))
        }
        defer { harness.remove() }
        // Not awaited: play() may never settle, and an await here can't be cancelled.
        _ = try await harness.webView.evaluateJavaScript("document.getElementById('v').play(); 0")
        var time = 0.0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, time <= 0.5 {
            try await Task.sleep(for: .milliseconds(200))
            time = try await harness.webView.evaluateJavaScript("document.getElementById('v').currentTime") as? Double ?? 0
        }
        let state = try await harness.webView.evaluateJavaScript("""
            (() => { const v = document.getElementById('v'); const q = v.getVideoPlaybackQuality();
              return JSON.stringify({duration: v.duration, width: v.videoWidth, error: v.error ? v.error.code : 0, frames: q.totalVideoFrames}); })()
            """) as? String ?? "{}"
        let info = try JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any] ?? [:]
        let media = harness.handler.requestLog.filter { $0.components?.last == "v.mp4" }
        print("H1e-record media size=\(bytes.count) moov=\(moov.offset) currentTime=\(time) state=\(state) responses=\(media.count)")
        #expect(time > 0)
        #expect(info["duration"] as? Double == 10)
        #expect(info["width"] as? Int == 1280)
        #expect(info["error"] as? Int == 0)
        #expect(!media.isEmpty)
        for entry in media {
            guard case .served(let status, let size) = entry.outcome else {
                Issue.record("unexpected media outcome \(entry.outcome)")
                continue
            }
            #expect(status == 206)
            #expect(size <= 8 << 20)
        }
        #expect(bytes.count >= 20 << 20)
    }

    // MARK: 5. Session swap

    @Test func requestsWithAnOldTokenFailAfterANewLoad() async throws {
        let harness = try await load(
            html: "<!doctype html><img id=a src=\"img/a.png\">",
            files: ["site/pages/img/a.png": RecordingServer.png, "site/pages/img/b.png": RecordingServer.png]
        )
        defer { harness.remove() }
        try await waitUntil(timeout: .seconds(5)) { harness.served().contains(["site", "pages", "img", "a.png"]) }
        let before = harness.handler.requestLog.count
        _ = try harness.handler.beginLoad(
            document: Data("<p>new</p>".utf8),
            documentURL: harness.root.appendingPathComponent("site/pages/index.html"),
            scopeRoot: harness.root,
            allowsRemoteContent: false
        )
        // App script, not page script: JavaScript is off for the page.
        _ = try await harness.webView.evaluateJavaScript(
            "const i = document.createElement('img'); i.src = 'img/b.png'; document.body.append(i); 0"
        )
        try await waitUntil(timeout: .seconds(5)) { harness.handler.requestLog.count > before }
        #expect(harness.handler.requestLog.dropFirst(before).map(\.outcome) == [.refused("unknown load")])
        #expect(!harness.served().contains(["site", "pages", "img", "b.png"]))
    }
}
#endif
