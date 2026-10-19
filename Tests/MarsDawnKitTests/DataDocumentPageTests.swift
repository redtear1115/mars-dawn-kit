#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// The JSON and YAML page (kit #128) drawing documents: D1 rendering and default expansion, D2's
/// over-cap and wide-array behaviour, D2b limits from Swift, D4 prototype-shaped keys, D5 hostile
/// text, D7 errors on the page, D8b the source-view button, D9 sequence, D11 labels.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DataDocumentPageTests {
    /// Every drawn row in document order: nesting level, key, kind and text.
    static let describe = """
    Array.from(document.querySelectorAll('#data .data-node')).map((row) => {
      let level = 0;
      for (let at = row.parentElement; at && at.id !== 'data'; at = at.parentElement) if (at.classList.contains('data-children')) level++;
      const toggle = row.querySelector(':scope > .data-toggle');
      const head = toggle || row;
      const key = head.querySelector(':scope > .data-key');
      const value = row.querySelector(':scope > .data-value, :scope > .data-cycle');
      const kind = toggle ? (Array.from(toggle.querySelectorAll(':scope > .data-punct')).some((p) => p.textContent === '[') ? 'array' : 'object')
                 : value ? value.className.replace('data-value ', '') : '?';
      const count = toggle ? toggle.querySelector(':scope > .data-count').textContent : null;
      return { level, key: key ? key.textContent : null, kind,
               text: value ? value.textContent : count, expanded: toggle ? toggle.getAttribute('aria-expanded') : null };
    })
    """

    struct Row: Equatable, CustomStringConvertible {
        let level: Int, key: String?, kind: String, text: String?, expanded: String?
        var description: String { "\(level) \(key ?? "-") \(kind) \(text ?? "-") \(expanded ?? "")" }
    }

    static func rows(_ webView: WKWebView) async throws -> [Row] {
        let list = try await DataPage.value(describe, in: webView) as? [[String: Any]] ?? []
        return list.map {
            Row(level: $0["level"] as? Int ?? -1, key: $0["key"] as? String, kind: $0["kind"] as? String ?? "?",
                text: $0["text"] as? String, expanded: $0["expanded"] as? String)
        }
    }

    // MARK: D1

    @Test func jsonNestedRendersEveryTypeWithItsClass() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render(#"{"a": {"b": [1, "x", true, null]}, "c": 2.5, "o": {}, "l": []}"#, kind: .json, in: webView) == .rendered)
        let rows = try await Self.rows(webView)
        #expect(rows == [
            Row(level: 0, key: nil, kind: "object", text: "4 items", expanded: "true"),
            Row(level: 1, key: "a", kind: "object", text: "1 item", expanded: "true"),
            Row(level: 2, key: "b", kind: "array", text: "4 items", expanded: "true"),
            Row(level: 3, key: "0", kind: "data-number", text: "1", expanded: nil),
            Row(level: 3, key: "1", kind: "data-string", text: "\"x\"", expanded: nil),
            Row(level: 3, key: "2", kind: "data-bool", text: "true", expanded: nil),
            Row(level: 3, key: "3", kind: "data-null", text: "null", expanded: nil),
            Row(level: 1, key: "c", kind: "data-number", text: "2.5", expanded: nil),
            Row(level: 1, key: "o", kind: "object", text: "0 items", expanded: "true"),
            Row(level: 1, key: "l", kind: "array", text: "0 items", expanded: "true"),
        ], "\(rows)")
    }

    @Test func unicodeKeysAndValuesAreShownAsWritten() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render("{\"日本語\": \"値 🚀\", \"עברית\": \"שלום\"}", kind: .json, in: webView) == .rendered)
        let rows = try await Self.rows(webView)
        #expect(rows.dropFirst().map(\.key) == ["日本語", "עברית"])
        #expect(rows.dropFirst().map(\.text) == ["\"値 🚀\"", "\"שלום\""])
    }

    @Test func multiDocumentYAMLHasOneRootPerDocument() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render("a: 1\n---\nb: [x, y]\n---\nplain\n", kind: .yaml, in: webView) == .rendered)
        #expect(try await DataPage.int("document.querySelectorAll('#data .data-document').length", in: webView) == 3)
        let rows = try await Self.rows(webView)
        #expect(rows.filter { $0.level == 0 }.map(\.kind) == ["object", "object", "data-string"])
    }

    @Test func anchorsAndAliasesShowTheSharedValueAtEachPlace() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render("a: &x {k: 1}\nb: *x\n", kind: .yaml, in: webView) == .rendered)
        let rows = try await Self.rows(webView)
        #expect(rows.filter { $0.key == "k" }.count == 2)
        #expect(rows.filter { $0.kind == "data-cycle" }.isEmpty)
    }

    @Test(arguments: [
        ("42", DataDocumentPreview.Kind.json, "data-number", "42"), ("\"text\"", .json, "data-string", "\"text\""),
        ("null", .json, "data-null", "null"), ("true", .json, "data-bool", "true"),
        ("hello\n", .yaml, "data-string", "\"hello\""), ("0x10\n", .yaml, "data-number", "16"), (".inf\n", .yaml, "data-number", "Infinity"),
    ])
    func aScalarAtTheRootIsOneRow(text: String, kind: DataDocumentPreview.Kind, kindClass: String, shown: String) async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render(text, kind: kind, in: webView) == .rendered)
        #expect(try await Self.rows(webView) == [Row(level: 0, key: nil, kind: kindClass, text: shown, expanded: nil)])
    }

    /// Levels 1 to 8 open, level 9 drawn collapsed, nothing deeper; a click opens exactly one level.
    @Test func defaultExpansionStopsAtEightAndAClickOpensOneLevel() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render(DataPage.nestedSequences(12), kind: .json, in: webView) == .rendered)
        var rows = try await Self.rows(webView)
        #expect(rows.count == 9, "\(rows)")
        #expect(rows.prefix(8).allSatisfy { $0.expanded == "true" }, "\(rows)")
        #expect(rows.last?.expanded == "false")
        try await DataPage.click("#data .data-toggle[aria-expanded=false]", in: webView)
        rows = try await Self.rows(webView)
        #expect(rows.count == 10, "a click draws exactly the next level: \(rows)")
        #expect(rows[8].expanded == "true" && rows[9].expanded == "false")
        // Collapsing hides the children without drawing anything.
        try await DataPage.click("#data .data-node .data-node .data-node .data-node .data-node .data-node .data-node .data-node .data-node > .data-toggle", in: webView)
        #expect(try await DataPage.int("document.querySelectorAll('#data .data-children:not([hidden])').length", in: webView) == 8)
        #expect(try await DataPage.rows(in: webView) == 10)
    }

    @Test func enterAndSpaceToggleBecauseRowsAreButtons() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render(DataPage.nestedSequences(10), kind: .json, in: webView) == .rendered)
        let kinds = try await DataPage.value("Array.from(document.querySelectorAll('#data .data-toggle')).map((b) => b.tagName + ':' + b.type + ':' + (b.hasAttribute('aria-label') ? 'label' : ''))", in: webView) as? [String] ?? []
        #expect(!kinds.isEmpty && kinds.allSatisfy { $0 == "BUTTON:button:" }, "\(kinds)")
    }

    // MARK: D2 (behaviour; the measurement is DataDocumentMeasurementTests)

    @Test func overTheCapThereIsNoTextAndThePageSaysSo() async throws {
        for (kind, cap) in [(DataDocumentPreview.Kind.json, DataDocumentPreview.maximumJSONBytes), (.yaml, DataDocumentPreview.maximumYAMLBytes)] {
            let over = DataDocumentPreview.update(data: Data(repeating: 0x20, count: cap + 1), kind: kind, sequence: 1, labels: .english)
            #expect(over.arguments["text"] == nil)
            #expect(over.arguments["state"] as? String == "overCap")
            let at = DataDocumentPreview.update(data: Data(repeating: 0x20, count: cap), kind: kind, sequence: 1, labels: .english)
            #expect((at.arguments["text"] as? String)?.utf8.count == cap)
            #expect(at.arguments["state"] as? String == "ok")
            let webView = try await DataPage.load()
            #expect(await DataDocumentPreview.render(over, in: webView) == .overCap)
            let size = kind == .json ? "16" : "0.5"
            #expect(try await DataPage.messageText(in: webView) == DataLabels.english.overCap.replacingOccurrences(of: "{size}", with: size))
            #expect(try await DataPage.int("document.querySelectorAll('#data .data-source-button').length", in: webView) == 1)
        }
    }

    /// The size is checked before the bytes are decoded: over the cap, nothing is decoded.
    @Test func overTheCapNothingIsDecoded() {
        var decodes = 0
        let decode: (Data) -> String? = { decodes += 1; return String(data: $0, encoding: .utf8) }
        _ = DataDocumentPreview.update(data: Data(repeating: 0x20, count: DataDocumentPreview.maximumJSONBytes + 1), kind: .json, sequence: 1, labels: .english, decode: decode)
        _ = DataDocumentPreview.update(data: Data(repeating: 0x20, count: DataDocumentPreview.maximumYAMLBytes + 1), kind: .yaml, sequence: 1, labels: .english, decode: decode)
        #expect(decodes == 0)
        _ = DataDocumentPreview.update(data: Data("{}".utf8), kind: .json, sequence: 1, labels: .english, decode: decode)
        #expect(decodes == 1, "positive: an update under the cap decodes once")
    }

    @Test func invalidUTF8IsItsOwnStateWithoutText() async throws {
        let update = DataDocumentPreview.update(data: Data([0x7B, 0xFF, 0x7D]), kind: .json, sequence: 1, labels: .english)
        #expect(update.arguments["text"] == nil)
        #expect(update.arguments["state"] as? String == "invalidEncoding")
        let webView = try await DataPage.load()
        #expect(await DataDocumentPreview.render(update, in: webView) == .invalidEncoding)
        #expect(try await DataPage.messageText(in: webView) == DataLabels.english.invalidEncoding)
    }

    /// A million numbers: the first pass stops at the row cap with the notice, and "Show more"
    /// draws the next part within 100 ms.
    @Test func aWideArrayIsCappedAndShowMoreIsQuick() async throws {
        let text = "[" + (0..<1_000_000).map { String($0 % 1000) }.joined(separator: ",") + "]"
        let webView = try await DataPage.load()
        let outcome = await DataPage.render(text, kind: .json, in: webView)
        #expect(outcome == .capped)
        #expect(try await DataPage.string("(document.querySelector('#data .data-notice') || {}).textContent", in: webView) == DataLabels.english.expansionStopped)
        let first = try await DataPage.rows(in: webView)
        #expect(first <= DataDocumentPreview.maximumRenderedNodes && first > 100)
        let ms = try await DataPage.value("(() => { const b = document.querySelector('#data .data-more'); const t = performance.now(); b.click(); return performance.now() - t; })()", in: webView) as? Double ?? 999
        #expect(ms < 100, "Show more took \(ms) ms")
        #expect(try await DataPage.rows(in: webView) > first)
    }

    // MARK: D2b

    /// The page's limits are the ones Swift sends: a small row cap is where the page stops.
    @Test func thePageStopsAtTheRowCapItIsSent() async throws {
        let webView = try await DataPage.load()
        let text = "[" + (0..<100).map(String.init).joined(separator: ",") + "]"
        #expect(await DataPage.render(text, kind: .json, in: webView, limits: ["maximumRenderedNodes": 7]) == .capped)
        #expect(try await DataPage.rows(in: webView) == 7)
        #expect(await DataPage.render(text, kind: .json, in: webView, sequence: 2, limits: ["maximumRenderedNodes": 30]) == .capped)
        #expect(try await DataPage.rows(in: webView) == 30)
        #expect(await DataPage.render(text, kind: .json, in: webView, sequence: 3) == .rendered)
        #expect(try await DataPage.rows(in: webView) == 101)
    }

    @Test func missingOrBrokenLimitsDrawNothing() async throws {
        let webView = try await DataPage.load()
        var update = DataPage.update("[1]", kind: .json)
        var arguments = update.arguments
        var limits = DataDocumentPreview.limits
        limits.removeValue(forKey: "maximumRenderedNodes")
        arguments["limits"] = limits
        update = DataDocumentPreview.DataUpdate(functionBody: update.functionBody, arguments: arguments)
        #expect(await DataDocumentPreview.render(update, in: webView) == .failed)
        #expect(await DataPage.render("[1]", kind: .json, in: webView, sequence: 2, limits: ["maximumRenderedNodes": 0]) == .failed)
    }

    // MARK: D4

    static let shapedKeys = ["__proto__", "constructor", "prototype", "length", "toString", "hasOwnProperty"]

    @Test(arguments: [DataDocumentPreview.Kind.json, .yaml])
    func prototypeShapedKeysAreText(kind: DataDocumentPreview.Kind) async throws {
        let text = kind == .json
            ? #"{"__proto__": {"polluted": 1}, "constructor": 2, "prototype": 3, "length": 4294967295, "toString": "s", "hasOwnProperty": null}"#
            : "__proto__: {polluted: 1}\nconstructor: 2\nprototype: 3\nlength: 4294967295\ntoString: s\nhasOwnProperty: null\n"
        let webView = try await DataPage.load()
        let before = try await DataPage.value("JSON.stringify([Object.getOwnPropertyNames(Object.prototype).sort(), Object.getOwnPropertyNames(window).sort(), Object.getOwnPropertyNames(Array.prototype).sort()])", in: webView) as? String
        #expect(await DataPage.render(text, kind: kind, in: webView) == .rendered)
        let rows = try await Self.rows(webView)
        #expect(rows.filter { $0.level == 1 }.map(\.key) == Self.shapedKeys, "\(rows)")
        #expect(rows.first?.text == "6 items")
        #expect(rows.contains(Row(level: 2, key: "polluted", kind: "data-number", text: "1", expanded: nil)))
        let after = try await DataPage.value("JSON.stringify([Object.getOwnPropertyNames(Object.prototype).sort(), Object.getOwnPropertyNames(window).sort(), Object.getOwnPropertyNames(Array.prototype).sort()])", in: webView) as? String
        #expect(before != nil && before == after)
        #expect(try await DataPage.value("({}).polluted === undefined && Object.prototype.toString.call([]) === '[object Array]'", in: webView) as? Bool == true)
    }

    @Test func anObjectWithALengthIsNotAnArray() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render(#"{"length": 4294967295}"#, kind: .json, in: webView) == .rendered)
        #expect(try await Self.rows(webView) == [
            Row(level: 0, key: nil, kind: "object", text: "1 item", expanded: "true"),
            Row(level: 1, key: "length", kind: "data-number", text: "4294967295", expanded: nil),
        ])
    }

    // MARK: D5

    static let hostile = ["<img src=x onerror=window.__pwned=1>", "</script><script>window.__pwned=2</script>", "javascript:window.__pwned=3", "\u{202E}evil\u{202C}"]

    /// Elements and classes the builder makes; anything else in #data came from the document.
    static let domWalk = """
    (() => {
      const tags = new Set(['DIV', 'SPAN', 'BUTTON', 'P']);
      const classes = new Set(['data-node', 'data-document', 'data-leaf', 'data-toggle', 'data-children', 'data-key', 'data-index', 'data-punct', 'data-count',
        'data-value', 'data-string', 'data-number', 'data-bool', 'data-null', 'data-cycle', 'data-more', 'data-panel', 'data-notice', 'data-message',
        'data-message-text', 'data-error', 'data-guidance', 'data-source-button']);
      const attributes = new Set(['class', 'type', 'aria-expanded', 'role', 'hidden']);
      const foreign = [];
      for (const el of document.getElementById('data').querySelectorAll('*')) {
        if (!tags.has(el.tagName)) foreign.push('tag ' + el.tagName);
        for (const c of el.classList) if (!classes.has(c)) foreign.push('class ' + c);
        for (const a of el.attributes) if (!attributes.has(a.name)) foreign.push('attribute ' + a.name);
      }
      return { foreign, links: document.querySelectorAll('a').length, pwned: window.__pwned === undefined ? 0 : window.__pwned };
    })()
    """

    @Test(arguments: [DataDocumentPreview.Kind.json, .yaml])
    func hostileTextIsTextOnly(kind: DataDocumentPreview.Kind) async throws {
        let pairs = Self.hostile.enumerated().map { (index, value) in (value + "-key\(index)", value) }
        let text: String
        if kind == .json {
            let object = Dictionary(uniqueKeysWithValues: pairs)
            text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        } else {
            text = pairs.map { "\(PreviewWebView.jsonStringLiteral($0.0)): \(PreviewWebView.jsonStringLiteral($0.1))" }.joined(separator: "\n") + "\n"
        }
        let webView = try await DataPage.load()
        #expect(await DataPage.render(text, kind: kind, in: webView) == .rendered)
        try await Task.sleep(for: .milliseconds(200))
        let walk = try #require(try await DataPage.value(Self.domWalk, in: webView) as? [String: Any])
        #expect((walk["foreign"] as? [String])?.isEmpty == true, "\(walk)")
        #expect(walk["links"] as? Int == 0)
        #expect(walk["pwned"] as? Int == 0)
        let rows = try await Self.rows(webView)
        #expect(Set(rows.dropFirst().compactMap(\.key)) == Set(pairs.map(\.0)))
        #expect(Set(rows.dropFirst().compactMap(\.text)) == Set(pairs.map { "\"\($0.1)\"" }))
    }

    @Test func longValuesAndKeysAreCut() async throws {
        let long = String(repeating: "v", count: 25_000)
        let key = String(repeating: "k", count: 1_500)
        let webView = try await DataPage.load()
        #expect(await DataPage.render("{\"\(key)\": \"\(long)\"}", kind: .json, in: webView) == .rendered)
        var rows = try await Self.rows(webView)
        #expect(rows[1].key == String(repeating: "k", count: 1_000) + "\u{2026}")
        #expect(rows[1].text == "\"" + String(repeating: "v", count: 10_000) + "\u{2026}")
        #expect(try await DataPage.string("document.querySelector('#data .data-more').textContent", in: webView) == "Show 15000 More")
        try await DataPage.click("#data .data-more", in: webView)
        rows = try await Self.rows(webView)
        #expect(rows[1].text == "\"" + String(repeating: "v", count: 20_000) + "\u{2026}")
        try await DataPage.click("#data .data-more", in: webView)
        rows = try await Self.rows(webView)
        #expect(rows[1].text == "\"" + long + "\"")
        #expect(try await DataPage.int("document.querySelectorAll('#data .data-more').length", in: webView) == 0)
    }

    // MARK: D7 (the page; the decoder's own tests are in DataDocumentHostTests)

    struct ErrorCase: Sendable, CustomTestStringConvertible {
        let text: String, kind: DataDocumentPreview.Kind, line: Int, column: Int
        var testDescription: String { "\(kind) \(text.debugDescription)" }
    }

    @Test(arguments: [
        ErrorCase(text: "{\n  \"a\": 1\n  \"b\": 2\n}", kind: .json, line: 3, column: 6),
        ErrorCase(text: "[1, 2", kind: .json, line: 1, column: 6),
        ErrorCase(text: "a: [1, 2\nb: 3\n", kind: .yaml, line: 2, column: 1),
        ErrorCase(text: "a: 1\na: 2\n", kind: .yaml, line: 2, column: 1),
        ErrorCase(text: "a: 1\nb: !Ref thing\n", kind: .yaml, line: 2, column: 4),
    ])
    func aParseErrorShowsAndPostsItsPosition(_ error: ErrorCase) async throws {
        let recorder = RecordingMessageHandler()
        let webView = try await DataPage.load(messageHandlers: [DataDocumentPreview.errorMessageName: recorder])
        #expect(await DataPage.render(error.text, kind: error.kind, in: webView) == .parseError)
        let format = error.kind == .json ? "JSON" : "YAML"
        #expect(try await DataPage.messageText(in: webView) == DataPage.parseErrorAt(format, error.line, error.column))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.bodies.count == 1)
        let body = try #require(recorder.bodies.first as? [String: Any])
        #expect(Set(body.keys) == ["line", "column"])
        #expect(body["line"] as? Int == error.line && body["column"] as? Int == error.column)
        let lines = DataDocumentPreview.lineCount(of: error.text)
        #expect(DataDocumentPreview.errorPosition(fromMessageBody: body, lineCount: lines).map { [$0.line, $0.column] } == [error.line, error.column])
    }

    /// JSON that YAML accepts has no position to give: the error says so and nothing is posted.
    @Test func jsonThatYAMLAcceptsHasNoPosition() async throws {
        let recorder = RecordingMessageHandler()
        let webView = try await DataPage.load(messageHandlers: [DataDocumentPreview.errorMessageName: recorder])
        #expect(await DataPage.render(#"{"a": 1,}"#, kind: .json, in: webView) == .parseError)
        #expect(try await DataPage.messageText(in: webView) == DataLabels.english.parseError.replacingOccurrences(of: "{format}", with: "JSON"))
        #expect(try await DataPage.rows(in: webView) == 0, "what YAML parsed is never shown")
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.bodies.isEmpty)
    }

    /// Invalid JSON over the YAML cap is not re-parsed for a position.
    @Test func invalidJSONOverTheYAMLCapHasNoPosition() async throws {
        let recorder = RecordingMessageHandler()
        let webView = try await DataPage.load(messageHandlers: [DataDocumentPreview.errorMessageName: recorder])
        let text = "[" + String(repeating: "1,", count: DataDocumentPreview.maximumYAMLBytes / 2) + "x]"
        #expect(await DataPage.render(text, kind: .json, in: webView) == .parseError)
        #expect(try await DataPage.messageText(in: webView) == DataLabels.english.parseError.replacingOccurrences(of: "{format}", with: "JSON"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.bodies.isEmpty)
    }

    // MARK: D8b

    @Test(arguments: ["tooComplex", "overCap", "parseError"])
    func everyStateWithoutATreeOffersTheSourceView(state: String) async throws {
        let recorder = RecordingMessageHandler()
        let webView = try await DataPage.load(messageHandlers: [DataDocumentPreview.showSourceMessageName: recorder])
        let outcome: DataDocumentPreview.RenderOutcome
        switch state {
        case "tooComplex": outcome = await DataPage.render(DataPage.nestedSequences(DataDocumentPreview.maximumDepth + 1), kind: .json, in: webView)
        case "overCap": outcome = await DataDocumentPreview.render(DataDocumentPreview.update(data: Data(count: DataDocumentPreview.maximumYAMLBytes + 1), kind: .yaml, sequence: 1, labels: .english), in: webView)
        default: outcome = await DataPage.render("[1,", kind: .json, in: webView)
        }
        #expect("\(outcome)" == state)
        #expect(try await DataPage.string("document.querySelector('#data .data-guidance').textContent", in: webView) == DataLabels.english.showSourceGuidance)
        #expect(try await DataPage.string("document.querySelector('#data .data-source-button').textContent", in: webView) == DataLabels.english.showSourceButton)
        try await DataPage.click("#data .data-source-button", in: webView)
        try await DataPage.click("#data .data-source-button", in: webView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.bodies.count == 2)
        #expect(recorder.bodies.allSatisfy { $0 is NSNull }, "\(recorder.bodies)")
        #expect(recorder.mainFrame.allSatisfy { $0 })
    }

    /// A host without a source view (Quick Look) passes showsSourceButton: false: the guidance
    /// line stays, the button is not drawn, in every state without a tree.
    @Test(arguments: ["tooComplex", "overCap", "parseError", "invalidEncoding"])
    func aHostCanLeaveTheButtonOut(state: String) async throws {
        let webView = try await DataPage.load()
        let data: Data
        let kind: DataDocumentPreview.Kind
        switch state {
        case "tooComplex": (data, kind) = (Data(DataPage.nestedSequences(DataDocumentPreview.maximumDepth + 1).utf8), .json)
        case "overCap": (data, kind) = (Data(count: DataDocumentPreview.maximumYAMLBytes + 1), .yaml)
        case "invalidEncoding": (data, kind) = (Data([0xFF]), .yaml)
        default: (data, kind) = (Data("[1,".utf8), .json)
        }
        for (sequence, shows) in [(1, false), (2, true), (3, false)] {
            let update = DataDocumentPreview.update(data: data, kind: kind, sequence: sequence, labels: .english, showsSourceButton: shows)
            #expect("\(await DataDocumentPreview.render(update, in: webView))" == state)
            #expect(try await DataPage.string("document.querySelector('#data .data-guidance').textContent", in: webView) == DataLabels.english.showSourceGuidance)
            #expect(try await DataPage.int("document.querySelectorAll('#data .data-source-button, #data button').length", in: webView) == (shows ? 1 : 0),
                    "\(state), showsSourceButton \(shows)")
        }
    }

    @Test func withNoHandlerTheButtonThrowsNothing() async throws {
        let webView = try await DataPage.load(userScript: "window.__errors = 0; window.addEventListener('error', () => { window.__errors++; });")
        #expect(await DataPage.render("[1,", kind: .json, in: webView) == .parseError)
        try await DataPage.click("#data .data-source-button", in: webView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await DataPage.int("window.__errors", in: webView) == 0)
    }

    // MARK: D9

    @Test func anOlderUpdateNeverReplacesANewerOne() async throws {
        let webView = try await DataPage.load()
        #expect(await DataPage.render("[\"newer\"]", kind: .json, in: webView, sequence: 2) == .rendered)
        #expect(await DataPage.render("[\"older\", \"x\"]", kind: .json, in: webView, sequence: 1) == .rendered)
        #expect(try await Self.rows(webView).last?.text == "\"newer\"")
        #expect(await DataPage.render("[1,", kind: .json, in: webView, sequence: 1) == .rendered, "the older one answers with what is shown")
        #expect(await DataPage.render("[\"newest\"]", kind: .json, in: webView, sequence: 3) == .rendered)
        #expect(try await Self.rows(webView).last?.text == "\"newest\"")
    }

    // MARK: D11 (drawn labels)

    static let marked = DataLabels(
        itemCount: "IC{n}", itemCountOne: "ONE", showMore: "SM{n}", cycle: "CY", expansionStopped: "ES", tooComplex: "TC", overCap: "OC{size}",
        invalidEncoding: "IE", parseErrorAt: "PA{format}|{line}|{column}", parseError: "PE{format}", showSourceGuidance: "SG", showSourceButton: "SB"
    )

    @Test func everyLabelIsDrawnInItsStateFromThePassedLabels() async throws {
        let labels = Self.marked
        func page(_ text: String, _ kind: DataDocumentPreview.Kind, limits: [String: Int] = [:]) async throws -> (DataDocumentPreview.RenderOutcome, String) {
            let webView = try await DataPage.load()
            let outcome = await DataPage.render(text, kind: kind, in: webView, limits: limits, labels: labels)
            return (outcome, try await DataPage.string("document.getElementById('data').textContent", in: webView))
        }
        var (outcome, text) = try await page("&a [*a, [1, 2, 3]]\n", .yaml, limits: ["maximumRenderedNodes": 4])
        #expect(outcome == .capped)
        #expect(text.contains("IC2") && text.contains("CY") && text.contains("ES") && text.contains("SM"), "\(text)")
        (outcome, text) = try await page("[[1]]", .json)
        #expect(outcome == .rendered && text.contains("ONE") && !text.contains("IC1"), "\(text)")
        (outcome, text) = try await page(DataPage.nestedSequences(DataDocumentPreview.maximumDepth + 1), .json)
        #expect(outcome == .tooComplex && text.hasPrefix("TCSGSB"), "\(text)")
        (outcome, text) = try await page("[1, 2", .json)
        #expect(outcome == .parseError && text.hasPrefix("PAJSON|1|6SGSB"), "\(text)")
        (outcome, text) = try await page(#"{"a": 1,}"#, .json)
        #expect(outcome == .parseError && text.hasPrefix("PEJSONSGSB"), "\(text)")
        let webView = try await DataPage.load()
        #expect(await DataDocumentPreview.render(DataDocumentPreview.update(data: Data(count: DataDocumentPreview.maximumJSONBytes + 1), kind: .json, sequence: 1, labels: labels), in: webView) == .overCap)
        #expect(try await DataPage.string("document.getElementById('data').textContent", in: webView) == "OC16SGSB")
        #expect(await DataDocumentPreview.render(DataDocumentPreview.update(data: Data([0xC3, 0x28]), kind: .yaml, sequence: 2, labels: labels), in: webView) == .invalidEncoding)
        #expect(try await DataPage.string("document.getElementById('data').textContent", in: webView) == "IESGSB")
    }
}

#endif
