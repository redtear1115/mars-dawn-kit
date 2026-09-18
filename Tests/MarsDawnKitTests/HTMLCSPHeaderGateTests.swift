#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// H1 gate (P1-3): WebKit must enforce a Content-Security-Policy sent as a header on a
/// custom-scheme response, and a looser `<meta>` policy must not relax it.
///
/// `h1-gate:` serves the page; `h1-other:` is a second scheme with its own logging handler.
/// The content rule lists don't cover custom schemes, so only the header can stop `h1-other:`.
/// Script runs in these tests only, so a blocked inline script is observable.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTMLCSPHeaderGateTests {
    /// The production blocked-state CSP with its scheme swapped to `h1-gate:`.
    static let gateCSP = "default-src 'none'; img-src h1-gate: data:; style-src h1-gate: 'unsafe-inline'; font-src h1-gate: data:; media-src h1-gate:; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; connect-src 'none'; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"

    /// Looser than the header in every respect that matters here (inline style included, which
    /// the plan's wording `style-src *` would block). `*` alone doesn't match
    /// custom schemes, so `h1-other:` is named: without the header, this meta lets it load.
    static let looserMeta = "script-src 'unsafe-inline'; style-src * h1-other: 'unsafe-inline'; img-src * h1-other:"
    /// The meta exactly as the plan words it (recorded, see `planMetaWordingIsRecorded`).
    static let planMeta = "script-src 'unsafe-inline'; style-src *; img-src *"

    static func page(token: String, meta: String) -> String {
        """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="\(meta)">
        <style>#inline-marker { width: 11px; }</style>
        <link rel=stylesheet href="h1-gate://\(token)/ok.css">
        <link rel=stylesheet href="h1-other://x/s.css">
        </head><body>
        <div id="inline-marker"></div><div id="sheet-marker"></div><div id="other-marker"></div>
        <img id="allowed" src="h1-gate://\(token)/allowed.png">
        <img id="other" src="h1-other://x/i.png">
        <script>window.webkit.messageHandlers.gate.postMessage("script-ran");</script>
        </body></html>
        """
    }

    static let inspectScript = """
    const sheets = [...document.styleSheets].map((s) => s.href || "");
    return JSON.stringify({
      allowedWidth: document.getElementById("allowed").naturalWidth,
      otherWidth: document.getElementById("other").naturalWidth,
      inline: getComputedStyle(document.getElementById("inline-marker")).width,
      sheet: getComputedStyle(document.getElementById("sheet-marker")).width,
      otherRule: getComputedStyle(document.getElementById("other-marker")).width,
      otherSheets: sheets.filter((h) => h.startsWith("h1-other:")).length,
      otherLinkHasSheet: document.querySelector('link[href^="h1-other:"]').sheet !== null,
    });
    """

    struct Outcome {
        var page: [String: Any]
        var messages: [String]
        var gatePaths: [String]
        var otherPaths: [String]
    }

    private func run(headerCSP: String?, meta: String) async throws -> Outcome {
        let token = randomTestToken()
        let gate = RecordingSchemeHandler()
        let other = RecordingSchemeHandler()
        var pageHeaders = ["Content-Type": "text/html; charset=utf-8"]
        if let headerCSP { pageHeaders["Content-Security-Policy"] = headerCSP }
        gate.resources["/index.html"] = .init(headers: pageHeaders, body: Data(Self.page(token: token, meta: meta).utf8))
        gate.resources["/allowed.png"] = .init(headers: ["Content-Type": "image/png"], body: RecordingServer.png)
        gate.resources["/ok.css"] = .init(headers: ["Content-Type": "text/css"], body: Data("#sheet-marker { width: 13px; }".utf8))
        other.resources["/s.css"] = .init(headers: ["Content-Type": "text/css"], body: Data("#other-marker { width: 17px; }".utf8))
        other.resources["/i.png"] = .init(headers: ["Content-Type": "image/png"], body: RecordingServer.png)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(gate, forURLScheme: "h1-gate")
        configuration.setURLSchemeHandler(other, forURLScheme: "h1-other")
        let messages = ScriptMessageRecorder()
        configuration.userContentController.add(messages, name: "gate")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let navigation = TestNavigationDelegate()
        try await navigation.load(URLRequest(url: URL(string: "h1-gate://\(token)/index.html")!), in: webView)
        let page = try await pageJSON(webView, Self.inspectScript)
        // Give a late script message or request time to arrive.
        try await Task.sleep(for: .milliseconds(300))
        return Outcome(page: page, messages: messages.messages, gatePaths: gate.paths, otherPaths: other.paths)
    }

    @Test func headerCSPIsEnforcedOnACustomSchemeResponse() async throws {
        let outcome = try await run(headerCSP: Self.gateCSP, meta: Self.looserMeta)
        print("H1a-record gate: \(outcome.page) messages=\(outcome.messages) gate=\(outcome.gatePaths) other=\(outcome.otherPaths)")
        // Allowed by the header: same-scheme image, inline style, same-scheme stylesheet.
        #expect((outcome.page["allowedWidth"] as? Int ?? 0) > 0)
        #expect(outcome.page["inline"] as? String == "11px")
        #expect(outcome.page["sheet"] as? String == "13px")
        #expect(Set(outcome.gatePaths) == ["/index.html", "/allowed.png", "/ok.css"])
        // Blocked by the header only: script and the other scheme, despite the looser meta.
        #expect(outcome.messages.isEmpty)
        #expect(outcome.otherPaths.isEmpty)
        #expect(outcome.page["otherSheets"] as? Int == 0)
        #expect(outcome.page["otherLinkHasSheet"] as? Bool == false)
        #expect(outcome.page["otherRule"] as? String != "17px")
        #expect(outcome.page["otherWidth"] as? Int == 0)
    }

    /// Control: without the header the same page runs its script and loads `h1-other:`.
    @Test func withoutTheHeaderScriptRunsAndTheOtherSchemeLoads() async throws {
        let outcome = try await run(headerCSP: nil, meta: Self.looserMeta)
        print("H1a-record control: \(outcome.page) messages=\(outcome.messages) gate=\(outcome.gatePaths) other=\(outcome.otherPaths)")
        #expect(outcome.messages == ["script-ran"])
        #expect(Set(outcome.otherPaths) == ["/s.css", "/i.png"])
        #expect(outcome.page["otherSheets"] as? Int == 1)
        #expect(outcome.page["otherRule"] as? String == "17px")
    }

    /// The plan's literal meta (`*` only). Recorded: whether `*` lets a custom scheme load.
    @Test func planMetaWordingIsRecorded() async throws {
        let without = try await run(headerCSP: nil, meta: Self.planMeta)
        let with = try await run(headerCSP: Self.gateCSP, meta: Self.planMeta)
        print("H1a-record plan-meta without header: messages=\(without.messages) other=\(without.otherPaths)")
        print("H1a-record plan-meta with header: messages=\(with.messages) other=\(with.otherPaths)")
        #expect(without.messages == ["script-ran"])
        #expect(with.messages.isEmpty)
        #expect(with.otherPaths.isEmpty)
    }

    // MARK: Referrer

    private static let referrerImage = "/r.png"

    /// Loads a page from `h1-gate:` that requests one `h1-gate:` image and one image from the
    /// local server, and returns the `Referer` each request carried.
    private func customSchemeReferrers(policyHeader: Bool, meta: String?) async throws -> (scheme: String?, server: [String?]) {
        let server = try await RecordingServer.start()
        defer { server.stop() }
        let token = randomTestToken()
        let gate = RecordingSchemeHandler()
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        if policyHeader { headers["Referrer-Policy"] = "no-referrer" }
        let metaTag = meta.map { "<meta name=referrer content=\"\($0)\">" } ?? ""
        let html = """
        <!doctype html><html><head>\(metaTag)</head><body>
        <img src="h1-gate://\(token)/%2F/%2F/r.png"><img src="http://127.0.0.1:\(server.port)\(Self.referrerImage)">
        </body></html>
        """
        gate.resources["/%2F/%2F/index.html"] = .init(headers: headers, body: Data(html.utf8))
        gate.resources["/%2F/%2F/r.png"] = .init(headers: ["Content-Type": "image/png"], body: RecordingServer.png)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(gate, forURLScheme: "h1-gate")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let navigation = TestNavigationDelegate()
        try await navigation.load(URLRequest(url: URL(string: "h1-gate://\(token)/%2F/%2F/index.html")!), in: webView)
        try await waitUntil(timeout: .seconds(3)) { !server.paths.isEmpty }
        let imageRequest = gate.requests.first { $0.url?.lastPathComponent == "r.png" }
        print("H1a-record custom-scheme image URL: \(imageRequest?.url?.absoluteString ?? "none")")
        return (imageRequest?.value(forHTTPHeaderField: "Referer"),
                server.requests.filter { $0.path == Self.referrerImage }.map { $0.headers["referer"] })
    }

    /// Loads an http page from the local server that requests an image from the same server.
    private func httpPageReferrer(policyHeader: Bool) async throws -> [String?] {
        let server = try await RecordingServer.start { request in
            if request.path == "/page.html" {
                return .init(contentType: "text/html", headers: policyHeader ? ["Referrer-Policy": "no-referrer"] : [:],
                             body: Data("<!doctype html><img src=\"/img.png\">".utf8))
            }
            return .init(contentType: "image/png", body: RecordingServer.png)
        }
        defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let navigation = TestNavigationDelegate()
        try await navigation.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/page.html")!), in: webView)
        try await waitUntil(timeout: .seconds(3)) { server.paths.contains("/img.png") }
        return server.requests.filter { $0.path == "/img.png" }.map { $0.headers["referer"] }
    }

    /// Control: without a policy, a plain http page's image request carries a `Referer`.
    @Test func withoutAPolicyAnHTTPImageRequestCarriesAReferer() async throws {
        let referrers = try await httpPageReferrer(policyHeader: false)
        print("H1a-record http control referrers: \(referrers)")
        #expect(referrers.count == 1)
        #expect(referrers.allSatisfy { $0 != nil })
    }

    @Test func noReferrerHeaderStripsTheRefererFromHTTPRequests() async throws {
        let referrers = try await httpPageReferrer(policyHeader: true)
        #expect(referrers.count == 1)
        #expect(referrers.allSatisfy { $0 == nil })
    }

    /// Recorded on macOS 26.6: WebKit sends no `Referer` from a custom-scheme page even without
    /// a policy, so the custom-scheme half of this check can't fail today. The http tests above
    /// are the ones that show the header is honoured.
    @Test func noReferrerHeaderStripsTheRefererFromACustomSchemePage() async throws {
        let control = try await customSchemeReferrers(policyHeader: false, meta: nil)
        print("H1a-record custom-scheme without policy: scheme=\(control.scheme ?? "nil") server=\(control.server)")
        let result = try await customSchemeReferrers(policyHeader: true, meta: nil)
        print("H1a-record custom-scheme with policy: scheme=\(result.scheme ?? "nil") server=\(result.server)")
        #expect(result.scheme == nil)
        #expect(result.server.count == 1)
        #expect(result.server.allSatisfy { $0 == nil })
    }

    /// The page can override the header. Recorded, not required: whatever leaks is the page URL,
    /// which holds only placeholders.
    @Test func metaReferrerOverrideIsRecorded() async throws {
        let result = try await customSchemeReferrers(policyHeader: true, meta: "unsafe-url")
        print("H1a-record meta unsafe-url: scheme=\(result.scheme ?? "nil") server=\(result.server)")
        for referrer in [result.scheme] + result.server {
            guard let referrer else { continue }
            #expect(!referrer.contains("index") || referrer.contains("/%2F/%2F/index.html"))
        }
    }
}
#endif
