#if os(macOS)
import AppKit
import ArgumentParser
import Foundation
import MarsDawnExport
import MarsDawnKit

/// `marsdawn`: open Markdown in MarsDawn, or export it to PDF, from a shell or an LLM agent.
struct MarsDawnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marsdawn",
        abstract: "Open Markdown documents in MarsDawn or export them to PDF.",
        discussion: """
        export renders on its own and needs nothing else installed. open hands the files to the \
        MarsDawn app, so it needs the app, which is not publicly available yet.
        Pass --json for machine-readable results. Exit codes: 0 success, \(CLIFailure.Code.inputNotFound.rawValue) input not found, \
        \(CLIFailure.Code.appNotInstalled.rawValue) MarsDawn not installed (open only), \(CLIFailure.Code.outputExists.rawValue) output exists \
        (use --force), \(CLIFailure.Code.exportFailed.rawValue) export failed, \(CLIFailure.Code.appCannotOpenFolders.rawValue) this MarsDawn \
        can't show a folder (open only), 64 usage error.
        """,
        version: MarsDawnCLI.version,
        subcommands: [Open.self, Export.self, Skill.self]
    )
}

// MARK: - Shared

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print a JSON result on stdout instead of text.")
    var json = false

    func report(_ fields: [String: Any], text: String) {
        if json {
            var object = fields
            object["ok"] = true
            printJSON(object)
        } else {
            print(text)
        }
    }
}

