// EXPERIMENT (#26), delete before merge: which part of a raw Thread's closure makes macOS 15's
// Concurrency runtime ask which executor it is on (and trap)?
import Darwin
import Foundation
import Testing
@testable import MarsDawnKit

struct Experiment26Tests {
    private func plainHelper() -> Int { 42 }

    private static func staticFIFORead(_ reader: ScopedFileReader) -> ScopedFileReader.Failure? {
        do {
            _ = try ScopedFileReader.withDatalessFilesNotMaterialized { () throws(ScopedFileReader.Failure) -> Data in
                try reader.open(components: ["pipe.png"], maxSize: 1 << 20).readAll()
            }
            return nil
        } catch {
            return error as? ScopedFileReader.Failure ?? .ioError
        }
    }

    private func onThread(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        Thread { body(); done.signal() }.start()
        #expect(done.wait(timeout: .now() + 30) == .success)
    }

    @Test func x1EmptyThread() { onThread {} }

    @Test func x2ThreadReadsTheClock() { onThread { _ = DispatchTime.now() } }

    @Test func x3ThreadCallsAnInstanceHelper() { onThread { _ = plainHelper() } }

    @Test func x4ThreadDoesTheFIFOReadThroughAStatic() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("x26-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(mkfifo(root.appendingPathComponent("pipe.png").path, 0o600) == 0)
        let reader = try ScopedFileReader(root: root)
        onThread { _ = Self.staticFIFORead(reader) }
    }
}
