#if os(macOS)
import Foundation
import Network
import Security
import WebKit

// Shared helpers for the HTML serving tests. Everything stays on this machine: web servers
// listen on 127.0.0.1, and custom schemes are answered in process.

/// A scheme handler that answers from a fixed table and records every request it sees.
@MainActor
final class RecordingSchemeHandler: NSObject, WKURLSchemeHandler {
    struct Resource {
        var status = 200
        var headers: [String: String]
        var body: Data
    }

    /// Responses by raw (percent-encoded) URL path.
    var resources: [String: Resource] = [:]
    private(set) var requests: [URLRequest] = []

    /// Raw (percent-encoded) request paths.
    var paths: [String] { requests.compactMap { $0.url?.path(percentEncoded: true) } }

    func requests(forPath path: String) -> [URLRequest] {
        requests.filter { $0.url?.path(percentEncoded: true) == path }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        requests.append(urlSchemeTask.request)
        guard let url = urlSchemeTask.request.url, let resource = resources[url.path(percentEncoded: true)],
              let response = HTTPURLResponse(url: url, statusCode: resource.status, httpVersion: "HTTP/1.1", headerFields: resource.headers)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(resource.body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Waits for navigations and, optionally, lets only chosen ones through.
@MainActor
final class TestNavigationDelegate: NSObject, WKNavigationDelegate {
    enum State { case idle, loading, finished, failed(Error) }
    private(set) var state: State = .idle
    /// When set, a navigation action is allowed only if this returns true.
    var policy: ((WKNavigationAction) -> Bool)?
    private(set) var cancelledNavigations: [URL?] = []
    /// When set, TLS connections to 127.0.0.1 presenting this certificate are trusted.
    var trustedCertificate: SecCertificate?

    func load(_ request: URLRequest, in webView: WKWebView, timeout: Duration = .seconds(15)) async throws {
        state = .loading
        webView.navigationDelegate = self
        guard webView.load(request) != nil else { throw URLError(.cancelled) }
        try await waitForLoad(timeout: timeout)
    }

    func waitForLoad(timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch state {
            case .finished: return
            case .failed(let error): throw error
            case .idle, .loading: try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw URLError(.timedOut)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state = .finished
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        state = .failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state = .failed(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if let policy, !policy(navigationAction) {
            cancelledNavigations.append(navigationAction.request.url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == "127.0.0.1",
              let trustedCertificate, let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              SecCertificateCopyData(leaf) as Data == SecCertificateCopyData(trustedCertificate) as Data
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Collects messages posted by page script.
@MainActor
final class ScriptMessageRecorder: NSObject, WKScriptMessageHandler {
    private(set) var messages: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        messages.append("\(message.body)")
    }
}

/// A web server on 127.0.0.1 (plain HTTP or TLS) that records accepted connections and requests.
final class RecordingServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        /// Header names lowercased.
        let headers: [String: String]
    }

    struct Response: Sendable {
        var status = 200
        var contentType = "application/octet-stream"
        var headers: [String: String] = [:]
        var body = Data()
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "RecordingServer")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var acceptCount = 0
    private let respond: @Sendable (Request) -> Response

    var requests: [Request] { lock.withLock { recorded } }
    var paths: [String] { requests.map(\.path) }
    /// Connections accepted, whether or not a request followed (a preconnect sends none).
    var accepts: Int { lock.withLock { acceptCount } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    private init(identity: SecIdentity?, respond: @escaping @Sendable (Request) -> Response) throws {
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.respond = respond
    }

    /// Answers every request with a 1×1 PNG unless `respond` says otherwise.
    static func start(
        identity: SecIdentity? = nil,
        respond: @escaping @Sendable (Request) -> Response = { _ in Response(contentType: "image/png", body: RecordingServer.png) }
    ) async throws -> RecordingServer {
        let server = try RecordingServer(identity: identity, respond: respond)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
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
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil || buffer.count > 1 << 20 {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: buffer)
                }
                return
            }
            guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
                connection.cancel()
                return
            }
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let request = Request(method: String(parts[0]), path: String(parts[1]), headers: headers)
            lock.withLock { recorded.append(request) }
            let answer = respond(request)
            var head2 = "HTTP/1.1 \(answer.status) X\r\nContent-Type: \(answer.contentType)\r\nContent-Length: \(answer.body.count)\r\nConnection: close\r\n"
            for (name, value) in answer.headers { head2 += "\(name): \(value)\r\n" }
            var response = Data((head2 + "\r\n").utf8)
            response.append(answer.body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// A throwaway self-signed identity for 127.0.0.1, made with /usr/bin/openssl and imported
/// into memory only (never into a keychain). The key exists only for this test process.
@available(macOS 26, *) // kSecImportToMemoryOnly; the app's minimum is macOS 26.
enum TestTLSIdentity {
    struct Material {
        let identity: SecIdentity
        let certificate: SecCertificate
    }

    enum Failure: Error { case openssl(Int32), importFailed(OSStatus), noIdentity }

    static func make() throws -> Material {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        let p12 = directory.appendingPathComponent("id.p12").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                 "-days", "1", "-subj", "/CN=127.0.0.1"])
        try run(["pkcs12", "-export", "-out", p12, "-inkey", key, "-in", cert, "-passout", "pass:test"])
        let data = try Data(contentsOf: URL(fileURLWithPath: p12))
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: "test",
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw Failure.importFailed(status) }
        guard let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String]
        else { throw Failure.noIdentity }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw Failure.noIdentity
        }
        return Material(identity: identity, certificate: certificate)
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.openssl(process.terminationStatus) }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// A random lowercase hex string for test hosts.
func randomTestToken() -> String {
    (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Runs `script` in the page's world and decodes its JSON string result.
@MainActor
func pageJSON(_ webView: WKWebView, _ script: String) async throws -> [String: Any] {
    let text = try await webView.callAsyncJavaScript(script, contentWorld: .page) as? String ?? "{}"
    return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
}
#endif
