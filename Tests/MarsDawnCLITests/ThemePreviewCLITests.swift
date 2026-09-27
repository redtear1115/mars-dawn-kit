#if os(macOS)
import AppKit
import ArgumentParser
import Darwin
import Foundation
import Network
import Testing
import WebKit
@testable import marsdawn
@testable import MarsDawnExport
@testable import MarsDawnKit
import MarsDawnThemes

/// `marsdawn theme preview <file> --appearance light|dark -o out.png [--width N]` (kit #139).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ThemePreviewCLITests {
    typealias Scratch = ThemeValidateCLITests.Scratch

    static let fixture = ThemeCSSCLITests.fixtures.appendingPathComponent("valid/every-option.json").path

    struct Run {
        var status: Int32
        var output: String
    }

    static func run(
        _ path: String, appearance: ThemePreviewRenderer.Appearance, output: String, width: Int = ThemePreviewRenderer.defaultWidth,
        force: Bool = false, json: Bool = false, inspect: ((PreviewWKWebView) async throws -> Void)? = nil
    ) async throws -> Run {
        var text = ""
        let status = try await MarsDawnCommand.Theme.Preview.run(
            path: path, appearance: appearance, output: output, width: width, force: force, json: json,
            write: { text += $0 + "\n" }, inspect: inspect
        )
        return Run(status: status, output: text)
    }

    /// Width and height from a PNG's IHDR, after checking the signature.
    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count > 24, bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
              String(decoding: bytes[12..<16], as: UTF8.self) == "IHDR" else { return nil }
        func be(_ at: Int) -> Int { bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (be(16), be(20))
    }

    /// The stored samples of the pixel at (x, y) from the top: the PNG is tagged sRGB, so these
    /// are its sRGB components. (Not `colorAt`, which converts through another colour space.)
    static func pixel(_ data: Data, x: Int, y: Int) -> [Int]? {
        guard let bitmap = NSBitmapImageRep(data: data), bitmap.samplesPerPixel >= 3, bitmap.bitsPerSample == 8 else { return nil }
        var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&samples, atX: x, y: y)
        return Array(samples.prefix(3))
    }

    static func rgb(_ hex: String) -> [Int] {
        let value = Int(hex.dropFirst(), radix: 16)!
        return [value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF]
    }

    static func close(_ a: [Int]?, _ b: [Int]) -> Bool {
        guard let a else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) <= 2 }
    }

    /// What the page says about itself: its theme, its `--bg`, whether the diagram and the math
    /// rendered, and which rule list and URL it loaded with.
    struct PageFacts {
        var theme = ""
        var background = ""
        var diagrams = 0
        var math = 0
        var ruleList: String?
        var url: URL?
    }

    static func facts(_ webView: PreviewWKWebView) async throws -> PageFacts {
        var facts = PageFacts()
        facts.theme = try await webView.evaluateJavaScript("document.documentElement.dataset.theme") as? String ?? ""
        facts.background = (try await webView.evaluateJavaScript(
            "getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()"
        ) as? String ?? "").uppercased()
        facts.diagrams = try await webView.evaluateJavaScript("document.querySelectorAll('.mermaid-output svg').length") as? Int ?? 0
        facts.math = try await webView.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int ?? 0
        facts.ruleList = webView.firstLoad?.contentRuleListIdentifier
        facts.url = webView.firstLoad?.url
        return facts
    }

    // MARK: - Rendering

    /// A theme that isn't a built-in renders in both palettes, at the requested width, with its
    /// own colours on the page and in the pixels.
    @Test(arguments: ThemePreviewRenderer.Appearance.allCases)
    func aFixtureRendersAtTheRequestedWidth(_ appearance: ThemePreviewRenderer.Appearance) async throws {
        let scratch = try Scratch()
        let theme = try #require(ThemeValidator.validate(data: Data(contentsOf: URL(fileURLWithPath: Self.fixture))).theme)
        let expected = appearance == .dark ? theme.dark.background : theme.light.background
        #expect(theme.light.background != theme.dark.background, "positive fixture: the palettes differ")
        for width in [ThemePreviewRenderer.defaultWidth, ThemePreviewRenderer.widthRange.lowerBound] {
            let out = scratch.url.appendingPathComponent("\(appearance)-\(width).png").path
            var seen = PageFacts()
            let result = try await Self.run(Self.fixture, appearance: appearance, output: out, width: width, json: true) { seen = try await Self.facts($0) }
            #expect(result.status == 0, "\(result.output)")
            let data = try Data(contentsOf: URL(fileURLWithPath: out))
            let size = try #require(Self.pngSize(data), "a PNG")
            #expect(size.width == width)
            #expect(size.height > 500 && size.height <= ThemePreviewRenderer.maxHeight)
            #expect(seen.theme == "every-option")
            #expect(seen.background == expected.uppercased(), "the page's --bg is the \(appearance) palette's")
            #expect(seen.diagrams == 1, "the sample's diagram rendered")
            #expect(seen.math >= 2, "the sample's math rendered")
            #expect(Self.close(Self.pixel(data, x: 2, y: 2), Self.rgb(expected)), "corner pixel \(String(describing: Self.pixel(data, x: 2, y: 2))) vs \(expected)")
            let object = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
            #expect(object["ok"] as? Bool == true)
            #expect(object["width"] as? Int == width)
            #expect(object["height"] as? Int == size.height)
            #expect(object["appearance"] as? String == appearance.rawValue)
            #expect(object["id"] as? String == "every-option")
            #expect(object["output"] as? String == URL(fileURLWithPath: out).standardizedFileURL.path)
        }
    }

    /// A file whose id is a built-in's previews the file, not the built-in: the page is served
    /// from a registry holding that one theme.
    @Test func aFileWithABuiltInsIDShowsTheFilesColours() async throws {
        let scratch = try Scratch()
        let text = try ThemeValidateCLITests.dawnText()
            .replacingOccurrences(of: ##""background": "#FFFDFB""##, with: ##""background": "#FFFFFF""##)
        #expect(text != (try ThemeValidateCLITests.dawnText()), "positive fixture: the colour changed")
        let path = try scratch.file("dawn.json", Data(text.utf8))
        let out = scratch.url.appendingPathComponent("dawn.png").path
        var seen = PageFacts()
        let result = try await Self.run(path, appearance: .light, output: out) { seen = try await Self.facts($0) }
        #expect(result.status == 0, "\(result.output)")
        #expect(seen.theme == "dawn")
        #expect(seen.background == "#FFFFFF")
    }

    // MARK: - Refusals

    @Test func anInvalidThemeExitsOneAndWritesNothing() async throws {
        let scratch = try Scratch()
        let text = try ThemeValidateCLITests.dawnText().replacingOccurrences(of: #""id": "dawn""#, with: #""id": "Dawn""#)
        let path = try scratch.file("bad.json", Data(text.utf8))
        let out = scratch.url.appendingPathComponent("bad.png").path
        let result = try await Self.run(path, appearance: .light, output: out)
        #expect(result.status == 1)
        #expect(result.output.contains("id.pattern at id:"))
        #expect(!FileManager.default.fileExists(atPath: out))
        let json = try await Self.run(path, appearance: .dark, output: out, json: true)
        #expect(json.status == 1)
        #expect(try JSONDecoder().decode(ThemeValidateOutput.self, from: Data(json.output.utf8)).issues.first?.rule == "id.pattern")
        #expect(!FileManager.default.fileExists(atPath: out))
        let command = try #require(try MarsDawnCommand.parseAsRoot(["theme", "preview", path, "--appearance", "light", "-o", out]) as? MarsDawnCommand.Theme.Preview)
        do {
            try await command.run()
            Issue.record("an invalid theme didn't exit 1")
        } catch {
            #expect(error as? ExitCode == ExitCode(1))
        }
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    @Test func aMissingFileIsInputNotFound() async throws {
        let scratch = try Scratch()
        let missing = scratch.url.appendingPathComponent("nope.json").path
        let out = scratch.url.appendingPathComponent("nope.png").path
        await #expect {
            _ = try await Self.run(missing, appearance: .light, output: out)
        } throws: { cliExitCode(for: $0) == 2 && ($0 as? CLIFailure)?.code.kind == "input_not_found" }
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    @Test func aSymlinkedThemeIsRefused() async throws {
        let scratch = try Scratch()
        let link = scratch.url.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: Self.fixture)
        let out = scratch.url.appendingPathComponent("link.png").path
        let result = try await Self.run(link, appearance: .light, output: out)
        #expect(result.status == 1)
        #expect(result.output.contains("file.notRegular"))
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    @Test(arguments: [599, 2001, 0, -1200])
    func aWidthOutsideTheRangeIsAUsageError(_ width: Int) throws {
        let scratch = try Scratch()
        let out = scratch.url.appendingPathComponent("w.png").path
        #expect(throws: (any Error).self) {
            _ = try MarsDawnCommand.parseAsRoot(["theme", "preview", Self.fixture, "--appearance", "light", "-o", out, "--width=\(width)"])
        }
        do {
            _ = try MarsDawnCommand.parseAsRoot(["theme", "preview", Self.fixture, "--appearance", "light", "-o", out, "--width=\(width)"])
        } catch {
            #expect(cliExitCode(for: error) == 64)
        }
        #expect(throws: Never.self) {
            _ = try MarsDawnCommand.parseAsRoot(["theme", "preview", Self.fixture, "--appearance", "dark", "-o", out, "--width", "2000"])
        }
    }

    @Test func appearanceAndOutputAreRequired() {
        #expect(throws: (any Error).self) { _ = try MarsDawnCommand.parseAsRoot(["theme", "preview", Self.fixture, "-o", "x.png"]) }
        #expect(throws: (any Error).self) { _ = try MarsDawnCommand.parseAsRoot(["theme", "preview", Self.fixture, "--appearance", "light"]) }
        #expect(throws: (any Error).self) { _ = try MarsDawnCommand.parseAsRoot(["theme", "preview", Self.fixture, "--appearance", "sepia", "-o", "x.png"]) }
    }

    // MARK: - Where it writes

    @Test func anOutputSymlinkIsNeverWrittenThroughEvenWithForce() async throws {
        let scratch = try Scratch()
        let target = try scratch.file("victim.txt", Data("keep me".utf8))
        let link = scratch.url.appendingPathComponent("out.png").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        for force in [false, true] {
            await #expect {
                _ = try await Self.run(Self.fixture, appearance: .light, output: link, force: force)
            } throws: { ($0 as? OutputPathFailure)?.kind == .symlink && cliExitCode(for: $0) == 64 }
            #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep me")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == target, "the link itself is left alone")
        }
        // A dangling link is refused too: nothing is created where it points.
        let dangling = scratch.url.appendingPathComponent("dangling.png").path
        let pointee = scratch.url.appendingPathComponent("created.png").path
        try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: pointee)
        await #expect(throws: OutputPathFailure.self) { _ = try await Self.run(Self.fixture, appearance: .light, output: dangling, force: true) }
        #expect(!FileManager.default.fileExists(atPath: pointee))
    }

    @Test func aMissingFolderIsRefusedAndNotCreated() async throws {
        let scratch = try Scratch()
        let folder = scratch.url.appendingPathComponent("nope")
        let out = folder.appendingPathComponent("out.png").path
        await #expect {
            _ = try await Self.run(Self.fixture, appearance: .light, output: out)
        } throws: { ($0 as? OutputPathFailure)?.kind == .folderMissing && cliExitCode(for: $0) == 64 }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aFolderAtTheOutputIsRefused() async throws {
        let scratch = try Scratch()
        await #expect {
            _ = try await Self.run(Self.fixture, appearance: .light, output: scratch.url.path, force: true)
        } throws: { ($0 as? OutputPathFailure)?.kind == .notAFile }
    }

    @Test func anExistingFileNeedsForce() async throws {
        let scratch = try Scratch()
        let out = try scratch.file("out.png", Data("old".utf8))
        await #expect {
            _ = try await Self.run(Self.fixture, appearance: .light, output: out, width: 600)
        } throws: { ($0 as? CLIFailure)?.code == .outputExists && cliExitCode(for: $0) == 4 }
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "old")
        let result = try await Self.run(Self.fixture, appearance: .light, output: out, width: 600, force: true)
        #expect(result.status == 0)
        #expect(Self.pngSize(try Data(contentsOf: URL(fileURLWithPath: out)))?.width == 600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "no temporary files left: \(leftovers)")
    }

    // MARK: - No network

    /// Loads one resource of each kind from `127.0.0.1:port` over http and https, plus a
    /// preconnect, and waits for each to settle. A plain TCP listener counts a connection for any of
    /// them, https included (the TLS handshake starts after the connection is accepted).
    static let networkProbe = """
    const settle = (element, event) => new Promise((resolve) => {
      element.addEventListener(event, () => resolve("load"), { once: true });
      element.addEventListener("error", () => resolve("error"), { once: true });
      setTimeout(() => resolve("timeout"), 3000);
    });
    const loads = [];
    for (const scheme of ["http", "https"]) {
      const image = new Image();
      loads.push(settle(image, "load"));
      image.src = `${scheme}://127.0.0.1:${port}/image.png`;
      loads.push(fetch(`${scheme}://127.0.0.1:${port}/fetch.txt`).then(() => "load", () => "error"));
      const style = document.createElement("style");
      style.textContent = `body { background-image: url(${scheme}://127.0.0.1:${port}/bg.png); }`;
      document.head.append(style);
    }
    const preconnect = document.createElement("link");
    preconnect.rel = "preconnect";
    preconnect.href = `https://127.0.0.1:${port}/`;
    document.head.append(preconnect);
    getComputedStyle(document.body).backgroundImage;
    return (await Promise.all(loads)).join(",");
    """

    /// A hostile-but-valid theme: display strings the validator lets through that would reach the
    /// network if the preview ever put them in the page.
    static func hostileTheme(port: UInt16, in scratch: Scratch) throws -> String {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: ThemeDocumentLoader.builtInURL(id: "dawn")!)) as? [String: Any])
        object["id"] = "hostile"
        object["name"] = ["en": "<img src=//127.0.0.1:\(port)/name.png>"]
        object["summary"] = ["en": "@import url(//127.0.0.1:\(port)/summary.css)"]
        object["author"] = ["name": "\"><link rel=preconnect href=//127.0.0.1:\(port)>"]
        let path = try scratch.file("hostile.json", try JSONSerialization.data(withJSONObject: object))
        return path
    }

    @Test func theProbeReachesTheServerWhereNothingBlocksIt() async throws {
        let server = try await PreviewLoopbackServer.start()
        defer { server.stop() }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }())
        webView.loadHTMLString("<!doctype html><html><head></head><body>control</body></html>", baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while webView.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await webView.callAsyncJavaScript(Self.networkProbe, arguments: ["port": Int(server.port)], contentWorld: .page)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.accepts >= 1, "the instrument sees a connection when nothing blocks it")
    }

    /// Zero connections from the preview of a hostile-but-valid theme, with the probe run inside
    /// the prepared page too, before it is captured.
    @Test func aPreviewMakesNoNetworkRequest() async throws {
        let server = try await PreviewLoopbackServer.start()
        defer { server.stop() }
        let scratch = try Scratch()
        let path = try Self.hostileTheme(port: server.port, in: scratch)
        var validated = ""
        _ = try MarsDawnCommand.Theme.Validate.run(path: path, json: false) { validated += $0 }
        #expect(validated == "valid: hostile", "positive fixture: the hostile theme is valid")
        for appearance in ThemePreviewRenderer.Appearance.allCases {
            let out = scratch.url.appendingPathComponent("hostile-\(appearance).png").path
            var seen = PageFacts()
            var probe = ""
            let result = try await Self.run(path, appearance: appearance, output: out) { webView in
                seen = try await Self.facts(webView)
                probe = try await webView.callAsyncJavaScript(Self.networkProbe, arguments: ["port": Int(server.port)], contentWorld: .page) as? String ?? ""
            }
            #expect(result.status == 0, "\(result.output)")
            #expect(seen.theme == "hostile", "positive fixture: the page used the theme")
            #expect(seen.diagrams == 1)
            #expect(seen.ruleList == PreviewContentRules.identifier(allowRemoteImages: false))
            let query = URLComponents(url: try #require(seen.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(!query.contains { $0.name == PreviewSchemeHandler.remoteImagesQueryItem }, "remote images off: \(query)")
            try await Task.sleep(for: .seconds(1))
            #expect(server.accepts == 0, "connections: \(server.accepts), paths: \(server.paths), page saw \(probe)")
        }
    }
}

/// A TCP listener on 127.0.0.1 that counts accepted connections and records request paths.
final class PreviewLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PreviewLoopbackServer")
    private let lock = NSLock()
    private var recorded: [String] = []
    private var acceptCount = 0

    var paths: [String] { lock.withLock { recorded } }
    var accepts: Int { lock.withLock { acceptCount } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> PreviewLoopbackServer {
        let server = try PreviewLoopbackServer()
        let once = PreviewOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            server.listener.newConnectionHandler = { [server] connection in server.handle(connection) }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        lock.withLock { acceptCount += 1 }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
            if let data, let line = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first {
                let parts = line.split(separator: " ")
                if parts.count >= 2 { lock.withLock { recorded.append(String(parts[1])) } }
            }
            connection.send(content: Data("HTTP/1.1 404 X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

final class PreviewOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
#endif
