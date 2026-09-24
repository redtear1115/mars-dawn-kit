#if os(macOS)
import AppKit
import ArgumentParser
import Foundation

// WebKit layout and printing need a running AppKit event loop, so the command runs as a
// task while NSApplication spins; the app never shows a Dock icon or takes focus.
let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")

@MainActor
func finish(_ error: Error?) -> Never {
    guard let error else { exit(0) }
    if let failure = error as? CLIFailure {
        if wantsJSON {
            printJSON(["ok": false, "error": failure.code.kind, "message": failure.message])
        } else {
            FileHandle.standardError.write(Data("marsdawn: \(failure.message)\n".utf8))
        }
        exit(cliExitCode(for: failure))
    }
    if let failure = error as? WaitRangeFailure {
        if wantsJSON {
            printJSON(["ok": false, "error": WaitRangeFailure.kind, "message": failure.message])
        } else {
            FileHandle.standardError.write(Data("marsdawn: \(failure.message)\n".utf8))
        }
        exit(WaitRangeFailure.exitCode) // 64, ArgumentParser's own usage-error code.
    }
    // Other usage errors, --help and --version keep ArgumentParser's own output and exit codes.
    MarsDawnCommand.exit(withError: error)
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

Task { @MainActor in
    do {
        var command = try MarsDawnCommand.parseAsRoot(arguments)
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
        finish(nil)
    } catch {
        finish(error)
    }
}

application.run()
#else
print("marsdawn is only available on macOS.")
#endif