func jsonString(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

func printJSON(_ object: [String: Any]) {
    print(jsonString(object))
}

/// A failure with a stable exit code and a machine-readable kind.
struct CLIFailure: Error, CustomStringConvertible {
    enum Code: Int32 {
        case inputNotFound = 2
        case appNotInstalled = 3
        case outputExists = 4
        case exportFailed = 5
        case appCannotOpenFolders = 6

        var kind: String {
            switch self {
            case .inputNotFound: "input_not_found"
            case .appNotInstalled: "app_not_installed"
            case .outputExists: "output_exists"
            case .exportFailed: "export_failed"
            case .appCannotOpenFolders: "app_cannot_open_folders"
            }
        }
    }

    let code: Code
    let message: String
    var description: String { message }

    /// Wording approved by the owner (#165).
    static func appCannotOpenFolders(app: URL) -> CLIFailure {
        CLIFailure(
            code: .appCannotOpenFolders,
            message: "This version of MarsDawn can't show a folder from the command line; that needs "
                + "an update to MarsDawn. Nothing was opened. Open the files without the folder, or "
                + "use File > Open Folder… in MarsDawn. (App: \(app.path))"
        )
    }

    static func appNotInstalled() -> CLIFailure {
        CLIFailure(code: .appNotInstalled, message: "MarsDawn is not installed. open needs the app, which is not publicly available yet; export works without it.")
    }

    /// `appNotInstalled`, but naming why `$MARSDAWN_APP_PATH` was rejected. Same code and kind
    /// (`app_not_installed`): nothing that reads the exit code or the JSON `error` field needs to
    /// change, only the `message`.
    static func appPathOverrideRejected(_ reason: String) -> CLIFailure {
        CLIFailure(code: .appNotInstalled, message: "$MARSDAWN_APP_PATH was ignored: \(reason)")
    }
}

/// The status `marsdawn` exits with for an error: a `CLIFailure`'s own code, `WaitRangeFailure`'s
/// or `SkillInstallFailure`'s own code, and otherwise ArgumentParser's — 64 for a usage error, 0
/// for `--help` and `--version`.
func cliExitCode(for error: Error) -> Int32 {
    if let failure = error as? CLIFailure { return failure.code.rawValue }
    if error is WaitRangeFailure { return WaitRangeFailure.exitCode }
    if error is SkillInstallFailure { return SkillInstallFailure.exitCode }
    return MarsDawnCommand.exitCode(for: error).rawValue
}

/// `--wait` outside 0–30 (plan L4). A separate type from `CLIFailure`: this is a usage error, so
/// it exits `64`, the codebase's own convention for one (every other `Open` validation error, such
/// as `--line` out of range, throws ArgumentParser's `ValidationError` and gets `64` the same way).
/// The plan's draft said exit `2`, but `2` is already `CLIFailure.Code.inputNotFound`'s number for
/// an unrelated failure, so a bad `--wait` can't reuse it without two different failures sharing one
/// code. Kept as its own type rather than a `ValidationError`, both because `run()` must throw it
/// as the very first thing it does — before resolving targets, folders or the app — and
/// `validate()` runs too early for that, and because it carries a stable machine-readable
/// `wait_out_of_range` kind for `--json`, which a plain `ValidationError` doesn't support.
struct WaitRangeFailure: Error, CustomStringConvertible {
    let value: Int
    var message: String { "--wait must be between 0 and 30 seconds, but \(value) was given." }
    var description: String { message }
    static let exitCode: Int32 = 64
    static let kind = "wait_out_of_range"
}

/// `skill --install` refuses to write, for a reason the person can fix rather than a runtime
/// failure: a different `SKILL.md` already at the target without `--force`, the target being a
/// symlink that escapes the folder it's meant to stay in, the target being something other than a
/// plain file (a folder, a FIFO, …), or an existing file that can't even be read to compare. A
/// usage error like `WaitRangeFailure` (#120): it exits `64`, not one of `CLIFailure.Code`'s
/// runtime codes, and carries its own machine-readable `kind` for `--json`.
struct SkillInstallFailure: Error, CustomStringConvertible {
    enum Kind: String {
        /// A `SKILL.md` is already at the target and its bytes differ from this version's.
        case differs = "skill_differs"
        /// The target path is a symlink whose resolved destination is outside the target folder.
        case unsafeSymlink = "skill_unsafe_symlink"
        /// Something is at the target path (or at what a safe symlink there resolves to) that
        /// isn't a plain file — a folder, a FIFO, a socket, a device. Refused unconditionally,
        /// `--force` included: replacing a folder isn't "replacing a file", and `--force` only
        /// ever means "yes, overwrite the differing SKILL.md I asked about."
        case notAFile = "skill_target_not_a_file"
        /// A plain file is already at the target, but it couldn't be read to compare against this
        /// version's skill (permission denied, most likely). Treated as differing: refused without
        /// `--force`, same as bytes that don't match, rather than guessed at and silently replaced.
        case unreadable = "skill_unreadable"
    }

    let kind: Kind
    let message: String
    var description: String { message }
    static let exitCode: Int32 = 64
}

/// Where MarsDawn is installed. Replaceable for tests.
enum MarsDawnApp {
    static let bundleIdentifier = "dev.southern-light.marsdawn"

    /// What `resolveOverride` found for `$MARSDAWN_APP_PATH`, once the variable is known to be set.
    enum OverrideOutcome: Equatable {
        /// Nothing exists at the override path.
        case notFound
        /// A bundle exists there and its `CFBundleIdentifier` is `MarsDawnApp.bundleIdentifier` or a
        /// `MarsDawnApp.bundleIdentifier.*` copy.
        case app(URL)
    }

    /// `$MARSDAWN_APP_PATH` only stands in for MarsDawn itself, never for an arbitrary app: whoever
    /// sets it in the agent's environment could already put a fake `marsdawn` first on `PATH`, so
    /// this isn't a security boundary — it only catches an override left pointing at a deleted test
    /// copy or another app by accident. A throwaway verification copy's bundle id (like
    /// `dev.southern-light.marsdawn.verify-3`) still passes; the bare id with a trailing dot and
    /// nothing after it does not.
    ///
    /// A pure function of its arguments — no global state, no filesystem writes, nothing process-
    /// wide — so tests call it directly with fixed inputs instead of mutating `ProcessInfo`'s
    /// environment or a shared `locate` closure. `nil` means `$MARSDAWN_APP_PATH` wasn't set in
    /// `environment` at all, and the caller should fall back to the normal lookup.
    static func resolveOverride(
        environment: [String: String],
        bundleIdentifier readBundleIdentifier: (URL) -> String?,
        stderr: (String) -> Void
    ) throws -> OverrideOutcome? {
        guard let override = environment["MARSDAWN_APP_PATH"] else { return nil }
        stderr("marsdawn: using $MARSDAWN_APP_PATH override: \(override)\n")
        guard FileManager.default.fileExists(atPath: override) else { return .notFound }
        let url = URL(fileURLWithPath: override)
        guard let identifier = readBundleIdentifier(url) else {
            throw CLIFailure.appPathOverrideRejected("\(url.path) has no readable CFBundleIdentifier in its Info.plist.")
        }
        let ownPrefix = "\(bundleIdentifier)."
        let isOwnCopy = identifier.hasPrefix(ownPrefix) && identifier.count > ownPrefix.count
        guard identifier == bundleIdentifier || isOwnCopy else {
            throw CLIFailure.appPathOverrideRejected(
                "\(url.path)'s bundle id is \(identifier), not \(bundleIdentifier) or a \(ownPrefix)* copy."
            )
        }
        return .app(url)
    }

    /// Replaceable for tests. Its default calls the pure `resolveOverride` with the process's own
    /// environment, Info.plist reader and stderr.
    nonisolated(unsafe) static var locate: () throws -> URL? = {
        switch try resolveOverride(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: bundleIdentifier(at:),
            stderr: { FileHandle.standardError.write(Data($0.utf8)) }
        ) {
        case .app(let url): return url
        case .notFound: return nil
        case nil: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
    }

    static func require() throws -> URL {
        guard let url = try locate() else { throw CLIFailure.appNotInstalled() }
        return url
    }

    /// The Info.plist key an app sets once it can take a folder from `open` and show it in the
    /// sidebar. It names a capability, not a version, so the CLI asks the app it will actually
    /// launch rather than guessing from a number (#165).
    static let opensFoldersKey = "MarsDawnOpensFolders"

    /// Whether the app at `url` declares it can take a folder. Replaceable for tests.
    nonisolated(unsafe) static var opensFolders: (URL) -> Bool = { url in
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return false }
        return (info[opensFoldersKey] as? Bool) == true
    }

    /// The Info.plist key an app sets once it posts back whether a folder actually attached
    /// (PLAN #69 slice B). Gated the same way as `opensFoldersKey`: a capability, read from the
    /// app the CLI will actually launch.
    static let reportsFolderStatusKey = "MarsDawnReportsFolderStatus"

    /// Whether the app at `url` declares it reports folder status. Replaceable for tests.
    nonisolated(unsafe) static var reportsFolderStatus: (URL) -> Bool = { url in
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return false }
        return (info[reportsFolderStatusKey] as? Bool) == true
    }

    /// `CFBundleIdentifier` from a bundle's Info.plist, or nil if it's missing or unreadable.
    static func bundleIdentifier(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}

func existingFile(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw CLIFailure(code: .inputNotFound, message: "No such file: \(url.path)")
    }
    return url
}

