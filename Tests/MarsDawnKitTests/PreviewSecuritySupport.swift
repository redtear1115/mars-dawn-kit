#if os(macOS)
import AppKit
import Foundation
import WebKit
@testable import MarsDawnKit

// Shared support for the preview-page security suites (kit #157).
//
// The real preview page is served by `PreviewSchemeHandler`. To show that a fixture that stays
// inert on the shipping page *would* run if a protection were removed, these tests serve a
// throwaway copy of the `Preview/` folder whose `index.html` and `preview.js` have been patched to
// realise one control at a time, through `PreviewSchemeHandler(rootURL:)`. Every patch is read
// back from the copy before the page loads, so a control that silently failed to apply can't pass
// for a protection that held.

/// The source `Preview/` folder, found from this file's path (the resource bundle isn't reachable
/// from the test module), matching how the other preview suites locate `preview.js`.
let previewSourceFolderURL: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // MarsDawnKitTests
    .deletingLastPathComponent()      // Tests
    .deletingLastPathComponent()      // repo root
    .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview", isDirectory: true)

/// A throwaway, patchable copy of the bundled `Preview/` folder.
@MainActor
final class PreviewPageCopy {
    let rootURL: URL
    private let indexURL: URL
    private let previewJSURL: URL

    enum CopyError: Error { case patchDidNotApply(String) }

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("md157-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: previewSourceFolderURL, to: base)
        rootURL = base
        indexURL = base.appendingPathComponent("index.html")
        previewJSURL = base.appendingPathComponent("preview.js")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: Patches

    /// Replaces `needle` with `replacement` in `fileURL`, failing loudly if it matched other than
    /// exactly once (so a rename in the source can't leave a control quietly inert).
    private func patch(_ fileURL: URL, _ needle: String, _ replacement: String) throws {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let count = text.components(separatedBy: needle).count - 1
        guard count == 1 else { throw CopyError.patchDidNotApply("\(needle) matched \(count)× in \(fileURL.lastPathComponent)") }
        try text.replacingOccurrences(of: needle, with: replacement).write(to: fileURL, atomically: true, encoding: .utf8)
        // Prove the edit landed.
        let after = try String(contentsOf: fileURL, encoding: .utf8)
        guard after.contains(replacement), !after.contains(needle) else {
            throw CopyError.patchDidNotApply("read-back failed for \(fileURL.lastPathComponent)")
        }
    }

    /// Restores the base element filter (removes `script`/`noscript` from `blockedElements`).
    @discardableResult func revertScriptNoscriptFilter() throws -> PreviewPageCopy {
        try patch(previewJSURL,
                  #"object, embed, portal, fencedframe, script, noscript";"#,
                  #"object, embed, portal, fencedframe";"#)
        return self
    }

    /// Restores the pre-#157 read-back of `.mermaid-output`'s current markup on the edit-update
    /// stale-capture path and/or the theme/appearance redraw path.
    enum RedrawPath { case update, theme, both }
    @discardableResult func revertMermaidReadback(_ path: RedrawPath) throws -> PreviewPageCopy {
        if path == .update || path == .both {
            try patch(previewJSURL,
                      #"const svg = el._mdSVG;  // kit #157: the SVG this code produced, not .mermaid-output's markup."#,
                      #"const svg = el.querySelector(".mermaid-output")?.innerHTML;"#)
        }
        if path == .theme || path == .both {
            try patch(previewJSURL,
                      #"const previous = block._mdSVG;  // kit #157: the SVG this code produced, not .mermaid-output's markup."#,
                      #"const previous = output?.innerHTML;"#)
        }
        return self
    }

    /// Plants `loose` into `configureMermaid`'s `mermaid.initialize` call (F3 control).
    @discardableResult func plantLooseMermaid() throws -> PreviewPageCopy {
        try patch(previewJSURL, #"securityLevel: "strict","#, #"securityLevel: "loose","#)
        return self
    }

    // MARK: Loading

    /// Builds a configuration that serves this copy (not the bundled Preview folder).
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(PreviewSchemeHandler(rootURL: rootURL), forURLScheme: PreviewSchemeHandler.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }
}

/// Loads a preview page in a real `PreviewWKWebView`, installs the sentinel bootstrap, and returns
/// the loaded view. `configuration` serves either the bundled page or a patched copy.
@MainActor
func loadSecurityPreview(configuration: WKWebViewConfiguration, theme: PreviewTheme = .dawn) async throws -> PreviewWKWebView {
    let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), configuration: configuration)
    webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
    guard webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: theme))) != nil else { throw URLError(.cancelled) }
    let deadline = ContinuousClock.now + .seconds(20)
    while webView.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    // Sentinel plus the instruments the security review asked for (F7): CSP violations and the
    // identity of the page's own globals, so a page-script re-run is caught even if it is silent.
    _ = try await webView.callAsyncJavaScript(
        """
        window.__md157 = 0;
        window.__md157cspViolations = [];
        window.addEventListener('securitypolicyviolation', (e) => window.__md157cspViolations.push(e.violatedDirective));
        window.__md157MarsDawnRef = window.MarsDawn;
        window.__md157katexRef = window.katex;
        return true;
        """, contentWorld: .page)
    return webView
}

/// Feeds `html` through the page's own `update()` and waits for its diagrams to settle.
@MainActor
func previewUpdate(_ html: String, lineCount: Int = 40, in webView: PreviewWKWebView) async throws {
    _ = try await webView.evaluateJavaScript(PreviewWebView.updateScript(html: html, lineCount: lineCount))
    _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
}

/// Reads an integer out of the page world.
@MainActor
func previewInt(_ webView: WKWebView, _ expression: String) async throws -> Int {
    let value = try await webView.callAsyncJavaScript("return (\(expression));", contentWorld: .page)
    return value as? Int ?? -1
}

/// Reads a string out of the page world.
@MainActor
func previewString(_ webView: WKWebView, _ expression: String) async throws -> String {
    let value = try await webView.callAsyncJavaScript("return String(\(expression));", contentWorld: .page)
    return value as? String ?? ""
}

/// The sentinel's value: anything other than 0 means a document's script or handler ran.
@MainActor
func sentinel(_ webView: WKWebView) async throws -> Int {
    try await previewInt(webView, "window.__md157 | 0")
}

/// Yields through several fresh macrotasks and a short timer so a theme/appearance redraw — which
/// `renderMermaidSequentially` runs off `pendingWork`, out of reach of `MarsDawn.idle()` — has
/// finished its single invalid diagram before the test reads the DOM.
@MainActor
func settleRender(_ webView: WKWebView) async throws {
    _ = try? await webView.callAsyncJavaScript(
        """
        // No requestAnimationFrame: a web view outside a window never runs frames, so a promise
        // waiting on one never settles (and callAsyncJavaScript can't be cancelled). Fresh tasks
        // and a short timer only, with a hard cap so this always returns.
        await Promise.race([
          new Promise((resolve) => {
            let n = 0;
            const tick = () => {
              const ch = new MessageChannel();
              ch.port2.onmessage = () => { n += 1; if (n < 16) tick(); else setTimeout(resolve, 100); };
              ch.port1.postMessage(0);
            };
            tick();
          }),
          new Promise((resolve) => setTimeout(resolve, 5000)),
        ]);
        return true;
        """, contentWorld: .page)
}
#endif
