#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// D5 (lint) and D6 (CSP) for the JSON and YAML page (kit #128).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DataDocumentSecurityTests {
    static let preview = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview")

    /// The exact policy of data.html (scope 1). Changing it is a decision of its own.
    static let dataPolicy = "default-src 'none'; script-src marsdawn-app:; style-src marsdawn-app:; font-src marsdawn-app:; img-src 'none'; base-uri 'none'; form-action 'none'"

    /// data.js without its `//` comments (it has no block comments, and no `//` inside a string).
    static func code() throws -> String {
        let source = try String(contentsOf: preview.appendingPathComponent("data.js"), encoding: .utf8)
        #expect(!source.contains("/*"), "data.js grew a block comment; teach the lint to strip it")
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    // MARK: D5 lint

    @Test func dataJSUsesNoHTMLOrStyleSink() throws {
        let code = try Self.code()
        #expect(code.contains("textContent") && code.contains("createElement"), "positive: the lint reads the real file")
        for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "insertAdjacentText", "document.write", "cssText", ".style",
                     "eval(", "Function(", "setTimeout(", "setInterval(", "createContextualFragment", "DOMParser", "srcdoc",
                     ".href", ".src", ".id =", ".name =", "location.assign", "window.open", "import(", "`"] {
            #expect(!code.contains(sink), "data.js uses \(sink)")
        }
        #expect(code.matches(of: /\.on[a-z]+\s*=/).isEmpty, "data.js assigns an event handler property")
    }

    /// setAttribute only with the literal names aria-expanded, type and role; dataset only for the theme.
    @Test func setAttributeOnlyFromTheAllowList() throws {
        let code = try Self.code()
        let calls = code.matches(of: /setAttribute\(/).count
        let literal = code.matches(of: #/setAttribute\("([a-z-]+)", /#).map { String($0.output.1) }
        #expect(calls > 0 && calls == literal.count, "every setAttribute names its attribute literally (\(calls) calls, \(literal.count) literal)")
        #expect(Set(literal).isSubset(of: ["aria-expanded", "type", "role"]), "\(literal)")
        let datasets = code.matches(of: /dataset\.([A-Za-z]+)/).map { String($0.output.1) }
        #expect(Set(datasets) == ["theme"], "\(datasets)")
        #expect(!code.contains("aria-label"))
    }

    // MARK: D6 CSP

    @Test func theDataPagePolicyIsExactlyTheOneString() throws {
        let html = try String(contentsOf: Self.preview.appendingPathComponent("data.html"), encoding: .utf8)
        let policies = html.matches(of: /http-equiv="Content-Security-Policy"\s+content="([^"]*)"/).map { String($0.output.1) }
        #expect(policies == [Self.dataPolicy], "\(policies)")
        // The Markdown page's policy is unchanged (CalloutCSPTests pins it); and it is not this one.
        let index = try String(contentsOf: Self.preview.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(index.contains(CalloutCSPTests.previewMeta))
    }

    /// The page as served is the file as written: the handler fills nothing into data.html.
    @Test func theServedPageCarriesThePolicyUnchanged() async throws {
        let webView = try await DataPage.load()
        let served = try await DataPage.string("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content", in: webView)
        #expect(served == Self.dataPolicy)
    }

    static let violationRecorder = """
    window.__violations = [];
    document.addEventListener('securitypolicyviolation', (e) => { window.__violations.push(e.violatedDirective + ' ' + e.blockedURI); });
    """

    /// A listener registered before the page parses sees nothing during a real YAML parse and
    /// tree; and it does see a violation when one happens (the instrument works).
    @Test func aRealYAMLParseViolatesNothing() async throws {
        let webView = try await DataPage.load(userScript: Self.violationRecorder)
        let yaml = "doc: &d {name: \"x\", list: [1, 2.5, true, null, 0x10, .inf]}\nagain: *d\nlong: |\n  text\n  more\n---\n- !!str 12\n- [a, {b: c}]\n"
        #expect(await DataPage.render(yaml, kind: .yaml, in: webView) == .rendered)
        #expect(await DataPage.render("a: !Ref x\n", kind: .yaml, in: webView, sequence: 2) == .parseError)
        try await DataPage.click("#data .data-source-button", in: webView)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await DataPage.value("window.__violations", in: webView) as? [String] == [])
        // Positive: an inline style attribute is refused by this policy and reported.
        _ = try await DataPage.value("(() => { const d = document.createElement('div'); d.innerHTML = '<span style=\"color:red\">x</span>'; document.body.append(d); return 1; })()", in: webView)
        try await Task.sleep(for: .milliseconds(300))
        let seen = try await DataPage.value("window.__violations", in: webView) as? [String] ?? []
        #expect(seen.contains { $0.hasPrefix("style-src") }, "the recorder saw \(seen)")
    }

    /// What each page asks the scheme handler for: data.html never the preview's scripts, the
    /// Markdown page never js-yaml.
    @Test func eachPageLoadsOnlyItsOwnScripts() async throws {
        let dataHandler = RecordingPreviewSchemeHandler()
        let webView = try await DataPage.load(handler: dataHandler)
        #expect(await DataPage.render("a: [1, 2]\n", kind: .yaml, in: webView) == .rendered)
        try await Task.sleep(for: .milliseconds(200))
        let dataPaths = Set(dataHandler.paths.map { $0.components(separatedBy: "?")[0] })
        #expect(dataPaths == ["/data.html", "/theme-boot.js", "/themes.css", "/data.css", "/vendor/js-yaml.umd.min.js", "/data.js"], "\(dataPaths.sorted())")

        let indexHandler = RecordingPreviewSchemeHandler()
        let index = try await DataPage.load(handler: indexHandler, url: PreviewSchemeHandler.pageURL(theme: .dawn))
        _ = try await index.evaluateJavaScript(PreviewWebView.updateScript(html: MarkdownRenderer.render("# Hi\n\n```js\nlet a = 1\n```\n"), lineCount: 4))
        try await Task.sleep(for: .milliseconds(300))
        let indexPaths = Set(indexHandler.paths.map { $0.components(separatedBy: "?")[0] })
        #expect(indexPaths.contains("/preview.js"), "positive: the recorder sees the Markdown page's scripts (\(indexPaths.sorted()))")
        #expect(!indexPaths.contains { $0.contains("js-yaml") || $0.contains("data.") })
    }
}
#endif