/// Resolves a path that must be a directory. The mirror of `existingFile`.
func existingDirectory(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        throw CLIFailure(code: .inputNotFound, message: "No such folder: \(url.path)")
    }
    guard isDirectory.boolValue else {
        throw CLIFailure(code: .inputNotFound, message: "Not a folder: \(url.path)")
    }
    return url
}

extension PreviewTheme: ExpressibleByArgument {
    public init?(argument: String) {
        guard let theme = PreviewTheme.all.first(where: { $0.id == argument.lowercased() }) else { return nil }
        self = theme
    }

    public static var allValueStrings: [String] { all.map(\.id) }
    public var defaultValueDescription: String { id }
}

extension DocumentExporter.Paper: ExpressibleByArgument {}

// MARK: - open

/// One file `open` hands to MarsDawn, with the line it should land on.
struct OpenTarget: Equatable {
    var url: URL
    var line: Int?
}

extension MarsDawnCommand {
    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open Markdown files in MarsDawn for review. Needs the MarsDawn app, which is not publicly available yet.",
            discussion: """
            A folder argument opens in the window's sidebar instead of as a document, so \
            `marsdawn open .` shows the current directory; --folder does the same alongside files. \
            A window's sidebar shows one folder, so naming two is a usage error, and there is no \
            -a: VS Code's -a adds a second root, which MarsDawn has no way to do.
            Showing a folder needs a MarsDawn that can take one. With an app that can't, open \
            refuses before opening anything and exits \(CLIFailure.Code.appCannotOpenFolders.rawValue); files on their own open as before.
            With an app that also reports back, --folder's JSON result carries a "status" once the \
            wait ends: "attached", "needsUser" (see "waitingFor"), "declined", "failed", \
            "attachedDifferentFolder", "full", "unavailable" or "unknown". --wait sets how long to \
            wait for it, in seconds (0–30, default 2); --wait 0, or an app that doesn't report back, \
            skips waiting and reports nothing beyond "requested": true, exactly as before this existed.
            A file argument can name a line: `notes.md:120` opens notes.md and lands on line 120. \
            A column after the line, as in `notes.md:120:8`, is accepted and ignored. An argument \
            that names a file which exists is always the whole filename, so a file called \
            `weird:12` still opens as itself.
            --line says the same thing for a single file, and is the way to ask for a line on a \
            path that itself ends in a colon and digits. Lines run from \
            \(RevealRequest.lineRange.lowerBound) to \(RevealRequest.lineRange.upperBound).
            """
        )

        @Argument(help: ArgumentHelp("Markdown files to open, each optionally as path:line. A folder opens in the sidebar.", valueName: "path"))
        var files: [String] = []

        @Option(name: .long, help: ArgumentHelp("Line to land on. Needs exactly one file.", valueName: "n"))
        var line: Int?

        @Option(name: .long, parsing: .singleValue,
                help: ArgumentHelp("Folder to show in the window's sidebar, alongside the files. One only.", valueName: "path"))
        var folder: [String] = []

        /// Not a feature. People and agents arrive with VS Code's muscle memory, and an error
        /// naming `--folder` teaches them more than "unknown option '-a'" does.
        @Flag(name: .customShort("a"), help: .hidden)
        var vsCodeAdd = false

        /// For an agent opening files mid-task: MarsDawn opens them without coming to the front,
        /// so the window the user is working in keeps focus (#59).
        @Flag(name: .long, help: "Open without bringing MarsDawn to the front.")
        var background = false

        /// PLAN #69 slice B: how long to wait for the app's own report of what happened to
        /// `--folder`, once both the app and this build support it. 0 skips waiting, and skips
        /// sending the token at all — the byte-identical, pre-slice-B `requested`-only path.
        @Option(name: .long, help: ArgumentHelp(
            "Seconds to wait for MarsDawn's report on --folder (0–30, 0 to skip). Only takes effect "
                + "with --folder; a value outside 0–30 is a usage error either way.",
            valueName: "seconds"
        ))
        var wait = 2

        @OptionGroup var output: OutputOptions

        static let waitRange = 0...30

        func validate() throws {
            if vsCodeAdd {
                throw ValidationError(Open.noDashA)
            }
            guard folder.count <= 1 else {
                throw ValidationError(
                    "--folder takes one folder, but \(folder.count) were given. A MarsDawn window's "
                        + "sidebar shows one folder at a time."
                )
            }
            // Not here: ArgumentParser wraps whatever `validate()` throws in its own internal
            // `CommandError`, which would swallow `WaitRangeFailure`'s own JSON `error` kind behind
            // its generic text-only error formatting. `run()` throws it directly instead, as the
            // first thing it does, before anything is sent — the same shape `CLIFailure` already
            // uses.
            guard !files.isEmpty || !folder.isEmpty else {
                throw ValidationError("Nothing to open. Give a file, a folder, or --folder <path>.")
            }
            // A folder may arrive as a directory argument, as --folder, or both; more than one is
            // a usage error either way (#104). Checked here, in validate(), rather than only in
            // run()'s resolvedFolders(): ArgumentParser knows which subcommand's usage to print
            // for an error thrown from validate(), so `open`'s own usage line prints instead of
            // the top-level `Usage: marsdawn <subcommand>`. This doesn't call resolvedFolders()
            // itself: that also checks the folder exists, throwing a plain CLIFailure, and
            // ArgumentParser wraps whatever validate() throws in its own ParserError, which would
            // hide CLIFailure's exit code and JSON `error` kind behind ArgumentParser's own
            // (`aFolderThatIsntThereOrIsntAFolderIsReported` still exercises that path, via
            // run()). This only dedups syntactically, with no filesystem access, so a genuinely
            // missing folder still surfaces from resolvedFolders() in run(), as before.
            let folderCandidates = Open.distinctFolderCandidates(files: files, folder: folder)
            guard folderCandidates.count <= 1 else {
                throw ValidationError(
                    "More than one folder was given (\(folderCandidates.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))). "
                        + "A MarsDawn window's sidebar shows one folder at a time."
                )
            }
            let directories = files.filter(Open.isDirectory)
            let fileArguments = files.count - directories.count
            // A folder with no line to land on, named whichever way it arrived: a directory
            // argument, or --folder with no file argument at all (#104).
            if line != nil, fileArguments == 0, let onlyFolder = directories.first ?? folder.first {
                throw ValidationError(
                    "--line needs a file, but \(onlyFolder) is a folder. A folder opens in the sidebar "
                        + "and has no line to land on."
                )
            }
            guard line == nil || fileArguments == 1 else {
                throw ValidationError(
                    "--line needs exactly one file, but \(fileArguments) were given. "
                        + "Write the line on each file instead, as path:line."
                )
            }
            if let line, !RevealRequest.lineRange.contains(line) {
                throw ValidationError(Open.outOfRange(line))
            }
        }

        static let noDashA = "MarsDawn has no -a. Use --folder <path> to show a folder in the "
            + "window's sidebar. It isn't VS Code's -a: a MarsDawn window's sidebar shows one "
            + "folder, so --folder sets that folder rather than adding a second one."

        static func isDirectory(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            let expanded = (path as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        static func outOfRange(_ line: Int) -> String {
            "Line \(line) is out of range: lines run from "
                + "\(RevealRequest.lineRange.lowerBound) to \(RevealRequest.lineRange.upperBound)."
        }

        static func fileExists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
        }

        /// The distinct folder candidates named by directory arguments and `--folder` together, in
        /// the order given and without repeats — the same source list `resolvedFolders()` resolves,
        /// but deduped by the path's own syntax only, with no filesystem access (`standardizedFileURL`
        /// normalizes "." and ".." without touching disk or requiring the path to exist). Used by
        /// `validate()` (#104) to catch "more than one folder" purely as a usage error, and by
        /// `resolvedFolders()`, which still resolves and checks existence for each one.
        static func distinctFolderCandidates(files: [String], folder: [String]) -> [String] {
            var seen = Set<String>()
            var candidates: [String] = []
            for path in files.filter(Open.isDirectory) + folder {
                let key = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
                if seen.insert(key).inserted { candidates.append(path) }
            }
            return candidates
        }

        /// Resolves every argument to a file and the line it asked for. A line the app would have
        /// to guess at is a usage error here, before anything is sent.
        func resolvedTargets(fileExists: (String) -> Bool = Open.fileExists) throws -> [OpenTarget] {
            try files.filter { !Open.isDirectory($0) }.map { argument in
                let parsed = RevealRequest.parseArgument(argument, fileExists: fileExists)
                let url = try existingFile(parsed.path)
                guard let requested = parsed.line ?? line else {
                    return OpenTarget(url: url, line: nil)
                }
                guard RevealRequest.lineRange.contains(requested) else {
                    throw ValidationError(Open.outOfRange(requested) + " \(parsed.path) asked for one.")
                }
                // What travels is the resolved, standardized path, so the app can match it against
                // an open document's URL without touching the filesystem with it itself.
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard let request = RevealRequest(path: resolved.path, line: requested) else {
                    throw ValidationError("Can’t send a line for \(resolved.path): MarsDawn won’t accept that path.")
                }
                return OpenTarget(url: URL(fileURLWithPath: request.path), line: request.line)
            }
        }

        /// The folders to show, from directory arguments and `--folder` alike, in the order
        /// given and without repeats. A window's sidebar shows one folder, so more than one is
        /// a usage error rather than a silent choice between them.
        func resolvedFolders() throws -> [URL] {
            var seen = Set<String>()
            var folders: [URL] = []
            for path in Open.distinctFolderCandidates(files: files, folder: folder) {
                let url = try existingDirectory(path)
                if seen.insert(url.path).inserted { folders.append(url) }
            }
            guard folders.count <= 1 else {
                throw ValidationError(
                    "More than one folder was given (\(folders.map(\.lastPathComponent).joined(separator: ", "))). "
                        + "A MarsDawn window's sidebar shows one folder at a time."
                )
            }
            return folders
        }

        /// The failure `open` must stop with before sending anything, or nil to go ahead: folders
        /// asked of an app that doesn't declare it can take one. Files alone never ask.
        static func folderRefusal(folders: [URL], app: URL) -> CLIFailure? {
            guard !folders.isEmpty, !MarsDawnApp.opensFolders(app) else { return nil }
            return CLIFailure.appCannotOpenFolders(app: app)
        }

        /// How the app is asked to open things: brought to the front unless `--background`.
        func openConfiguration() -> NSWorkspace.OpenConfiguration {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = !background
            return configuration
        }

        @MainActor
        func run() async throws {
            guard Open.waitRange.contains(wait) else { throw WaitRangeFailure(value: wait) }
            let targets = try resolvedTargets()
            let folders = try resolvedFolders()
            let app = try MarsDawnApp.require()
            // Before anything is sent: an app that can't take a folder shows an error dialog for
            // it (#165), so asking would leave a person with an error and an agent with "ok".
            if let refusal = Open.folderRefusal(folders: folders, app: app) { throw refusal }
            // Files asking for the same line travel in one event; the line applies to all of them.
            for group in RevealEvent.groups(for: targets) {
                let configuration = openConfiguration()
                configuration.appleEvent = RevealEvent.openDocuments(urls: group.urls, line: group.line)
                _ = try await NSWorkspace.shared.open(group.urls, withApplicationAt: app, configuration: configuration)
            }
            // Folders travel on their own, with no reveal line: a folder has no line to land on.
            // PLAN #69 slice B: with an app that reports back and --wait > 0, a one-time token
            // rides this event and we wait for its answer; otherwise this sends exactly what
            // `open --folder` always has.
            var folderStatus: FolderStatusRequest.Result?
            if let folder = folders.first {
                let configuration = openConfiguration()
                let capable = MarsDawnApp.reportsFolderStatus(app)
                folderStatus = try await FolderStatusRequest.send(
                    folder: folder, app: app, wait: wait, capable: capable, configuration: configuration,
                    opener: FolderStatusEnvironment.opener, notifier: FolderStatusEnvironment.notifier
                )
            }
            var fields: [String: Any] = [
                "opened": targets.map { target -> [String: Any] in
                    guard let line = target.line else { return ["path": target.url.path] }
                    return ["path": target.url.path, "line": line]
                },
                "app": app.path,
            ]
            // `requested`, not `attached`: this command hands the folder to the app and returns.
            // Whether the sidebar ends up showing it — or the app has to ask the user for access
            // first — is decided inside the app. With an app and a --wait that ask for it, `status`
            // (and, for `needsUser`, `waitingFor`) carries the app's own answer; otherwise this
            // stays exactly what it always reported.
            if let folder = folders.first {
                fields["folder"] = Open.folderFields(path: folder.path, result: folderStatus)
            }
            var lines = targets.map { target -> String in
                guard let line = target.line else { return "Opened \(target.url.path)" }
                return "Opened \(target.url.path) at line \(line)"
            }
            if let folder = folders.first {
                lines.append(Open.folderLine(path: folder.path, result: folderStatus))
            }
            output.report(fields, text: lines.joined(separator: "\n"))
        }

        /// The `"folder"` object in `--json`: always `path` and `requested: true`; `status` (and,
        /// for `needsUser`, `waitingFor`) only when `result` carries one. Shared by `run()` and by
        /// tests, so a test that checks the token never reaches this exercises the exact code
        /// that ships, not a copy of it.
        static func folderFields(path: String, result: FolderStatusRequest.Result?) -> [String: Any] {
            var fields: [String: Any] = ["path": path, "requested": true]
            if let status = result?.status {
                fields["status"] = status.rawValue
                if let waitingFor = result?.waitingFor {
                    fields["waitingFor"] = waitingFor.rawValue
                }
            }
            return fields
        }

        /// The matching text line for `folderFields`.
        static func folderLine(path: String, result: FolderStatusRequest.Result?) -> String {
            var line = "Asked MarsDawn to show \(path) in the sidebar"
            if let status = result?.status {
                line += " (\(status.rawValue)"
                if let waitingFor = result?.waitingFor {
                    line += ", waiting for \(waitingFor.rawValue)"
                }
                line += ")"
            }
            return line
        }
    }
}

