#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// An `http` image can never load: the page's CSP admits `marsdawn-app:`, `marsdawn-asset:`,
/// `data:` and, when the reader turns web images on, `https:` — never `http:`. So it gets a
/// placeholder that says why, in both image policies, and it is not counted when deciding whether
/// to offer "Load Images" (mars-dawn#26).
///
/// These drive the real page, because the bug was in what the page does with a load that failed,
/// not in anything the renderer produces.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct InsecureImageTests {
    static let insecureLabel = "Not loaded: unencrypted connection (http)"
    static let remoteLabel = "Web image not loaded"

    private func loadedPreview(allowRemoteImages: Bool) async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: allowRemoteImages))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn, allowRemoteImages: allowRemoteImages))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!webView.isLoading)
        _ = try await webView.evaluateJavaScript(PreviewWebView.remoteImagesScript(
            blocked: !allowRemoteImages,
            message: "Web images are off",
            buttonLabel: "Load Images",
            placeholderLabel: Self.remoteLabel,
            insecureLabel: Self.insecureLabel
        ))
        return webView
    }

    /// Renders `markdown` and waits for the failed loads to have been turned into placeholders.
    private func show(_ markdown: String, in webView: PreviewWKWebView) async throws {
        let html = MarkdownRenderer.render(markdown, options: MarkdownRenderer.Options())
        _ = try await webView.evaluateJavaScript(PreviewWebView.updateScript(html: html, lineCount: 20))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let pending = try await count("#content img", in: webView)
            if pending == 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func count(_ selector: String, in webView: WKWebView) async throws -> Int {
        let value = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll(selector).length;",
            arguments: ["selector": selector], contentWorld: .page)
        return value as? Int ?? -1
    }

    private func text(_ selector: String, in webView: WKWebView) async throws -> String {
        let value = try await webView.callAsyncJavaScript(
            "const e = document.querySelector(selector); return e ? e.textContent : '';",
            arguments: ["selector": selector], contentWorld: .page)
        return value as? String ?? ""
    }

    private func barIsShown(in webView: WKWebView) async throws -> Bool {
        let value = try await webView.callAsyncJavaScript(
            "return !document.getElementById('remote-images-bar').hidden;", contentWorld: .page)
        return value as? Bool ?? false
    }

    /// The bug as reported: with web images on, an http image was left as a broken `<img>`.
    @Test(arguments: [false, true])
    func anHTTPImageGetsItsOwnPlaceholderInEitherPolicy(allowRemoteImages: Bool) async throws {
        let webView = try await loadedPreview(allowRemoteImages: allowRemoteImages)
        try await show("![diagram](http://example.invalid/a.png)", in: webView)

        #expect(try await count("#content img", in: webView) == 0, "the broken <img> is still in the page")
        #expect(try await count("#content .image-placeholder.insecure", in: webView) == 1)
        #expect(try await text("#content .image-placeholder-label", in: webView) == Self.insecureLabel)
        // Not the remote wording, which would suggest a setting could load it.
        #expect(try await count("#content .image-placeholder.remote", in: webView) == 0)
    }

    /// The other face of the bug: the bar offered to load an image that no setting can load.
    @Test func theLoadImagesBarIsNotOfferedForHTTPImagesAlone() async throws {
        let webView = try await loadedPreview(allowRemoteImages: false)
        try await show("![one](http://example.invalid/a.png)\n\n![two](http://example.invalid/b.png)", in: webView)
        #expect(try await count("#content .image-placeholder.insecure", in: webView) == 2)
        #expect(try await barIsShown(in: webView) == false, "the bar offers to load what it cannot load")
    }

    /// …but a document that also holds an https image still gets the offer, for that image.
    @Test func anHTTPSImageStillGetsTheOffer() async throws {
        let webView = try await loadedPreview(allowRemoteImages: false)
        try await show("![http](http://example.invalid/a.png)\n\n![https](https://example.invalid/b.png)", in: webView)
        #expect(try await count("#content .image-placeholder.insecure", in: webView) == 1)
        #expect(try await count("#content .image-placeholder.remote", in: webView) == 1)
        #expect(try await barIsShown(in: webView) == true)
    }

    /// The tooltip carries what the label leaves out, so the label can stay a sentence.
    @Test func theTooltipNamesTheHostAndTheAltText() async throws {
        let webView = try await loadedPreview(allowRemoteImages: false)
        try await show("![a diagram](http://images.example/a.png)", in: webView)
        let title = try await webView.callAsyncJavaScript(
            "return document.querySelector('#content .image-placeholder-label').title;",
            contentWorld: .page) as? String ?? ""
        #expect(title.contains("images.example"))
        #expect(title.contains("a diagram"))
    }

    /// No request is made in either policy. A loopback listener answers that, where a hostname
    /// that doesn't resolve would fail the same way whether or not the page tried.
    @Test(arguments: [false, true])
    func nothingIsRequested(allowRemoteImages: Bool) async throws {
        let listener = try LoopbackRequestListener()
        listener.start()
        defer { listener.stop() }
        let webView = try await loadedPreview(allowRemoteImages: allowRemoteImages)
        try await show("![diagram](http://127.0.0.1:\(listener.port)/a.png)", in: webView)
        try await Task.sleep(for: .seconds(1))
        #expect(listener.requests.isEmpty, "the page asked for \(listener.requests)")
        #expect(try await count("#content .image-placeholder.insecure", in: webView) == 1)
    }

    /// The exported and printed page has no window to take labels from, so the kit's own wording
    /// has to be there, translated.
    @Test func theKitOwnsTheWordingForExportAndPrint() throws {
        #expect(PreviewWebView.insecureImagePlaceholderLabel.isEmpty == false)
        let translated = try #require(PreviewWebView.moduleLocalizedString(
            "Not loaded: unencrypted connection (http)", localization: "zh-Hant"))
        #expect(translated == "未載入：連線未加密（http）")
        // A caller with no opinion still gets it.
        let script = PreviewWebView.remoteImagesScript(
            blocked: true, message: "", buttonLabel: "", placeholderLabel: "Web image")
        #expect(script.contains("insecureLabel"))
    }
}

