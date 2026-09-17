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

    @Test func allowedListLetsOnlyImagesThrough() async throws {
        let (paths, results) = try await requestedPaths(allowRemoteImages: true)
        // The control test shows every other fixture request reaches the server without a list.
        #expect(paths == ["/image.png"], "requests that got through: \(paths), page saw \(results)")
        #expect(results.hasPrefix("load,"), "page saw \(results)")
    }
}

/// A minimal HTTP server on 127.0.0.1 that records request paths and answers with a 1×1 PNG.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var recorded: Set<String> = []

    var paths: Set<String> { lock.withLock { recorded } }
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