// MARK: - export

extension MarsDawnCommand {
    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export a Markdown file to a paginated PDF, rendered like MarsDawn's preview.",
            discussion: """
            Runs on its own: the MarsDawn app does not have to be installed. Relative images \
            resolve against the input file's folder. Web images are left out unless \
            --allow-remote-images is given.
            """
        )

        @Argument(help: "The Markdown file to export.")
        var file: String

        @Option(name: .shortAndLong, help: "Where to write the PDF. Defaults to the input path with a .pdf extension.")
        var output: String?

        @Option(help: "Preview theme (light palette). Defaults to $MARSDAWN_THEME, or dawn.")
        var theme: PreviewTheme?

        @Option(help: "Paper size.")
        var paper: DocumentExporter.Paper = .a4

        @Flag(help: "Load images from the web while rendering.")
        var allowRemoteImages = false

        @Flag(help: "Replace the output file if it already exists.")
        var force = false

        @OptionGroup var options: OutputOptions

        func outputURL(for input: URL) -> URL {
            if let output {
                return URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
            }
            return input.deletingPathExtension().appendingPathExtension("pdf")
        }

        func resolvedTheme(environment: [String: String] = ProcessInfo.processInfo.environment) -> PreviewTheme {
            theme ?? environment["MARSDAWN_THEME"].flatMap(PreviewTheme.init(argument:)) ?? .dawn
        }

        @MainActor
        func run() async throws {
            // No MarsDawnApp.require() here: export is the same rendering the app does, and it
            // ships in this package, so it must work with nothing else installed (Homebrew builds
            // and tests the tool on machines that have no MarsDawn.app). `open` still needs it.
            let input = try existingFile(file)
            let destination = outputURL(for: input)
            if FileManager.default.fileExists(atPath: destination.path), !force {
                throw CLIFailure(code: .outputExists, message: "\(destination.path) already exists. Pass --force to replace it.")
            }
            let markdown: String
            do {
                markdown = try String(contentsOf: input, encoding: .utf8)
            } catch {
                throw CLIFailure(code: .inputNotFound, message: "Couldn’t read \(input.path) as UTF-8 text.")
            }

            // Write beside the destination first, so a failed export never leaves a partial file.
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp.pdf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let result: DocumentExporter.PDFResult
            do {
                result = try await DocumentExporter.exportPDF(
                    markdown: markdown,
                    to: temporary,
                    theme: resolvedTheme(),
                    baseDirectory: input.deletingLastPathComponent(),
                    allowRemoteImages: allowRemoteImages,
                    paper: paper
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            } catch {
                throw CLIFailure(code: .exportFailed, message: "Export failed: \(error.localizedDescription)")
            }

            var text = "Exported \(destination.path) (\(result.pageCount) page\(result.pageCount == 1 ? "" : "s"))"
            for message in result.diagramErrors {
                text += "\nwarning: Mermaid diagram failed to render: \(message)"
            }
            options.report(
                [
                    "output": destination.path,
                    "pages": result.pageCount,
                    "theme": resolvedTheme().id,
                    "paper": paper.rawValue,
                    "diagramErrors": result.diagramErrors,
                    "diagramErrorDetails": result.diagramErrorDetails.map { error -> [String: Any] in
                        var entry: [String: Any] = ["message": error.message]
                        if let fenceLine = error.fenceLine { entry["fenceLine"] = fenceLine }
                        if let line = error.line { entry["line"] = line }
                        return entry
                    },
                ],
                text: text
            )
        }
    }
}
#endif
