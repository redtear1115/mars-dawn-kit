#if os(macOS)
import ArgumentParser
import Darwin
import Foundation
import Testing
import WebKit
@testable import marsdawn
@testable import MarsDawnKit
import MarsDawnThemes

/// Asks a real `PreviewSchemeHandler` for one URL, as the page's web view would, and keeps the body.
final class ServedResource: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private(set) var body = Data()
    private(set) var finished = false
    private(set) var failure: Error?

    init(_ url: URL) { request = URLRequest(url: url) }

    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { failure = error }

    /// The bytes `handler` serves for `path` (e.g. `/themes.css`), with the query of `query`.
    @MainActor
    static func fetch(_ handler: PreviewSchemeHandler, _ pathAndQuery: String) -> Data? {
        let url = URL(string: "\(PreviewSchemeHandler.scheme)://preview\(pathAndQuery)")!
        let task = ServedResource(url)
        handler.webView(WKWebView(frame: .zero), start: task)
        return task.finished && task.failure == nil ? task.body : nil
    }
}

/// `marsdawn theme css <file> [--json]` (kit #139): exactly the CSS the preview serves for a valid
/// theme, and exactly `theme validate`'s refusals for anything else.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ThemeCSSCLITests {
    typealias Scratch = ThemeValidateCLITests.Scratch

    static let builtInIDs = ["dawn", "classic", "modern", "vivid"]
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MarsDawnThemesTests/ThemeFixtures")

    static func run(_ path: String, json: Bool) -> (status: Int32, output: String) {
        var output = ""
        do {
            let status = try MarsDawnCommand.Theme.CSS.run(path: path, json: json) { output += $0 }
            return (status, output)
        } catch {
            Issue.record("run threw \(error)")
            return (-1, output)
        }
    }

    static func css(_ path: String) throws -> ThemeCSSOutput {
        let (status, output) = run(path, json: true)
        #expect(status == 0, "\(path): \(output)")
        #expect(output.hasSuffix("}\n") && output.filter { $0 == "\n" }.count == 1, "one JSON line: \(output)")
        return try JSONDecoder().decode(ThemeCSSOutput.self, from: Data(output.utf8))
    }

    static func builtInPath(_ id: String) -> String { ThemeDocumentLoader.builtInURL(id: id)!.path }

    static let previewCSSSourceURL: URL? = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.css")

    // MARK: - Byte-equal to what the preview serves

    /// The four built-ins' `theme css` output, joined as the registry joins them, is byte for byte
    /// the `themes.css` and the spliced `preview.css` a real `PreviewSchemeHandler` serves.
    @Test func builtInsEqualTheServedStylesheets() throws {
        let outputs = try Self.builtInIDs.map { try Self.css(Self.builtInPath($0)) }
        #expect(outputs.map(\.id) == Self.builtInIDs)
        #expect(outputs.allSatisfy { $0.ok && $0.variables.hasPrefix(":root[data-theme=\"\($0.id)\"] {\n") })
        #expect(outputs.filter { !$0.rules.isEmpty }.count == 4, "positive fixture: every built-in has rules")

        let handler = PreviewSchemeHandler()
        let served = try #require(ServedResource.fetch(handler, "/themes.css"))
        #expect(String(decoding: served, as: UTF8.self) == outputs.map(\.variables).joined(separator: "\n"))

        let servedPreview = String(decoding: try #require(ServedResource.fetch(handler, "/preview.css")), as: UTF8.self)
        let template = try String(contentsOf: try #require(Self.previewCSSSourceURL), encoding: .utf8)
        #expect(template.components(separatedBy: PreviewSchemeHandler.themeRulesMarker).count == 2, "positive fixture: the marker")
        #expect(servedPreview == template.replacingOccurrences(of: PreviewSchemeHandler.themeRulesMarker, with: outputs.map(\.rules).joined()))
        for output in outputs {
            #expect(servedPreview.contains(output.rules))
        }
    }

    /// The text form is the palette block, a newline, then the rules: the same bytes as `--json`.
    @Test func theTextFormIsTheSameCSS() throws {
        for id in Self.builtInIDs {
            let json = try Self.css(Self.builtInPath(id))
            let (status, text) = Self.run(Self.builtInPath(id), json: false)
            #expect(status == 0)
            #expect(text == json.variables + "\n" + json.rules)
            #expect(text.hasSuffix("}\n"))
        }
    }

    /// A theme that isn't a built-in: its output is what a page previewing it (the registry
    /// `theme preview` serves from) is served, through the same scheme handler, with the page's
    /// snapshot pinned the way `index.html` names it.
    @Test(arguments: ["every-option", "edge-numbers", "minimal-no-syntax-or-diagram", "sample-dawn"])
    func aFixtureEqualsWhatItsPreviewIsServed(_ name: String) throws {
        let path = Self.fixtures.appendingPathComponent("valid/\(name).json").path
        let output = try Self.css(path)
        let theme = try #require(ThemeValidator.validate(data: Data(contentsOf: URL(fileURLWithPath: path))).theme)
        let handler = ThemeRegistry.$override.withValue(ThemeRegistry(serving: [theme])) { PreviewSchemeHandler() }
        let page = String(decoding: try #require(ServedResource.fetch(handler, "/index.html")), as: UTF8.self)
        let link = try #require(page.firstMatch(of: /href="(themes\.css\?snapshot=\d+)"/)?.output.1)
        let previewLink = try #require(page.firstMatch(of: /href="(preview\.css\?snapshot=\d+)"/)?.output.1)
        let served = String(decoding: try #require(ServedResource.fetch(handler, "/\(link)")), as: UTF8.self)
        #expect(served == output.variables)
        let template = try String(contentsOf: try #require(Self.previewCSSSourceURL), encoding: .utf8)
        let servedPreview = String(decoding: try #require(ServedResource.fetch(handler, "/\(previewLink)")), as: UTF8.self)
        #expect(servedPreview == template.replacingOccurrences(of: PreviewSchemeHandler.themeRulesMarker, with: output.rules))
    }

    @Test func theJSONShapeIsFixed() throws {
        let (_, text) = Self.run(Self.fixtures.appendingPathComponent("valid/every-option.json").path, json: true)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["ok", "id", "variables", "rules"])
        #expect(object["ok"] as? Bool == true)
        #expect(object["id"] as? String == "every-option")
        #expect((object["rules"] as? String)?.isEmpty == false)
        #expect(!text.contains(#"\/"#), "slashes aren't escaped")
    }

    @Test func aThemeWithNoStyleOptionsHasEmptyRules() throws {
        let scratch = try Scratch()
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: ThemeDocumentLoader.builtInURL(id: "dawn")!)) as? [String: Any])
        object["id"] = "plain"
        object.removeValue(forKey: "style")
        let path = try scratch.file("plain.json", try JSONSerialization.data(withJSONObject: object))
        let output = try Self.css(path)
        #expect(output.rules == "")
        #expect(Self.run(path, json: false).output == output.variables + "\n")
    }

    // MARK: - Refused exactly like theme validate

    @Test func anInvalidThemeExitsOneWithTheValidatorsRule() throws {
        let scratch = try Scratch()
        let text = try ThemeValidateCLITests.dawnText().replacingOccurrences(of: #""id": "dawn""#, with: #""id": "Dawn""#)
        let path = try scratch.file("bad.json", Data(text.utf8))
        let (status, output) = Self.run(path, json: false)
        #expect(status == 1)
        #expect(output.hasPrefix("invalid: 1 problem\n"))
        #expect(output.contains("id.pattern at id:"))
        #expect(!output.contains("--bg"), "no CSS for an invalid theme")
        var validate = ""
        _ = try MarsDawnCommand.Theme.Validate.run(path: path, json: true) { validate += $0 + "\n" }
        #expect(Self.run(path, json: true).output == validate, "--json is theme validate's own output")
        var command = try MarsDawnCommand.parseAsRoot(["theme", "css", path])
        #expect(throws: ExitCode(1)) { try command.run() }
    }

    /// Every invalid fixture is refused, with the rule `theme validate` names for it.
    @Test func everyInvalidFixtureIsRefusedWithItsRule() throws {
        let folder = Self.fixtures.appendingPathComponent("invalid")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.sorted()
        #expect(names.count > 40, "positive fixture: the invalid fixtures")
        for name in names {
            let path = folder.appendingPathComponent(name).path
            // Fixtures are named `<rule>--<case>.json`.
            let rule = name.components(separatedBy: "--")[0]
            let (status, output) = Self.run(path, json: true)
            #expect(status == 1, "\(name)")
            let result = try JSONDecoder().decode(ThemeValidateOutput.self, from: Data(output.utf8))
            #expect(!result.ok && result.issues.contains { $0.rule == rule }, "\(name): \(result.issues)")
        }
    }

    @Test func aMissingFileIsInputNotFound() throws {
        let scratch = try Scratch()
        let missing = scratch.url.appendingPathComponent("nope.json").path
        #expect {
            _ = try MarsDawnCommand.Theme.CSS.run(path: missing, json: true) { _ in }
        } throws: { ($0 as? CLIFailure)?.code == .inputNotFound }
        var command = try MarsDawnCommand.parseAsRoot(["theme", "css", missing, "--json"])
        do {
            try command.run()
            Issue.record("a missing file didn't throw")
        } catch {
            #expect(cliExitCode(for: error) == 2)
            #expect((error as? CLIFailure)?.code.kind == "input_not_found")
        }
    }

    // The same file rules as theme validate: the shared reader.

    @Test func aSymlinkIsRefusedEvenToAValidTheme() throws {
        let scratch = try Scratch()
        let link = scratch.url.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: Self.builtInPath("dawn"))
        let (status, output) = Self.run(link, json: false)
        #expect(status == 1)
        #expect(output.contains("file.notRegular"))
        #expect(output.contains("symlink"))
        #expect(!output.contains("--bg"))
    }

    @Test func aFIFOIsRefusedWithoutBlocking() throws {
        let scratch = try Scratch()
        let path = scratch.url.appendingPathComponent("fifo").path
        #expect(mkfifo(path, 0o600) == 0)
        let start = ContinuousClock.now
        let (status, output) = Self.run(path, json: false)
        #expect(status == 1)
        #expect(output.contains("file.notRegular"))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func oneByteOverTheCapIsRefusedAndTheCapItselfIsRead() throws {
        let scratch = try Scratch()
        var text = try ThemeValidateCLITests.dawnText()
        text += String(repeating: " ", count: ThemeValidator.maxFileBytes - text.utf8.count)
        #expect(Self.run(try scratch.file("cap.json", Data(text.utf8)), json: false).status == 0)
        let (status, output) = Self.run(try scratch.file("over.json", Data((text + " ").utf8)), json: false)
        #expect(status == 1)
        #expect(output.contains("file.tooLarge"))
    }

    @Test func aDuplicateKeyIsRefused() throws {
        let scratch = try Scratch()
        let text = try ThemeValidateCLITests.dawnText().replacingOccurrences(of: ##""accent": "#C8471B","##, with: ##""accent": "#C8471B", "accent": "#000000","##)
        #expect(text != (try ThemeValidateCLITests.dawnText()), "positive fixture: the duplicate was inserted")
        let (status, output) = Self.run(try scratch.file("dup.json", Data(text.utf8)), json: false)
        #expect(status == 1)
        #expect(output.contains("json.duplicateKey at light:"))
    }

    @Test func theHelpNamesBothNewCommands() {
        let help = MarsDawnCommand.helpMessage(for: MarsDawnCommand.Theme.self)
        #expect(help.contains("css"))
        #expect(help.contains("preview"))
        #expect(help.contains("validate"))
    }
}
#endif
