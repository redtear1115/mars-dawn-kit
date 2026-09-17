#if os(macOS)
import Foundation
import Network
import Testing
import WebKit
@testable import MarsDawnKit

/// Evaluates the compiled rule lists in a real web view. Requests go to a loopback server in
/// this process (`http://127.0.0.1` matches `^https?:`), which records the ones that arrive;
/// nothing leaves the machine.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ContentRuleBehaviorTests {
    /// Loads one resource of each kind from the server and waits until each has loaded or failed.
    private static let fixtureScript = """
    const base = `http://127.0.0.1:${port}`;
    const settle = (element, event) => new Promise((resolve) => {
      element.addEventListener(event, () => resolve("load"), { once: true });
      element.addEventListener("error", () => resolve("error"), { once: true });
      setTimeout(() => resolve("timeout"), 3000);
    });
    const image = new Image();
    const imageDone = settle(image, "load");
    image.src = `${base}/image.png`;

    const style = document.createElement("link");
    style.rel = "stylesheet";
    const styleDone = settle(style, "load");
    style.href = `${base}/style.css`;
    document.head.append(style);

    const script = document.createElement("script");
    const scriptDone = settle(script, "load");
    script.src = `${base}/script.js`;
    document.head.append(script);

    const fetchDone = fetch(`${base}/fetch.txt`).then(() => "load", () => "error");

    const socketDone = new Promise((resolve) => {
      try {
        const socket = new WebSocket(`ws://127.0.0.1:${port}/socket`);
        socket.onopen = () => resolve("load");
        socket.onerror = () => resolve("error");
        setTimeout(() => resolve("timeout"), 3000);
      } catch (error) {
        resolve("error");
      }
    });

    const results = await Promise.all([imageDone, styleDone, scriptDone, fetchDone, socketDone]);
    return results.join(",");
    """

    /// `allowRemoteImages` nil: no rule list at all (the control).
    private func requestedPaths(allowRemoteImages: Bool?) async throws -> (paths: Set<String>, results: String) {
        let server = try await LoopbackServer.start()
        defer { server.stop() }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let allowRemoteImages {
            let list = try await PreviewContentRules.ruleList(allowRemoteImages: allowRemoteImages)
            configuration.userContentController.add(list)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        webView.loadHTMLString("<!doctype html><html><head></head><body>fixture</body></html>", baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let results = try await webView.callAsyncJavaScript(
            Self.fixtureScript, arguments: ["port": Int(server.port)], contentWorld: .page
        ) as? String ?? ""
        // Give any request that did get through time to reach the server.
        try await Task.sleep(for: .milliseconds(300))
        return (server.paths, results)
    }

    @Test func withoutARuleListEveryFixtureRequestArrives() async throws {
        let (paths, results) = try await requestedPaths(allowRemoteImages: nil)
        #expect(paths == ["/image.png", "/style.css", "/script.js", "/fetch.txt", "/socket"], "page saw \(results)")
    }

    @Test func blockedListStopsEveryRequest() async throws {
        let (paths, results) = try await requestedPaths(allowRemoteImages: false)
        #expect(paths.isEmpty, "requests that got through: \(paths), page saw \(results)")
    }

    /// The fixture is plaintext http throughout. MarsDawn supports https only, so the allowed
    /// list blocks all of it, the image included; `SecureOnlyRuleBehaviorTests` shows the same
    /// list letting an https image through.
    @Test func allowedListStopsEveryPlaintextHTTPRequestIncludingImages() async throws {
        let (paths, results) = try await requestedPaths(allowRemoteImages: true)
        // The control test shows every fixture request reaches the server without a list.
        #expect(paths.isEmpty, "requests that got through: \(paths), page saw \(results)")
    }
}

/// The allowed rule lists lift their block for https only. Two loopback servers, one plain and
/// one TLS, show what each state does with the same `<img>` in a real web view.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SecureOnlyRuleBehaviorTests {
    enum Rules: String, CaseIterable, Sendable {
        /// The control: no list at all, so both references load.
        case none
        case previewImagesAllowed
        case htmlRemoteAllowed
    }

    private func imageRequests(_ rules: Rules) async throws -> (plain: RecordingServer, secure: RecordingServer)? {
        guard #available(macOS 26, *) else {
            Issue.record("Needs macOS 26 (in-memory TLS identity)")
            return nil
        }
        let tls = try TestTLSIdentity.make()
        let plain = try await RecordingServer.start()
        let secure = try await RecordingServer.start(identity: tls.identity)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        switch rules {
        case .none: break
        case .previewImagesAllowed:
            configuration.userContentController.add(try await PreviewContentRules.ruleList(allowRemoteImages: true))
        case .htmlRemoteAllowed:
            configuration.userContentController.add(try await HTMLContentRules.ruleList(allowsRemoteContent: true))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let navigation = TestNavigationDelegate()
        navigation.trustedCertificate = tls.certificate
        webView.navigationDelegate = navigation
        webView.loadHTMLString("""
        <!doctype html><html><body>
        <img src="http://127.0.0.1:\(plain.port)/http.png">
        <img src="https://127.0.0.1:\(secure.port)/https.png">
        </body></html>
        """, baseURL: nil)
        try await navigation.waitForLoad()
        // Wait for the https image, which every state here allows, then let the http one have
        // the same time to arrive.
        try await waitUntil(timeout: .seconds(8)) { secure.paths.contains("/https.png") }
        try await Task.sleep(for: .seconds(3))
        return (plain, secure)
    }

    @Test(arguments: Rules.allCases)
    func onlyTheHTTPSImageIsLoadedWhenRemoteContentIsAllowed(rules: Rules) async throws {
        guard let (plain, secure) = try await imageRequests(rules) else { return }
        defer { plain.stop(); secure.stop() }
        #expect(secure.paths == ["/https.png"], "https: \(secure.paths)")
        if rules == .none {
            // The control: without a list the plaintext reference does reach the server, so the
            // other two cases are showing the list at work.
            #expect(plain.paths == ["/http.png"], "http without a list: \(plain.paths)")
        } else {
            #expect(plain.accepts == 0, "plaintext http connected: accepts=\(plain.accepts) paths=\(plain.paths)")
        }
    }
}

