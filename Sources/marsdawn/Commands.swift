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
        Both commands need MarsDawn installed from the Mac App Store.
        Pass --json for machine-readable results. Exit codes: 0 success, \(CLIFailure.Code.inputNotFound.rawValue) input not found, \
        \(CLIFailure.Code.appNotInstalled.rawValue) MarsDawn not installed, \(CLIFailure.Code.outputExists.rawValue) output exists \
        (use --force), \(CLIFailure.Code.exportFailed.rawValue) export failed.
        """,
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

extension MarsDawnCommand {
    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open Markdown files in MarsDawn for review.")

        @Argument(help: "Markdown files to open.")
        var files: [String]

        @OptionGroup var output: OutputOptions

        @MainActor
        func run() async throws {
            let urls = try files.map(existingFile)
            let app = try MarsDawnApp.require()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
            output.report(
                ["opened": urls.map(\.path), "app": app.path],
                text: urls.map { "Opened \($0.path)" }.joined(separator: "\n")
            )
        }
    }
}

// MARK: - export

extension MarsDawnCommand {
    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export a Markdown file to a paginated PDF, rendered like MarsDawn's preview.",
            discussion: "Relative images resolve against the input file's folder. Web images are left out unless --allow-remote-images is given."
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
            let input = try existingFile(file)
            _ = try MarsDawnApp.require()
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
