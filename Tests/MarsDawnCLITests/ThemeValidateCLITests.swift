#if os(macOS)
import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import marsdawn
import MarsDawnThemes

/// `marsdawn theme validate <file> [--json]` (kit #125): exit 0 valid, 1 invalid; the file rules
/// of security review L2 (regular files only, a bounded read, duplicate keys refused) and M4's
/// output rules (nothing raw from the file in the human output, JSON written by `JSONEncoder`).
@Suite(.timeLimit(.minutes(1)))
struct ThemeValidateCLITests {
    static let dawnURL = ThemeDocumentLoader.builtInURL(id: "dawn")!

    /// A fresh folder per test, removed afterwards.
    final class Scratch {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-validate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func file(_ name: String, _ data: Data) throws -> String {
            let path = url.appendingPathComponent(name).path
            try data.write(to: URL(fileURLWithPath: path))
            return path
        }
    }

    static func run(_ path: String, json: Bool = false, requireComplete: Bool = false) -> (status: Int32, output: String) {
        var output = ""
        do {
            let status = try MarsDawnCommand.Theme.Validate.run(path: path, json: json, requireComplete: requireComplete) { output += $0 + "\n" }
            return (status, output)
        } catch {
            Issue.record("run threw \(error)")
            return (-1, output)
        }
    }

    static func dawnText() throws -> String { try String(contentsOf: dawnURL, encoding: .utf8) }

    @Test func aBuiltInIsValid() {
        let (status, output) = Self.run(Self.dawnURL.path)
        #expect(status == 0)
        #expect(output == "valid: dawn\n")
    }

    @Test func anInvalidThemeExitsOneAndNamesTheRule() throws {
        let scratch = try Scratch()
        let path = try scratch.file("t.json", Data(try Self.dawnText().replacingOccurrences(of: #""id": "dawn""#, with: #""id": "Dawn""#).utf8))
        let (status, output) = Self.run(path)
        #expect(status == 1)
        #expect(output.hasPrefix("invalid: 1 problem\n"))
        #expect(output.contains("id.pattern at id:"))
    }

    /// The command itself, through ArgumentParser: an invalid theme exits 1 via `ExitCode`, which
    /// `main.swift` hands to ArgumentParser's own `exit(withError:)` -- no error text of its own.
    @Test func theParsedCommandExitsWithTheStatus() throws {
        let scratch = try Scratch()
        let bad = try scratch.file("bad.json", Data("{}".utf8))
        var command = try MarsDawnCommand.parseAsRoot(["theme", "validate", bad, "--json"])
        #expect(throws: ExitCode(1)) { try command.run() }
        var good = try MarsDawnCommand.parseAsRoot(["theme", "validate", Self.dawnURL.path])
        #expect(throws: Never.self) { try good.run() }
        #expect(MarsDawnCommand.exitCode(for: ExitCode(1)).rawValue == 1)
    }

    // MARK: - L2: what gets read

    @Test func oneByteOverTheCapIsRefusedAndTheCapItselfIsRead() throws {
        let scratch = try Scratch()
        var text = try Self.dawnText()
        text += String(repeating: " ", count: ThemeValidator.maxFileBytes - text.utf8.count)
        #expect(text.utf8.count == ThemeValidator.maxFileBytes)
        #expect(Self.run(try scratch.file("cap.json", Data(text.utf8))).status == 0)
        let over = try scratch.file("over.json", Data((text + " ").utf8))
        let (status, output) = Self.run(over)
        #expect(status == 1)
        #expect(output.contains("file.tooLarge"))
    }

    @Test func aCharacterDeviceIsRefusedWithoutBeingRead() {
        let start = ContinuousClock.now
        let (status, output) = Self.run("/dev/zero")
        #expect(status == 1)
        #expect(output.contains("file.notRegular"))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func aFIFOIsRefusedWithoutBlocking() throws {
        let scratch = try Scratch()
        let path = scratch.url.appendingPathComponent("fifo").path
        #expect(mkfifo(path, 0o600) == 0)
        let start = ContinuousClock.now
        let (status, output) = Self.run(path)
        #expect(status == 1)
        #expect(output.contains("file.notRegular"))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func aSymlinkIsRefusedEvenToAValidTheme() throws {
        let scratch = try Scratch()
        let link = scratch.url.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: Self.dawnURL.path)
        let (status, output) = Self.run(link)
        #expect(status == 1)
        #expect(output.contains("file.notRegular"))
        #expect(output.contains("symlink"))
    }

    @Test func aFolderIsRefused() throws {
        let scratch = try Scratch()
        #expect(Self.run(scratch.url.path).output.contains("file.notRegular"))
    }

    /// A missing file is the CLI-wide `input_not_found` (exit 2), like `export` and `open`, not a
    /// validation result; main.swift prints `{"ok": false, "error": "input_not_found", …}` for it.
    @Test func aMissingFileIsInputNotFound() throws {
        let scratch = try Scratch()
        let missing = scratch.url.appendingPathComponent("nope.json").path
        #expect {
            _ = try MarsDawnCommand.Theme.Validate.run(path: missing, json: true) { _ in }
        } throws: { ($0 as? CLIFailure)?.code == .inputNotFound }
        var command = try MarsDawnCommand.parseAsRoot(["theme", "validate", missing, "--json"])
        do {
            try command.run()
            Issue.record("a missing file didn't throw")
        } catch {
            #expect(cliExitCode(for: error) == 2)
            #expect((error as? CLIFailure)?.code.kind == "input_not_found")
            #expect((error as? CLIFailure)?.message == "No such file: \(missing)")
        }
    }

    @Test func requireCompleteRefusesAMissingColourGroup() throws {
        let scratch = try Scratch()
        let text = try Self.dawnText()
        var object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var light = try #require(object["light"] as? [String: Any])
        light.removeValue(forKey: "diagram")
        object["light"] = light
        let path = try scratch.file("partial.json", try JSONSerialization.data(withJSONObject: object))
        #expect(Self.run(path).status == 0, "without the flag a missing group is filled from Dawn")
        let (status, output) = Self.run(path, requireComplete: true)
        #expect(status == 1)
        #expect(output.contains("palette.incomplete at light.diagram: is required for a published theme"), "\(output)")
        #expect(Self.run(Self.dawnURL.path, requireComplete: true).status == 0, "a complete theme passes the flag")
        var parsed = try MarsDawnCommand.parseAsRoot(["theme", "validate", path, "--require-complete"])
        #expect(throws: ExitCode(1)) { try parsed.run() }
    }

    @Test func theTopLevelHelpNamesThemeValidateAndItsExitCode() {
        // Help text wraps at the terminal width; compare with the wrapping taken out.
        let help = MarsDawnCommand.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("theme"))
        #expect(help.contains("1 invalid theme (theme commands only)"))
        #expect(help.contains("2 input not found"))
    }

