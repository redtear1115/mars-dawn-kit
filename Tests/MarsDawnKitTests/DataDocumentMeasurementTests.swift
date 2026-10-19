#if os(macOS)
import AppKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// The measurement the YAML limits were chosen from (kit #128, D2). Not part of the normal run:
/// set `MARSDAWN_DATA_MEASURE=1` (and optionally `MARSDAWN_DATA_MEASURE_SET` to one group name),
/// on a Mac, never on the shared CI runner. Each case loads a fresh page, sends the document with
/// every page-side limit relaxed (so the worst case reaches the parser and the tree builder), and
/// prints one `D2|` table row: the WebContent process's peak `phys_footprint` above its idle
/// footprint, the host's footprint change, the time to the page's answer, and the parse time on its
/// own (a second page). A watchdog kills that page's WebContent process (only it) at 8 GB.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["MARSDAWN_DATA_MEASURE"] == "1"))
struct DataDocumentMeasurementTests {
    nonisolated static let set = ProcessInfo.processInfo.environment["MARSDAWN_DATA_MEASURE_SET"]
    static let mebibyte = 1024 * 1024
    static let killAt: UInt64 = 8 * 1024 * 1024 * 1024

    struct Footprint { let current: UInt64; let peak: UInt64 }

    nonisolated static func footprint(_ pid: pid_t) -> Footprint? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        return Footprint(current: info.ri_phys_footprint, peak: info.ri_lifetime_max_phys_footprint)
    }

    /// Polls `pid` every 20 ms and SIGKILLs it past `killAt`. Only ever the page's own process.
    final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private(set) var killed = false
        private(set) var highest: UInt64 = 0

        init(pid: pid_t, watchOnly: Bool = false) {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let go = running; lock.unlock()
                    guard go else { return }
                    if let f = DataDocumentMeasurementTests.footprint(pid) {
                        lock.lock(); highest = max(highest, f.current); lock.unlock()
                        if !watchOnly, f.current > DataDocumentMeasurementTests.killAt {
                            kill(pid, SIGKILL)
                            lock.lock(); killed = true; running = false; lock.unlock()
                            return
                        }
                    }
                    usleep(20_000)
                }
            }
        }

        func stop() { lock.lock(); running = false; lock.unlock() }
    }

    /// `MARSDAWN_DATA_MEASURE_REAL=1`: the kit's own limits (only the byte caps opened, so a
    /// candidate size reaches the page); otherwise every parse-side limit relaxed.
    nonisolated static let realLimits = ProcessInfo.processInfo.environment["MARSDAWN_DATA_MEASURE_REAL"] == "1"

    static var relaxed: [String: Int] {
        var limits = DataDocumentPreview.limits
        if realLimits {
            limits["maximumJSONBytes"] = 1 << 40
            limits["maximumYAMLBytes"] = 1 << 40
            return limits
        }
        for name in ["maximumJSONBytes", "maximumYAMLBytes", "maximumAliases", "parseBudgetMilliseconds"] {
            limits[name] = 1 << 40
        }
        return limits
    }

    static func arguments(_ text: String, kind: String, limits: [String: Int] = relaxed) -> [String: Any] {
        ["text": text, "state": "ok", "kind": kind, "sequence": 1, "labels": DataLabels.english.dictionary, "limits": limits]
    }

    static func pid(of webView: WKWebView) -> pid_t {
        (webView.value(forKey: "_webProcessIdentifier") as? Int).map { pid_t($0) } ?? 0
    }

    /// Host footprint (this test process), current.
    static func hostFootprint() -> UInt64 { footprint(getpid())?.current ?? 0 }

    struct Row {
        let name: String, bytes: Int, outcome: String, totalMS: Double, peakMB: Double, idleMB: Double,
            hostDeltaMB: Double, parseMS: Double, constructMS: Double, events: Int, killed: Bool, pid: pid_t
    }

    static func measure(_ name: String, _ text: String, kind: String = "yaml") async throws -> Row {
        // The page's answer, its time and its footprint.
        let webView = try await DataPage.load()
        let pagePID = Self.pid(of: webView)
        try await Task.sleep(for: .milliseconds(300))
        let idle = Self.footprint(pagePID)?.current ?? 0
        let hostBefore = hostFootprint()
        let dog = Watchdog(pid: pagePID)
        let hostDog = Watchdog(pid: getpid(), watchOnly: true)
        let start = ContinuousClock.now
        let answer = try? await webView.callAsyncJavaScript(
            DataDocumentPreview.functionBody + " ", arguments: arguments(text, kind: kind), in: nil, contentWorld: .page)
        // The root level laid out: the page's answer is back and layout is forced once.
        _ = try? await webView.callAsyncJavaScript("return document.body.offsetHeight;", contentWorld: .page)
        let total = ContinuousClock.now - start
        dog.stop()
        hostDog.stop()
        let hostAfter = hostFootprint()
        let peak = max(Self.footprint(pagePID)?.peak ?? 0, dog.highest)

        // Parse alone, in a second page.
        var parseMS = -1.0, constructMS = -1.0, events = -1
        if kind == "yaml" && !dog.killed {
            let timing = try await DataPage.load()
            let tdog = Watchdog(pid: Self.pid(of: timing))
            let result = try? await timing.callAsyncJavaScript("""
            const t0 = performance.now();
            let events;
            try { events = jsyaml.parseEvents(text, { maxDepth: \(DataDocumentPreview.maximumDepth + 1) }); } catch (e) { return { failed: String(e.reason || e), parse: performance.now() - t0 }; }
            const t1 = performance.now();
            try { jsyaml.constructFromEvents(events, { source: text, schema: jsyaml.CORE_SCHEMA, json: false }); } catch (e) { return { failed: String(e.reason || e), parse: t1 - t0, events: events.length }; }
            return { parse: t1 - t0, construct: performance.now() - t1, events: events.length };
            """, arguments: ["text": text], in: nil, contentWorld: .page) as? [String: Any]
            tdog.stop()
            parseMS = result?["parse"] as? Double ?? -1
            constructMS = result?["construct"] as? Double ?? -1
            events = result?["events"] as? Int ?? -1
        }
        let mb = { (b: UInt64) in Double(b) / Double(mebibyte) }
        let row = Row(name: name, bytes: text.utf8.count, outcome: (answer as? String) ?? "(no answer)",
                      totalMS: Double(total.components.attoseconds) / 1e15 + Double(total.components.seconds) * 1000,
                      peakMB: mb(peak), idleMB: mb(idle), hostDeltaMB: (Double(max(hostAfter, hostDog.highest)) - Double(hostBefore)) / Double(mebibyte),
                      parseMS: parseMS, constructMS: constructMS, events: events, killed: dog.killed, pid: pagePID)
        print(String(format: "D2|%@%@|%.2f MiB|%@|total %.0f ms|parse %.0f ms|construct %.0f ms|events %d|WebContent peak %.0f MB (idle %.0f, +%.0f)|host peak %+.0f MB over %.0f MB|%@|pid %d",
                     Self.realLimits ? "[kit limits] " : "", row.name, Double(row.bytes) / Double(mebibyte), row.outcome, row.totalMS, row.parseMS, row.constructMS, row.events,
                     row.peakMB, row.idleMB, row.peakMB - row.idleMB, row.hostDeltaMB, Double(hostBefore) / Double(mebibyte), row.killed ? "KILLED at 8 GB" : "ok", row.pid))
        return row
    }

    // MARK: Fixtures (worst cases for js-yaml's events and the builder)

    static func repeated(_ head: String, _ unit: String, _ tail: String, bytes: Int) -> String {
        let count = max(1, (bytes - head.utf8.count - tail.utf8.count) / unit.utf8.count)
        return head + String(repeating: unit, count: count) + tail
    }

    static func shapes(bytes: Int) -> [(String, String)] {
        let deep = DataPage.nestedSequences(DataDocumentPreview.maximumDepth - 1)
        return [
            ("flow-empty [[],…]", repeated("[", "[],", "[]]", bytes: bytes)),
            ("flow-scalars [a,…]", repeated("[", "a,", "a]", bytes: bytes)),
            ("block-scalars - a", repeated("", "- a\n", "", bytes: bytes)),
            ("block-map k: v", (0..<max(1, bytes / 12)).map { "k\($0): \($0 % 10)\n" }.joined()),
            ("nested at maxDepth", repeated("", "- " + deep + "\n", "", bytes: bytes)),
            ("aliases *a", repeated("a: &a x\nb: [", "*a,", "*a]\n", bytes: bytes)),
            ("multi-doc --- a", repeated("", "--- a\n", "", bytes: bytes)),
            ("flow maps {a: [b]}", repeated("", "- {a: [b]}\n", "", bytes: bytes)),
            ("tagged !!str a", repeated("[", "!!str a,", "a]", bytes: bytes)),
            ("explicit keys ?", repeated("", "?\n", "", bytes: bytes)),
        ]
    }

    @Test func yamlShapesAtCandidateSizes() async throws {
        let sizes = (ProcessInfo.processInfo.environment["MARSDAWN_DATA_MEASURE_SIZES"] ?? "1,2,4,8")
            .split(separator: ",").compactMap { Int($0) }
        for size in sizes {
            for (name, text) in Self.shapes(bytes: size * Self.mebibyte) where Self.set == nil || Self.set == "yaml" || name.hasPrefix(Self.set ?? "") {
                _ = try await Self.measure(name, text)
            }
        }
    }

    @Test(.enabled(if: set == nil || set == "json")) func json16MiB() async throws {
        let size = 16 * Self.mebibyte
        let cases: [(String, String)] = [
            ("json wide numbers", Self.repeated("[", "1234567,", "1]", bytes: size)),
            ("json small objects", Self.repeated("[", "{\"a\":1,\"b\":[true,null]},", "{}]", bytes: size)),
            ("json long strings", Self.repeated("[", "\"" + String(repeating: "x", count: 4000) + "\",", "\"\"]", bytes: size)),
            ("json all control characters", String(repeating: "\u{1}", count: size)),
            ("json nested objects", Self.repeated("[", "{\"a\":{\"b\":{\"c\":{\"d\":[1,2,3]}}}},", "{}]", bytes: size)),
        ]
        for (name, text) in cases {
            _ = try await Self.measure(name, text, kind: "json")
        }
    }

    /// The deepest nesting the parser takes in the page before the stack runs out, for maximumDepth.
    @Test(.enabled(if: set == nil || set == "stack")) func stackDepth() async throws {
        let webView = try await DataPage.load()
        let result = try await webView.callAsyncJavaScript("""
        const fits = (n) => { try { jsyaml.parseEvents("[".repeat(n) + "]".repeat(n), { maxDepth: n + 2 }); return true; } catch (e) { return false; } };
        let low = 1, high = 1;
        while (fits(high) && high < (1 << 24)) { low = high; high *= 2; }
        while (high - low > 1) { const mid = Math.floor((low + high) / 2); if (fits(mid)) low = mid; else high = mid; }
        let jsonDepth = 0;
        try { JSON.parse("[".repeat(1000000) + "]".repeat(1000000)); jsonDepth = 1000000; } catch (e) { jsonDepth = -1; }
        return { yamlParserStack: low, jsonParse1M: jsonDepth };
        """, contentWorld: .page)
        print("D2|stack|\(String(describing: result))")
    }
}
#endif
