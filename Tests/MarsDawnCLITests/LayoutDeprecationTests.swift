#if os(macOS)
import Foundation
import Testing
@testable import marsdawn

private final class Anchor {}

/// kit #211: `--layout manual` prints one deprecation line on stderr and nothing else changes.
/// Runs the built `marsdawn` as a subprocess so stdout and stderr are separate pipes. It pins
/// MARSDAWN_APP_PATH to a path that doesn't exist and gives it a scratch HOME: export never
/// needs, and these tests never launch, the real MarsDawn app.
@Suite(.timeLimit(.minutes(3)))
struct LayoutDeprecationTests {
    static let warning = "warning: --layout manual is deprecated; use --layout handbook"

    struct Run { var status: Int32; var stdout: String; var stderr: String }

    static func binary() throws -> URL {
        let products = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("marsdawn")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "no marsdawn at \(url.path)")
        return url
    }

    static func export(layout: String, json: Bool) throws -> Run {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("a.md")
        try Data("# Hi\n\nText.\n".utf8).write(to: input)
        let process = Process()
        process.executableURL = try binary()
        process.arguments = ["export", input.path, "-o", root.appendingPathComponent("a.pdf").path, "--layout", layout] + (json ? ["--json"] : [])
        process.environment = ["MARSDAWN_APP_PATH": "/nonexistent", "HOME": root.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self))
    }

    @Test func manualWarnsOnStderrOnly() throws {
        let manual = try Self.export(layout: "manual", json: false)
        let handbook = try Self.export(layout: "handbook", json: false)
        #expect(manual.stderr.components(separatedBy: Self.warning).count == 2, "exactly once: \(manual.stderr)")
        #expect(manual.stderr == Self.warning + "\n", "the only stderr line: \(manual.stderr)")
        #expect(!manual.stdout.contains("deprecated"))
        #expect(manual.status == 0 && manual.status == handbook.status)
    }

    @Test func manualWithJSONLeavesStdoutParsableAndWarningFree() throws {
        let manual = try Self.export(layout: "manual", json: true)
        let handbook = try Self.export(layout: "handbook", json: true)
        #expect(manual.stderr == Self.warning + "\n", "\(manual.stderr)")
        #expect(!manual.stdout.contains("deprecated"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(manual.stdout.utf8)) as? [String: Any], Comment(rawValue: manual.stdout))
        #expect(object["ok"] as? Bool == true)
        let other = try #require(try JSONSerialization.jsonObject(with: Data(handbook.stdout.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set(other.keys))
        #expect(manual.status == handbook.status)
    }

    @Test func handbookAndDocumentDoNotWarn() throws {
        for layout in ["handbook", "document"] {
            let run = try Self.export(layout: layout, json: false)
            #expect(run.status == 0, "\(layout): \(run.stderr)")
            #expect(run.stderr.isEmpty, "\(layout): \(run.stderr)")
        }
    }
}
#endif
