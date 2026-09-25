#if os(macOS)
import ArgumentParser
import Darwin
import Foundation

/// The agent skill for this exact CLI (#60): `marsdawn skill > ~/.claude/skills/marsdawn/SKILL.md`.
///
/// Printed from here, so the skill never describes an option the installed CLI lacks.
/// `SkillTests` check it against the CLI's own help.
///
/// **The canonical text is `skill/SKILL.md` in this repository**, and this string must equal it
/// byte for byte (`SkillTests.theEmbeddedTextIsTheSkillFile`). The website's `/cli/skill/SKILL.md`
/// is checked against that file at the kit tag the site documents, so a wording change lands
/// here first and reaches the site with a release.
enum MarsDawnSkill {
    static let text = #"""
---
name: marsdawn
description: Export Markdown to PDF with the marsdawn command-line tool on macOS and read its JSON result, and open Markdown you wrote in MarsDawn for the user to review. Use when asked to turn a Markdown file into a PDF, or to render Markdown with tables, math, Mermaid diagrams or highlighted code into a PDF. Also use after writing or revising a Markdown document the user will read, to open it in MarsDawn for review.
---

# marsdawn

`marsdawn export` renders a Markdown file to PDF on macOS 15 or later. It needs nothing else
installed, not even the MarsDawn app.

## Install and check

```sh
command -v marsdawn || brew install redtear1115/tap/marsdawn
marsdawn --version
```

Use the version it prints. Don't assume one. On Apple silicon Homebrew pours a prebuilt bottle;
on an Intel Mac it builds from source and needs Xcode 26 or later. If the install stops with
"A full installation of Xcode.app 26.0 is required", say so rather than retrying.

## Export

```sh
marsdawn export input.md --json
```

Options: `-o out.pdf` (default: beside the input), `--theme dawn|classic|modern|vivid`,
`--paper a4|letter`, `--force` to replace an existing PDF, and
`--allow-remote-images` to load web images, which are left out by default.

On success it exits 0 and prints one JSON line:

- `ok`: always true
- `output`: Absolute path of the PDF that was written.
- `pages`: Number of pages in the PDF.
- `theme`: Theme used for the export.
- `paper`: Paper size used for the export.
- `diagramErrors`: One message per Mermaid diagram that failed to render. The PDF is still written.
- `diagramErrorDetails`: The same failures as `diagramErrors`, in the same order, each as
  `{message, fenceLine, line}`. `fenceLine` is the document line the diagram's fence starts on,
  present whenever that's known. `line` is the document line of the error itself (`fenceLine` plus
  Mermaid's own line number from its message), present only when Mermaid's message names a line —
  some errors, like an undetected diagram type, don't. Either can be absent on its own.

If `diagramErrors` isn't empty, the PDF was still written: tell the user which diagrams failed.

## Exit codes

On failure with `--json` it prints `{"ok": false, "error": <kind>, "message": ...}`.

| Code | `error` | Meaning |
|---|---|---|
| 0 | — | Success. With --json, stdout is one JSON line. |
| 2 | `input_not_found` | The input file isn't there. |
| 3 | `app_not_installed` | MarsDawn isn't installed. Only `open` returns this. |
| 4 | `output_exists` | The PDF already exists. Pass --force to replace it, or -o to write elsewhere. |
| 5 | `export_failed` | Rendering failed. |
| 6 | `app_cannot_open_folders` | This MarsDawn can't show a folder, so nothing was opened. Only `open` returns this. |
| 64 | — | Usage error: a bad option or value. Printed as text on stderr, never as JSON. |

## Review: open what you wrote

After writing or revising a Markdown document the user will read, open it in the MarsDawn app,
where they read it rendered next to the source:

```sh
marsdawn open plan.md:42 --json
```

- `:42` is the line of your first change, counted from 1, so the user lands on it. Leave it off
  when the whole document is new.
- Open it **once**. When you edit the file again, the open window picks up the change by itself
  and tells the user, with Undo. Don't run `open` again after every edit.
- It needs the MarsDawn app. Without it, `open` exits 3 (`app_not_installed`): tell the user once
  and carry on. Don't retry, and don't try to install the app.
- Never use `open` to make a PDF: that's `export`.

### Showing a folder

`marsdawn open . --folder . --json` (or a folder path as an argument) also asks MarsDawn to show
that folder in the window's sidebar, alongside any files. With a MarsDawn that reports back, the
`folder` object in `--json` carries a `status` once the wait ends: `attached`, `needsUser` (see
`waitingFor`: `confirmation` or `folderChoice`, meaning the user has to act — don't retry, just
tell them), `declined`, `failed`, `attachedDifferentFolder`, `full`, `unavailable`, or `unknown`
(the app didn't answer in time; try again with a longer `--wait`, or treat it as "don't know").
`--wait <seconds>` sets how long to wait, 0–30, default 2; a value ArgumentParser can parse as a
number but outside that range is a usage error, exit 64, with `error: wait_out_of_range` in
`--json`. Write a negative value as `--wait=-1`, not `--wait -1`: with a space, ArgumentParser reads
it as another flag and gives its own plain usage error instead — still exit 64, but no
`wait_out_of_range`; a value too large to be a number at all gets the same plain error. `--wait 0`,
or an older MarsDawn that doesn't report
back, skips waiting: the `folder` object only carries `path` and `requested: true`, same as
before this existed.

## Full contract

Every field, schema and code: https://marsdawn.southern-light.dev/cli/agents/
"""#
}

extension MarsDawnCommand {
    struct Skill: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the agent skill (SKILL.md) that matches this version of marsdawn, or install it with --install.",
            discussion: """
            Without --install, prints the skill to stdout — the old way to install it is still \
            good shell:
              mkdir -p ~/.claude/skills/marsdawn && marsdawn skill > ~/.claude/skills/marsdawn/SKILL.md

            --install does that in one step:
              marsdawn skill --install

            It writes ~/.claude/skills/marsdawn/SKILL.md, creating the folder if it doesn't exist \
            yet. A byte-identical file already there is left alone, reported as unchanged. A \
            different one is only replaced with --force, so a local edit to the skill is never \
            overwritten silently; without --force it exits 64 (skill_differs in --json) and says \
            what to do instead. --dir <path> installs to <path>/SKILL.md instead, for another \
            agent's skill folder.
            """
        )

        @Flag(help: "Write the skill to disk (~/.claude/skills/marsdawn/SKILL.md, or --dir) instead of printing it.")
        var install = false

        @Option(help: ArgumentHelp(
            "With --install, the skill folder to write into instead of ~/.claude/skills/marsdawn. Writes <path>/SKILL.md.",
            valueName: "path"
        ))
        var dir: String?

        @Flag(help: "With --install, replace a SKILL.md that's already there and differs.")
        var force = false

        @OptionGroup var output: OutputOptions

        func validate() throws {
            guard !install else { return }
            if dir != nil {
                throw ValidationError("--dir only applies with --install.")
            }
            if force {
                throw ValidationError("--force only applies with --install.")
            }
            if output.json {
                throw ValidationError("--json only applies with --install. Without --install, skill prints the skill text on its own, unchanged by --json.")
            }
        }

        func run() throws {
            try Self.run(install: install, dir: dir, force: force, json: output.json)
        }

        /// The actual logic, apart from `run()` itself, so it can take a `write` sink as a plain
        /// parameter instead of going through `OutputOptions.report`'s real `print`. `Skill`
        /// (like every `ParsableCommand`) is `Decodable`, so a stored closure property on it or on
        /// `OutputOptions` won't compile — Swift can't synthesize `Decodable` for `(String) ->
        /// Void` — and a shared `static var` seam would just move #120 verifier round 3's fd race
        /// one level down: two `SkillTests` running concurrently would still be able to stomp on
        /// each other's override of one global. A plain parameter has neither problem: nothing
        /// shared, nothing to reassign out from under another test, and it fits Swift Testing's
        /// default parallel execution instead of fighting it.
        static func run(install: Bool, dir: String?, force: Bool, json: Bool, write: (String) -> Void = { print($0) }) throws {
            guard install else {
                // `print`'s own "\n" terminator matches the one the old
                // `FileHandle.standardOutput.write` appended by hand — same bytes, either way.
                write(MarsDawnSkill.text)
                return
            }
            let installed = try SkillInstaller.install(dir: dir, force: force)
            let text: String
            switch installed.action {
            case .unchanged: text = "Already installed at \(installed.path)."
            case .replaced: text = "Replaced \(installed.path) with this version's skill."
            case .installed: text = "Installed the skill at \(installed.path)."
            }
            if json {
                write(jsonString(["ok": true, "path": installed.path, "action": installed.action.rawValue]))
            } else {
                write(text)
            }
        }
    }
}

// MARK: - skill --install

/// Writes `MarsDawnSkill.text` to a skill folder (#120), instead of `marsdawn skill` printing it
/// for the caller to redirect. The folder and file name mirror what Claude Code itself expects:
/// `<folder>/SKILL.md`.
enum SkillInstaller {
    /// `$HOME` if set, otherwise `homeDirectoryForCurrentUser` (which itself ignores `$HOME`),
    /// plus `.claude/skills/marsdawn` — the real answer for "where does --install write without
    /// --dir" (verifier round 3). Kept apart from `defaultDirectory` below so a test can call it
    /// directly to check the `$HOME` logic itself, even once `defaultDirectory` has been
    /// overridden or poisoned; it only builds a `URL`, so calling it touches no filesystem.
    static func productionDefaultDirectory() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/skills/marsdawn", isDirectory: true)
    }

    /// Where `--install` writes without `--dir`. Replaceable for tests, so they never touch the
    /// real `~/.claude` (mirrors `MarsDawnApp.locate`'s seam) — but its default is
    /// `productionDefaultDirectory`, which honours `$HOME`, so a run under a temp `$HOME` is safe
    /// even without a test overriding this seam.
    nonisolated(unsafe) static var defaultDirectory: () -> URL = productionDefaultDirectory

    struct Installed {
        enum Action: String {
            case installed, unchanged, replaced
        }

        var path: String
        var action: Action
    }

    /// A short name for a `lstat` file type, for a refusal message.
    static func describe(_ type: FileAttributeType?) -> String {
        switch type {
        case .typeDirectory: "a folder"
        case .typeSymbolicLink: "a symlink"
        case .typeSocket: "a socket"
        case .typeCharacterSpecial: "a character device"
        case .typeBlockSpecial: "a block device"
        default: "not a plain file"
        }
    }

    /// Installs `MarsDawnSkill.text` at `<dir ?? defaultDirectory()>/SKILL.md`, atomically: a temp
    /// file written next to the target, in the same folder so the swap can't cross a filesystem,
    /// then `rename(2)` puts it at `target` in one step. A reader never sees a half-written file,
    /// and — critically for `--force` — a failed rename never loses what was at `target`: nothing
    /// ever deletes it first, `rename(2)` replaces it atomically or the call fails and it's
    /// untouched.
    static func install(dir: String?, force: Bool, fileManager: FileManager = .default) throws -> Installed {
        let directory = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL } ?? defaultDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let target = directory.appendingPathComponent("SKILL.md")

        // What's at the target, `lstat`-style (the symlink itself, never what it points to).
        // `targetIsAFile` stays false when nothing is there, the common case. Everything below
        // this either refuses unconditionally — a symlink escaping the folder, or anything that
        // isn't a plain file — or falls through to the existing-content comparison; `--force` only
        // ever overrides *that* comparison, never these: it means "replace the differing SKILL.md
        // I asked about," never "delete whatever's in the way."
        var targetIsAFile = false
        if let attributes = try? fileManager.attributesOfItem(atPath: target.path) {
            let type = attributes[.type] as? FileAttributeType
            switch type {
            case .typeSymbolicLink:
                // Refuse before touching anything if the symlink escapes the folder it's meant to
                // stay in — never followed to overwrite something elsewhere on the disk.
                let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
                guard resolvedTarget.path.hasPrefix(resolvedDirectory.path + "/") else {
                    throw SkillInstallFailure(
                        kind: .unsafeSymlink,
                        message: "\(target.path) is a symlink to \(resolvedTarget.path), outside \(resolvedDirectory.path). "
                            + "Refusing to write through it. Remove or repoint the symlink, then run --install again."
                    )
                }
                // Inside the folder is safe from the escape check above, but what it resolves to
                // still has to be a plain file (or nothing — a dangling symlink is fine to
                // replace), for the same reason a folder at the target path is refused below.
                if let resolvedAttributes = try? fileManager.attributesOfItem(atPath: resolvedTarget.path) {
                    let resolvedType = resolvedAttributes[.type] as? FileAttributeType
                    guard resolvedType == .typeRegular else {
                        throw SkillInstallFailure(
                            kind: .notAFile,
                            message: "\(target.path) is a symlink to \(resolvedTarget.path), which is \(describe(resolvedType)), not a file. "
                                + "Refusing to write there, --force included: that isn't replacing a SKILL.md."
                        )
                    }
                    targetIsAFile = true
                }
            case .typeRegular:
                targetIsAFile = true
            default:
                // A folder, a FIFO, a socket, a device — never deleted to make room for the skill.
                throw SkillInstallFailure(
                    kind: .notAFile,
                    message: "\(target.path) is \(describe(type)), not a file. Refusing to write there, --force included: "
                        + "that isn't replacing a SKILL.md. Move or remove it yourself, then run --install again."
                )
            }
        }

        let newData = Data((MarsDawnSkill.text + "\n").utf8)
        if targetIsAFile {
            let existingData = try? Data(contentsOf: target)
            if let existingData, existingData == newData {
                return Installed(path: target.path, action: .unchanged)
            }
            guard force else {
                if let existingData {
                    let hint = versionHint(in: String(decoding: existingData, as: UTF8.self)).map { " (\($0))" } ?? ""
                    throw SkillInstallFailure(
                        kind: .differs,
                        message: "\(target.path) already exists and differs from this version's skill\(hint). "
                            + "Pass --force to replace it, or --dir to install somewhere else."
                    )
                }
                throw SkillInstallFailure(
                    kind: .unreadable,
                    message: "\(target.path) already exists, but couldn't be read to compare against this version's "
                        + "skill (permission denied, most likely). Treating it as different: check its permissions, "
                        + "or pass --force to replace it without comparing."
                )
            }
        }

        let temporary = directory.appendingPathComponent(".SKILL.md.\(UUID().uuidString).tmp")
        try newData.write(to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        // POSIX `rename(2)`, not `FileManager.moveItem`/`replaceItemAt`: on the same filesystem
        // (guaranteed above — the temp file lives right next to `target`) it atomically replaces
        // whatever is at `target`, in one step, or fails leaving `target` exactly as it was.
        // `moveItem` refuses outright when something's already at the destination; `replaceItemAt`
        // resolves symlinks while building its own backup and then fails looking for the target
        // through it (the bug an earlier pass here hit); deleting `target` first and then
        // `moveItem`-ing the replacement in (what an earlier pass here did instead) avoided that,
        // but opened exactly the non-atomic window a `--force` replace exists to close — a failed
        // `moveItem` after the delete would have lost the user's existing file for good.
        guard rename(temporary.path, target.path) == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't install the skill: rename(2) from \(temporary.path) to \(target.path) failed: \(String(cString: strerror(code)))"]
            )
        }
        return Installed(path: target.path, action: targetIsAFile ? .replaced : .installed)
    }

    /// A version-looking mention (`marsdawn 0.5.1`, say) near the top of an existing file, for the
    /// conflict message. Today's canonical `SKILL.md` carries no such line, so this usually finds
    /// nothing — it exists for whatever a hand-edited or future file does carry, per #120's "the
    /// version line if the file has one".
    static func versionHint(in text: String) -> String? {
        for line in text.components(separatedBy: "\n").prefix(20) {
            if let match = line.firstMatch(of: /marsdawn[^\d\n]{0,12}(\d+\.\d+(?:\.\d+)?)/) {
                return "marsdawn \(match.output.1)"
            }
        }
        return nil
    }
}
#endif
