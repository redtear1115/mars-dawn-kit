#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnKit

/// https script for a document the reader runs (mars-dawn#658): what the running policy now
/// grants, and the limits it keeps. The end-to-end halves are in `HTMLDocumentEndToEndTests`
/// ("3c"); these lock the policy text, so a change to any one directive fails here by name.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLRemoteScriptPolicyTests {
    typealias Handler = HTMLDocumentSchemeHandler

    /// The sources of one directive in a policy, in order.
    private func sources(_ directive: String, in csp: String) throws -> [String] {
        let clause = try #require(csp.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(directive + " ") || $0 == directive }, "\(directive) missing")
        return clause.split(separator: " ").dropFirst().map(String.init)
    }

    /// Exactly inline and https. Not `http:` (plaintext code), not `'unsafe-eval'` (data fetched at
    /// run time must not become code), not `'strict-dynamic'`, not `marsdawn-html:` (the reader's
    /// own `.js` files), not `*`, `data:` or `blob:`.
    @Test func runningScriptSourcesAreInlineAndHTTPSOnly() throws {
        let csp = Handler.documentCSP(for: .running)
        #expect(try sources("script-src", in: csp) == ["'unsafe-inline'", "https:"])
        #expect(!csp.contains("unsafe-eval"))
        #expect(!csp.contains("strict-dynamic"))
        #expect(!csp.contains("http:"), "plaintext http anywhere in the running policy")
        #expect(!csp.contains("ws:") && !csp.contains("wss:"))
    }

    @Test func aStaticDocumentRunsNoScriptAtAll() throws {
        #expect(try sources("script-src", in: Handler.documentCSP(for: .blocked)) == ["'none'"])
        #expect(try sources("connect-src", in: Handler.documentCSP(for: .blocked)) == ["'none'"])
    }

    /// The opaque origin is what keeps the contents of the document's neighbours from its script,
    /// remote script included: `allow-scripts` and nothing else.
    @Test func theRunningSandboxGrantsScriptsAndNothingElse() throws {
        #expect(Handler.documentSandboxDirective(for: .running) == "sandbox allow-scripts")
        #expect(try sources("sandbox", in: Handler.documentCSP(for: .running)) == ["allow-scripts"])
        #expect(!Handler.documentCSP(for: .running).contains("allow-same-origin"))
        #expect(!Handler.upgradesInsecureRequests, "http is refused, not upgraded to a host nobody named")
    }

    /// Nested documents, workers, forms and plugins stay shut for remote script as for inline.
    @Test func runningKeepsEverythingButTheListedTypesShut() throws {
        let csp = Handler.documentCSP(for: .running)
        for directive in ["object-src", "frame-src", "child-src", "worker-src", "manifest-src", "form-action", "base-uri", "frame-ancestors"] {
            #expect(try sources(directive, in: csp) == ["'none'"], "\(directive)")
        }
        #expect(try sources("connect-src", in: csp) == ["https:"])
    }

    /// The reader's own `.js` never becomes a script source: the handler doesn't serve it, and the
    /// policy doesn't name the scheme it would come from.
    @Test func theReadersOwnScriptFilesAreNeverServed() throws {
        for name in ["app.js", "app.mjs", "app.cjs", "APP.JS", "data.json", "page.html", "page.xhtml"] {
            #expect(ServedFileType.entry(forFileName: name) == nil, "\(name)")
        }
        #expect(!(try sources("script-src", in: Handler.documentCSP(for: .running))).contains("marsdawn-html:"))
    }

    @Test func theRuleListVersionMovedWithTheLift() {
        #expect(HTMLContentRules.version == 4)
        #expect(HTMLContentRules.runningResourceTypes.contains("script"))
    }

    // MARK: What the bar says (copy only, never a control)

    @Test func hostsAreTheHTTPSScriptHostsFirstSeenFirstAtMostThree() {
        let html = """
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
        <script src='https://CDN.jsdelivr.net/npm/other.js'></script>
        <script src=https://unpkg.com/mermaid@11/dist/mermaid.min.js></script>
        <script src="http://plain.example/x.js"></script>
        <script src="https://user:pw@cdnjs.cloudflare.com:443/x.js"></script>
        <script src="https://fourth.example/x.js"></script>
        """
        #expect(remoteScriptHosts(html) == ["cdn.jsdelivr.net", "unpkg.com", "cdnjs.cloudflare.com"])
    }

    /// A Unicode host is left out rather than shown in a form that can imitate another name; a
    /// punycode one is shown as written. Inline-only documents name nobody.
    @Test func onlyASCIIHostNamesAreShown() {
        #expect(remoteScriptHosts("<script src=https://bücher.example/x.js></script>").isEmpty)
        #expect(remoteScriptHosts("<script src=https://xn--bcher-kva.example/x.js></script>") == ["xn--bcher-kva.example"])
        #expect(remoteScriptHosts("<script>import('https://cdn.example/x.js')</script>").isEmpty)
        #expect(remoteScriptHosts("<img src=https://cdn.example/a.png>").isEmpty)
        #expect(remoteScriptHosts("<script src=https:/cdn.example/x.js></script>").isEmpty)
    }

    /// The "It was not run" sentence is for what a running document still can't load.
    @Test func onlyNonHTTPSRemoteScriptIsRefused() {
        #expect(asksForRefusedScript("<script src=http://cdn.example/x.js></script>"))
        #expect(asksForRefusedScript("<script src=//cdn.example/x.js></script>"))
        #expect(asksForRefusedScript("<script src=wss://cdn.example/x.js></script>"))
        #expect(!asksForRefusedScript("<script src=https://cdn.example/x.js></script>"))
        #expect(!asksForRefusedScript("<script SRC = 'HTTPS://cdn.example/x.js'></script>"))
        #expect(!asksForRefusedScript("<script src=app.js></script><script>x()</script>"))
        #expect(asksForRemoteScript("<script src=https://cdn.example/x.js></script>"))
    }

    @Test func thePreparedDocumentCarriesBoth() throws {
        let prepared = try #require(HTMLDocumentText.prepareNow(Data("""
        <script src=https://cdn.example/a.js></script><script src=http://old.example/b.js></script>
        """.utf8)))
        #expect(prepared.remoteScriptHosts == ["cdn.example"])
        #expect(prepared.asksForRefusedScript)
        #expect(prepared.asksForRemoteScript)
        #expect(prepared.mightRunScript)
    }
}
#endif
