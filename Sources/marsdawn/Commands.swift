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
        MarsDawn app, so it needs MarsDawn from the Mac App Store.
        Pass --json for machine-readable results. Exit codes: 0 success, \(CLIFailure.Code.inputNotFound.rawValue) input not found, \
        \(CLIFailure.Code.appNotInstalled.rawValue) MarsDawn not installed (open only), \(CLIFailure.Code.outputExists.rawValue) output exists \
        (use --force), \(CLIFailure.Code.exportFailed.rawValue) export failed, 64 usage error.
        """,
        version: MarsDawnCLI.version,
        subcommands: [Open.self, Export.self]
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

func printJSON(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
}

/// A failure with a stable exit code and a machine-readable kind.
struct CLIFailure: Error, CustomStringConvertible {
    enum Code: Int32 {
        case inputNotFound = 2
        case appNotInstalled = 3
        case outputExists = 4
        case exportFailed = 5

        var kind: String {
            switch self {
            case .inputNotFound: "input_not_found"
            case .appNotInstalled: "app_not_installed"
            case .outputExists: "output_exists"
            case .exportFailed: "export_failed"
            }
        }
    }

    let code: Code
    let message: String
    var description: String { message }

    static func appNotInstalled() -> CLIFailure {
        CLIFailure(code: .appNotInstalled, message: "MarsDawn is not installed. Get it from the Mac App Store, then try again.")
    }
}

/// The status `marsdawn` exits with for an error: a `CLIFailure`'s own code, and otherwise
/// ArgumentParser's — 64 for a usage error, 0 for `--help` and `--version`.
func cliExitCode(for error: Error) -> Int32 {
    if let failure = error as? CLIFailure { return failure.code.rawValue }
    return MarsDawnCommand.exitCode(for: error).rawValue
}

/// Where MarsDawn is installed. Replaceable for tests.
enum MarsDawnApp {
    static let bundleIdentifier = "dev.southern-light.marsdawn"

    nonisolated(unsafe) static var locate: () -> URL? = {
        if let override = ProcessInfo.processInfo.environment["MARSDAWN_APP_PATH"] {
            return FileManager.default.fileExists(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func require() throws -> URL {
        guard let url = locate() else { throw CLIFailure.appNotInstalled() }
        return url
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
            abstract: "Open Markdown files in MarsDawn for review.",
            discussion: """
            A folder argument opens in the window's sidebar instead of as a document, so \
            `marsdawn open .` shows the current directory; --folder does the same alongside files. \
            A window's sidebar shows one folder, so naming two is a usage error, and there is no \
            -a: VS Code's -a adds a second root, which MarsDawn has no way to do.
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

        @OptionGroup var output: OutputOptions

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
            guard !files.isEmpty || !folder.isEmpty else {
                throw ValidationError("Nothing to open. Give a file, a folder, or --folder <path>.")
            }
            let directories = files.filter(Open.isDirectory)
            if line != nil, let directory = directories.first {
                throw ValidationError(
                    "--line needs a file, but \(directory) is a folder. A folder opens in the sidebar "
                        + "and has no line to land on."
                )
            }
            let fileArguments = files.count - directories.count
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
            for path in files.filter(Open.isDirectory) + folder {
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

        @MainActor
        func run() async throws {
            let targets = try resolvedTargets()
            let folders = try resolvedFolders()
            let app = try MarsDawnApp.require()
            // Files asking for the same line travel in one event; the line applies to all of them.
            for group in RevealEvent.groups(for: targets) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.appleEvent = RevealEvent.openDocuments(urls: group.urls, line: group.line)
                _ = try await NSWorkspace.shared.open(group.urls, withApplicationAt: app, configuration: configuration)
            }
            // Folders travel on their own, with no reveal line: a folder has no line to land on.
            if !folders.isEmpty {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open(folders, withApplicationAt: app, configuration: configuration)
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
            // first — is decided inside the app, and nothing reports back here. Saying "attached"
            // would tell an agent a thing this command cannot know.
            if let folder = folders.first {
                fields["folder"] = ["path": folder.path, "requested": true]
            }
            var lines = targets.map { target -> String in
                guard let line = target.line else { return "Opened \(target.url.path)" }
                return "Opened \(target.url.path) at line \(line)"
            }
            if let folder = folders.first {
                lines.append("Asked MarsDawn to show \(folder.path) in the sidebar")
            }
            output.report(fields, text: lines.joined(separator: "\n"))
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
                ],
                text: text
            )
        }
    }
}
#endif
