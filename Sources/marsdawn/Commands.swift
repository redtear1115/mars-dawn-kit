#if os(macOS)
import AppKit
import ArgumentParser
import Foundation
import MarsDawnExport
import MarsDawnKit
import MarsDawnThemes

/// `marsdawn`: open Markdown in MarsDawn, or export it to PDF, from a shell or an LLM agent.
struct MarsDawnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marsdawn",
        abstract: "Open Markdown documents in MarsDawn or export them to PDF.",
        discussion: """
        export renders on its own and needs nothing else installed. open hands the files to the \
        MarsDawn app, so it needs the app, which is not publicly available yet.
        Pass --json for machine-readable results. Exit codes: 0 success, 1 invalid theme (theme commands only), \
        \(CLIFailure.Code.inputNotFound.rawValue) input not found, \
        \(CLIFailure.Code.appNotInstalled.rawValue) MarsDawn not installed (open only), \(CLIFailure.Code.outputExists.rawValue) output exists \
        (use --force), \(CLIFailure.Code.exportFailed.rawValue) export failed, \(CLIFailure.Code.appCannotOpenFolders.rawValue) this MarsDawn \
        can't show a folder (open only), 64 usage error (including theme preview's refused -o).
        """,
        version: MarsDawnCLI.version,
        subcommands: [Open.self, Export.self, Skill.self, Theme.self]
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
    if error is OutputPathFailure { return OutputPathFailure.exitCode }
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

/// `--theme` and `$MARSDAWN_THEME` resolve through the theme registry's built-ins only (kit #126,
/// design §7.4): the CLI can't read the app's container without a privacy prompt, so it never
/// loads installed themes, and it doesn't resolve them even if something in the process did.
extension PreviewTheme: ExpressibleByArgument {
    public init?(argument: String) {
        guard let theme = ThemeRegistry.builtIns.themes.first(where: { $0.id == argument.lowercased() }) else { return nil }
        self = theme
    }

    public static var allValueStrings: [String] { ThemeRegistry.builtIns.themes.map(\.id) }
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

// MARK: - theme validate

extension MarsDawnCommand {
    struct Theme: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Work with MarsDawn theme files.",
            subcommands: [Validate.self, CSS.self, Preview.self]
        )

        struct Validate: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Check a theme.json against every rule a MarsDawn theme must meet.",
                discussion: """
                Runs the same validator the app uses when it installs a theme: the schema, colours, \
                numbers and style options, display strings, the contrast of every colour pair the \
                preview draws, and the thresholds of the scenarios the theme declares. \
                --require-complete is the check for publishing a theme: the syntax and diagram \
                colours, optional otherwise (the app fills them from Dawn), must all be in the file. \
                Exit codes: 0 valid, 1 invalid (each problem is listed with its rule id), \
                \(CLIFailure.Code.inputNotFound.rawValue) input not found, 64 usage error. Only a \
                regular file of at most \(ThemeValidator.maxFileBytes) bytes is read: a symlink, a \
                folder, a FIFO or a device is refused without being opened.
                """
            )

            @Argument(help: ArgumentHelp("The theme.json to check.", valueName: "file"))
            var file: String

            @Flag(help: "Require every colour group (syntax and diagram) in the file, as a published theme must have.")
            var requireComplete = false

            @OptionGroup var output: OutputOptions

            func run() throws {
                let status = try Self.run(path: file, json: output.json, requireComplete: requireComplete)
                if status != 0 { throw ExitCode(status) }
            }

            /// The command's logic with its output sink as a parameter (as `Skill.run`), so tests
            /// can read what it prints without touching the process's stdout. A missing file throws
            /// the CLI-wide `input_not_found` (exit 2), like every other command; anything else wrong
            /// with the file or its content is a validation result (exit 1).
            static func run(path: String, json: Bool, requireComplete: Bool = false, write: (String) -> Void = { print($0) }) throws -> Int32 {
                let report = try ThemeInput.validate(path: path, requireComplete: requireComplete)
                if json {
                    write(ThemeValidateOutput(report).jsonText)
                } else if let theme = report.theme {
                    write("valid: \(theme.id)")
                } else {
                    ThemeInput.writeInvalid(report, json: false, write: write)
                }
                return report.theme == nil ? 1 : 0
            }
        }
    }
}

