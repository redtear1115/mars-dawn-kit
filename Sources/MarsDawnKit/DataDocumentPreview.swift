import CoreFoundation
import Foundation
import WebKit

/// The JSON and YAML tree page (kit #128): a document shown as a collapsible tree.
///
/// A host loads `pageURL(theme:darkTheme:)` in a web view made by
/// `PreviewWebView.makeConfiguration()` **with no asset handler** (the page reads nothing but the
/// kit's own files), then shows a document with `render(update(data:kind:sequence:), in:)`. The
/// page is a page of its own, `data.html`, with a stricter Content-Security-Policy than the
/// Markdown preview: it never loads preview.js, Mermaid, highlight.js or KaTeX, and the Markdown
/// page never loads js-yaml.
///
/// Every limit below travels to the page with each update; the page has none of its own.
///
/// The page may post two messages. `errorMessageName` carries `{line, column}` of a parse error
/// (decode it with `errorPosition(fromMessageBody:lineCount:)`); `showSourceMessageName` is sent,
/// with the body `null`, by the button that every state without a tree shows, and asks the host
/// for its source view. Accept both only from the main frame; the second may arrive more than once.
public enum DataDocumentPreview {
    public enum Kind: Sendable {
        case json, yaml

        var literal: String {
            switch self {
            case .json: "json"
            case .yaml: "yaml"
            }
        }
    }

    // MARK: Limits

    /// The largest JSON file shown, checked on the bytes before they are decoded.
    public static let maximumJSONBytes = 16 * 1024 * 1024
    /// The largest YAML file shown, checked on the bytes before they are decoded; a larger one
    /// shows the over-cap state, which points to the source view. js-yaml parses in one call that
    /// can't be interrupted, so this is the bound on its time and memory, chosen from the
    /// kit-harness measurement on worst-case fixtures (kit #128). Within it no YAML text can
    /// produce more parser events than the tree can take, so there is no separate event limit.
    public static let maximumYAMLBytes = 512 * 1024
    /// The most alias occurrences in one YAML document.
    public static let maximumAliases = 100_000
    /// The deepest nesting shown, in nodes (a scalar counts as a level, as in js-yaml's
    /// `maxDepth`); for YAML also the parser's own limit. Deeper documents are "too complex".
    public static let maximumDepth = 1_000
    /// Levels opened when a document is first shown; deeper ones open on a click, one at a time.
    public static let autoExpandDepth = 8
    /// The most rows one pass draws, the first one and each click alike.
    public static let maximumRenderedNodes = 10_000
    /// The time one drawing pass may take before it stops and leaves the rest collapsed.
    public static let autoExpandBudgetMilliseconds = 200
    /// The time a YAML parse may take before the document is "too complex".
    public static let parseBudgetMilliseconds = 2_000
    /// How long `render(_:in:)` waits for the page: the parse budget, the drawing budget, and
    /// 3 s for moving the text to the page and JSON's parse, which has no budget of its own.
    public static let hostWaitMilliseconds = parseBudgetMilliseconds + autoExpandBudgetMilliseconds + 3_000

    /// Characters of a string value shown at once; the rest comes in chunks of the same size.
    static let valueDisplayCharacters = 10_000
    /// Characters of a key shown; a longer key ends in an ellipsis.
    static let keyDisplayCharacters = 1_000
    /// The largest column `errorPosition` reports: no line is longer than the largest file.
    static let maximumColumn = maximumJSONBytes

    /// The script message handler names the page posts to.
    public static let errorMessageName = "dataError"
    public static let showSourceMessageName = "dataShowSource"

    /// The page's file in the Preview folder.
    static let pageName = "data.html"

    /// The page's `limits` argument: every limit above, by the name data.js reads it under. The
    /// tree's depth limit is `maximumDepth` too; it travels separately so a test can relax one
    /// without the other.
    static var limits: [String: Int] {
        [
            "maximumJSONBytes": maximumJSONBytes,
            "maximumYAMLBytes": maximumYAMLBytes,
            "maximumAliases": maximumAliases,
            "maximumDepth": maximumDepth,
            "maximumTreeDepth": maximumDepth,
            "autoExpandDepth": autoExpandDepth,
            "maximumRenderedNodes": maximumRenderedNodes,
            "autoExpandBudgetMilliseconds": autoExpandBudgetMilliseconds,
            "parseBudgetMilliseconds": parseBudgetMilliseconds,
            "valueDisplayCharacters": valueDisplayCharacters,
            "keyDisplayCharacters": keyDisplayCharacters,
        ]
    }

