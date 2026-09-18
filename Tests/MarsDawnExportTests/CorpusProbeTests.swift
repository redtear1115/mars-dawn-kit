#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// TEMPORARY step-0 probe for the PDF corpus (redtear1115/mars-dawn#2); replaced by the corpus
/// before review. It asserts nothing: it prints `PROBE` lines so both CI runners report what
/// extraction, pagination and timing look like there, before the corpus fixes its assertions.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(20)))
struct CorpusProbeTests {
    static let mixed = """
    ---
    title: FMTITLE01
    ---
    # Heading HDA01

    繁體中文段落 CJKA01：這是一段測試文字，包含標點。日本語テキスト。한국어 텍스트.

    | KeyTBL01 | ValTBL02 |
    |---|---|
    | cellTBL03 | 中文TBL04 |

    - [x] doneTASK01
    - [ ] openTASK02

    > quoteQTE01

    ```swift
    let codeCODE01 = 1
    ```

    ![altIMG01](missing.png)

    ```mermaid
    flowchart LR
      A[FLOWA01] --> B[FLOWB02]
    ```

    ```mermaid
    sequenceDiagram
      SEQA01->>SEQB02: SEQMSG03
    ```

    ```mermaid
    pie title PIETITLE01
      "PIEA02" : 40
      "PIEB03" : 60
    ```

    ```mermaid
    mindmap
      root((MINDROOT01))
        MINDCHILD02
    ```

    ```mermaid
    gantt
      title GANTTTITLE01
      dateFormat YYYY-MM-DD
      section GANTTSEC02
      GANTTTASK03 :a1, 2026-01-01, 3d
    ```

    ```mermaid
    flowchart LR
      this is not valid (((
    ```

    Last paragraph ENDMARK99.
    """

    static let markers = [
        "HDA01", "CJKA01", "繁體中文段落", "這是一段測試文字", "日本語テキスト", "한국어", "KeyTBL01", "cellTBL03", "中文TBL04",
        "doneTASK01", "openTASK02", "quoteQTE01", "codeCODE01", "Image not available: missing.png",
        "FLOWA01", "FLOWB02", "SEQA01", "SEQMSG03", "PIETITLE01", "PIEA02", "MINDROOT01", "MINDCHILD02",
        "GANTTTITLE01", "GANTTTASK03", "Mermaid: Parse error", "this is not valid", "ENDMARK99",
    ]

    @Test func environment() {
        let webKit = Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        print("PROBE env os=\(os) webkit=\(webKit) config=\(config)")
    }

    @Test func extractionFacts() async throws {
        let result = try await Self.export(Self.mixed)
        let pages = result.pages
        print("PROBE mixed pages=\(pages.count) diagramErrors=\(result.diagramErrors.count) ink=\(result.ink)")
        let raw = pages.joined(separator: "\n")
        print("PROBE mixed compatibilityIdeographs=\(raw.unicodeScalars.contains { (0x2F00...0x2FDF).contains($0.value) })")
        let normalized = Self.normalize(raw)
        let missing = Self.markers.filter { !normalized.contains(Self.normalize($0)) }
        print("PROBE mixed missingMarkers=\(missing)")
        print("PROBE mixed frontMatterShown=\(normalized.contains("FMTITLE01"))")
        let order = ["ENDMARK99", "PIEA02"].map { m in pages.firstIndex { Self.normalize($0).contains(m) } ?? -1 }
        print("PROBE mixed pageOf ENDMARK99=\(order[0]) PIEA02=\(order[1])")
        for (index, page) in pages.enumerated() {
            print("PROBE mixed page\(index + 1) text=\(page.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(400))")
        }
    }

    @Test func blankTrailingPage() async throws {
        for count in [44, 45, 46] {
            var markdown = "# Lines\n\n"
            for index in 1...count { markdown += "Paragraph \(String(format: "%03d", index)).\n\n" }
            let result = try await Self.export(markdown)
            print("PROBE lines\(count) pages=\(result.pages.count) ink=\(result.ink)")
        }
    }

