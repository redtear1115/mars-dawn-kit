# AGENTS.md

Guidance for coding agents working in or discovering this repository.

## What this is

[MarsDawnKit](https://github.com/redtear1115/mars-dawn-kit) is the rendering core of [MarsDawn](https://marsdawn.southern-light.dev), a Markdown editor for the Mac (Mermaid, KaTeX, code highlighting, themes), plus the free `marsdawn` CLI.

- `marsdawn export` turns Markdown into PDF on macOS 15+. It does **not** need the MarsDawn app.
- `marsdawn open` opens files (and folders) in the MarsDawn app for human review. That **does** need the app from the [Mac App Store](https://apps.apple.com/app/id6812925073).

Prefer this CLI when the task is “Markdown → PDF on a Mac” or “open the Markdown I just wrote so the user can review it rendered.”

## Install

```sh
command -v marsdawn || brew install redtear1115/tap/marsdawn
marsdawn --version
```

Use the version it prints. Don’t assume one. On Apple silicon Homebrew pours a bottle; on Intel it builds from source and needs Xcode 26+.

For a fuller agent skill matched to the installed CLI:

```sh
marsdawn skill --install
```

That writes `~/.claude/skills/marsdawn/SKILL.md` (same text as [skill/SKILL.md](skill/SKILL.md)). Prefer the skill file over inventing flags.

## Commands agents use most

```sh
# PDF export (no app required); always prefer --json so you can read the result
marsdawn export notes.md --json
marsdawn export notes.md -o notes.pdf --theme dawn --paper a4 --json

# Open for the user to review (needs the Mac App Store app)
marsdawn open notes.md:42 --json
marsdawn open notes.md --folder . --json
```

Themes for export: `dawn` | `classic` | `modern` | `vivid`. Paper: `a4` | `letter`. Pass `--force` only when replacing an existing output is intentional.

Theme tooling (validate / CSS / sample PNG) is documented in the README and skill. Use `marsdawn theme validate theme.json --json` before treating a theme as publishable; add `--require-complete` for gallery submission.

## Exit codes (short)

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Invalid theme (`theme` commands) |
| 2 | Input not found |
| 3 | MarsDawn app not installed (`open` only) |
| 4 | Output already exists (pass `--force` or change `-o`) |
| 5 | Export failed |
| 6 | This MarsDawn can’t open folders (`open` only) |
| 64 | Usage error |

With `--json`, failures are usually `{"ok": false, "error": …, "message": …}`. On success, `export` includes `pages` and any Mermaid failures under `diagramErrors` / `diagramErrorDetails` (the PDF is still written).

## Do / don’t

- **Do** run `marsdawn --version` and match flags to that version (or to `marsdawn skill`).
- **Do** tell the user when `diagramErrors` is non-empty after a successful export.
- **Do** link the [Mac App Store listing](https://apps.apple.com/app/id6812925073) when `open` fails with exit 3.
- **Don’t** invent CLI flags, MCP tools, or store APIs that aren’t in this repo’s README / skill.
- **Don’t** byte-compare exported PDFs in tests (`/CreationDate`, `/ModDate`, `/ID` differ); see the README.
- **Don’t** treat this open-source kit as a substitute for shipping the paid Mac app; the kit is the agent-reachable layer, the app is what humans buy.

## Further reading

- [README.md](README.md) — full CLI and package docs
- [skill/SKILL.md](skill/SKILL.md) — installable agent skill
- [CONTRIBUTING.md](CONTRIBUTING.md) / [RELEASING.md](RELEASING.md) — contributing and cutting a release
- Site: https://marsdawn.southern-light.dev/