    // MARK: The page

    /// `marsdawn-app://preview/data.html` with the initial theme (and dark theme) applied before
    /// first paint, as `PreviewSchemeHandler.pageURL(lightTheme:darkTheme:)` does for the preview.
    public static func pageURL(theme: PreviewTheme, darkTheme: PreviewTheme?) -> URL {
        var components = URLComponents()
        components.scheme = PreviewSchemeHandler.scheme
        components.host = "preview"
        components.path = "/" + pageName
        components.queryItems = [URLQueryItem(name: "theme", value: theme.id)]
        if let darkTheme {
            components.queryItems?.append(URLQueryItem(name: "darkTheme", value: darkTheme.id))
        }
        return components.url!
    }

    /// JavaScript that switches the page to another light/dark theme pair (no dark theme: the
    /// light one for both). The page keeps whichever one matches the current appearance and
    /// follows appearance changes by itself.
    public static func themeScript(light: PreviewTheme, dark: PreviewTheme?) -> String {
        "window.MarsDawnData && MarsDawnData.setThemes(\(PreviewWebView.jsonStringLiteral(light.id)), \(PreviewWebView.jsonStringLiteral((dark ?? light).id)));"
    }

    // MARK: Updates

    /// One update for the page: a fixed function body and the arguments it reads. The document's
    /// text is one of the arguments, never part of the script.
    public struct DataUpdate: Sendable {
        public let functionBody: String
        public let arguments: [String: any Sendable]
    }

    /// The fixed page function: it hands the arguments to the page and returns its answer.
    static let functionBody = """
    return window.MarsDawnData ? MarsDawnData.render({ text: typeof text === "string" ? text : null, \
    state: state, kind: kind, sequence: sequence, labels: labels, limits: limits }) : "failed";
    """

    /// The update that shows `data` as `kind`. Over the size limit for `kind`, the arguments hold
    /// no text at all and `state` is `"overCap"`: the size is checked on the bytes, before they
    /// are decoded. Bytes that aren't UTF-8 give `"invalidEncoding"`, also without text.
    ///
    /// `sequence` orders updates to one page: the page never replaces a newer update with an
    /// older one, and answers an older one with what it shows.
    public static func update(data: Data, kind: Kind, sequence: Int, labels: DataLabels = .preferred()) -> DataUpdate {
        update(data: data, kind: kind, sequence: sequence, labels: labels) { String(data: $0, encoding: .utf8) }
    }

    /// `update(data:kind:sequence:labels:)` with the decoder given, so a test can count decodes.
    static func update(data: Data, kind: Kind, sequence: Int, labels: DataLabels, decode: (Data) -> String?) -> DataUpdate {
        var arguments: [String: any Sendable] = [
            "kind": kind.literal,
            "sequence": sequence,
            "labels": labels.dictionary,
            "limits": limits,
        ]
        let cap = kind == .json ? maximumJSONBytes : maximumYAMLBytes
        if data.count > cap {
            arguments["state"] = "overCap"
        } else if let text = decode(data) {
            arguments["state"] = "ok"
            arguments["text"] = text
        } else {
            arguments["state"] = "invalidEncoding"
        }
        return DataUpdate(functionBody: functionBody, arguments: arguments)
    }

    // MARK: Rendering

    /// What the page shows after an update.
    public enum RenderOutcome: Sendable {
        /// The whole tree, opened to `autoExpandDepth`.
        case rendered
        /// A tree whose automatic opening stopped at `maximumRenderedNodes` rows or the time
        /// budget; the rest is collapsed, with a notice.
        case capped
        /// Too deep, too many aliases, or too slow to parse.
        case tooComplex
        /// Not valid JSON or YAML (with a position when there is one).
        case parseError
        /// Over the size limit for its kind.
        case overCap
        /// Not UTF-8.
        case invalidEncoding
        /// The page didn't answer within `hostWaitMilliseconds`.
        case timedOut
        /// The page answered with something else, threw, or its process ended.
        case failed
    }

