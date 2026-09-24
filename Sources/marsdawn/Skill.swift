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
`--wait <seconds>` sets how long to wait, 0–30, default 2; a value outside that range is a usage
error, exit 64, with `error: wait_out_of_range` in `--json` to tell it apart from other bad-option
errors. `--wait 0`, or an older MarsDawn that doesn't report
back, skips waiting: the `folder` object only carries `path` and `requested: true`, same as
before this existed.

## Full contract

Every field, schema and code: https://marsdawn.southern-light.dev/cli/agents/
"""#
}

extension MarsDawnCommand {
    struct Skill: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the agent skill (SKILL.md) that matches this version of marsdawn.",
            discussion: """
            Install it for Claude Code with:
              mkdir -p ~/.claude/skills/marsdawn && marsdawn skill > ~/.claude/skills/marsdawn/SKILL.md
            """
        )

        func run() {
            FileHandle.standardOutput.write(Data((MarsDawnSkill.text + "\n").utf8))
        }
    }
}
#endif
