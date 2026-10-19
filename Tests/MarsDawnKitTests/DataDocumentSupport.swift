#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Loads the JSON and YAML page (kit #128) the way a host would, and drives it.
@MainActor
enum DataPage {
    /// A web view on `data.html`, loaded. `handler` replaces the kit's scheme handler (a recording
    /// one, or one with a registry of its own); `userScript` runs at document start.
    static func load(
        theme: PreviewTheme = .dawn, darkTheme: PreviewTheme? = nil, dark: Bool = false,
        handler: (any WKURLSchemeHandler)? = nil, userScript: String? = nil,
        messageHandlers: [String: any WKScriptMessageHandler] = [:],
        url: URL? = nil
    ) async throws -> WKWebView {
        let configuration: WKWebViewConfiguration
        if let handler {
            configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        } else {
            configuration = PreviewWebView.makeConfiguration()
        }
        if let userScript {
            configuration.userContentController.addUserScript(
                WKUserScript(source: userScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        for (name, handler) in messageHandlers {
            configuration.userContentController.add(handler, name: name)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 900), configuration: configuration)
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let list = try? await PreviewContentRules.ruleList(allowRemoteImages: false) {
            webView.configuration.userContentController.add(list)
        }
        _ = webView.load(URLRequest(url: url ?? DataDocumentPreview.pageURL(theme: theme, darkTheme: darkTheme)))
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!webView.isLoading, "data.html did not finish loading")
        return webView
    }

    /// The update for `text`, with `limits` overriding the kit's limits by name.
    static func update(_ text: String, kind: DataDocumentPreview.Kind, sequence: Int = 1,
                       limits: [String: Int] = [:], labels: DataLabels = .english) -> DataDocumentPreview.DataUpdate {
        let base = DataDocumentPreview.update(data: Data(text.utf8), kind: kind, sequence: sequence, labels: labels)
        return relaxed(base, limits)
    }

    static func relaxed(_ update: DataDocumentPreview.DataUpdate, _ limits: [String: Int]) -> DataDocumentPreview.DataUpdate {
        guard !limits.isEmpty else { return update }
        var arguments = update.arguments
        var merged = DataDocumentPreview.limits
        for (name, value) in limits {
            precondition(merged[name] != nil, "no limit named \(name)")
            merged[name] = value
        }
        arguments["limits"] = merged
        return DataDocumentPreview.DataUpdate(functionBody: update.functionBody, arguments: arguments)
    }

    static func render(_ text: String, kind: DataDocumentPreview.Kind, in webView: WKWebView, sequence: Int = 1,
                       limits: [String: Int] = [:], labels: DataLabels = .english) async -> DataDocumentPreview.RenderOutcome {
        await DataDocumentPreview.render(update(text, kind: kind, sequence: sequence, limits: limits, labels: labels), in: webView)
    }

    static func value(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript("return \(script);", contentWorld: .page)
    }

    static func int(_ script: String, in webView: WKWebView) async throws -> Int {
        try await value(script, in: webView) as? Int ?? -1
    }

    static func string(_ script: String, in webView: WKWebView) async throws -> String {
        try await value(script, in: webView) as? String ?? "<not a string>"
    }

    /// Rows drawn (every visit is one `.data-node`).
    static func rows(in webView: WKWebView) async throws -> Int {
        try await int("document.querySelectorAll('#data .data-node').length", in: webView)
    }

    /// The text of the state message, or "" when a tree is shown.
    static func messageText(in webView: WKWebView) async throws -> String {
        try await string("(document.querySelector('#data .data-message > p') || { textContent: '' }).textContent", in: webView)
    }

    static func click(_ selector: String, in webView: WKWebView) async throws {
        _ = try await value("(() => { const b = document.querySelector(\(PreviewWebView.jsonStringLiteral(selector))); if (!b) return false; b.click(); return true; })()", in: webView)
    }

    /// The English parse-error message with a position.
    static func parseErrorAt(_ format: String, _ line: Int, _ column: Int) -> String {
        DataLabels.english.parseErrorAt.replacingOccurrences(of: "{format}", with: format)
            .replacingOccurrences(of: "{line}", with: String(line)).replacingOccurrences(of: "{column}", with: String(column))
    }

    /// `n` nested sequences, the innermost empty: `[[[]]]` for 3.
    static func nestedSequences(_ n: Int) -> String {
        String(repeating: "[", count: n) + String(repeating: "]", count: n)
    }
}

/// Records every message a page posts to it.
@MainActor
final class RecordingMessageHandler: NSObject, WKScriptMessageHandler {
    private(set) var bodies: [Any] = []
    private(set) var mainFrame: [Bool] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        bodies.append(message.body)
        mainFrame.append(message.frameInfo.isMainFrame)
    }
}

/// The kit's scheme handler, recording each path it is asked for.
@MainActor
final class RecordingPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private let inner: PreviewSchemeHandler
    private(set) var paths: [String] = []

    init(registry: ThemeRegistry? = nil) {
        if let registry {
            inner = PreviewSchemeHandler(rootURL: KitStrings.bundle.url(forResource: "Preview", withExtension: nil), registry: registry)
        } else {
            inner = PreviewSchemeHandler()
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        if let url = urlSchemeTask.request.url {
            paths.append(url.path + (url.query.map { "?" + $0 } ?? ""))
        }
        inner.webView(webView, start: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        inner.webView(webView, stop: urlSchemeTask)
    }
}
#endif
