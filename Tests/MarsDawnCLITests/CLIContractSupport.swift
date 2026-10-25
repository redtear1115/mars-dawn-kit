#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import marsdawn

/// A stand-in for the opener `Open.run()` hands documents and folders to, so a test never reaches
/// `NSWorkspace` and can say exactly what would have been sent.
final class OpenRecorder: @unchecked Sendable {
    struct Call: CustomStringConvertible {
        var urls: [URL]
        var app: URL
        var activates: Bool
        var description: String { "open \(urls.map(\.path)) with \(app.path), activates \(activates)" }
    }

    private let lock = NSLock()
    private var storage: [Call] = []

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return storage }

    var opener: @MainActor @Sendable ([URL], URL, NSWorkspace.OpenConfiguration) async throws -> Void {
        { [self] urls, app, configuration in
            record(Call(urls: urls, app: app, activates: configuration.activates))
        }
    }

    private func record(_ call: Call) {
        lock.lock()
        storage.append(call)
        lock.unlock()
    }
}

/// Everything a command passed to `OutputOptions.report`, one entry per printed line.
final class PrintedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }

    /// The one line printed, parsed as the JSON object `--json` promises.
    func jsonObject() throws -> [String: Any] {
        let lines = all
        try #require(lines.count == 1, "one JSON line expected: \(lines)")
        return try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any], Comment(rawValue: lines[0]))
    }
}

/// The built `marsdawn`, run as a subprocess the way a script or an agent runs it, so
/// `main.swift`'s `finish()` and the real `MarsDawnApp.locate` are in the path. The environment is
/// pinned the way `HandoutCLITests` and `LayoutDeprecationTests` pin it: `MARSDAWN_APP_PATH` at a
/// path that does not exist (so no run can find, let alone launch, the real app), a scratch HOME
/// and a minimal PATH.
enum CLIProcess {
    struct Run {
        var status: Int32
        var stdout: String
        var stderr: String

        /// stdout parsed as the single JSON object `--json` prints.
        func jsonObject() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any], Comment(rawValue: stdout))
        }
    }

    private final class Anchor {}

    static func binary() throws -> URL {
        let products = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("marsdawn")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "no marsdawn at \(url.path)")
        return url
    }

    /// A scratch directory, removed by the caller.
    static func scratch() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marsdawn-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func run(_ arguments: [String], in root: URL) throws -> Run {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["MARSDAWN_APP_PATH": "/nonexistent", "HOME": root.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
#endif
