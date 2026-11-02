// PERF15-TEMP: this whole file is temporary profiling instrumentation for mars-dawn#15.
// PERF15-TEMP: remove it (and every line marked PERF15-TEMP) once the profile is done.
#if os(macOS) // PERF15-TEMP
import Foundation // PERF15-TEMP
import OSLog // PERF15-TEMP

/// Extra export timing for mars-dawn#15. Signposts always fire (same subsystem/category as the
/// exporter's own); stderr lines (`PERF15 {json}`) only with `MARSDAWN_PERF15=1`. // PERF15-TEMP
enum Perf15 { // PERF15-TEMP
    static let enabled = ProcessInfo.processInfo.environment["MARSDAWN_PERF15"] == "1" // PERF15-TEMP
    static let origin = ContinuousClock.now // PERF15-TEMP
    static let signposter = OSSignposter(subsystem: "dev.southern-light.marsdawn-kit", category: "Performance") // PERF15-TEMP

    /// Seconds since this type was first touched (process-relative clock for stderr lines). // PERF15-TEMP
    static func now() -> Double { // PERF15-TEMP
        let d = ContinuousClock.now - origin // PERF15-TEMP
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 // PERF15-TEMP
    } // PERF15-TEMP

    /// One `PERF15 {...}` JSON line on stderr. `fields` must be JSON-serialisable. // PERF15-TEMP
    static func log(_ event: String, _ fields: [String: Any] = [:]) { // PERF15-TEMP
        guard enabled else { return } // PERF15-TEMP
        var all = fields // PERF15-TEMP
        all["event"] = event // PERF15-TEMP
        all["t"] = now() // PERF15-TEMP
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return } // PERF15-TEMP
        FileHandle.standardError.write(Data("PERF15 ".utf8) + data + Data("\n".utf8)) // PERF15-TEMP
    } // PERF15-TEMP

    struct Span { // PERF15-TEMP
        let name: StaticString // PERF15-TEMP
        let state: OSSignpostIntervalState // PERF15-TEMP
        let start: Double // PERF15-TEMP
    } // PERF15-TEMP

    static func begin(_ name: StaticString) -> Span { // PERF15-TEMP
        let start = now() // PERF15-TEMP
        return Span(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()), start: start) // PERF15-TEMP
    } // PERF15-TEMP

    /// Ends the signpost and logs `{"event": "<name>", "seconds": …, …fields}`. // PERF15-TEMP
    static func end(_ span: Span, _ fields: [String: Any] = [:]) { // PERF15-TEMP
        signposter.endInterval(span.name, span.state) // PERF15-TEMP
        var all = fields // PERF15-TEMP
        all["seconds"] = now() - span.start // PERF15-TEMP
        all["start"] = span.start // PERF15-TEMP
        log("\(span.name)", all) // PERF15-TEMP
    } // PERF15-TEMP

    /// Parses a JSON string returned by in-page instrumentation; `nil`-safe for logging. // PERF15-TEMP
    static func object(_ value: Any?) -> Any { // PERF15-TEMP
        guard let string = value as? String, let data = string.data(using: .utf8), // PERF15-TEMP
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return NSNull() } // PERF15-TEMP
        return parsed // PERF15-TEMP
    } // PERF15-TEMP

    /// Samples `NSPrintOperation.currentPage` from a background queue every few ms while the // PERF15-TEMP
    /// operation runs and records when each page number is first seen. // PERF15-TEMP
    final class PageSampler: @unchecked Sendable { // PERF15-TEMP
        private let timer: DispatchSourceTimer // PERF15-TEMP
        private let lock = NSLock() // PERF15-TEMP
        private var lastPage = Int.min // PERF15-TEMP
        private var marks: [[Double]] = [] // PERF15-TEMP  [page, t]
        private var samples = 0 // PERF15-TEMP

        init(_ read: @escaping @Sendable () -> Int) { // PERF15-TEMP
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated)) // PERF15-TEMP
            timer.schedule(deadline: .now(), repeating: .milliseconds(2)) // PERF15-TEMP
            timer.setEventHandler { [unowned self] in // PERF15-TEMP
                let page = read() // PERF15-TEMP
                let t = Perf15.now() // PERF15-TEMP
                lock.lock() // PERF15-TEMP
                samples += 1 // PERF15-TEMP
                if page != lastPage { lastPage = page; marks.append([Double(page), t]) } // PERF15-TEMP
                lock.unlock() // PERF15-TEMP
            } // PERF15-TEMP
            timer.resume() // PERF15-TEMP
        } // PERF15-TEMP

        func stop() -> (marks: [[Double]], samples: Int) { // PERF15-TEMP
            timer.cancel() // PERF15-TEMP
            lock.lock(); defer { lock.unlock() } // PERF15-TEMP
            return (marks, samples) // PERF15-TEMP
        } // PERF15-TEMP
    } // PERF15-TEMP

    /// In-page: forces a synchronous layout and returns the update's own timings. // PERF15-TEMP
    static let layoutProbeScript = """
    (() => {
      const p = window.__perf15 || {};
      const t0 = performance.now();
      const h = document.body.scrollHeight;
      p.layoutMs = performance.now() - t0;
      p.scrollHeight = h;
      p.domElements = document.getElementsByTagName("*").length;
      p.contentChildren = document.getElementById("content")?.children.length ?? null;
      p.codeBlocks = document.querySelectorAll("pre > code").length;
      p.mermaidBlocks = document.querySelectorAll(".mermaid-block").length;
      p.headings = document.querySelectorAll("#content > :is(h1, h2, h3, h4, h5, h6)").length;
      return JSON.stringify(p);
    })()
    """ // PERF15-TEMP

    /// In-page: the mermaid pass's end, read after the readiness wait. // PERF15-TEMP
    static let mermaidProbeScript = """
    JSON.stringify({ mermaidStart: window.__perf15?.mermaidStart ?? null, mermaidEnd: window.__perf15?.mermaidEnd ?? null,
      mermaidCount: window.__perf15?.mermaidCount ?? null, mermaidMs: window.__perf15?.mermaidMs ?? null,
      mermaidPerDiagramMs: window.__perf15?.mermaidPerDiagramMs ?? null, now: performance.now(),
      rendered: document.querySelectorAll(".mermaid-block.rendered").length })
    """ // PERF15-TEMP

    /// Wraps an IIFE expression so it returns its in-page duration plus `extra` (a JS expression). // PERF15-TEMP
    static func timed(_ script: String, extra: String = "null") -> String { // PERF15-TEMP
        "(() => { const __t0 = performance.now(); const __r = \(script); const __ms = performance.now() - __t0; return JSON.stringify({ ms: __ms, extra: \(extra) }); })()" // PERF15-TEMP
    } // PERF15-TEMP

    /// The readiness poll body, with its own in-page duration (callAsyncJavaScript body). // PERF15-TEMP
    static let pollScript = """
    const __t0 = performance.now();
    const diagramsReady = [...document.querySelectorAll(".mermaid-block")]
      .every((b) => (b.classList.contains("rendered") || b.classList.contains("error") || b.classList.contains("skipped")) && !b.classList.contains("stale"));
    const mathReady = document.querySelectorAll(".math-inline:not(.math-done), .math-block:not(.math-done)").length === 0;
    const imagesReady = [...document.images].every((img) => img.complete);
    const ready = diagramsReady && mathReady && imagesReady && document.fonts.status === "loaded";
    return JSON.stringify({ ready, ms: performance.now() - __t0, diagramsReady, mathReady, imagesReady, fonts: document.fonts.status });
    """ // PERF15-TEMP
} // PERF15-TEMP
#endif // PERF15-TEMP