/// The one way every `theme` subcommand gets a theme from a path (kit #139): `ThemeFileReader`'s
/// file rules, then `ThemeValidator` on the bytes read. `theme css` and `theme preview` use exactly
/// this, so they refuse what `theme validate` refuses, with the same rule ids and exit codes, and
/// what they generate or render from is only ever a `ValidatedTheme`.
enum ThemeInput {
    /// A missing file throws the CLI-wide `input_not_found` (exit 2); anything else wrong with the
    /// file or its content is in the report (exit 1).
    static func validate(path: String, requireComplete: Bool = false) throws -> ThemeValidationReport {
        switch ThemeFileReader.read(path: path) {
        case .success(let data): return ThemeValidator.validate(data: data, requireComplete: requireComplete)
        case .failure(.notFound): throw CLIFailure(code: .inputNotFound, message: "No such file: \(path)")
        case .failure(.refused(let issue)): return ThemeValidationReport(issues: [issue], theme: nil)
        }
    }

    /// Prints an invalid report exactly as `theme validate` does.
    static func writeInvalid(_ report: ThemeValidationReport, json: Bool, write: (String) -> Void) {
        if json {
            write(ThemeValidateOutput(report).jsonText)
        } else {
            let count = report.issues.count
            write((["invalid: \(count) problem\(count == 1 ? "" : "s")"] + report.issues.map { "  \($0)" }).joined(separator: "\n"))
        }
    }
}

// MARK: - theme css

extension MarsDawnCommand.Theme {
    struct CSS: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "css",
            abstract: "Print the CSS MarsDawn's preview serves for a theme.json.",
            discussion: """
            Validates the file exactly as theme validate does, then prints the theme's palette \
            block (its light variables, and its dark variables under prefers-color-scheme: dark) \
            followed by its generated style rules, all scoped to its id: byte for byte what the \
            preview serves for it. --json prints {"ok": true, "id", "variables", "rules"}, where \
            variables is the palette block and rules the style rules (empty for a theme with no \
            style options), each exactly as served. An invalid theme prints its problems as theme \
            validate does. Exit codes: 0 printed, 1 invalid, \
            \(CLIFailure.Code.inputNotFound.rawValue) input not found, 64 usage error.
            """
        )

        @Argument(help: ArgumentHelp("The theme.json to generate CSS for.", valueName: "file"))
        var file: String

        @OptionGroup var output: OutputOptions

        func run() throws {
            let status = try Self.run(path: file, json: output.json)
            if status != 0 { throw ExitCode(status) }
        }

        /// The command's logic with its output sink as a parameter, like `Validate.run`. `write`
        /// gets the whole output in one call, with no newline added: the text form is the CSS
        /// itself, ending in a newline.
        static func run(path: String, json: Bool, write: (String) -> Void = { print($0, terminator: "") }) throws -> Int32 {
            let report = try ThemeInput.validate(path: path)
            guard let theme = report.theme else {
                ThemeInput.writeInvalid(report, json: json) { write($0 + "\n") }
                return 1
            }
            let css: ThemeCSSOutput
            do throws(ThemeCSSGenerator.Refusal) {
                css = ThemeCSSOutput(id: theme.id, variables: try ThemeCSSGenerator.variables(for: theme),
                                     rules: try ThemeCSSGenerator.rules(for: theme).css)
            } catch {
                // A validated theme the generator still refuses: the kit's own fault, reported as
                // an invalid result (the refusal carries no text from the file).
                ThemeInput.writeInvalid(ThemeValidationReport(issues: [ThemeIssue(rule: "css.refused", path: "", message: error.description)], theme: nil),
                                        json: json) { write($0 + "\n") }
                return 1
            }
            write(json ? css.jsonText + "\n" : css.text)
            return 0
        }
    }
}

/// `theme css`'s output (kit #139). `variables` is the theme's block of `themes.css` and `rules`
/// its part of the rules spliced into `preview.css`, each byte for byte as the preview serves
/// them, so a port of the generator can be checked against these two strings exactly.
struct ThemeCSSOutput: Codable, Equatable {
    var ok = true
    var id: String
    var variables: String
    var rules: String