    static func outcome(from value: Any?) -> RenderOutcome {
        switch value as? String {
        case "rendered": .rendered
        case "capped": .capped
        case "tooComplex": .tooComplex
        case "parseError": .parseError
        case "overCap": .overCap
        case "invalidEncoding": .invalidEncoding
        default: .failed
        }
    }

    /// Renders made with `render(_:in:)` that haven't resolved, per web view.
    @MainActor private static var pending: [ObjectIdentifier: [Int: Pending]] = [:]
    @MainActor private static var nextRender = 0

    private struct Pending {
        let continuation: CheckedContinuation<RenderOutcome, Never>
        let timeout: Task<Void, Never>
    }

    /// Sends `update` to the page in `webView` and waits at most `hostWaitMilliseconds` for its
    /// answer (`.timedOut` after that). The page world is used, where data.js lives.
    ///
    /// This never touches the web view's `navigationDelegate`. The host's own delegate must call
    /// `webContentTerminated(_:)` from `webViewWebContentProcessDidTerminate(_:)`, which ends every
    /// render pending on that web view as `.failed`. After `.timedOut` or `.failed`, discard the
    /// web view: its page may still be busy.
    @MainActor
    public static func render(_ update: DataUpdate, in webView: WKWebView) async -> RenderOutcome {
        let key = ObjectIdentifier(webView)
        nextRender &+= 1
        let id = nextRender
        let arguments: [String: Any] = update.arguments
        return await withCheckedContinuation { continuation in
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(hostWaitMilliseconds))
                if !Task.isCancelled { finish(key, id, .timedOut) }
            }
            pending[key, default: [:]][id] = Pending(continuation: continuation, timeout: timeout)
            webView.callAsyncJavaScript(update.functionBody, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): finish(key, id, outcome(from: value))
                case .failure: finish(key, id, .failed)
                }
            }
        }
    }

    /// Resolves one pending render, once; later calls for it do nothing.
    @MainActor
    private static func finish(_ key: ObjectIdentifier, _ id: Int, _ outcome: RenderOutcome) {
        guard let entry = pending[key]?.removeValue(forKey: id) else { return }
        if pending[key]?.isEmpty == true { pending[key] = nil }
        entry.timeout.cancel()
        entry.continuation.resume(returning: outcome)
    }

    /// Ends every render pending on `webView` as `.failed`. Call it from the host's
    /// `webViewWebContentProcessDidTerminate(_:)`.
    @MainActor
    public static func webContentTerminated(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard let entries = pending.removeValue(forKey: key) else { return }
        for entry in entries.values {
            entry.timeout.cancel()
            entry.continuation.resume(returning: .failed)
        }
    }

    // MARK: Messages from the page

    /// The position in a `dataError` message body, or nil for anything but a dictionary of exactly
    /// `line` and `column`, each a whole number (not a Boolean, not NaN or infinite), with `line`
    /// in `1...lineCount` and `column` at least 1. The column, 1-based in UTF-16 units, is clamped
    /// to `maximumColumn`; clamp it to the real line yourself.
    ///
    /// `lineCount` is the document's number of lines with CR, LF and CRLF each counted as one
    /// break, as js-yaml counts them (`lineCount(of:)`).
    public static func errorPosition(fromMessageBody body: Any, lineCount: Int) -> (line: Int, column: Int)? {
        guard let dictionary = body as? [String: Any], dictionary.count == 2,
              let line = wholeNumber(dictionary["line"]), let column = wholeNumber(dictionary["column"]),
              lineCount >= 1, (1...lineCount).contains(line), column >= 1
        else { return nil }
        return (line, min(column, max(1, maximumColumn)))
    }

    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// Lines in `text`, with CR, LF and CRLF each one break.
    static func lineCount(of text: String) -> Int {
        var lines = 1
        var afterCR = false
        for unit in text.utf16 {
            if unit == 0x0A {
                if !afterCR { lines += 1 }
                afterCR = false
            } else if unit == 0x0D {
                lines += 1
                afterCR = true
            } else {
                afterCR = false
            }
        }
        return lines
    }
}
