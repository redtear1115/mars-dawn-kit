# MarsDawnKit

The rendering core of [MarsDawn](https://marsdawn.southern-light.dev), a Markdown editor for the Mac, plus the free `marsdawn` command-line tool.

| Product | Platforms | What it does |
|---|---|---|
| `MarsDawnKit` | macOS 15, iOS 17 | Markdown → HTML renderer, preview page (Mermaid diagrams, code highlighting, KaTeX math), preview themes |
| `MarsDawnExport` | macOS 15 | Paginated PDF export of the preview, the same exporter the app uses |
| `marsdawn` | macOS 15 | Command-line tool: open documents in MarsDawn, export them to PDF |

## Build and test

Requires Xcode 26 or later (the package uses swift-tools 6.2).

```sh
swift build
swift test
```

On a machine with only a few cores, add `--no-parallel`. CI runs `swift test --no-parallel` and
`swift test -c release --no-parallel` (`.github/workflows/ci.yml`), because on its 3-CPU runners the
WebKit suites time out waiting for their pages when every suite runs at once, and the timing-budget
tests miss their budgets.

Two things that have caught people out when writing tests here:

- **Don't compare exported PDFs byte for byte.** Two exports of the same document differ only in `/CreationDate`, `/ModDate` and the `/ID` derived from them, which have one-second resolution. Exports within the same second are byte-identical and exports a second apart are not, so a byte comparison passes or fails depending on timing. Compare the page count, the extracted text and the rendered pages instead.
- **Resolve symlinks on both sides when comparing file URLs.** `FileManager.temporaryDirectory` hands back `/var/folders/…` while enumeration reports `/private/var/folders/…`, so a test that compares a hand-built URL against one the file system produced passes under the signed, sandboxed test host (whose temporary directory is inside the app container) and fails with `CODE_SIGNING_ALLOWED=NO`. `resolvingSymlinksInPath()` maps both back to `/var/…`, so it has to be applied to both sides; resolving only one still fails.

## Command line

Install it with Homebrew: `brew tap redtear1115/tap && brew install marsdawn`.
Using a coding agent? Add the skill: https://marsdawn.southern-light.dev/cli/skill/

```sh
swift run marsdawn open notes.md
swift run marsdawn open notes.md:120
swift run marsdawn open .
swift run marsdawn open notes.md --folder .
swift run marsdawn export notes.md -o notes.pdf --theme classic --paper a4
```

- `open <paths…> [--line N] [--folder DIR] [--background] [--wait N] [--json]` opens files in the MarsDawn app, and folders in its sidebar.
  - **It needs the MarsDawn app, from the [Mac App Store](https://apps.apple.com/app/id6812925073).** Without the app, `open` exits with code 3. `export` needs no app.
  - A file argument can name a line: `notes.md:120` lands on line 120, and a column after it (`notes.md:120:8`) is accepted and ignored. An argument that names a file which exists is always the whole filename, so a file called `weird:12` still opens as itself.
  - `--line N` says the same thing for a single file, and is the way to ask for a line on a path that itself ends in a colon and digits. With more than one file it is a usage error.
  - Lines run from 1 to 999999999. Anything else is a usage error, and nothing is sent.
  - The line travels inside the same open-documents Apple Event that carries the files, so it arrives whether MarsDawn is already running or not. There is no URL scheme.
  - A **folder** argument opens in the window's sidebar instead of as a document: `marsdawn open .` shows the current directory. `--folder DIR` does the same alongside files, so `marsdawn open notes.md --folder .` opens the document and shows its project.
  - A MarsDawn window's sidebar shows **one** folder, so naming two is a usage error, and so is `--folder` twice, even for the same folder. Naming the same folder as an argument and again with `--folder` is not: it's one folder.
  - There is no `-a`. VS Code's `-a` adds a second root to a window; MarsDawn has one folder per window, so `--folder` sets that folder rather than adding to it. Passing `-a` fails with a message saying so.
  - `--line` needs a file. A folder has no line to land on, so asking for one is a usage error.
  - **Folders need an app that can take them.** A folder argument or `--folder DIR` asks MarsDawn to show that folder in the window's sidebar, but only an app that declares it can (`MarsDawnOpensFolders` in its Info.plist) is sent one. MarsDawn 1.0.0, the App Store release, does. With an app that doesn't, `open` refuses folders before sending anything and exits 6, and files on their own open as usual. The usage rules still apply: one folder, `--line` needs a file, and there is no `-a`.
  - **An app that also reports back tells you what happened to the folder.** With an app that declares `MarsDawnReportsFolderStatus` in its Info.plist, and `--wait` greater than 0, `open --folder` waits for the app's own answer instead of only reporting that it asked. `--wait N` sets how long to wait, in seconds, `0`–`30` (default `2`); a value ArgumentParser can parse as a number but outside that range is a usage error, exit `64`, with `error: "wait_out_of_range"` in `--json`. Write a negative value as `--wait=-1`, not `--wait -1`: with a space, ArgumentParser reads it as another flag and gives its own plain usage error instead — still exit `64`, but no `wait_out_of_range`; a value too large to be a number at all gets the same plain error. `--wait 0`, or an app that doesn't report back, skips waiting entirely and sends exactly what `open --folder` always has — no extra network or Apple Event traffic, byte-identical to before this existed.
  - `--background` opens without bringing MarsDawn to the front, for an agent that opens files while you work elsewhere. Without it, MarsDawn comes to the front, as before. The `--json` result is the same either way.
  - `--json` prints `ok`, `app` and `opened`: one object per file, `{"path": …}`, carrying `"line"` when one was asked for. With an app that takes folders, a folder adds `"folder": {"path": …, "requested": true}` — **`requested`, not `attached`**: whether the sidebar ends up showing it, or the app has to ask you for access first, is decided inside the app. With an app that reports back and a `--wait` that asks for it, the same object also carries `"status"` (`"attached"`, `"needsUser"`, `"declined"`, `"failed"`, `"attachedDifferentFolder"`, `"full"`, `"unavailable"` or `"unknown"`) once the wait ends, and, only alongside `"needsUser"`, `"waitingFor"` (`"confirmation"` or `"folderChoice"`).
- `export <file> [-o out.pdf] [--theme dawn|classic|modern|vivid] [--paper a4|letter] [--allow-remote-images] [--force] [--json]` renders a PDF without opening a window.
  - The theme defaults to `$MARSDAWN_THEME`, then `dawn`.
  - Existing files are only overwritten with `--force`.
  - `--json` prints `ok`, `output`, `pages`, `diagramErrors` and `diagramErrorDetails` (the same
    failures as `diagramErrors`, in the same order, each as `{message, fenceLine, line}`:
    `fenceLine` is the diagram's own fence line, present whenever known; `line` is the error's own
    line — `fenceLine` plus Mermaid's line number from its message — present only when Mermaid's
    message names one, which not every error does).
  - It renders on its own: the MarsDawn app does not have to be installed. Only `open` needs the app.
- `--version` prints the release number and nothing else, so a package manager can compare it against its own. Bumping it is part of cutting a release; see [RELEASING.md](RELEASING.md).
- `--generate-completion-script bash|zsh|fish` writes a shell completion script to stdout.
- Exit codes: 2 input not found, 3 MarsDawn not installed (`open` only), 4 output exists, 5 export failed, 6 this MarsDawn can't take a folder (`open` only), 64 usage error.
- `MARSDAWN_APP_PATH` overrides where the tool looks for the MarsDawn app. It exists for testing, so
  it's only honoured for a bundle whose `CFBundleIdentifier` is `dev.southern-light.marsdawn` or
  starts with `dev.southern-light.marsdawn.` (a throwaway verification copy); anything else is
  refused with exit code 3, and every use prints a notice on stderr.

## Use as a package

```swift
.package(url: "https://github.com/redtear1115/mars-dawn-kit.git", exact: "0.5.3"),
```

## License

Apache-2.0; see [LICENSE](LICENSE). Bundled Mermaid (MIT), highlight.js (BSD-3-Clause) and KaTeX (MIT) keep their own licenses; see [NOTICE](NOTICE).

Security issues: see [SECURITY.md](SECURITY.md).
