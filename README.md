# MarsDawnKit

The rendering core of [MarsDawn](https://marsdawn.southern-light.dev), a Markdown editor for the Mac, plus the free `marsdawn` command-line tool.

| Product | Platforms | What it does |
|---|---|---|
| `MarsDawnKit` | macOS 15, iOS 17 | Markdown → HTML renderer, preview page (Mermaid diagrams, code highlighting, KaTeX math), preview themes |
| `MarsDawnExport` | macOS 15 | Paginated PDF export of the preview, the same exporter the app uses |
| `marsdawn` | macOS 15 | Command-line tool: open documents in MarsDawn, export them to PDF |

## Build and test

Requires Xcode 26 (the package uses swift-tools 6.2).

```sh
swift build
swift test
```

Two things that have caught people out when writing tests here:

- **Don't compare exported PDFs byte for byte.** Two exports of the same document differ only in `/CreationDate`, `/ModDate` and the `/ID` derived from them, which have one-second resolution. Exports within the same second are byte-identical and exports a second apart are not, so a byte comparison passes or fails depending on timing. Compare the page count, the extracted text and the rendered pages instead.
- **Resolve symlinks on both sides when comparing file URLs.** `FileManager.temporaryDirectory` hands back `/var/folders/…` while enumeration reports `/private/var/folders/…`, so a test that compares a hand-built URL against one the file system produced passes under the signed, sandboxed test host (whose temporary directory is inside the app container) and fails with `CODE_SIGNING_ALLOWED=NO`. `resolvingSymlinksInPath()` maps both back to `/var/…`, so it has to be applied to both sides; resolving only one still fails.

## Command line

```sh
swift run marsdawn open notes.md
swift run marsdawn open notes.md:120
swift run marsdawn open .
swift run marsdawn open notes.md --folder .
swift run marsdawn export notes.md -o notes.pdf --theme classic --paper a4
```

- `open <paths…> [--line N] [--folder DIR] [--json]` opens files in the MarsDawn app, and folders in its sidebar.
  - **It needs the MarsDawn app, which is not publicly available yet.** It is headed for the Mac App Store; until it is there, `open` exits with code 3 on any Mac that does not already have the app, and everything below describes what it will do once you have it. `export` needs no app and works today.
  - A file argument can name a line: `notes.md:120` lands on line 120, and a column after it (`notes.md:120:8`) is accepted and ignored. An argument that names a file which exists is always the whole filename, so a file called `weird:12` still opens as itself.
  - `--line N` says the same thing for a single file, and is the way to ask for a line on a path that itself ends in a colon and digits. With more than one file it is a usage error.
  - Lines run from 1 to 999999999. Anything else is a usage error, and nothing is sent.
  - The line travels inside the same open-documents Apple Event that carries the files, so it arrives whether MarsDawn is already running or not. There is no URL scheme.
  - A **folder** argument opens in the window's sidebar instead of as a document: `marsdawn open .` shows the current directory. `--folder DIR` does the same alongside files, so `marsdawn open notes.md --folder .` opens the document and shows its project.
  - A MarsDawn window's sidebar shows **one** folder, so naming two is a usage error. Naming the same folder twice (as an argument and again with `--folder`) is not — it's one folder.
  - There is no `-a`. VS Code's `-a` adds a second root to a window; MarsDawn has one folder per window, so `--folder` sets that folder rather than adding to it. Passing `-a` fails with a message saying so.
  - `--line` needs a file. A folder has no line to land on, so asking for one is a usage error.
  - `--json` prints `ok`, `app` and `opened`: one object per file, `{"path": …}`, carrying `"line"` when one was asked for. A folder adds `"folder": {"path": …, "requested": true}` — **`requested`, not `attached`**: the command hands the folder to the app and returns, and whether the sidebar ends up showing it, or the app has to ask you for access first, is decided inside the app and never reported back here.
- `export <file> [-o out.pdf] [--theme dawn|classic|modern|vivid] [--paper a4|letter] [--allow-remote-images] [--force] [--json]` renders a PDF without opening a window.
  - The theme defaults to `$MARSDAWN_THEME`, then `dawn`.
  - Existing files are only overwritten with `--force`.
  - `--json` prints `ok`, `output`, `pages` and `diagramErrors`.
  - It renders on its own: the MarsDawn app does not have to be installed. Only `open` needs the app.
- `--version` prints the release number and nothing else, so a package manager can compare it against its own. Bumping it is part of cutting a release; see [RELEASING.md](RELEASING.md).
- `--generate-completion-script bash|zsh|fish` writes a shell completion script to stdout.
- Exit codes: 2 input not found, 3 MarsDawn not installed (`open` only), 4 output exists, 5 export failed, 64 usage error.
- `MARSDAWN_APP_PATH` overrides where the tool looks for the MarsDawn app. It exists for testing.

## Use as a package

```swift
.package(url: "https://github.com/redtear1115/mars-dawn-kit.git", exact: "0.1.0"),
```

## License

Apache-2.0; see [LICENSE](LICENSE). Bundled Mermaid (MIT), highlight.js (BSD-3-Clause) and KaTeX (MIT) keep their own licenses; see [NOTICE](NOTICE).

Security issues: see [SECURITY.md](SECURITY.md).
