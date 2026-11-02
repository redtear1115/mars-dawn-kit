#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// `marsdawn export --format png`'s renderer on a real page (kit #243): a document with a table,
/// a Mermaid diagram, math and an image comes out as the page lays it out, pixel for pixel where
/// the page says each one is; a part of it (`lines`) shows only its blocks; a long one is cut
/// between blocks.
///
/// The pixel checks here hold on any Mac: they compare the PNG with the page's own layout and
/// colours, not with a stored image. The stored-image comparison is `golden`, which runs only
/// under `MARSDAWN_PNG_GOLDENS=1` on the machine the golden was recorded on (rendering differs by
/// macOS build).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DocumentImageRenderTests {
    /// Written next to `image.png` (a solid red square) in a scratch folder.
    static let markdown = """
    # Mixed

    Some text before the table.

    | Name | Value |
    |---|---|
    | alpha | 1 |
    | bravo | 2 |

    ```mermaid
    graph TD
      A --> B
    ```

    $$
    E = mc^2
    $$

    ![red](image.png)

    ## Broken

    ```mermaid
    notadiagram here
    ```

    The end.
    """

    static let red = [255, 0, 0]

    /// An 80 × 80 PNG of pure red (no colour profile, so read as sRGB).
    static let redSquare = "iVBORw0KGgoAAAANSUhEUgAAAFAAAABQCAIAAAABc2X6AAAAd0lEQVR4nO3PMRHAQBDEsONPOumewhbWjAFY992l2h8AAwMDAwMDZ9ofAAMDAwMDA2faHwADAwMDAwNn2h8AAwMDAwMDZ9ofAAMDAwMDA2faHwADAwMDAwNn2h8AAwMDAwMDZ9ofAAMDAwMDA2faHwADAwMDA79+wOboaXDAFhsAAAAASUVORK5CYII="

    /// A scratch folder with the document's image in it.
    static func folder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-png-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(Data(base64Encoded: Self.redSquare)).write(to: folder.appendingPathComponent("image.png"))
        return folder
    }

    /// Where the page put each thing, in CSS pixels from the top of the page.
    struct Rect: Decodable { let x: Double, y: Double, width: Double, height: Double }

    static func rect(_ selector: String, in webView: WKWebView) async throws -> Rect? {
        let json = try await webView.evaluateJavaScript("""
        (() => { const el = document.querySelector(\(String(reflecting: selector)));
          if (!el) return "null";
          const r = el.getBoundingClientRect();
          return JSON.stringify({x: r.left + window.scrollX, y: r.top + window.scrollY, width: r.width, height: r.height}); })()
        """) as? String ?? "null"
        return try JSONDecoder().decode(Rect?.self, from: Data(json.utf8))
    }

    static func background(_ webView: WKWebView) async throws -> [Int] {
        let css = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String ?? ""
        let numbers = css.matches(of: /[\d.]+/).compactMap { Double($0.output) }
        return numbers.prefix(3).map { Int($0.rounded()) }
    }

    static func pixels(_ png: Data) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(data: png))
        try #require(bitmap.samplesPerPixel >= 3 && bitmap.bitsPerSample == 8)
        return bitmap
    }

    static func sample(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
        var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&samples, atX: x, y: y)
        return Array(samples.prefix(3))
    }

    static func differs(_ a: [Int], _ b: [Int], by tolerance: Int = 12) -> Bool {
        zip(a, b).contains { abs($0 - $1) > tolerance }
    }

    /// The share of pixels inside `rect` that aren't the page background.
    static func ink(_ bitmap: NSBitmapImageRep, _ rect: Rect, background: [Int]) -> Double {
        let x0 = max(Int(rect.x), 0), y0 = max(Int(rect.y), 0)
        let x1 = min(Int(rect.x + rect.width), bitmap.pixelsWide), y1 = min(Int(rect.y + rect.height), bitmap.pixelsHigh)
        guard x1 > x0, y1 > y0 else { return 0 }
        var inked = 0, total = 0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                total += 1
                if differs(sample(bitmap, x, y), background) { inked += 1 }
            }
        }
        return Double(inked) / Double(total)
    }

    @Test(arguments: ThemePreviewRenderer.Appearance.allCases)
    func everyBlockIsDrawnWhereThePageSaysItIs(_ appearance: ThemePreviewRenderer.Appearance) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var rects: [String: Rect] = [:]
        var background: [Int] = []
        var pageHeight = 0
        let result = try await DocumentImageRenderer.render(
            markdown: Self.markdown, theme: .dawn, appearance: appearance, width: 1000, baseDirectory: folder,
            calloutTitles: .english
        ) { webView in
            for (name, selector) in ["table": "#content table", "diagram": ".mermaid-output svg", "math": ".katex-display", "image": "#content img"] {
                rects[name] = try await Self.rect(selector, in: webView)
            }
            background = try await Self.background(webView)
            pageHeight = try await webView.evaluateJavaScript("document.documentElement.scrollHeight") as? Int ?? 0
        }

        #expect(result.images.count == 1)
        let image = try #require(result.images.first)
        #expect(image.width == 1000)
        #expect(image.height == pageHeight, "the image is the page, no taller and no shorter")
        #expect(image.firstLine == 1 && image.lastLine == DocumentImageRenderer.lineCount(Self.markdown))
        let bitmap = try Self.pixels(image.png)
        #expect(bitmap.pixelsWide == 1000 && bitmap.pixelsHigh == image.height)

        // The background is the theme's, light or dark.
        try #require(background.count == 3)
        #expect(!Self.differs(Self.sample(bitmap, 5, 5), background, by: 3), "corner \(Self.sample(bitmap, 5, 5)) vs page \(background)")
        let luminance = background.reduce(0, +) / 3
        #expect(appearance == .dark ? luminance < 80 : luminance > 200, "\(appearance) background \(background)")

        // Each block is drawn where the page put it: ink inside its rect.
        for name in ["table", "diagram", "math", "image"] {
            let rect = try #require(rects[name], "\(name) is on the page")
            #expect(rect.width > 10 && rect.height > 10, "\(name) \(rect)")
            // A display formula's box is the column's width, and E = mc² fills little of it.
            let least = name == "math" ? 0.005 : 0.02
            #expect(Self.ink(bitmap, rect, background: background) > least, "\(name) has ink at \(rect)")
        }
        // The image is the red square, at its place.
        let picture = try #require(rects["image"])
        let middle = Self.sample(bitmap, Int(picture.x + picture.width / 2), Int(picture.y + picture.height / 2))
        #expect(!Self.differs(middle, Self.red, by: 3), "image centre \(middle)")

        // The broken diagram is reported, with its fence's line.
        #expect(result.diagramErrors.count == 1)
        #expect(result.diagramErrors.first?.fenceLine == 23)
        #expect(result.oversizedBlocks.isEmpty)
    }

    @Test func linesShowOnlyTheirBlocks() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var shown: [String] = []
        // Lines 7–8 are inside the table: the whole table is shown, and nothing else.
        let result = try await DocumentImageRenderer.render(
            markdown: Self.markdown, theme: .dawn, width: 1000, baseDirectory: folder, lines: 7...8, calloutTitles: .english
        ) { webView in
            let json = try await webView.evaluateJavaScript(
                #"JSON.stringify([...document.getElementById("content").children].filter((el) => el.style.display !== "none").map((el) => el.tagName))"#
            ) as? String ?? "[]"
            shown = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        }
        #expect(shown == ["TABLE"], "\(shown)")
        let image = try #require(result.images.first)
        #expect(result.images.count == 1)
        #expect(image.firstLine == 5 && image.lastLine == 9, "the table's own lines, to the line before the next block")
        #expect(image.height < 400)
        #expect(result.diagramErrors.isEmpty, "the broken diagram isn't in the lines shown")
    }

    @Test func aLongDocumentIsCutIntoImagesBetweenBlocks() async throws {
        var markdown = "# Long\n\n"
        for section in 1...8 {
            markdown += "## Section \(section)\n\n| k | v |\n|---|---|\n"
            markdown += (1...30).map { "| row\($0) | \($0) |" }.joined(separator: "\n") + "\n\n```\n"
            markdown += (1...30).map { "code line \($0)" }.joined(separator: "\n") + "\n```\n\n"
        }
        var blocks: [(top: Int, bottom: Int)] = []
        let result = try await DocumentImageRenderer.render(
            markdown: markdown, theme: .dawn, width: 800, baseDirectory: nil, calloutTitles: .english, maxHeight: 3000
        ) { webView in
            let json = try await webView.evaluateJavaScript(#"""
            JSON.stringify([...document.querySelectorAll("#content table, #content pre")].map((el) => {
              const r = el.getBoundingClientRect(); return [Math.floor(r.top + scrollY), Math.ceil(r.bottom + scrollY)]; }))
            """#) as? String ?? "[]"
            blocks = try JSONDecoder().decode([[Int]].self, from: Data(json.utf8)).map { ($0[0], $0[1]) }
        }
        #expect(blocks.count == 16)
        #expect(result.images.count > 2)
        var top = 0
        for image in result.images {
            #expect(image.height <= 3000)
            let bottom = top + image.height
            #expect(!blocks.contains { $0.top < bottom && $0.bottom > bottom }, "a table or code block is cut at \(bottom)")
            top = bottom
        }
        for (a, b) in zip(result.images, result.images.dropFirst()) {
            #expect(a.lastLine + 1 == b.firstLine)
        }
    }

    // MARK: Golden (MARSDAWN_PNG_GOLDENS=1)

    static func goldenURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("PNGGoldens").appendingPathComponent(name)
    }

    /// The mixed document, light, compared pixel by pixel with `PNGGoldens/mixed-light.png`.
    /// Recorded with `MARSDAWN_UPDATE_GOLDENS=1`, with the macOS build beside it
    /// (`mixed-light.txt`): on another build the comparison is reported, not run.
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["MARSDAWN_PNG_GOLDENS"] == "1",
        "rendering differs by macOS build: set MARSDAWN_PNG_GOLDENS=1 on the machine the golden was recorded on"
    ))
    func golden() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await DocumentImageRenderer.render(
            markdown: Self.markdown, theme: .dawn, width: 1000, baseDirectory: folder, calloutTitles: .english
        )
        let image = try #require(result.images.first)
        let pngURL = Self.goldenURL("mixed-light.png"), headerURL = Self.goldenURL("mixed-light.txt")
        let header = GoldenHeader.current(paper: "png").line

        if ProcessInfo.processInfo.environment["MARSDAWN_UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: pngURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.png.write(to: pngURL)
            try (header + "\n").write(to: headerURL, atomically: true, encoding: .utf8)
            return
        }
        let recordedHeader = try String(contentsOf: headerURL, encoding: .utf8).trimmingCharacters(in: .newlines)
        guard GoldenHeader.parse(recordedHeader)?.osBuild == GoldenHeader.current(paper: "png").osBuild else {
            Issue.record(Comment(rawValue: "the golden was recorded on \(recordedHeader); this is \(header): re-record it here"))
            return
        }
        let recorded = try Self.pixels(Data(contentsOf: pngURL))
        let current = try Self.pixels(image.png)
        #expect(recorded.pixelsWide == current.pixelsWide && recorded.pixelsHigh == current.pixelsHigh,
                "size \(current.pixelsWide)×\(current.pixelsHigh), golden \(recorded.pixelsWide)×\(recorded.pixelsHigh)")
        guard recorded.pixelsWide == current.pixelsWide, recorded.pixelsHigh == current.pixelsHigh else { return }
        var different = 0
        for y in 0..<current.pixelsHigh {
            for x in 0..<current.pixelsWide where Self.differs(Self.sample(current, x, y), Self.sample(recorded, x, y), by: 8) {
                different += 1
            }
        }
        let share = Double(different) / Double(current.pixelsWide * current.pixelsHigh)
        #expect(share < 0.001, "\(different) pixels (\(share * 100)%) differ from the golden by more than 8")
    }
}
#endif
