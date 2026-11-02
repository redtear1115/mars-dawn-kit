#if os(macOS)
import Foundation
import Testing
@testable import marsdawn

/// `OutputFile.writeAll` (kit #246): several files written as one, so a failure part-way leaves
/// none of the run's files behind, neither a destination nor a temporary.
@Suite struct OutputFileWriteAllTests {
    static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("writeall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aFailureWhileStagingLeavesNothing() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = (1...3).map { (data: Data("image \($0)".utf8), url: root.appendingPathComponent("plan-\($0).png")) }
        #expect(throws: CLIFailure.self) {
            try OutputFile.writeAll(items, force: false, failStaging: { $0 == 1 })
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(left.isEmpty, "nothing written and no temporary left: \(left)")
    }

    @Test func withoutAFailureEveryFileIsWritten() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = (1...3).map { (data: Data("image \($0)".utf8), url: root.appendingPathComponent("plan-\($0).png")) }
        try OutputFile.writeAll(items, force: false)
        for item in items { #expect(try Data(contentsOf: item.url) == item.data) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["plan-1.png", "plan-2.png", "plan-3.png"])
    }
}
#endif
