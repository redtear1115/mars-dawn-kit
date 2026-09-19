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

        // Only a debug build records what was served, so this reads it only there; every
        // caller is guarded to match.
        #if DEBUG
        // Only a debug build records what was served, so this reads it only there; every
        // caller is guarded to match.
        #if DEBUG
        func served() -> Set<[String]> {
            Set(handler.requestLog.compactMap { entry -> [String]? in
                if case .served = entry.outcome { return entry.components }
                return nil
            })
        }
        #endif
        #endif

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
        webView.applyContentRuleList(try await HTMLContentRules.ruleList(for: remote ? .running : .blocked))

        let pageURL = try handler.beginLoad(
            document: Data(html.utf8),
            documentURL: root.appendingPathComponent("site/pages/index.html"),
            scopeRoot: root,
            policy: remote ? .running : .blocked
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

    // Debug-only in full, not for what it asserts but for what it waits for: the waits
    // below are on the handler's debug-only log, and a test that runs without its
    // waits is worse than one that doesn't run.
    #if DEBUG
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
        // The handler records this only in a debug build, so these assertions compile away
        // in release rather than failing there. What they observe is bookkeeping; the
        // behaviour behind it is asserted alongside and still runs in both configurations.
        #if DEBUG
        #expect(harness.served() == expected)
        #endif

        let url = harness.pageURL.absoluteString
        #expect(url.hasSuffix("/%2F/%2F/index.html"))
        for name in ["site", "pages", harness.root.lastPathComponent] { #expect(!url.contains(name)) }

        // The handler records this only in a debug build, so these assertions compile away
        // in release rather than failing there. What they observe is bookkeeping; the
        // behaviour behind it is asserted alongside and still runs in both configurations.
        #if DEBUG
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
        #endif
    }
    #endif

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

    /// `TestTLSIdentity` builds its identity in memory, which needs macOS 26. On an older
    /// system the test is skipped rather than failed: it has nothing to say there, and a
    /// failure would claim something is broken that nobody broke. See mars-dawn-kit#35.
    @Test(.enabled(if: TestTLS.isAvailable))
    func remoteStateLoadsOnlyImagesStylesFontsAndMedia() async throws {
        // The trait is checked before this runs, so reaching here means an identity can be made.
        guard #available(macOS 26, *) else { return }
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
        // MarsDawn supports https only. The `plain` listener is HTTP, and `<img src=http://…>`
        // must not reach it in any form: not as an HTTP request, and not as the TLS handshake
        // `upgrade-insecure-requests` would have sent instead. The same markup does connect when
        // nothing protects it: `withoutProtectionTheVectorsConnect` records its `httpImage`
        // vector reaching a plain listener.
        #expect(plain.accepts == 0, "plain http image connected")
        #expect(plain.paths.isEmpty)
        #expect(!Handler.upgradesInsecureRequests)
        #expect(harness.other.requests.isEmpty)
    }

    // MARK: 3b. What a running document can reach (A4-3)

    /// `connect-src https:` and the running rule list have to agree about `fetch()`, or one of
    /// them is a grant that never works. WebKit's dialect accepts both `raw` and `fetch` as
    /// resource-type names and doesn't document which a `fetch()` is classified under, so this
    /// measures it: the lift names `fetch` only, because naming `raw` as well also lifted
    /// `<link rel=preconnect>` and `<link rel=preload as=fetch>` — the very reach the rule list
    /// exists to stop, and which no CSP directive can.
    ///
    /// Both halves matter. Without the positive one, this passes when nothing ran at all.
    /// Needs macOS 26 for `TestTLSIdentity`'s in-memory identity; skipped rather than failed on
    /// an older system, the same as the other TLS tests since mars-dawn-kit#35.
    @Test(.enabled(if: TestTLS.isAvailable))
    func aRunningDocumentCanFetchOverHTTPSButNotPreconnect() async throws {
        // The trait is checked before this runs, so reaching here means an identity can be made.
        guard #available(macOS 26, *) else { return }
        let tls = try TestTLSIdentity.make()
        let target = try await RecordingServer.start(identity: tls.identity)
        defer { target.stop() }
        let preconnect = try await RecordingServer.start(identity: tls.identity)
        defer { preconnect.stop() }

        let html = """
        <!doctype html><html><head>
        <link rel=preconnect href="https://127.0.0.1:\(preconnect.port)/">
        </head><body><script>
        fetch("https://127.0.0.1:\(target.port)/beacon?sent=1").catch(() => {});
        </script></body></html>
        """
        let harness = try await load(html: html, remote: true, javaScript: true, trusting: tls.certificate)
        defer { harness.remove() }
        try await waitUntil(timeout: .seconds(8)) { !target.paths.isEmpty }
        try await Task.sleep(for: Self.window)
        print("A4-3-record running fetch paths=\(target.paths) preconnect accepts=\(preconnect.accepts)")
        #expect(target.paths.contains("/beacon?sent=1"), "arrived: \(target.paths)")
        #expect(preconnect.accepts == 0, "preconnect connected while running")
    }

    /// And the same page, not running, reaches neither.
    /// Needs macOS 26 for `TestTLSIdentity`'s in-memory identity; skipped rather than failed on
    /// an older system, the same as the other TLS tests since mars-dawn-kit#35.
    @Test(.enabled(if: TestTLS.isAvailable))
    func aStaticDocumentFetchesNothing() async throws {
        // The trait is checked before this runs, so reaching here means an identity can be made.
        guard #available(macOS 26, *) else { return }
        let tls = try TestTLSIdentity.make()
        let target = try await RecordingServer.start(identity: tls.identity)
        defer { target.stop() }
        let html = """
        <!doctype html><html><body><script>
        fetch("https://127.0.0.1:\(target.port)/beacon?sent=1").catch(() => {});
        </script></body></html>
        """
        let harness = try await load(html: html, remote: false, javaScript: true, trusting: tls.certificate)
        defer { harness.remove() }
        try await Task.sleep(for: .seconds(2))
        #expect(target.accepts == 0, "a static document reached the network: \(target.paths)")
    }

    // MARK: 4. Media

    /// Ranged serving, observed through this handler rather than through `evaluateJavaScript`.
    ///
    /// The page's CSP now carries `sandbox` (A4-3, D-2), and an opaque origin refuses app-injected
    /// script as well as the page's own — "Cannot execute JavaScript in this document". That is the
    /// trade P3-9 recorded and the plan chose deliberately: fix the test, not the policy. So the
    /// page reports what it found by *requesting* a path that encodes it, and the request log is
    /// the instrument. It is a better measurement anyway: it watches what the page did to the
    /// outside world instead of asking the page about itself.
    ///
    /// The fixture's movie header sits past the first 8 MB, so a known duration and frame size
    /// show the player reached it through ranged responses. The old `currentTime > 0` assertion is
    /// gone: this test's own note recorded that `currentTime` advances even for a truncated copy,
    /// so it never showed that media data was served.
    @Test func playsMediaServedInRanges() async throws {
        let movie = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("e2e-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await HTMLMediaFixture.writeNoiseMovie(to: movie, minimumBytes: 20 << 20)
        let bytes = try Data(contentsOf: movie)
        let moov = try #require(HTMLMediaFixture.topLevelBoxes(in: bytes).first { $0.type == "moov" })
        #expect(moov.offset > 8 << 20)
        let html = """
        <!doctype html><html><body>
        <video id=v src="media/v.mp4" muted playsinline preload=auto></video>
        <script>
        const v = document.getElementById('v');
        function report() {
          const i = new Image();
          i.src = 'probe/d-' + Math.round(v.duration) + '-w-' + v.videoWidth + '-e-' + (v.error ? v.error.code : 0) + '.png';
          document.body.append(i);
        }
        v.addEventListener('loadedmetadata', report);
        v.addEventListener('error', report);
        </script></body></html>
        """
        let harness = try await load(html: html, remote: true, javaScript: true) { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("site/pages/media"), withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("site/pages/media/v.mp4"))
        }
        defer { harness.remove() }

        try await waitUntil(timeout: .seconds(20)) {
            harness.handler.requestLog.contains { ($0.components?.last ?? "").hasPrefix("d-") }
        }
        let probe = try #require(harness.handler.requestLog.compactMap { $0.components?.last }.first { $0.hasPrefix("d-") })
        let media = harness.handler.requestLog.filter { $0.components?.last == "v.mp4" }
        print("A4-3-record media size=\(bytes.count) moov=\(moov.offset) probe=\(probe) responses=\(media.count)")
        // The page read the metadata, which lives past the first 8 MB, so ranged reads got there.
        #expect(probe == "d-10-w-1280-e-0.png", "the page reported \(probe)")
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

    /// A request carrying a retired token is refused, observed the same way as everything else
    /// now: the page itself keeps asking, on an interval, so the token can be retired underneath
    /// it without racing a one-shot.
    ///
    /// It used to inject the second request with `evaluateJavaScript`. The page's `sandbox`
    /// (A4-3, D-2) refuses app-injected script as firmly as the page's own, and this is the
    /// better instrument regardless: what a page with a stale base URL gets is the thing under
    /// test, not what we can inject into it.
    @Test func requestsWithAnOldTokenFailAfterANewLoad() async throws {
        let html = """
        <!doctype html><html><body><img id=a src="img/a.png">
        <script>
        let n = 0;
        setInterval(() => {
          const i = new Image();
          i.src = 'img/b.png?n=' + (++n);
          document.body.append(i);
        }, 300);
        </script></body></html>
        """
        let harness = try await load(
            html: html,
            files: ["site/pages/img/a.png": RecordingServer.png, "site/pages/img/b.png": RecordingServer.png],
            remote: true,
            javaScript: true
        )
        defer { harness.remove() }
        // The page is live, and its own repeated request is being served under the current token.
        try await waitUntil(timeout: .seconds(5)) { harness.served().contains(["site", "pages", "img", "a.png"]) }
        try await waitUntil(timeout: .seconds(5)) { harness.served().contains(["site", "pages", "img", "b.png"]) }

        // Retire it. Everything the page asks for from here carries the old one.
        let before = harness.handler.requestLog.count
        _ = try harness.handler.beginLoad(
            document: Data("<p>new</p>".utf8),
            documentURL: harness.root.appendingPathComponent("site/pages/index.html"),
            scopeRoot: harness.root,
            policy: .blocked
        )
        try await waitUntil(timeout: .seconds(5)) { harness.handler.requestLog.count > before }
        let after = Array(harness.handler.requestLog.dropFirst(before))
        #expect(!after.isEmpty, "the page stopped asking")
        #expect(after.allSatisfy { $0.outcome == .refused("unknown load") },
                "a retired token was not refused: \(after.map(\.outcome))")
    }
}
#endif
