#if os(macOS)
import Foundation
import Testing
@testable import marsdawn

/// `marsdawn export --format png` (kit #243), run as the built binary: what it writes, its
/// `--json`, `--lines`/`--heading`, `heading_not_found`, its usage errors, and that a PDF export
/// is untouched by any of it (`ExportJSONContractTests` pins the PDF's JSON).
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ExportPNGCLITests {
    static let document = """
    # Plan

    Intro.

    ## Table

    | Name | Value |
    |---|---|
    | a | 1 |

    ## Diagram

    ```mermaid
    notadiagram here
    ```

    ## End

    Last words.
    """

    /// A scratch folder holding `plan.md`.
    static func scratch(_ markdown: String = document) throws -> (root: URL, input: URL) {
        let root = try CLIProcess.scratch()
        let input = root.appendingPathComponent("plan.md")
        try Data(markdown.utf8).write(to: input)
        return (root, input)
    }

    /// The theme fixture `theme preview`'s tests use.
    static let themeFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MarsDawnThemesTests/ThemeFixtures/valid/every-option.json").path

    /// Width and height from a PNG's IHDR, after checking the signature.
    static func pngSize(_ url: URL) throws -> (width: Int, height: Int) {
        let bytes = [UInt8](try Data(contentsOf: url))
        try #require(bytes.count > 24 && bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "\(url.path) is a PNG")
        func be(_ at: Int) -> Int { bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (be(16), be(20))
    }

    @Test func theResultListsEachImageAndTheWarnings() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try CLIProcess.run(["export", input.path, "--format", "png", "--json"], in: root)
        #expect(run.status == 0, "\(run.stderr)")
        let result = try run.jsonObject()
        #expect(Set(result.keys) == ["ok", "format", "theme", "appearance", "images", "warnings"], "\(result)")
        #expect(result["ok"] as? Bool == true)
        #expect(result["format"] as? String == "png")
        #expect(result["theme"] as? String == "dawn")
        #expect(result["appearance"] as? String == "light")
        let images = try #require(result["images"] as? [[String: Any]])
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(Set(image.keys) == ["path", "width", "height", "lines"])
        let path = root.appendingPathComponent("plan.png").path
        #expect(image["path"] as? String == path)
        #expect(image["width"] as? Int == 1200)
        #expect(image["lines"] as? String == "1-19")
        let size = try Self.pngSize(URL(fileURLWithPath: path))
        #expect(size.width == 1200 && size.height == image["height"] as? Int)

        let warnings = try #require(result["warnings"] as? [[String: Any]])
        #expect(warnings.count == 1, "\(warnings)")
        #expect(warnings.first?["kind"] as? String == "mermaid_error")
        #expect(warnings.first?["line"] as? Int == 13)
        #expect((warnings.first?["message"] as? String)?.contains("No diagram type detected") == true)
    }

    @Test func withoutJSONItSaysWhatItWroteAndWarnsOnStdout() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try CLIProcess.run(["export", input.path, "--format", "png", "--width", "800", "--appearance", "dark"], in: root)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout.hasPrefix("Exported \(root.appendingPathComponent("plan.png").path) (800×"), "\(run.stdout)")
        #expect(run.stdout.contains("warning: line 13: Mermaid diagram failed to render"), "\(run.stdout)")
        #expect(try Self.pngSize(root.appendingPathComponent("plan.png")).width == 800)
    }

    @Test func aHeadingRendersItsSectionOnly() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try CLIProcess.run(["export", input.path, "--format", "png", "--heading", "table", "--json"], in: root)
        #expect(run.status == 0, "\(run.stderr)")
        let result = try run.jsonObject()
        let images = try #require(result["images"] as? [[String: Any]])
        #expect(images.first?["lines"] as? String == "5-10", "\(images)")
        #expect((result["warnings"] as? [Any])?.isEmpty == true, "the broken diagram is outside the section")
    }

    @Test func linesAreWidenedToWholeBlocks() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // Line 8 is the table's delimiter row: the whole table, with its heading, which the page
        // keeps with a short block after it (`keep-with-next`), and nothing else.
        let run = try CLIProcess.run(["export", input.path, "--format", "png", "--lines", "8-8", "--json"], in: root)
        #expect(run.status == 0, "\(run.stderr)")
        let images = try #require(try run.jsonObject()["images"] as? [[String: Any]])
        #expect(images.first?["lines"] as? String == "5-10", "\(images)")
    }

    @Test func aHeadingThatIsNotThereExitsTwoAndWritesNothing() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try CLIProcess.run(["export", input.path, "--format", "png", "--heading", "Budget", "--json"], in: root)
        #expect(run.status == 2)
        let result = try run.jsonObject()
        #expect(result["ok"] as? Bool == false)
        #expect(result["error"] as? String == "heading_not_found")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("plan.png").path))

        let text = try CLIProcess.run(["export", input.path, "--format", "png", "--heading", "Budget"], in: root)
        #expect(text.status == 2)
        #expect(text.stderr.contains("has no heading \"Budget\""), "\(text.stderr)")
    }

    @Test(arguments: [
        ["--theme-file", "t.json"], ["--appearance", "dark"], ["--width", "800"], ["--lines", "1-2"], ["--heading", "Plan"],
    ])
    func aPNGOptionWithAPDFIsAUsageError(_ option: [String]) throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for format in [[], ["--format", "pdf"]] {
            let run = try CLIProcess.run(["export", input.path] + format + option, in: root)
            #expect(run.status == 64, "\(format + option): \(run.stderr)")
            #expect(run.stderr.contains("applies only to --format png"), "\(run.stderr)")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("plan.pdf").path))
        }
    }

    @Test(arguments: [
        ["--width", "599"], ["--width", "2001"], ["--lines", "5-2"], ["--lines", "0-3"], ["--lines", "a-b"],
        ["--lines", "1-2", "--heading", "Plan"], ["--theme", "dawn", "--theme-file", "t.json"], ["--heading", "  "],
        ["--lines", "40-50"],
    ])
    func badPNGOptionsAreUsageErrors(_ options: [String]) throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try CLIProcess.run(["export", input.path, "--format", "png"] + options, in: root)
        #expect(run.status == 64, "\(options): \(run.stderr)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("plan.png").path))
    }

    @Test func dashOAsAFolderWritesTheInputsNameInIt() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = try CLIProcess.run(["export", input.path, "--format", "png", "-o", folder.path, "--json"], in: root)
        #expect(run.status == 0, "\(run.stderr)")
        let images = try #require(try run.jsonObject()["images"] as? [[String: Any]])
        #expect(images.first?["path"] as? String == folder.appendingPathComponent("plan.png").path)
    }

    @Test func anExistingPNGNeedsForceAndIsLeftAloneWithout() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("plan.png")
        try Data("old".utf8).write(to: output)
        let refused = try CLIProcess.run(["export", input.path, "--format", "png", "--json"], in: root)
        #expect(refused.status == 4)
        #expect(try refused.jsonObject()["error"] as? String == "output_exists")
        #expect(try Data(contentsOf: output) == Data("old".utf8))
        let forced = try CLIProcess.run(["export", input.path, "--format", "png", "--force"], in: root)
        #expect(forced.status == 0, "\(forced.stderr)")
        #expect(try Self.pngSize(output).width == 1200)
    }

    @Test func aSymlinkAtTheOutputIsRefusedEvenWithForce() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("plan.png"), withDestinationURL: target)
        let run = try CLIProcess.run(["export", input.path, "--format", "png", "--force", "--json"], in: root)
        #expect(run.status == 64)
        #expect(try run.jsonObject()["error"] as? String == "output_symlink")
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }

    @Test func aThemeFileIsValidatedAndUsed() throws {
        let (root, input) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try CLIProcess.run(["export", input.path, "--format", "png", "--theme-file", Self.themeFixture, "--json"], in: root)
        #expect(valid.status == 0, "\(valid.stderr)")
        #expect(try valid.jsonObject()["theme"] as? String != "dawn")

        let bad = root.appendingPathComponent("bad.json")
        try Data("{}".utf8).write(to: bad)
        let invalid = try CLIProcess.run(["export", input.path, "--format", "png", "--theme-file", bad.path, "--force", "--json"], in: root)
        #expect(invalid.status == 1)
        #expect(try invalid.jsonObject()["ok"] as? Bool == false)

        let missing = try CLIProcess.run(["export", input.path, "--format", "png", "--theme-file", root.appendingPathComponent("none.json").path], in: root)
        #expect(missing.status == 2)
    }

    @Test func aLongDocumentIsWrittenAsNumberedImages() throws {
        var markdown = "# Long\n\n"
        for section in 1...14 {
            markdown += "## Section \(section)\n\n| k | v |\n|---|---|\n"
            markdown += (1...30).map { "| row\($0) | \($0) |" }.joined(separator: "\n") + "\n\n```\n"
            markdown += (1...30).map { "code line \($0)" }.joined(separator: "\n") + "\n```\n\n"
        }
        let (root, input) = try Self.scratch(markdown)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try CLIProcess.run(["export", input.path, "--format", "png", "--width", "600", "--json"], in: root)
        #expect(run.status == 0, "\(run.stderr)")
        let images = try #require(try run.jsonObject()["images"] as? [[String: Any]])
        #expect(images.count > 1, "\(images)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("plan.png").path))

        // The lines each image shows: none ends inside a table or a code block.
        let lines = markdown.components(separatedBy: "\n")
        var previousLast = 0
        for (index, image) in images.enumerated() {
            #expect(image["path"] as? String == root.appendingPathComponent("plan-\(index + 1).png").path)
            let height = try #require(image["height"] as? Int)
            #expect(height <= 8000)
            #expect(try Self.pngSize(URL(fileURLWithPath: image["path"] as! String)).height == height)
            let range = try #require((image["lines"] as? String)?.split(separator: "-").compactMap { Int($0) })
            #expect(range.count == 2 && range[0] == previousLast + 1)
            previousLast = range[1]
            if index < images.count - 1 {
                // The next image starts on a block's first line: a heading, a table's header or a fence.
                let next = lines[range[1]]
                #expect(next.hasPrefix("## ") || next.hasPrefix("| k |") || next == "```", "image \(index + 1) ends before \"\(next)\"")
            }
        }
    }

    @Test func numberedNamesKeepTheExtension() {
        let url = URL(fileURLWithPath: "/tmp/out/plan.png")
        #expect(MarsDawnCommand.Export.numbered(url, 2).path == "/tmp/out/plan-2.png")
        #expect(MarsDawnCommand.Export.numbered(URL(fileURLWithPath: "/tmp/shot"), 1).path == "/tmp/shot-1")
    }

    @Test func lineRangesParse() {
        #expect(LineRange(argument: "3-9") == LineRange(lower: 3, upper: 9))
        #expect(LineRange(argument: "4") == LineRange(lower: 4, upper: 4))
        for bad in ["", "-", "0-2", "5-2", "a", "1-2-3", "-3", "3-"] {
            #expect(LineRange(argument: bad) == nil, "\(bad)")
        }
    }
}
#endif
