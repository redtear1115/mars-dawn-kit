#if os(macOS)
import Foundation
import Testing

/// The golden comparison's own rules (audit D F2, F6), without a PDF: what it forgives and what
/// it reports. `PDFCorpus/golden` is skipped without `MARSDAWN_PDF_GOLDENS=1`, so this is what a
/// plain `swift test` knows about the comparison.
struct GoldenStoreTests {
    static func line(_ text: String, _ x: Int, _ y: Int, width: Int = 100, height: Int = 14) -> GoldenLine {
        GoldenLine(text: text, minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    static let page = [line("Title", 45, 760), line("first", 45, 700), line("second", 45, 680), line("1", 188, 375, width: 5)]

    @Test func pathsAreSelectedByMajorVersion() {
        for major in [26, 27] {
            let url = GoldenStore.url(for: "blocks", major: major)
            #expect(url.lastPathComponent == "blocks.txt")
            #expect(url.deletingLastPathComponent().lastPathComponent == "macos-\(major)")
            #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Goldens")
        }
        #expect(GoldenStore.url(for: "blocks") == GoldenStore.url(
            for: "blocks", major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        ))
    }

    @Test func recordingAndMissingFilesStayWithinTheirMajorVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = GoldenStore.render(
            header: GoldenHeader(osBuild: "b", webKit: "w", paper: "a4"), pages: [Self.page]
        )
        let recorded = GoldenStore.url(for: "blocks", major: 26, root: root)
        try FileManager.default.createDirectory(at: recorded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: recorded, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: recorded, encoding: .utf8) == content)

        // A fixture in 26 must not hide the missing recording for 27.
        let missing = GoldenStore.url(for: "blocks", major: 27, root: root)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(throws: (any Error).self) { try String(contentsOf: missing, encoding: .utf8) }

        try FileManager.default.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
        let updated = GoldenStore.render(
            header: GoldenHeader(osBuild: "new-build", webKit: "w", paper: "a4"), pages: [Self.page]
        )
        try updated.write(to: missing, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: missing, encoding: .utf8) == updated)
        #expect(try String(contentsOf: recorded, encoding: .utf8) == content)
    }

    @Test func theOrderOfExtractionDoesNotMatter() {
        #expect(GoldenStore.differences(recorded: [Self.page], current: [Self.page.reversed()]).isEmpty)
        // The F6 case: the same lines, written sorted, parsed back, compared with a reshuffle.
        let header = GoldenHeader(osBuild: "b", webKit: "w", paper: "a4")
        let written = GoldenStore.render(header: header, pages: [GoldenStore.sorted(Self.page)])
        #expect(GoldenStore.pages(from: written) == [GoldenStore.sorted(Self.page)])
        #expect(GoldenStore.differences(recorded: GoldenStore.pages(from: written), current: [[Self.page[3]] + Self.page.dropLast()]).isEmpty)
    }

    @Test func aMoveOfOnePointIsNoiseAndAMoveOfTwoIsReported() {
        func moved(by dx: Int, _ dy: Int) -> [[GoldenLine]] {
            var page = Self.page
            page[1].minX += dx; page[1].maxX += dx; page[1].minY += dy; page[1].maxY += dy
            return [page]
        }
        #expect(GoldenStore.differences(recorded: [Self.page], current: moved(by: 1, -1)).isEmpty)
        #expect(GoldenStore.differences(recorded: [Self.page], current: moved(by: 0, 2)).count == 1)
        #expect(GoldenStore.differences(recorded: [Self.page], current: moved(by: -2, 0)).count == 1)
        // One edge alone is enough: a line that is two points wider.
        var wider = Self.page
        wider[2].maxX += 2
        #expect(GoldenStore.differences(recorded: [Self.page], current: [wider]).count == 1)
    }

    @Test func textThatChangesOrRepeatsOrGoesMissingIsReported() {
        var edited = Self.page
        edited[1].text = "first!"
        #expect(GoldenStore.differences(recorded: [Self.page], current: [edited]).count == 2)  // gone, and new
        #expect(GoldenStore.differences(recorded: [Self.page], current: [Self.page + [Self.page[3]]]).count == 1)
        #expect(GoldenStore.differences(recorded: [Self.page], current: [Array(Self.page.dropLast())]).count == 1)
        #expect(GoldenStore.differences(recorded: [Self.page], current: [Self.page, Self.page]).count == 1)
    }

    @Test func aLineIsWrittenAndReadBackWithItsBarsAndSpaces() {
        let tricky = Self.line("a | b  c", 45, 10)
        #expect(GoldenLine.parse(tricky.render) == tricky)
        #expect(GoldenLine.parse("not a line") == nil)
    }
}
#endif