/// `retryImages()` runs over every placeholder when folder access is granted, but only the local
/// placeholder records a source to retry. Reading through a web placeholder threw, and every local
/// image after it in the document then never retried — the "Grant Access" placeholder just sat
/// there. Fails on kit main.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RetryAfterGrantingAccessTests {
    @Test func grantingAccessRetriesLocalImagesPastAWebPlaceholder() async throws {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await webView.evaluateJavaScript(PreviewWebView.remoteImagesScript(
            blocked: true, message: "Web images are off", buttonLabel: "Load Images",
            placeholderLabel: "Web image not loaded"))
        _ = try await webView.evaluateJavaScript(PreviewWebView.assetStateScript(
            needsAccess: true, grantLabel: "Grant Access…", missingLabel: "Image not found",
            blockedLabel: "Image needs folder access"))
        // The web image comes first, so the local one is behind it in the retry loop.
        let html = """
        <p data-line="1"><img src="https://example.invalid/b.png" alt="web"></p>
        <p data-line="2"><img src="marsdawn-asset://relative/missing.png" alt="local"></p>
        """
        _ = try await webView.evaluateJavaScript(PreviewWebView.updateScript(html: html, lineCount: 3))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        try await Task.sleep(for: .seconds(2))

        // The user picks the folder, and the app pushes the new state.
        let outcome = try await webView.callAsyncJavaScript("""
        try {
            MarsDawn.setAssetState({needsAccess: false, grantLabel: "", missingLabel: "Image not found", blockedLabel: "Image needs folder access"});
            return "ran";
        } catch (error) { return String(error); }
        """, contentWorld: .page) as? String ?? ""
        #expect(outcome == "ran", "setAssetState threw: \(outcome)")

        try await Task.sleep(for: .seconds(2))
        // The local image was retried, so its placeholder no longer asks for access.
        let labels = try await webView.callAsyncJavaScript(
            "return [...document.querySelectorAll('#content .image-placeholder-label')].map((e) => e.textContent).join(' | ');",
            contentWorld: .page) as? String ?? ""
        #expect(labels.contains("Image not found: missing.png"), "labels were: \(labels)")
        #expect(labels.contains("Image needs folder access") == false, "labels were: \(labels)")
        let buttons = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('#content .image-placeholder button').length;",
            contentWorld: .page) as? Int ?? -1
        #expect(buttons == 0, "the Grant Access button is still there")
    }
}

/// A TCP listener on loopback that records the request lines it is sent, so a test can ask whether
/// a request was made at all rather than inferring it from a failure.
final class LoopbackRequestListener: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32
    private var lines: [String] = []
    private let lock = NSLock()
    private var running = true

    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0, "bind failed")
        precondition(listen(fd, 8) == 0, "listen failed")
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = assigned.sin_port.byteSwapped
        socketFD = fd
    }

    func start() {
        Thread.detachNewThread { @Sendable [socketFD] in
            while true {
                let client = accept(socketFD, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 2048)
                let count = read(client, &buffer, buffer.count)
                let text = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
                self.record(text.split(separator: "\r\n").first.map(String.init) ?? "<empty>")
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                _ = response.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }

    private func record(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func stop() {
        guard running else { return }
        running = false
        close(socketFD)
    }
}
#endif