    /// The stylesheet as text: the palette block, a newline, then the rules (which end in one).
    var text: String { variables + "\n" + rules }

    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data(#"{"ok":false,"issues":[]}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - theme preview

extension MarsDawnCommand.Theme {
    struct Preview: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Render MarsDawn's sample document with a theme.json to a PNG.",
            discussion: """
            Validates the file exactly as theme validate does, then renders the kit's fixed sample \
            document (headings, lists, a quote, a table, code, a Mermaid diagram, math and a rule) \
            with that theme, in the light or dark palette, offscreen through the same WebKit page \
            export uses. Nothing is loaded from the network. The PNG is --width pixels wide \
            (\(ThemePreviewRenderer.widthRange.lowerBound)–\(ThemePreviewRenderer.widthRange.upperBound), \
            default \(ThemePreviewRenderer.defaultWidth)) and as tall as the sample, at most \
            \(ThemePreviewRenderer.maxHeight). -o must name a file in a folder that exists; a \
            symlink or anything other than a regular file at that path is refused, even with \
            --force. Exit codes: 0 written, 1 invalid theme, \
            \(CLIFailure.Code.inputNotFound.rawValue) input not found, \
            \(CLIFailure.Code.outputExists.rawValue) output exists (use --force), \
            \(CLIFailure.Code.exportFailed.rawValue) rendering failed, 64 usage error (including \
            an -o that is refused).
            """
        )

        @Argument(help: ArgumentHelp("The theme.json to preview.", valueName: "file"))
        var file: String

        @Option(help: "Which palette to render: light or dark.")
        var appearance: ThemePreviewRenderer.Appearance

        @Option(name: .shortAndLong, help: ArgumentHelp("Where to write the PNG.", valueName: "out.png"))
        var output: String

        @Option(help: ArgumentHelp(
            "Image width in pixels, \(ThemePreviewRenderer.widthRange.lowerBound)–\(ThemePreviewRenderer.widthRange.upperBound).",
            valueName: "n"
        ))
        var width = ThemePreviewRenderer.defaultWidth

        @Flag(help: "Replace the output file if it already exists.")
        var force = false

        @OptionGroup var options: OutputOptions

        func validate() throws {
            guard ThemePreviewRenderer.widthRange.contains(width) else {
                throw ValidationError(
                    "--width must be between \(ThemePreviewRenderer.widthRange.lowerBound) and "
                        + "\(ThemePreviewRenderer.widthRange.upperBound), but \(width) was given."
                )
            }
        }

        @MainActor
        func run() async throws {
            let status = try await Self.run(
                path: file, appearance: appearance, output: output, width: width, force: force, json: options.json
            )
            if status != 0 { throw ExitCode(status) }
        }

        /// The command's logic with its output sink as a parameter. The theme is validated first:
        /// an invalid one is reported (exit 1) before the output path is looked at or anything is
        /// rendered. `inspect` is for tests (see `ThemePreviewRenderer.render`).
        @MainActor
        static func run(
            path: String,
            appearance: ThemePreviewRenderer.Appearance,
            output: String,
            width: Int = ThemePreviewRenderer.defaultWidth,
            force: Bool = false,
            json: Bool,
            write: (String) -> Void = { print($0) },
            inspect: ((PreviewWKWebView) async throws -> Void)? = nil
        ) async throws -> Int32 {
            guard ThemePreviewRenderer.widthRange.contains(width) else {
                throw ValidationError("--width must be between \(ThemePreviewRenderer.widthRange.lowerBound) and \(ThemePreviewRenderer.widthRange.upperBound), but \(width) was given.")
            }
            let report = try ThemeInput.validate(path: path)
            guard let theme = report.theme else {
                ThemeInput.writeInvalid(report, json: json, write: write)
                return 1
            }
            let destination = try OutputFile.check(output, force: force)
            let result: ThemePreviewRenderer.Result
            do {
                result = try await ThemePreviewRenderer.render(theme: theme, appearance: appearance, width: width, inspect: inspect)
            } catch {
                throw CLIFailure(code: .exportFailed, message: "Preview failed: \(error.localizedDescription)")
            }
            try OutputFile.write(result.png, to: destination, force: force)
            let fields: [String: Any] = [
                "ok": true,
                "output": destination.path,
                "id": theme.id,
                "appearance": appearance.rawValue,
                "width": result.width,
                "height": result.height,
            ]
            write(json ? jsonString(fields) : "Wrote \(destination.path) (\(theme.id), \(appearance.rawValue), \(result.width)×\(result.height))")
            return 0
        }
    }
}

extension ThemePreviewRenderer.Appearance: ExpressibleByArgument {}

/// `theme preview -o` refused a path it will not write to (kit #139): a usage error like
/// `SkillInstallFailure`, exit 64, with its own machine-readable kind for `--json`.
struct OutputPathFailure: Error, CustomStringConvertible {
    enum Kind: String {
        /// The folder the file would go in isn't there (or isn't a folder).
        case folderMissing = "output_folder_missing"
        /// A symlink is at the path. Never followed and never replaced, `--force` included.
        case symlink = "output_symlink"
        /// Something that isn't a regular file (a folder, a FIFO, a device) is at the path.
        case notAFile = "output_not_a_file"
    }

    let kind: Kind
    let message: String
    var description: String { message }
    static let exitCode: Int32 = 64
}

