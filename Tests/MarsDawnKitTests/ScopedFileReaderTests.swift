import Darwin
import Foundation
import Testing
@testable import MarsDawnKit

@Suite(.timeLimit(.minutes(1)))
struct ScopedFileReaderTests {
    private typealias Reader = ScopedFileReader

    /// A fresh folder under `parent` (default: the user temporary folder, spelled `/var/…`).
    private func makeRoot(parent: String = NSTemporaryDirectory()) throws -> URL {
        let root = URL(fileURLWithPath: parent).appendingPathComponent("scoped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data("image".utf8).write(to: root.appendingPathComponent("a.png"))
        try Data("inner".utf8).write(to: root.appendingPathComponent("dir/b.png"))
        return root
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func read(_ reader: Reader, _ components: [String], maxSize: Int64 = 1 << 20) throws(Reader.Failure) -> Data {
        try Reader.withDatalessFilesNotMaterialized { () throws(Reader.Failure) -> Data in
            try reader.open(components: components, maxSize: maxSize).readAll()
        }
    }

    /// The reader failure `body` throws, or nil if it returns.
    private func failure(_ body: () throws -> Data) -> Reader.Failure? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? Reader.Failure ?? .ioError
        }
    }

    @Test func readsAFileInsideTheRoot() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let reader = try Reader(root: root)
        #expect(reader.canonicalRootSource == .descriptor)
        #expect(try read(reader, ["a.png"]) == Data("image".utf8))
        #expect(try read(reader, ["dir", "b.png"]) == Data("inner".utf8))
        #expect(try reader.readFile(atPath: root.appendingPathComponent("dir/b.png").path, maxSize: 100) == Data("inner".utf8))
    }

    @Test func refusesASymlinkAsTheFinalComponent() throws {
        let root = try makeRoot()
        defer { remove(root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.png").path, withDestinationPath: "a.png")
        let reader = try Reader(root: root)
        #expect(failure { try read(reader, ["link.png"]) } == .notAllowed)
    }

    @Test func refusesASymlinkInAnIntermediateFolder() throws {
        let root = try makeRoot()
        defer { remove(root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dirlink").path, withDestinationPath: "dir")
        let reader = try Reader(root: root)
        #expect(failure { try read(reader, ["dirlink", "b.png"]) } == .notAllowed)
        #expect(failure { try reader.readFile(atPath: root.path + "/dirlink/b.png", maxSize: 100) } == .notAllowed)
    }

    @Test func refusesASymlinkSwappedInAfterMapping() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let reader = try Reader(root: root)
        let components = try #require(reader.components(forAbsolutePath: root.appendingPathComponent("a.png").path))
        #expect(components == ["a.png"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.png"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("a.png").path, withDestinationPath: "dir/b.png")
        #expect(failure { try read(reader, components) } == .notAllowed)
    }

    @Test func refusesAFIFOWithoutHanging() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let fifo = root.appendingPathComponent("pipe.png").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let reader = try Reader(root: root)
        let result = FailureBox()
        let elapsed = ElapsedBox()
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        // A thread of its own, and a clock started inside it. A pooled queue can leave the work
        // item unscheduled for seconds when the whole suite runs at once, and timing the wait
        // from out here would measure that scheduling delay rather than the open (which is what
        // O_NONBLOCK is here to keep short).
        let thread = Thread { @Sendable in
            started.signal()
            let begin = DispatchTime.now()
            let outcome = failure { try read(reader, ["pipe.png"]) }
            elapsed.set(DispatchTime.now().uptimeNanoseconds - begin.uptimeNanoseconds)
            result.set(outcome)
            done.signal()
        }
        thread.start()
        _ = started.wait(timeout: .now() + 30)
        if done.wait(timeout: .now() + 30) == .timedOut {
            Issue.record("Opening a FIFO never returned")
            // Release the blocked open so the thread can finish.
            let writer = Darwin.open(fifo, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            _ = done.wait(timeout: .now() + 5)
            return
        }
        #expect(result.value == .notRegular)
        // The open itself, not the time to get a thread onto a core.
        #expect(elapsed.value < 1_000_000_000, "Opening a FIFO blocked for \(Double(elapsed.value) / 1e9) s")
    }

    @Test func refusesAFolder() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let reader = try Reader(root: root)
        #expect(failure { try read(reader, ["dir"]) } == .notRegular)
    }

    @Test func refusesAFileOverTheCap() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let reader = try Reader(root: root)
        #expect(failure { try read(reader, ["a.png"], maxSize: 4) } == .tooLarge)
        #expect(try read(reader, ["a.png"], maxSize: 5) == Data("image".utf8))
    }

    @Test func refusesMissingFiles() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let reader = try Reader(root: root)
        #expect(failure { try read(reader, ["none.png"]) } == .notFound)
        #expect(failure { try read(reader, ["a.png", "x.png"]) } == .notFound)
    }

    @Test func refusesInvalidComponents() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let reader = try Reader(root: root)
        for components in [["a\0.png"], [".."], ["."], [""], ["dir/b.png"], ["a\u{7}.png"], ["a\u{85}.png"], []] {
            #expect(failure { try read(reader, components) } == .notAllowed, "\(components)")
        }
        let path = root.path
        for request in ["\(path)/a\0.png", "\(path)/../a.png", "\(path)/dir/../a.png", "\(path)/./a.png",
                        "\(path)//a.png", "\(path)/dir/", "\(path)/", path, "\(path)/a\u{1}.png"] {
            #expect(reader.components(forAbsolutePath: request) == nil, "\(request)")
        }
    }

    @Test func mapsOnlyPathsInsideEitherRootSpellingAsExactBytes() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let reader = try Reader(root: root)
        #expect(reader.components(forAbsolutePath: root.path + "/dir/b.png") == ["dir", "b.png"])
        #expect(reader.components(forAbsolutePath: reader.canonicalRoot + "/dir/b.png") == ["dir", "b.png"])
        // Outside both spellings.
        #expect(reader.components(forAbsolutePath: root.path + "x/a.png") == nil)
        #expect(reader.components(forAbsolutePath: root.deletingLastPathComponent().path + "/other/a.png") == nil)
        #expect(reader.components(forAbsolutePath: "/Users/a.png") == nil)
        // Case and Unicode normalization never match.
        #expect(reader.components(forAbsolutePath: reader.canonicalRoot.uppercased() + "/a.png") == nil)
        // Canonically equivalent Unicode spellings are different bytes. The folder is stored
        // composed (NFC); Foundation file URLs spell it decomposed (NFD), so the reader's two
        // root spellings cover both. A third equivalent spelling (combining marks in another
        // order) matches neither, although Swift's `String ==` would call it equal.
        let nfc = root.path + "/\u{1EA1}\u{307}"
        let nfd = root.path + "/a\u{323}\u{307}"
        let unordered = root.path + "/a\u{307}\u{323}"
        #expect(nfc == unordered)
        #expect(mkdir(nfc, 0o755) == 0)
        let unicodeReader = try Reader(root: URL(fileURLWithPath: nfc))
        #expect(unicodeReader.canonicalRoot.utf8.elementsEqual((reader.canonicalRoot + "/\u{1EA1}\u{307}").utf8))
        #expect(unicodeReader.callerRoot.utf8.elementsEqual(("/private" + nfd).utf8))
        #expect(unicodeReader.components(forAbsolutePath: reader.canonicalRoot + "/\u{1EA1}\u{307}/a.png") == ["a.png"])
        #expect(unicodeReader.components(forAbsolutePath: nfd + "/a.png") == ["a.png"])
        #expect(unicodeReader.components(forAbsolutePath: unordered + "/a.png") == nil)
    }

    @Test func refusesTheFileSystemRoot() {
        #expect(throws: Reader.Failure.self) { try Reader(root: URL(fileURLWithPath: "/")) }
        #expect(throws: Reader.Failure.self) { try Reader(root: URL(fileURLWithPath: "/private/../")) }
        #expect(throws: Reader.Failure.self) { try Reader(root: URL(string: "https://example.com/")!) }
    }

    @Test func refusesAFileWhoseDescriptorPathLeavesTheScope() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let honest = try Reader(root: root)
        #expect(try read(honest, ["a.png"]) == Data("image".utf8))
        let moved = try Reader(root: root) { _ in Array("/private/etc/a.png".utf8) }
        #expect(failure { try read(moved, ["a.png"]) } == .notAllowed)
        // A sibling folder whose name starts with the root's name isn't inside it.
        let sibling = try Reader(root: root) { _ in Array((honest.canonicalRoot + "x/a.png").utf8) }
        #expect(failure { try read(sibling, ["a.png"]) } == .notAllowed)
        let failed = try Reader(root: root) { _ in nil }
        #expect(failure { try read(failed, ["a.png"]) } == .notAllowed)
    }

    @Test func rangeReadsReturnExactBytes() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let bytes = Data((0..<256).map { UInt8($0) })
        try bytes.write(to: root.appendingPathComponent("bytes.bin"))
        let reader = try Reader(root: root)
        try Reader.withDatalessFilesNotMaterialized { () throws(Reader.Failure) in
            let file = try reader.open(components: ["bytes.bin"], maxSize: 256)
            #expect(file.size == 256)
            #expect(try file.read(offset: 10, length: 20) == bytes[10..<30])
            #expect(try file.read(offset: 255, length: 1) == bytes[255...])
            #expect(try file.read(offset: 0, length: 0) == Data())
            #expect(try file.readAll() == bytes)
            #expect(throws: Reader.Failure.ioError) { try file.read(offset: 250, length: 10) }
            #expect(throws: Reader.Failure.ioError) { try file.read(offset: -1, length: 1) }
        }
    }

    @Test func rootWithoutReadPermissionWorksThroughRealpath() throws {
        let root = try makeRoot()
        defer {
            chmod(root.path, 0o755)
            remove(root)
        }
        #expect(chmod(root.path, 0o311) == 0)
        #expect(Darwin.open(root.path, O_RDONLY | O_DIRECTORY) == -1)
        let reader = try Reader(root: root)
        #expect(reader.canonicalRootSource == .realpath)
        #expect(try read(reader, ["a.png"]) == Data("image".utf8))
        #expect(failure { try read(reader, ["none.png"]) } == .notFound)
    }

    @Test func turnsOffDatalessMaterializationOnlyInsideTheBlock() throws {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let before = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        let inside = try Reader.withDatalessFilesNotMaterialized { () throws(Reader.Failure) -> Int32 in
            getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        }
        #expect(inside == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(getiopolicy_np(type, IOPOL_SCOPE_THREAD) == before)
    }

    // MARK: System alias spellings

    @Test func aliasTableMatchesWholeFirstComponentsOnly() {
        let normalize = Reader.normalizingSystemAliases
        #expect(normalize("/tmp") == "/private/tmp")
        #expect(normalize("/tmp/x") == "/private/tmp/x")
        #expect(normalize("/var/folders/x") == "/private/var/folders/x")
        #expect(normalize("/etc/hosts") == "/private/etc/hosts")
        #expect(normalize("/private/tmp/x") == "/private/tmp/x")
        #expect(normalize("/tmpfoo/x") == "/tmpfoo/x")
        #expect(normalize("/variable/x") == "/variable/x")
        #expect(normalize("/TMP/x") == "/TMP/x")
        #expect(normalize("/x/tmp/y") == "/x/tmp/y")
        #expect(normalize("tmp/x") == "tmp/x")
        #expect(normalize("/System/Volumes/Data/private/tmp/x") == "/System/Volumes/Data/private/tmp/x")
    }

    @Test func aliasLookalikesAreNotRewritten() throws {
        let root = try makeRoot(parent: "/tmp")
        defer { remove(root) }
        let reader = try Reader(root: root)
        let name = root.lastPathComponent
        #expect(reader.components(forAbsolutePath: "/tmpfoo/\(name)/a.png") == nil)
        #expect(reader.components(forAbsolutePath: "/variable/\(name)/a.png") == nil)
        #expect(reader.components(forAbsolutePath: "/tmp/\(name)/a.png") == ["a.png"])
    }

    private var varTemporaryDirectory: String {
        get throws {
            let path = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
            try #require(path.hasPrefix("/var/"), "expected a /var temporary folder, got \(path)")
            return path
        }
    }

    @Test func rootSpelledVarRequestSpelledPrivate() throws {
        let root = try makeRoot(parent: try varTemporaryDirectory)
        defer { remove(root) }
        let reader = try Reader(root: URL(fileURLWithPath: root.path))
        #expect(try reader.readFile(atPath: "/private" + root.path + "/dir/b.png", maxSize: 100) == Data("inner".utf8))
    }

    @Test func rootSpelledPrivateRequestSpelledVar() throws {
        let root = try makeRoot(parent: try varTemporaryDirectory)
        defer { remove(root) }
        let reader = try Reader(root: URL(fileURLWithPath: "/private" + root.path))
        #expect(try reader.readFile(atPath: root.path + "/dir/b.png", maxSize: 100) == Data("inner".utf8))
    }

    @Test func rootSpelledTmpRequestSpelledPrivate() throws {
        let root = try makeRoot(parent: "/tmp")
        defer { remove(root) }
        #expect(root.path.hasPrefix("/tmp/"))
        let reader = try Reader(root: root)
        #expect(try reader.readFile(atPath: "/private" + root.path + "/a.png", maxSize: 100) == Data("image".utf8))
    }

    @Test func rootSpelledPrivateRequestSpelledTmp() throws {
        let root = try makeRoot(parent: "/private/tmp")
        defer { remove(root) }
        let reader = try Reader(root: root)
        let tmpSpelling = String(root.path.dropFirst("/private".count))
        #expect(tmpSpelling.hasPrefix("/tmp/"))
        #expect(try reader.readFile(atPath: tmpSpelling + "/a.png", maxSize: 100) == Data("image".utf8))
    }
}

/// Nanoseconds the timed call took, written on the worker thread and read on the test's.
private final class ElapsedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64 = 0
    var value: UInt64 { lock.withLock { stored } }
    func set(_ value: UInt64) { lock.withLock { stored = value } }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScopedFileReader.Failure?
    var value: ScopedFileReader.Failure? { lock.withLock { stored } }
    func set(_ value: ScopedFileReader.Failure?) { lock.withLock { stored = value } }
}
