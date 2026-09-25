#if canImport(Darwin)
import Darwin
import Foundation
import OSLog

/// Reads regular files inside one folder, the scope root, without ever following a symlink.
///
/// - The root is known by two spellings: as the caller passed it (`callerRoot`, lexical) and
///   as the file system names it (`canonicalRoot`, symlinks resolved). A request path must
///   start with one of them, compared as exact bytes.
/// - The file is opened by its canonical path with `O_NOFOLLOW_ANY`, so a symlink anywhere
///   below the root, including one swapped in after the check, makes the open fail. The
///   canonical root itself holds no symlinks. `O_NONBLOCK` keeps a FIFO from hanging.
/// - The open file must be a regular file within the size cap, and the path the kernel reports
///   for the descriptor must still be inside the canonical root.
/// - Reads use `pread` (no memory maps) and never materialize dataless (iCloud) files.
///
/// Errors never carry paths.
struct ScopedFileReader: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case notFound, notAllowed, tooLarge, notRegular, ioError
    }

    /// How `canonicalRoot` was found.
    enum CanonicalRootSource: Equatable, Sendable {
        /// `F_GETPATH` of the opened root directory.
        case descriptor
        /// `realpath(3)`, for roots that can be searched but not opened for reading.
        case realpath
    }

    /// The path the kernel reports for an open descriptor, as bytes (`F_GETPATH`).
    typealias DescriptorPath = @Sendable (Int32) -> [UInt8]?

    private static let log = Logger(subsystem: "dev.southern-light.marsdawn-kit", category: "ScopedFileReader")
    private static let slash = UInt8(ascii: "/")

    /// macOS system symlinks at the top of the file system. A path whose first component is
    /// exactly one of these names is respelled with the target, on both the root and the
    /// request side. Nothing inside a scope is ever respelled.
    static let systemAliases: [(name: String, target: String)] = [
        ("tmp", "/private/tmp"),
        ("var", "/private/var"),
        ("etc", "/private/etc"),
    ]

    /// The root as the caller spelled it (standardized, system aliases respelled).
    let callerRoot: String
    /// The root with every symlink resolved; never `/`.
    let canonicalRoot: String
    let canonicalRootSource: CanonicalRootSource
    private let fileDescriptorPath: DescriptorPath

    /// - Parameter fileDescriptorPath: Looks up the path of each opened file. Tests inject a
    ///   replacement; the root's own lookup always uses `F_GETPATH`.
    init(root: URL, fileDescriptorPath: @escaping DescriptorPath = ScopedFileReader.descriptorPath) throws(Failure) {
        guard root.isFileURL else { throw .notAllowed }
        let lexical = root.standardizedFileURL.path
        guard lexical.utf8.first == Self.slash, !lexical.utf8.contains(0) else { throw .notAllowed }

        let canonical: [UInt8]
        let source: CanonicalRootSource
        let descriptor = Darwin.open(lexical, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            guard let path = Self.descriptorPath(descriptor) else { throw .ioError }
            canonical = path
            source = .descriptor
        } else if let resolved = realpath(lexical, nil) {
            defer { free(resolved) }
            canonical = Array(UnsafeBufferPointer(start: resolved, count: strlen(resolved))).map { UInt8(bitPattern: $0) }
            source = .realpath
        } else {
            throw Self.failure(errno)
        }
        guard let canonicalRoot = Self.validUTF8(canonical),
              canonical.first == Self.slash, canonical != [Self.slash], canonical.last != Self.slash
        else { throw .notAllowed }

        self.callerRoot = Self.normalizingSystemAliases(lexical)
        self.canonicalRoot = canonicalRoot
        self.canonicalRootSource = source
        self.fileDescriptorPath = fileDescriptorPath
    }

    // MARK: Mapping

    /// Respells a path whose first component is exactly a system alias (`/tmp`, `/var`, `/etc`).
    static func normalizingSystemAliases(_ path: String) -> String {
        let bytes = Array(path.utf8)
        guard bytes.first == slash else { return path }
        let end = bytes[1...].firstIndex(of: slash) ?? bytes.endIndex
        let first = bytes[1..<end]
        for alias in systemAliases where first.elementsEqual(alias.name.utf8) {
            return alias.target + String(decoding: bytes[end...], as: UTF8.self)
        }
        return path
    }

    /// The components below the root of an absolute, lexically standardized path, or nil if
    /// the path isn't inside either spelling of the root or has an invalid component.
    func components(forAbsolutePath path: String) -> [String]? {
        let request = Array(Self.normalizingSystemAliases(path).utf8)
        for root in [callerRoot, canonicalRoot] {
            let prefix = Array(root.utf8) + [Self.slash]
            guard request.starts(with: prefix) else { continue }
            var components: [String] = []
            for part in request[prefix.count...].split(separator: Self.slash, omittingEmptySubsequences: false) {
                guard let component = Self.validUTF8(Array(part)), Self.isValidComponent(component) else { return nil }
                components.append(component)
            }
            return components
        }
        return nil
    }

    /// A single path component: not empty, `.` or `..`, and free of `/`, NUL and control characters.
    static func isValidComponent(_ component: String) -> Bool {
        let bytes = Array(component.utf8)
        guard !bytes.isEmpty, bytes != [0x2E], bytes != [0x2E, 0x2E], !bytes.contains(slash) else { return false }
        return !component.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// `bytes` as a string, or nil if they aren't valid UTF-8.
    static func validUTF8(_ bytes: [UInt8]) -> String? {
        let string = String(decoding: bytes, as: UTF8.self)
        return string.utf8.elementsEqual(bytes) ? string : nil
    }

    // MARK: Opening and reading

    /// An open regular file; the descriptor closes when this is released.
    final class OpenFile {
        let descriptor: Int32
        let size: Int64

        fileprivate init(descriptor: Int32, size: Int64) {
            self.descriptor = descriptor
            self.size = size
        }

        deinit { close(descriptor) }

        /// Exactly `length` bytes from `offset`; a short read fails.
        func read(offset: Int64, length: Int) throws(Failure) -> Data {
            guard offset >= 0, length >= 0 else { throw .ioError }
            guard length > 0 else { return Data() }
            var data = Data(count: length)
            var done = 0
            var failure: Failure?
            data.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { failure = .ioError; return }
                while done < length {
                    let count = pread(descriptor, base + done, length - done, off_t(offset) + off_t(done))
                    if count > 0 {
                        done += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        failure = .ioError
                        return
                    }
                }
            }
            if let failure { throw failure }
            return data
        }

        func readAll() throws(Failure) -> Data {
            guard size <= Int64(Int.max) else { throw .tooLarge }
            return try read(offset: 0, length: Int(size))
        }
    }

    /// Opens `components` below the canonical root. Call inside `withDatalessFilesNotMaterialized`.
    func open(components: [String], maxSize: Int64) throws(Failure) -> OpenFile {
        guard !components.isEmpty, components.allSatisfy(Self.isValidComponent) else { throw .notAllowed }
        let path = canonicalRoot + "/" + components.joined(separator: "/")
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure(errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw .ioError
        }
        let file = OpenFile(descriptor: descriptor, size: Int64(info.st_size))
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw .notRegular }
        guard file.size >= 0, file.size <= maxSize else { throw .tooLarge }
        // The file must still be inside the root (defence in depth against renames).
        guard let actual = fileDescriptorPath(descriptor),
              actual.starts(with: Array(canonicalRoot.utf8) + [Self.slash])
        else {
            Self.log.error("Refused a file whose descriptor path is outside the scope")
            throw .notAllowed
        }
        return file
    }

    /// Maps, opens and reads a whole file named by an absolute path.
    func readFile(atPath path: String, maxSize: Int64) throws(Failure) -> Data {
        guard let components = components(forAbsolutePath: path) else { throw .notAllowed }
        return try Self.withDatalessFilesNotMaterialized { () throws(Failure) -> Data in
            try open(components: components, maxSize: maxSize).readAll()
        }
    }

    /// The calling thread's dataless-materialization policy: `getiopolicy_np` / `setiopolicy_np`
    /// on `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`, thread scope. Both return -1 on failure.
    /// Tests inject a replacement to make a call fail; everything else uses `.thread`.
    struct DatalessPolicy: Sendable {
        var get: @Sendable () -> Int32
        var set: @Sendable (Int32) -> Int32

        static let thread = DatalessPolicy(
            get: { getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) },
            set: { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, $0) }
        )
    }

    /// Runs `body` with this thread set not to materialize dataless files, so reading one fails
    /// quickly instead of waiting for a download. Afterwards the previous policy is restored, or,
    /// if it couldn't be read, `IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT` (follow the process
    /// policy), so a failed read never leaves the thread with materialization off.
    static func withDatalessFilesNotMaterialized<T>(
        policy: DatalessPolicy = .thread,
        _ body: () throws(Failure) -> T
    ) throws(Failure) -> T {
        let previous = policy.get()
        let changed = policy.set(IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        if !changed {
            log.error("Couldn't turn off dataless file materialization: \(errno, privacy: .public)")
        }
        defer {
            if changed {
                _ = policy.set(previous >= 0 ? previous : IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
            }
        }
        return try body()
    }

    // MARK: Helpers

    static let descriptorPath: DescriptorPath = { descriptor in
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1, let end = buffer.firstIndex(of: 0) else { return nil }
        return buffer[..<end].map { UInt8(bitPattern: $0) }
    }

    private static func failure(_ code: Int32) -> Failure {
        switch code {
        case ENOENT, ENOTDIR: .notFound
        case ELOOP, EACCES, EPERM, ENAMETOOLONG: .notAllowed
        default: .ioError
        }
    }
}
#endif
