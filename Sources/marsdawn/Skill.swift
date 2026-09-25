#if os(macOS)
import ArgumentParser
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
            guard install else {
                FileHandle.standardOutput.write(Data((MarsDawnSkill.text + "\n").utf8))
                return
            }
            let installed = try SkillInstaller.install(dir: dir, force: force)
            let text: String
            switch installed.action {
            case .unchanged: text = "Already installed at \(installed.path)."
            case .replaced: text = "Replaced \(installed.path) with this version's skill."
            case .installed: text = "Installed the skill at \(installed.path)."
            }
            output.report(["path": installed.path, "action": installed.action.rawValue], text: text)
        }
    }
}

// MARK: - skill --install

/// Writes `MarsDawnSkill.text` to a skill folder (#120), instead of `marsdawn skill` printing it
/// for the caller to redirect. The folder and file name mirror what Claude Code itself expects:
/// `<folder>/SKILL.md`.
enum SkillInstaller {
    /// Where `--install` writes without `--dir`. Replaceable for tests, so they never touch the
    /// real `~/.claude` (mirrors `MarsDawnApp.locate`'s seam).
    nonisolated(unsafe) static var defaultDirectory: () -> URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/marsdawn", isDirectory: true)
    }

    struct Installed {
        enum Action: String {
            case installed, unchanged, replaced
        }

        var path: String
        var action: Action
    }

    /// Installs `MarsDawnSkill.text` at `<dir ?? defaultDirectory()>/SKILL.md`, atomically (a temp
    /// file next to the target, then a rename, so a reader never sees a half-written file).
    static func install(dir: String?, force: Bool, fileManager: FileManager = .default) throws -> Installed {
        let directory = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL } ?? defaultDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let target = directory.appendingPathComponent("SKILL.md")

        // Refuse before touching anything if the target is a symlink that escapes the folder it's
        // meant to stay in — never followed to overwrite something elsewhere on the disk.
        if let attributes = try? fileManager.attributesOfItem(atPath: target.path),
           (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedTarget.path.hasPrefix(resolvedDirectory.path + "/") else {
                throw SkillInstallFailure(
                    kind: .unsafeSymlink,
                    message: "\(target.path) is a symlink to \(resolvedTarget.path), outside \(resolvedDirectory.path). "
                        + "Refusing to write through it. Remove or repoint the symlink, then run --install again."
                )
            }
        }

        let newData = Data((MarsDawnSkill.text + "\n").utf8)
        let existingData = try? Data(contentsOf: target)
        if let existingData {
            if existingData == newData {
                return Installed(path: target.path, action: .unchanged)
            }
            guard force else {
                let hint = versionHint(in: String(decoding: existingData, as: UTF8.self)).map { " (\($0))" } ?? ""
                throw SkillInstallFailure(
                    kind: .differs,
                    message: "\(target.path) already exists and differs from this version's skill\(hint). "
                        + "Pass --force to replace it, or --dir to install somewhere else."
                )
            }
        }

        let temporary = directory.appendingPathComponent(".SKILL.md.\(UUID().uuidString).tmp")
        try newData.write(to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        // `removeItem` on `target` removes the symlink itself, not what it points to, the same as
        // `rm`; harmless when nothing is there yet. Plain `moveItem` after that (not
        // `replaceItemAt`, which resolves symlinks while building its backup and then fails
        // looking for the target through it) is an atomic rename either way.
        try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: temporary, to: target)
        return Installed(path: target.path, action: existingData == nil ? .installed : .replaced)
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