    @Test func timing() async throws {
        // Boundary candidates: the largest size that still renders as Markdown, for three shapes.
        let shapes: [(String, Int, (Int) -> String)] = [
            ("table", 40_000, { rows in
                var s = "# TABLE\n\n| a | b | c | d | e | f | g | h | i | j |\n|---|---|---|---|---|---|---|---|---|---|\n"
                for r in 0..<rows { s += "| " + (0..<10).map { "r\(r)c\($0)" }.joined(separator: " | ") + " |\n" }
                return s + "\nENDTABLE99\n"
            }),
            ("emphasis", 30_000, { lines in
                var s = "# EMPH\n\n"
                for l in 0..<lines { s += (0..<20).map { "*e\(l)x\($0)*" }.joined(separator: " ") + "\n\n" }
                return s + "ENDEMPH99\n"
            }),
        ]
        for (name, upper, make) in shapes {
            var low = 1, high = upper
            while low < high {   // largest n that doesn't fall back
                let mid = (low + high + 1) / 2
                if MarkdownRenderer.renderResult(make(mid)).fallback == nil { low = mid } else { high = mid - 1 }
            }
            let under = make(low), over = make(low + 1)
            print("PROBE boundary \(name) n=\(low) underBytes=\(under.utf8.count) overFallback=\(String(describing: MarkdownRenderer.renderResult(over).fallback))")
            for (label, markdown) in [("under", under), ("over", over)] {
                let prepareStart = ContinuousClock.now
                let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false, width: 505)
                do {
                    try await exporter.prepare(markdown: markdown, theme: .dawn)
                    print("PROBE boundary \(name) \(label) prepare=\(ContinuousClock.now - prepareStart)")
                } catch {
                    print("PROBE boundary \(name) \(label) prepare failed after \(ContinuousClock.now - prepareStart): \(error)")
                    continue
                }
                let start = ContinuousClock.now
                let result = try await Self.export(markdown, measureInk: false)
                print("PROBE boundary \(name) \(label) export=\(ContinuousClock.now - start) pages=\(result.pages.count)")
            }
        }
        var long = ""
        for section in 1...200 {
            long += "## Section \(section)\n\n"
            for p in 1...10 { long += "LONG\(String(format: "%04d", (section - 1) * 10 + p)) " + String(repeating: "lorem ipsum dolor sit amet ", count: 6) + "\n\n" }
        }
        let start = ContinuousClock.now
        let first = try await Self.export(long)
        let middle = ContinuousClock.now
        let second = try await Self.export(long, measureInk: false)
        print("PROBE long pages=\(first.pages.count)/\(second.pages.count) sameText=\(first.pages == second.pages) export1=\(middle - start) export2=\(ContinuousClock.now - middle) blankPages=\(first.ink.filter { $0 == 0 }.count) lastPageHasLONG2000=\(Self.normalize(first.pages.last ?? "").contains("LONG2000"))")
    }

    // MARK: Helpers

    struct Exported {
        var pages: [String]
        var ink: [Int]
        var diagramErrors: [String]
    }

    static func export(_ markdown: String, measureInk: Bool = true) async throws -> Exported {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("probe.pdf")
        let result = try await DocumentExporter.exportPDF(markdown: markdown, to: url, theme: .dawn, baseDirectory: folder, allowRemoteImages: false)
        let document = try #require(PDFDocument(url: url))
        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        let ink = measureInk ? (0..<document.pageCount).map { inkSamples(document.page(at: $0)!) } : []
        return Exported(pages: pages, ink: ink, diagramErrors: result.diagramErrors)
    }

    /// Non-white samples on a small raster of the page; 0 means the page is blank.
    static func inkSamples(_ page: PDFPage) -> Int {
        let image = page.thumbnail(of: NSSize(width: 300, height: 424), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.95 || color.greenComponent < 0.95 || color.blueComponent < 0.95 { count += 1 }
            }
        }
        return count
    }

    /// NFKC with all whitespace removed: the corpus's matching rule.
    static func normalize(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}
#endif
