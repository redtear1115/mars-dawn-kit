#if os(macOS)
import Foundation

/// The one-line stderr tip after a successful `export` or `open` when the agent skill is missing
/// or out of date (kit #172). The decision is the pure `decide`; `emitAfterSuccess` is the thin
/// runner around it (lstat + one capped read of the skill, one tiny cache file), and everything
/// that runner touches comes from `Environment`, replaceable per task with `$override` so a test
/// never reads or writes the real home and parallel suites can't race on it.
enum SkillHint {
    /// What the default skill folder holds, as far as the hint cares.
    enum State: String, Equatable, Sendable {
        case missing, differs, equal
    }

    static let optOutVariable = "MARSDAWN_NO_SKILL_HINT"
    /// A bigger `SKILL.md` than this counts as "differs" without being read.
    static let readCap = 256 * 1024

    static let missingMessage = "Tip: run \"marsdawn skill --install\" so your agent knows how to use marsdawn."
    static let differsMessage = "Tip: your agent skill differs from this version of marsdawn. "
        + "Run \"marsdawn skill --install --force\" to update it (this replaces any local edits)."

    /// What is remembered between runs: `<version> <state>`.
    static func record(version: String, state: State) -> String { "\(version) \(state.rawValue)" }

    /// The cheap gates, checked before any filesystem access.
    static func isEnabled(isTTY: Bool, json: Bool, env: [String: String]) -> Bool {
        guard !json, isTTY else { return false }
        return (env[optOutVariable] ?? "").isEmpty
    }

    /// The tip to print, or nil. `state` is nil when the folder couldn't be inspected safely;
    /// `stored` is the cache file's content (nil when absent or unreadable).
    static func decide(
        state: State?, isTTY: Bool, json: Bool, env: [String: String], stored: String?, version: String
    ) -> String? {
        guard isEnabled(isTTY: isTTY, json: json, env: env), let state else { return nil }
        if let stored, stored == record(version: version, state: state) { return nil }
        switch state {
        case .missing: return missingMessage
        case .differs: return differsMessage
        case .equal: return nil
        }
    }

    // MARK: - Environment

    struct Environment: Sendable {
        var cacheDirectory: URL
        var skillDirectory: URL
        var isTTY: @Sendable () -> Bool
        var stderr: @Sendable (String) -> Void
        var environment: [String: String]
        var version: String
    }

    /// Per task, like `ThemeRegistry.$override`. Every CLI test that runs a successful export or
    /// open sets it; without one, the production runner in a test process records a violation
    /// and returns before touching the filesystem.
    @TaskLocal static var override: Environment?

    /// Called when the production runner is reached inside a test process. The test target
    /// installs one that records an `Issue` (this target can't import Testing).
    nonisolated(unsafe) static var underTestViolation: (@Sendable (String) -> Void)?

    static func isRunningUnderTest() -> Bool {
        let info = ProcessInfo.processInfo
        return info.environment["XCTestConfigurationFilePath"] != nil
            || info.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || info.processName.contains("xctest") || info.processName.contains("swiftpm-testing-helper")
    }

    /// `$HOME` if it is a non-blank absolute path, otherwise `homeDirectoryForCurrentUser` (the
    /// rule `SkillInstaller.productionDefaultDirectory` applies, kept pure so a test can feed it).
    static func home(environment: [String: String], fallback: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let value = environment["HOME"], !value.trimmingCharacters(in: .whitespaces).isEmpty, value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return fallback
    }

    static func productionEnvironment() -> Environment {
        Environment(
            cacheDirectory: home(environment: ProcessInfo.processInfo.environment).appendingPathComponent("Library/Caches/marsdawn", isDirectory: true),
            skillDirectory: SkillInstaller.productionDefaultDirectory(),
            isTTY: { isatty(STDERR_FILENO) != 0 },
            stderr: { FileHandle.standardError.write(Data($0.utf8)) },
            environment: ProcessInfo.processInfo.environment,
            version: MarsDawnCLI.version
        )
    }

    // MARK: - Runner

    /// Call after a successful, human-readable `export` or `open`, never on a failure path.
    /// `json` is the parsed `--json` flag. Never throws and never writes to stdout.
    static func emitAfterSuccess(json: Bool) {
        if json { return }
        let environment: Environment
        if let override {
            environment = override
        } else if isRunningUnderTest() {
            underTestViolation?("SkillHint's production runner ran inside a test with no SkillHint.$override; it returned before touching the filesystem")
            return
        } else {
            environment = productionEnvironment()
        }
        guard isEnabled(isTTY: environment.isTTY(), json: json, env: environment.environment) else { return }
        let state = inspect(directory: environment.skillDirectory)
        let cacheFile = environment.cacheDirectory.appendingPathComponent("skill-hint")
        let stored = readSmallFile(cacheFile.path, cap: 4096).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let state else { return }
        if let message = decide(
            state: state, isTTY: true, json: false, env: environment.environment, stored: stored, version: environment.version
        ) {
            environment.stderr(message + "\n")
        }
        let current = record(version: environment.version, state: state)
        if stored != current { store(current, in: environment.cacheDirectory, file: cacheFile) }
    }

    /// Best effort: any failure leaves the hint to be shown again next time.
    private static func store(_ record: String, in directory: URL, file: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try Data((record + "\n").utf8).write(to: file, options: .atomic)
        } catch {}
    }

    // MARK: - Read-only inspection

    /// The state of `<directory>/SKILL.md`, with the same lstat rules as `SkillInstaller.install`:
    /// a symlink escaping the folder is never followed, anything but a plain file is not
    /// readable, and any error means nil (no hint).
    static func inspect(directory: URL) -> State? {
        let target = directory.appendingPathComponent("SKILL.md")
        var info = stat()
        if lstat(target.path, &info) != 0 { return errno == ENOENT ? .missing : nil }
        var path = target.path
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            break
        case S_IFLNK:
            let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
            let resolved = target.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(resolvedDirectory.path + "/") else { return nil }
            var resolvedInfo = stat()
            if lstat(resolved.path, &resolvedInfo) != 0 { return errno == ENOENT ? .missing : nil }
            guard resolvedInfo.st_mode & S_IFMT == S_IFREG else { return nil }
            path = resolved.path
        default:
            return nil
        }
        guard let data = readSmallFile(path, cap: readCap) else { return nil }
        if data.count > readCap { return .differs }
        return data == Data((MarsDawnSkill.text + "\n").utf8) ? .equal : .differs
    }

    /// Up to `cap + 1` bytes of a regular file, or nil. `O_NONBLOCK | O_NOFOLLOW` so a FIFO swapped
    /// in after the lstat can't hang the read, and the opened descriptor is checked to be regular.
    static func readSmallFile(_ path: String, cap: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= cap {
            let count = read(descriptor, &buffer, min(buffer.count, cap + 1 - data.count))
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