/// `<link rel=preconnect>` opens a connection that the page's CSP doesn't stop, including from
/// an `<iframe srcdoc>` that the `<link` rename can't see. The rule lists must stop both.
/// Preconnects send no request, so these tests count accepted connections.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PreconnectRuleBehaviorTests {
    enum Fixture: String, CaseIterable, Sendable {
        /// A `<link rel=preconnect>` in the page itself.
        case link
        /// An `<iframe srcdoc>` holding the preconnect, inserted the way preview.js inserts
        /// rendered HTML (a template's `innerHTML`, then its content moved into the page).
        case srcdoc
    }

    enum Rules: String, CaseIterable, Sendable {
        case none, blocked, remoteImagesAllowed
    }

    /// How long a case watches for connections. Without rules a preconnect arrives well within
    /// this; with rules the whole window must pass without one.
    static let window: Duration = .seconds(4)

    private func accepts(_ fixture: Fixture, rules: Rules) async throws -> Int {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let target = "http://127.0.0.1:\(server.port)/"

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        switch rules {
        case .none: break
        case .blocked: configuration.userContentController.add(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        case .remoteImagesAllowed: configuration.userContentController.add(try await PreviewContentRules.ruleList(allowRemoteImages: true))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)

        let head = fixture == .link ? "<link rel=preconnect href=\"\(target)\">" : ""
        webView.loadHTMLString("<!doctype html><html><head>\(head)</head><body></body></html>", baseURL: nil)
        let loadDeadline = ContinuousClock.now + .seconds(10)
        while webView.isLoading, ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        if fixture == .srcdoc {
            let fragment = #"<iframe srcdoc="&lt;link rel=preconnect href=&quot;\#(target)&quot;&gt;"></iframe>"#
            let inserted = try await webView.callAsyncJavaScript("""
                const template = document.createElement("template");
                template.innerHTML = fragment;
                document.body.appendChild(template.content);
                const frame = document.querySelector("iframe");
                await new Promise((resolve) => { frame.onload = resolve; setTimeout(resolve, 2000); });
                return frame.contentDocument?.querySelector("link[rel=preconnect]") ? "linked" : "missing";
                """, arguments: ["fragment": fragment], contentWorld: .page) as? String
            // The fixture must really have produced a preconnect link inside the frame.
            #expect(inserted == "linked")
        } else {
            let linked = try await webView.evaluateJavaScript(#"document.querySelector("link[rel=preconnect]") ? "linked" : "missing""#) as? String
            #expect(linked == "linked")
        }

        let deadline = ContinuousClock.now + Self.window
        while ContinuousClock.now < deadline {
            // A control can stop at its first connection; a blocked case waits out the window.
            if rules == .none, server.accepts > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return server.accepts
    }

    @Test(arguments: Fixture.allCases)
    func withoutRulesThePreconnectConnects(_ fixture: Fixture) async throws {
        #expect(try await accepts(fixture, rules: .none) >= 1)
    }

    @Test(arguments: Fixture.allCases)
    func blockedRulesStopThePreconnect(_ fixture: Fixture) async throws {
        #expect(try await accepts(fixture, rules: .blocked) == 0)
    }

    @Test(arguments: Fixture.allCases)
    func remoteImagesRulesStillStopThePreconnect(_ fixture: Fixture) async throws {
        #expect(try await accepts(fixture, rules: .remoteImagesAllowed) == 0)
    }
}

/// A minimal HTTP server on 127.0.0.1 that records request paths and answers with a 1×1 PNG.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var recorded: Set<String> = []
    private var acceptCount = 0

    var paths: Set<String> { lock.withLock { recorded } }
    /// Connections accepted, whether or not a request followed (a preconnect sends none).
    var accepts: Int { lock.withLock { acceptCount } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> LoopbackServer {
        let server = try LoopbackServer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            server.listener.newConnectionHandler = { [server] connection in server.handle(connection) }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        lock.withLock { acceptCount += 1 }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            if parts.count >= 2 {
                lock.withLock { _ = recorded.insert(String(parts[1])) }
            }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(Self.png.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(Self.png)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
#endif
