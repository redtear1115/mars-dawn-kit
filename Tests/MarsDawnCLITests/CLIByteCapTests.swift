#if os(macOS)
import Foundation
import MarsDawnKit
import Testing
@testable import marsdawn

/// `marsdawn export` over the byte cap (kit #150, owner decision BC-3): its own failure kind,
/// `input_too_large`, sharing exit code 5 with `export_failed`.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct CLIByteCapTests {
    init() { HintTesting.installViolationHandler() }

    @Test func exportRefusesAnInputOverTheCap() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-cli-bytecap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("big.md")
        let cap = ParseLimits.defaultMaxBytes
        try Data(("# Big\n\n" + String(repeating: "a", count: cap + 1 - 7)).utf8).write(to: input)
        #expect(try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int == cap + 1)
        let output = root.appendingPathComponent("big.pdf")
        // The refusal comes from the renderer's default cap; without it this would export 16 MiB.
        try #require(MarkdownRenderer.Options.preview(baseDirectory: nil).maxBytes == cap)

        var thrown: Error?
        do {
            try await MarsDawnCommand.Export.parse([input.path, "-o", output.path, "--json"]).run()
        } catch {
            thrown = error
        }
        let failure = try #require(thrown as? CLIFailure, "\(String(describing: thrown))")
        #expect(failure.kind == "input_too_large")
        #expect(failure.code == .exportFailed)
        #expect(cliExitCode(for: failure) == 5)
        #expect(failure.message.contains("16777216 bytes") && failure.message.contains("16 MB"), "\(failure.message)")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["big.md"], "no temporary PDF left")

        // What `--json` prints, compared parsed (jsonString sorts keys).
        let printed = jsonString(failureJSONObject(failure))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
        #expect(Set(parsed.keys) == ["ok", "error", "message"])
        #expect(parsed["ok"] as? Bool == false)
        #expect(parsed["error"] as? String == "input_too_large")
        #expect(parsed["message"] as? String == failure.message)
        print("B4b CLI --json: \(printed)")
    }

    /// The other kinds keep their own code's kind.
    @Test func otherFailuresKeepTheirKinds() {
        for code in (Int32(1)...Int32(63)).compactMap(CLIFailure.Code.init(rawValue:)) {
            let failure = CLIFailure(code: code, message: "m")
            #expect(failure.kind == code.kind)
            #expect(cliExitCode(for: failure) == code.rawValue)
        }
        #expect(CLIFailure(.inputTooLarge, message: "m").code.kind == "export_failed", "shares 5, not its kind")
    }
}
#endif
