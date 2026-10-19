#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

// kit #157 S0 / S0b: a diagram's redraw keeps its own produced output and never re-reads the
// current markup of a `.mermaid-output` the document may have supplied. The marker here is an
// author-written, harmless element inside a document-supplied `.mermaid-output`; the diagram
// source is invalid so the (re)render fails and any output that was copied forward stays visible,
// which is what makes the difference observable.

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PreviewMermaidRedrawSafetyTests {
    /// A mermaid block that fails to render and carries a document-supplied `.mermaid-output`
    /// holding the harmless marker.
    static let markerBlock = """
    <div class="mermaid-block" data-line="1">\
    <pre class="mermaid-source">this is deliberately not a valid diagram</pre>\
    <div class="mermaid-output"><span data-md157-marker>x</span></div>\
    </div>
    """

    /// A different mermaid block that also fails to render, with no supplied output of its own, so
    /// the first block is pooled out and its stale output is offered to this fresh one.
    static let otherBlock = """
    <div class="mermaid-block" data-line="1">\
    <pre class="mermaid-source">this one is not valid either</pre>\
    <div class="mermaid-output"></div>\
    </div>
    """

    static func markerCount(in webView: WKWebView) async throws -> Int {
        try await previewInt(webView, "document.querySelectorAll('.mermaid-output [data-md157-marker]').length")
    }

    /// Edit-update path (b): an edit pools the first block out; its stale output is offered to a
    /// fresh block whose render fails. Returns how many drawn `.mermaid-output`s hold the marker.
    static func runEditPath(_ copy: PreviewPageCopy) async throws -> Int {
        let webView = try await loadSecurityPreview(configuration: copy.makeConfiguration())
        try await previewUpdate(markerBlock, in: webView)
        try await previewUpdate(otherBlock, in: webView)
        try await settleRender(webView)
        return try await markerCount(in: webView)
    }

    /// Theme/appearance redraw path (a): a theme switch redraws every diagram in place.
    static func runThemePath(_ copy: PreviewPageCopy) async throws -> Int {
        let webView = try await loadSecurityPreview(configuration: copy.makeConfiguration())
        try await previewUpdate(markerBlock, in: webView)
        _ = try await webView.evaluateJavaScript("window.MarsDawn.setTheme('classic')")
        try await settleRender(webView)
        return try await markerCount(in: webView)
    }

    // MARK: S0 — shipping page (the fix): the marker is never carried into a drawn output.

    @Test func editUpdateNeverCopiesSuppliedOutput() async throws {
        let copy = try PreviewPageCopy(); defer { copy.cleanUp() }
        #expect(try await Self.runEditPath(copy) == 0)
    }

    @Test func themeRedrawNeverCopiesSuppliedOutput() async throws {
        let copy = try PreviewPageCopy(); defer { copy.cleanUp() }
        #expect(try await Self.runThemePath(copy) == 0)
    }

    // MARK: S0 controls — restoring the read-back makes the marker reappear.

    /// Restoring both read-backs makes (a) and (b) red.
    @Test func restoringBothReadBacksReappearsOnBothPaths() async throws {
        let edit = try PreviewPageCopy(); defer { edit.cleanUp() }
        try edit.revertMermaidReadback(.both)
        #expect(try await Self.runEditPath(edit) >= 1, "control: edit path should copy the marker forward")

        let theme = try PreviewPageCopy(); defer { theme.cleanUp() }
        try theme.revertMermaidReadback(.both)
        #expect(try await Self.runThemePath(theme) >= 1, "control: theme path should copy the marker forward")
    }

    /// Partial-fix control: reverting only the edit-update read-back makes (b) red while (a) stays
    /// green, so the two sinks are independently load-bearing.
    @Test func revertingOnlyEditReadBackSplitsThePaths() async throws {
        let edit = try PreviewPageCopy(); defer { edit.cleanUp() }
        try edit.revertMermaidReadback(.update)
        #expect(try await Self.runEditPath(edit) >= 1, "edit path red with only :828 reverted")

        let theme = try PreviewPageCopy(); defer { theme.cleanUp() }
        try theme.revertMermaidReadback(.update)
        #expect(try await Self.runThemePath(theme) == 0, "theme path still green with only :828 reverted")
    }

    // MARK: S0b (F3) — a diagram can't lower Mermaid's security level.

    /// Renders a diagram that asks for loose mode and returns Mermaid's effective level, plus
    /// whether the diagram actually drew (so "strict" can't come from a diagram that never rendered).
    static func effectiveSecurityLevel(_ copy: PreviewPageCopy) async throws -> (level: String, drew: Bool) {
        let webView = try await loadSecurityPreview(configuration: copy.makeConfiguration())
        // A diagram asking for loose mode through an init directive, plus a `click ... call`.
        let diagram = """
        <div class="mermaid-block" data-line="1"><pre class="mermaid-source">%%{init: {"securityLevel":"loose"}}%%
        flowchart TD
          A[Node] --> B[Other]
          click A call danger()</pre><div class="mermaid-output"></div></div>
        """
        try await previewUpdate(diagram, in: webView)
        try await settleRender(webView)
        let drew = try await previewInt(webView, "document.querySelectorAll('.mermaid-block.rendered .mermaid-output svg').length") > 0
        // Mermaid 12 exposes its effective configuration through `mermaidAPI.getConfig()`.
        let level = try await previewString(webView, """
            (() => { const api = window.mermaid && window.mermaid.mermaidAPI;
              const cfg = api && (api.getConfig ? api.getConfig() : api.getSiteConfig && api.getSiteConfig());
              return cfg ? cfg.securityLevel : 'unknown'; })()
            """)
        return (level, drew)
    }

    @Test func diagramCannotLowerSecurityLevel() async throws {
        let copy = try PreviewPageCopy(); defer { copy.cleanUp() }
        let result = try await Self.effectiveSecurityLevel(copy)
        #expect(result.drew, "the directive-bearing diagram must render for this to mean anything")
        #expect(result.level == "strict")
        // renderMermaid never calls bindFunctions, so a `click ... call` has nothing to bind to.
    }

    @Test func plantingLooseMakesTheLevelControlRed() async throws {
        let copy = try PreviewPageCopy(); defer { copy.cleanUp() }
        try copy.plantLooseMermaid()
        let result = try await Self.effectiveSecurityLevel(copy)
        #expect(result.level == "loose")
    }
}
#endif
