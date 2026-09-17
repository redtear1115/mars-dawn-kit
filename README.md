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

- **Don't compare exported PDFs byte for byte.** AppKit's PDF producer writes a random `/ID` into every file, and under load it sometimes tags an embedded font subset differently, so two exports of the same document are never byte-identical, on any commit. Compare the page count and the extracted text, which is what a reader sees anyway.
- **Resolve symlinks on both sides when comparing file URLs.** `FileManager.temporaryDirectory` hands back `/var/folders/…` while enumeration reports `/private/var/folders/…`, so a test that compares a hand-built URL against one the file system produced passes under one signing mode and fails under the other.

## Command line

```sh
swift run marsdawn open notes.md
swift run marsdawn export notes.md -o notes.pdf --theme classic --paper a4
```

- `open <files…>` opens files in the MarsDawn app.
- `export <file> [-o out.pdf] [--theme dawn|classic|modern|vivid] [--paper a4|letter] [--allow-remote-images] [--force] [--json]` renders a PDF without opening a window.
  - The theme defaults to `$MARSDAWN_THEME`, then `dawn`.
  - Existing files are only overwritten with `--force`.
  - `--json` prints `ok`, `output`, `pages` and `diagramErrors`.
- Exit codes: 2 input not found, 3 MarsDawn not installed, 4 output exists, 5 export failed, 64 usage error.
- `MARSDAWN_APP_PATH` overrides where the tool looks for the MarsDawn app. It exists for testing.

## Use as a package

```swift
.package(url: "https://github.com/redtear1115/mars-dawn-kit.git", exact: "0.1.0"),
```

## License

Apache-2.0; see [LICENSE](LICENSE). Bundled Mermaid (MIT), highlight.js (BSD-3-Clause) and KaTeX (MIT) keep their own licenses; see [NOTICE](NOTICE).

Security issues: see [SECURITY.md](SECURITY.md).
