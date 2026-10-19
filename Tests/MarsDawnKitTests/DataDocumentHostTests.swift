#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// The host side of the JSON and YAML page (kit #128): the update's arguments, the page URL and
/// theme script, the dataError decoder (D7) and the bounded wait (D13).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DataDocumentHostTests {
    // MARK: Update arguments

    @Test func theUpdateCarriesFixedLiteralsAndTheLimits() throws {
        let update = DataDocumentPreview.update(data: Data("{\"a\": 1}".utf8), kind: .yaml, sequence: 42, labels: .english)
        #expect(Set(update.arguments.keys) == ["text", "state", "kind", "sequence", "labels", "limits", "showsSourceButton"])
        #expect(update.arguments["showsSourceButton"] as? Bool == true)
        #expect(DataDocumentPreview.update(data: Data("1".utf8), kind: .json, sequence: 1, labels: .english, showsSourceButton: false)
            .arguments["showsSourceButton"] as? Bool == false)
        #expect(DataDocumentPreview.functionBody.contains("showsSourceButton"))
        #expect(update.arguments["kind"] as? String == "yaml")
        #expect(update.arguments["state"] as? String == "ok")
        #expect(update.arguments["sequence"] as? Int == 42)
        #expect(update.arguments["labels"] as? [String: String] == DataLabels.english.dictionary)
        #expect(update.arguments["limits"] as? [String: Int] == DataDocumentPreview.limits)
        #expect(update.functionBody == DataDocumentPreview.functionBody)
        // The text is an argument, never part of the script.
        let hostile = DataDocumentPreview.update(data: Data("\"); window.x = 1; (\"".utf8), kind: .json, sequence: 1, labels: .english)
        #expect(hostile.functionBody == DataDocumentPreview.functionBody)
        #expect(DataDocumentPreview.update(data: Data(), kind: .json, sequence: 1, labels: .english).arguments["kind"] as? String == "json")
    }

    /// Every limit the page reads is one Swift sends (data.js has none of its own).
    @Test func theLimitsAreTheSwiftConstants() {
        let limits = DataDocumentPreview.limits
        #expect(limits["maximumJSONBytes"] == 16 * 1024 * 1024)
        #expect(limits["maximumYAMLBytes"] == 384 * 1024)
        #expect(limits["maximumDepth"] == DataDocumentPreview.maximumDepth)
        #expect(limits["maximumTreeDepth"] == DataDocumentPreview.maximumDepth)
        #expect(limits["autoExpandDepth"] == 8)
        #expect(limits["maximumRenderedNodes"] == 10_000)
        #expect(limits["autoExpandBudgetMilliseconds"] == 200)
        #expect(limits["parseBudgetMilliseconds"] == DataDocumentPreview.parseBudgetMilliseconds)
        #expect(limits["maximumAliases"] == DataDocumentPreview.maximumAliases)
        #expect(DataDocumentPreview.hostWaitMilliseconds == DataDocumentPreview.parseBudgetMilliseconds + DataDocumentPreview.autoExpandBudgetMilliseconds + 3_000)
    }

    @Test func theLimitNamesMatchTheOnesThePageReads() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/data.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        let block = try #require(source.firstMatch(of: /const limitNames = \[([^\]]*)\]/)?.output.1)
        let names = Set(block.matches(of: /"([A-Za-z]+)"/).map { String($0.output.1) })
        #expect(names == Set(DataDocumentPreview.limits.keys))
    }

    @Test func pageURLAndThemeScript() {
        #expect(DataDocumentPreview.pageURL(theme: .dawn, darkTheme: nil).absoluteString == "marsdawn-app://preview/data.html?theme=dawn")
        #expect(DataDocumentPreview.pageURL(theme: .classic, darkTheme: .modern).absoluteString == "marsdawn-app://preview/data.html?theme=classic&darkTheme=modern")
        #expect(DataDocumentPreview.themeScript(light: .classic, dark: .vivid) == #"window.MarsDawnData && MarsDawnData.setThemes("classic", "vivid");"#)
        #expect(DataDocumentPreview.themeScript(light: .dawn, dark: nil) == #"window.MarsDawnData && MarsDawnData.setThemes("dawn", "dawn");"#)
    }

    // MARK: D7: the dataError decoder

    @Test func lineCountCountsCRLFAndCRLFAsOneBreakEach() {
        #expect(DataDocumentPreview.lineCount(of: "") == 1)
        #expect(DataDocumentPreview.lineCount(of: "a") == 1)
        #expect(DataDocumentPreview.lineCount(of: "a\nb") == 2)
        #expect(DataDocumentPreview.lineCount(of: "a\r\nb") == 2)
        #expect(DataDocumentPreview.lineCount(of: "a\rb\r") == 3)
        #expect(DataDocumentPreview.lineCount(of: "a\n\r\nb\n") == 4)
    }

    @Test func aValidPositionIsDecodedAndTheColumnClamped() {
        let decode = { (body: Any) in DataDocumentPreview.errorPosition(fromMessageBody: body, lineCount: 10).map { [$0.line, $0.column] } }
        #expect(decode(["line": 1, "column": 1]) == [1, 1])
        #expect(decode(["line": 10, "column": 7]) == [10, 7])
        #expect(decode(["line": NSNumber(value: 3.0), "column": NSNumber(value: 4.0)]) == [3, 4])
        #expect(decode(["line": 2, "column": DataDocumentPreview.maximumColumn + 5]) == [2, DataDocumentPreview.maximumColumn])
    }

    static func body(_ name: String) -> [String: Any] {
        switch name {
        case "line Boolean": ["line": true, "column": 1]
        case "column Boolean": ["line": 1, "column": kCFBooleanTrue!]
        case "NaN": ["line": Double.nan, "column": 1]
        case "+inf": ["line": 1, "column": Double.infinity]
        case "-inf": ["line": -Double.infinity, "column": 1]
        case "1e300": ["line": 1e300, "column": 1]
        case "fraction": ["line": 1.5, "column": 1]
        case "negative line": ["line": -1, "column": 1]
        case "negative column": ["line": 1, "column": -3]
        case "zero line": ["line": 0, "column": 1]
        case "zero column": ["line": 1, "column": 0]
        case "past the last line": ["line": 11, "column": 1]
        case "string": ["line": "1", "column": 1]
        case "extra key": ["line": 1, "column": 1, "message": "x"]
        case "missing column": ["line": 1]
        case "missing line": ["column": 1]
        case "empty": [:]
        default: ["line": 1, "column": 1]
        }
    }

    @Test(arguments: [
        "line Boolean",
        "column Boolean",
        "NaN",
        "+inf",
        "-inf",
        "1e300",
        "fraction",
        "negative line",
        "negative column",
        "zero line",
        "zero column",
        "past the last line",
        "string",
        "extra key",
        "missing column",
        "missing line",
        "empty",
    ])
    func anythingElseIsNil(name: String) {
        #expect(DataDocumentPreview.errorPosition(fromMessageBody: Self.body(name), lineCount: 10) == nil, "\(name)")
    }

    @Test func aBodyThatIsNotADictionaryIsNil() {
        for body: Any in [NSNull(), "line 1", [1, 1], 1, true] {
            #expect(DataDocumentPreview.errorPosition(fromMessageBody: body, lineCount: 10) == nil)
        }
        #expect(DataDocumentPreview.errorPosition(fromMessageBody: ["line": 1, "column": 1], lineCount: 0) == nil)
    }

    // MARK: D13: the bounded wait

    func update(body: String) -> DataDocumentPreview.DataUpdate {
        let base = DataPage.update("[1]", kind: .json)
        return DataDocumentPreview.DataUpdate(functionBody: body, arguments: base.arguments)
    }

    /// A page function that never answers. The promise is held: one nothing references is
    /// collected, and WebKit then ends the call with an error (which `render` reports as `.failed`).
    static let never = "window.__held = window.__held || []; const p = new Promise(() => {}); window.__held.push(p); return p;"
    /// A page busy for 7 s: what a parse that doesn't return looks like.
    static let busy = "const t = performance.now(); while (performance.now() - t < 7000) {} return \"rendered\";"

    /// The task's value if it finishes before `deadline`, else nil; returns at the deadline even
    /// when the task never finishes (the task keeps running).
    static func peek(_ task: Task<DataDocumentPreview.RenderOutcome, Never>, until deadline: ContinuousClock.Instant) async -> DataDocumentPreview.RenderOutcome? {
        final class Once {
            var continuation: CheckedContinuation<DataDocumentPreview.RenderOutcome?, Never>?
            func resume(_ value: DataDocumentPreview.RenderOutcome?) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in once.resume(await task.value) }
            Task { @MainActor in try? await Task.sleep(until: deadline); once.resume(nil) }
        }
    }

    @Test(arguments: ["never", "busy"])
    func aPageThatNeverAnswersTimesOutWithinTheBound(kind: String) async throws {
        let webView = try await DataPage.load()
        let bound = Duration.milliseconds(DataDocumentPreview.hostWaitMilliseconds + 500)
        let start = ContinuousClock.now
        let body = kind == "never" ? Self.never : Self.busy
        let task = Task { @MainActor in await DataDocumentPreview.render(update(body: body), in: webView) }
        let result = await Self.peek(task, until: start + bound)
        let elapsed = ContinuousClock.now - start
        if result == nil { DataDocumentPreview.webContentTerminated(webView) }
        #expect(result == .timedOut, "no answer within \(bound) (elapsed \(elapsed))")
        #expect(elapsed >= .milliseconds(DataDocumentPreview.hostWaitMilliseconds - 50))
    }

    @Test func terminationEndsAPendingRenderAsFailedAtOnce() async throws {
        let webView = try await DataPage.load()
        let task = Task { @MainActor in await DataDocumentPreview.render(update(body: Self.never), in: webView) }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        DataDocumentPreview.webContentTerminated(webView)
        let result = await Self.peek(task, until: start + .milliseconds(100))
        #expect(result == .failed, "\(String(describing: result)) after termination")
        if result == nil { _ = await task.value }
    }

    @Test func aRealTerminationReachesTheHostsDelegateAndEndsTheRender() async throws {
        final class Host: NSObject, WKNavigationDelegate {
            func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
                MainActor.assumeIsolated { DataDocumentPreview.webContentTerminated(webView) }
            }
        }
        let host = Host()
        let webView = try await DataPage.load()
        webView.navigationDelegate = host
        let pid = (webView.value(forKey: "_webProcessIdentifier") as? Int).map { pid_t($0) } ?? 0
        #expect(pid > 0)
        let task = Task { @MainActor in await DataDocumentPreview.render(update(body: Self.never), in: webView) }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        // This page's own WebContent process, which this test started; nothing else.
        kill(pid, SIGKILL)
        // WebKit ends the call with an error when the process dies, and the host's delegate calls
        // webContentTerminated: either way the render ends as failed, promptly.
        let result = await Self.peek(task, until: start + .seconds(3))
        #expect(result == .failed, "\(String(describing: result))")
        if result == nil { DataDocumentPreview.webContentTerminated(webView); _ = await task.value }
        withExtendedLifetime(host) {}
    }

    @Test(arguments: ["return \"weird\";", "return 7;", "return null;", "throw new Error(\"x\");", "return { state: \"rendered\" };", "return \"Rendered\";"])
    func anAnswerOutsideTheSetIsFailed(body: String) async throws {
        let webView = try await DataPage.load()
        #expect(await DataDocumentPreview.render(update(body: body), in: webView) == .failed)
    }

    @Test func eachFixedAnswerMapsToItsOutcome() async throws {
        let webView = try await DataPage.load()
        let map: [(String, DataDocumentPreview.RenderOutcome)] = [("rendered", .rendered), ("capped", .capped), ("tooComplex", .tooComplex),
            ("parseError", .parseError), ("overCap", .overCap), ("invalidEncoding", .invalidEncoding)]
        for (answer, expected) in map {
            #expect(await DataDocumentPreview.render(update(body: "return \"\(answer)\";"), in: webView) == expected)
        }
    }

    /// Two renders at once on one web view, with the host's own navigation delegate: both resolve,
    /// the delegate is never replaced, and navigations during and after reach it.
    @Test func overlappingRendersLeaveTheHostsDelegateAlone() async throws {
        final class Recorder: NSObject, WKNavigationDelegate {
            var finished = 0
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { MainActor.assumeIsolated { finished += 1 } }
        }
        let host = Recorder()
        let webView = try await DataPage.load()
        webView.navigationDelegate = host
        let slow = "{\"a\": [" + (0..<200_000).map(String.init).joined(separator: ",") + "]}"
        let first = Task { @MainActor in await DataPage.render(slow, kind: .json, in: webView, sequence: 1) }
        let second = Task { @MainActor in await DataPage.render("[2]", kind: .json, in: webView, sequence: 2) }
        #expect(webView.navigationDelegate === host)
        let a = await first.value
        let b = await second.value
        #expect([a, b].allSatisfy { $0 != .timedOut && $0 != .failed }, "\(a) \(b)")
        #expect(webView.navigationDelegate === host)
        // A navigation during a render, then one after.
        let during = Task { @MainActor in await DataPage.render(slow, kind: .json, in: webView, sequence: 3) }
        _ = webView.load(URLRequest(url: DataDocumentPreview.pageURL(theme: .dawn, darkTheme: nil)))
        let c = await during.value
        #expect(c != .timedOut, "\(c)")
        try await waitForLoad(webView)
        #expect(webView.navigationDelegate === host)
        _ = webView.load(URLRequest(url: DataDocumentPreview.pageURL(theme: .modern, darkTheme: nil)))
        try await waitForLoad(webView)
        #expect(host.finished >= 2, "the host delegate saw \(host.finished) navigations finish")
        #expect(webView.navigationDelegate === host)
    }

    func waitForLoad(_ webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        try await Task.sleep(for: .milliseconds(50))
        while webView.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
    }
}
#endif
