#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// What the security review read in js-yaml, checked on the vendored 5.5.0 bytes in the data page
/// itself (kit #128, scope 3). JavaScript ignores option names it doesn't know, so each limit is
/// probed directly, with nothing in between: the call with the option must throw, and the same
/// call without it must not -- a probe that can't tell the two apart fails.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DataDocumentJSYAMLProbeTests {
    private func probe(_ script: String) async throws -> [String: Any] {
        let webView = try await DataPage.load()
        let result = try await DataPage.value("""
        (() => {
          const attempt = (f) => { try { f(); return "ok"; } catch (e) { return (e && e.name ? e.name : "?") + ": " + (e && e.reason !== undefined ? e.reason : String(e)); } };
          \(script)
        })()
        """, in: webView)
        return try #require(result as? [String: Any], "the probe returned \(String(describing: result))")
    }

    @Test func theFunctionsTheTreeUsesAreThere() async throws {
        let result = try await probe("""
        return { parseEvents: typeof jsyaml.parseEvents, constructFromEvents: typeof jsyaml.constructFromEvents,
                 exception: typeof jsyaml.YAMLException, core: typeof jsyaml.CORE_SCHEMA,
                 page: typeof MarsDawnData.render };
        """)
        #expect(result["parseEvents"] as? String == "function")
        #expect(result["constructFromEvents"] as? String == "function")
        #expect(result["exception"] as? String == "function")
        #expect(result["core"] as? String == "object")
        #expect(result["page"] as? String == "function")
    }

    /// `parseEvents` honours `maxDepth`, as the page calls it for a depth limit of N (maxDepth
    /// N + 1: js-yaml counts the document as a level): N + 1 nested sequences throw, N parse; the
    /// same N + 1 without the option (js-yaml's default is 100) parse.
    @Test func parseEventsHonoursMaxDepth() async throws {
        let n = 10
        let result = try await probe("""
        const deeper = \(PreviewWebView.jsonStringLiteral(DataPage.nestedSequences(n + 1)));
        const atLimit = \(PreviewWebView.jsonStringLiteral(DataPage.nestedSequences(n)));
        return { withOption: attempt(() => jsyaml.parseEvents(deeper, { maxDepth: \(n + 1) })),
                 withoutOption: attempt(() => jsyaml.parseEvents(deeper)),
                 atLimit: attempt(() => jsyaml.parseEvents(atLimit, { maxDepth: \(n + 1) })) };
        """)
        #expect((result["withOption"] as? String)?.contains("nesting exceeded maxDepth (\(n + 1))") == true, "\(result)")
        #expect(result["withoutOption"] as? String == "ok", "\(result)")
        #expect(result["atLimit"] as? String == "ok", "\(result)")
    }

    /// A scalar is a level of its own for `maxDepth`, which the tree's depth check counts the same
    /// way: N - 1 sequences around a scalar are N nested nodes.
    @Test func aScalarCountsAsALevel() async throws {
        let result = try await probe("""
        const n = 10;
        const atLimit = "[".repeat(n - 1) + "a" + "]".repeat(n - 1);
        const deeper = "[".repeat(n) + "a" + "]".repeat(n);
        return { atLimit: attempt(() => jsyaml.parseEvents(atLimit, { maxDepth: n + 1 })),
                 deeper: attempt(() => jsyaml.parseEvents(deeper, { maxDepth: n + 1 })) };
        """)
        #expect(result["atLimit"] as? String == "ok", "\(result)")
        #expect((result["deeper"] as? String)?.contains("nesting exceeded maxDepth") == true, "\(result)")
    }

    /// `constructFromEvents` honours `maxAliases`: N+1 aliases throw with maxAliases N; without the
    /// option (default unlimited) they build.
    @Test func constructFromEventsHonoursMaxAliases() async throws {
        let n = 5
        let result = try await probe("""
        const text = "a: &x 1\\nb: [" + Array(\(n + 1)).fill("*x").join(", ") + "]\\n";
        const events = jsyaml.parseEvents(text);
        return { withOption: attempt(() => jsyaml.constructFromEvents(events, { source: text, schema: jsyaml.CORE_SCHEMA, maxAliases: \(n) })),
                 withoutOption: attempt(() => jsyaml.constructFromEvents(events, { source: text, schema: jsyaml.CORE_SCHEMA })),
                 atLimit: attempt(() => jsyaml.constructFromEvents(events, { source: text, schema: jsyaml.CORE_SCHEMA, maxAliases: \(n + 1) })) };
        """)
        #expect((result["withOption"] as? String)?.contains("aliases exceeded maxAliases (\(n))") == true, "\(result)")
        #expect(result["withoutOption"] as? String == "ok", "\(result)")
        #expect(result["atLimit"] as? String == "ok", "\(result)")
    }

    /// CORE_SCHEMA is the YAML 1.2 core schema and nothing more: no merge, omap, pairs, set,
    /// binary or timestamp. Its seven tags, by name.
    @Test func theCoreSchemaHoldsOnlyTheCoreTags() async throws {
        let result = try await probe("""
        const names = jsyaml.CORE_SCHEMA.tags.map((t) => t.tagName).sort();
        const yaml11 = jsyaml.YAML11_SCHEMA.tags.map((t) => t.tagName);
        return { names: names.join(","), yaml11HasMerge: yaml11.includes("tag:yaml.org,2002:merge") };
        """)
        let core = ["bool", "float", "int", "map", "null", "seq", "str"].map { "tag:yaml.org,2002:\($0)" }.sorted().joined(separator: ",")
        #expect(result["names"] as? String == core, "\(result)")
        // The instrument can see a merge tag where there is one.
        #expect(result["yaml11HasMerge"] as? Bool == true)
    }

    /// `json: false` makes a duplicated key an error; `json: true` would let the last one win.
    @Test func aDuplicatedKeyThrowsWithJSONFalse() async throws {
        let result = try await probe("""
        const text = "a: 1\\na: 2\\n";
        const events = jsyaml.parseEvents(text);
        return { strict: attempt(() => jsyaml.constructFromEvents(events, { source: text, schema: jsyaml.CORE_SCHEMA, json: false })),
                 lenient: attempt(() => jsyaml.constructFromEvents(events, { source: text, schema: jsyaml.CORE_SCHEMA, json: true })) };
        """)
        #expect((result["strict"] as? String)?.contains("duplicated mapping key") == true, "\(result)")
        #expect(result["lenient"] as? String == "ok", "\(result)")
    }

    /// `__proto__` becomes an own key (mapTag defines it), the prototype is untouched; an object
    /// key (a complex key) is refused.
    @Test func protoIsAnOwnKeyAndObjectKeysAreRefused() async throws {
        let result = try await probe("""
        const text = "__proto__: {polluted: 1}\\nconstructor: 2\\n";
        const doc = jsyaml.constructFromEvents(jsyaml.parseEvents(text), { source: text, schema: jsyaml.CORE_SCHEMA, json: false })[0];
        const complex = "? [a]\\n: 1\\n";
        return { own: Object.hasOwn(doc, "__proto__"), keys: Object.keys(doc).join(","),
                 prototypeIntact: Object.getPrototypeOf(doc) === Object.prototype, globalClean: ({}).polluted === undefined,
                 innerPolluted: doc.__proto__ !== null && typeof doc.__proto__ === "object" && doc.__proto__.polluted === 1,
                 complex: attempt(() => jsyaml.constructFromEvents(jsyaml.parseEvents(complex), { source: complex, schema: jsyaml.CORE_SCHEMA, json: false })) };
        """)
        #expect(result["own"] as? Bool == true, "\(result)")
        #expect(result["keys"] as? String == "__proto__,constructor", "\(result)")
        #expect(result["prototypeIntact"] as? Bool == true)
        #expect(result["globalClean"] as? Bool == true)
        #expect(result["innerPolluted"] as? Bool == true, "positive: the own __proto__ holds the document's mapping")
        #expect((result["complex"] as? String)?.contains("does not support complex keys") == true, "\(result)")
    }

    /// An unknown tag is an error with a mark (line and column); a known one (`!!str`) is not.
    @Test func anUnknownTagIsAnErrorWithAMark() async throws {
        let result = try await probe("""
        const run = (text) => { try { jsyaml.constructFromEvents(jsyaml.parseEvents(text), { source: text, schema: jsyaml.CORE_SCHEMA, json: false }); return "ok"; }
                                catch (e) { return e.name + " " + e.mark.line + ":" + e.mark.column; } };
        return { unknown: run("a: 1\\nb: !Ref thing\\n"), known: run("a: !!str 1\\n"), omap: run("x: !!omap\\n  - a: 1\\n") };
        """)
        #expect(result["unknown"] as? String == "YAMLException 1:3", "\(result)")
        #expect(result["known"] as? String == "ok", "\(result)")
        #expect(result["omap"] as? String == "YAMLException 0:3", "\(result)")
    }

    /// An alias is the anchored value itself, not a copy; an alias to an ancestor makes a cycle.
    @Test func aliasesAreByReference() async throws {
        let result = try await probe("""
        const load = (text) => jsyaml.constructFromEvents(jsyaml.parseEvents(text), { source: text, schema: jsyaml.CORE_SCHEMA, json: false })[0];
        const shared = load("a: &x {k: 1}\\nb: *x\\n");
        const cycle = load("&a [*a]\\n");
        return { same: shared.a === shared.b, cycle: cycle[0] === cycle };
        """)
        #expect(result["same"] as? Bool == true)
        #expect(result["cycle"] as? Bool == true)
    }
}
#endif