/// Where `theme preview` writes (kit #139): only a regular file, in a folder that exists, never
/// through a symlink. The bytes go to a new file made with `O_CREAT | O_EXCL | O_NOFOLLOW` beside
/// the destination, which is then renamed over it -- `rename` replaces the directory entry and
/// never follows a link there, and without `--force` the rename is exclusive (`RENAME_EXCL`), so
/// a file that appears in the meantime is not replaced either.
enum OutputFile {
    static func check(_ path: String, force: Bool) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let folder = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard !url.lastPathComponent.isEmpty, url.path != "/",
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw OutputPathFailure(kind: .folderMissing, message: "The folder for \(url.path) doesn't exist. Create it first; theme preview doesn't.")
        }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                throw OutputPathFailure(kind: .symlink, message: "\(url.path) is a symlink. theme preview never writes through one; name the file itself.")
            case S_IFREG:
                if !force { throw CLIFailure(code: .outputExists, message: "\(url.path) already exists. Pass --force to replace it.") }
            default:
                throw OutputPathFailure(kind: .notAFile, message: "\(url.path) is not a regular file.")
            }
        }
        return url
    }

    static func write(_ data: Data, to url: URL, force: Bool) throws {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw CLIFailure(code: .exportFailed, message: "Couldn’t write beside \(url.path).")
        }
        var written = 0
        let ok = data.withUnsafeBytes { raw -> Bool in
            while written < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + written, raw.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += count
            }
            return true
        }
        close(fd)
        guard ok else {
            unlink(temporary.path)
            throw CLIFailure(code: .exportFailed, message: "Couldn’t write beside \(url.path).")
        }
        let renamed = force
            ? rename(temporary.path, url.path)
            : renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL))
        guard renamed == 0 else {
            let error = errno
            unlink(temporary.path)
            if error == EEXIST { throw CLIFailure(code: .outputExists, message: "\(url.path) already exists. Pass --force to replace it.") }
            throw CLIFailure(code: .exportFailed, message: "Couldn’t write \(url.path).")
        }
    }
}

/// `theme validate --json`'s output, written with `JSONEncoder` (security review M4), so every
/// string -- including the already-quoted parts of a message -- is escaped by the encoder, never
/// assembled by hand.
struct ThemeValidateOutput: Codable, Equatable {
    var ok: Bool
    var id: String?
    var issues: [ThemeIssue]

    init(_ report: ThemeValidationReport) {
        ok = report.theme != nil
        id = report.theme?.id
        issues = report.issues
    }

    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data(#"{"ok":false,"issues":[]}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads a theme file for `theme validate` (security review L2): `lstat` first, and only a regular
/// file is opened -- a symlink, folder, FIFO, socket or device (`/dev/zero`) is refused without an
/// `open`, so nothing can block or stream forever. The file is then opened with `O_NOFOLLOW` and
/// `O_NONBLOCK`, checked again with `fstat` to be the same regular file `lstat` saw, and read up to
/// one byte past the size cap.
enum ThemeFileReader {
    enum Refusal: Error {
        /// Nothing at that path: the CLI-wide `input_not_found`, not a validation result.
        case notFound
        case refused(ThemeIssue)
    }

    private static func refuse(_ rule: String, _ message: String) -> Refusal {
        .refused(ThemeIssue(rule: rule, path: "", message: message))
    }

    static func read(path: String) -> Result<Data, Refusal> {
        var before = stat()
        guard lstat(path, &before) == 0 else {
            return .failure(errno == ENOENT ? .notFound : refuse("file.unreadable", "the file can't be read"))
        }
        switch before.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFLNK: return .failure(refuse("file.notRegular", "is a symlink; pass the file itself"))
        case S_IFDIR: return .failure(refuse("file.notRegular", "is a folder, not a file"))
        default: return .failure(refuse("file.notRegular", "is not a regular file (a FIFO, socket or device)"))
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(refuse("file.unreadable", "the file can't be read")) }
        defer { close(fd) }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_mode & S_IFMT == S_IFREG,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino
        else { return .failure(refuse("file.notRegular", "changed while it was being opened")) }

        let limit = ThemeValidator.maxFileBytes + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let got = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
            if got < 0 {
                if errno == EINTR { continue }
                return .failure(refuse("file.unreadable", "the file can't be read"))
            }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<got])
        }
        if data.count > ThemeValidator.maxFileBytes {
            return .failure(refuse("file.tooLarge", "the file is larger than \(ThemeValidator.maxFileBytes) bytes"))
        }
        return .success(data)
    }
}
#endif