    @Test func aDuplicateKeyIsRefused() throws {
        let scratch = try Scratch()
        let text = try Self.dawnText().replacingOccurrences(of: ##""accent": "#C8471B","##, with: ##""accent": "#C8471B", "accent": "#000000","##)
        #expect(text != (try Self.dawnText()), "positive fixture: the duplicate was inserted")
        let (status, output) = Self.run(try scratch.file("dup.json", Data(text.utf8)))
        #expect(status == 1)
        #expect(output.contains("json.duplicateKey at light:"))
        #expect(output.contains("the key `accent` appears more than once"))
    }

    // MARK: - M4: repeating what the file says

    static let hostile = "\u{1B}]0;pwned\u{7}\u{1B}[31m@someuser [x](https://evil.test)" + String(repeating: "Z", count: 80)

    static func hostileFiles(_ scratch: Scratch) throws -> [String] {
        let base = try Self.dawnText()
        let key = String(data: try JSONEncoder().encode(Self.hostile), encoding: .utf8)!
        return [
            try scratch.file("key.json", Data(base.replacingOccurrences(of: #""schemaVersion": 1,"#, with: #""schemaVersion": 1, \#(key): true,"#).utf8)),
            try scratch.file("name.json", Data(base.replacingOccurrences(of: #""name": { "en": "Dawn" }"#, with: #""name": { "en": \#(key) }"#).utf8)),
            try scratch.file("locale.json", Data(base.replacingOccurrences(of: #""name": { "en": "Dawn" }"#, with: #""name": { "en": "Dawn", \#(key): "x" }"#).utf8)),
        ]
    }

    @Test func humanOutputRepeatsNothingRaw() throws {
        let scratch = try Scratch()
        for path in try Self.hostileFiles(scratch) {
            let (status, output) = Self.run(path)
            #expect(status == 1, "\(path): \(output)")
            // Positive fixture: the hostile text was caught -- repeated quoted (a key), or not
            // repeated at all (a display string is described, never echoed).
            #expect(output.contains("\\u{1B}") || output.contains("text.control at name.en"), "\(output)")
            #expect(!output.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 || $0.value == 0x9B }, "raw ESC/BEL/CSI in: \(output.debugDescription)")
            #expect(!output.contains("@someuser"))
            #expect(!output.contains("https://"))
            #expect(!output.contains(String(repeating: "Z", count: ThemeMessageText.cap + 1)))
        }
    }

    @Test func jsonOutputRoundTrips() throws {
        let scratch = try Scratch()
        for path in try Self.hostileFiles(scratch) + [Self.dawnURL.path] {
            let (status, output) = Self.run(path, json: true)
            let data = Data(output.trimmingCharacters(in: .newlines).utf8)
            let decoded = try JSONDecoder().decode(ThemeValidateOutput.self, from: data)
            #expect(decoded.ok == (status == 0))
            let reencoded = decoded.jsonText
            #expect(reencoded == output.trimmingCharacters(in: .newlines))
            #expect(!output.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x0A }, "raw control character in JSON: \(output.debugDescription)")
        }
        let valid = try JSONDecoder().decode(ThemeValidateOutput.self, from: Data(Self.run(Self.dawnURL.path, json: true).output.utf8))
        #expect(valid == ThemeValidateOutput(ok: true, id: "dawn", issues: []))
    }
}

extension ThemeValidateOutput {
    init(ok: Bool, id: String?, issues: [ThemeIssue]) {
        self.init(ThemeValidationReport(issues: issues, theme: nil))
        self.ok = ok
        self.id = id
    }
}
#endif
