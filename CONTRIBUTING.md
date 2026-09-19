# Contributing

MarsDawnKit is the rendering core, PDF export and the `marsdawn` command-line tool: the
Markdown-to-HTML renderer, preview themes, paginated PDF export and the CLI built on top of them.
This is the right repo for bugs and changes in any of those.

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## What goes elsewhere

- Feedback about the MarsDawn Mac app itself (not the renderer or the CLI) —
  [mars-dawn-website/discussions](https://github.com/redtear1115/mars-dawn-website/discussions).
- Problems installing `marsdawn` through Homebrew, or with the formula or bottles — the
  [homebrew-tap](https://github.com/redtear1115/homebrew-tap) repo. The tap's formula version is
  bumped from this repo's releases; it's not the place to report a rendering or CLI bug.

## Build and test

Requires Xcode 26 (the package uses swift-tools 6.2).

```sh
swift build
swift test
```

CI also runs the release configuration and, on the iOS job, `xcodebuild -scheme MarsDawnKit
-destination 'generic/platform=iOS' build`. If you're touching anything platform-sensitive, it's
worth running `swift test -c release` locally too.

Two things that catch people out when writing tests here:

- **Don't compare exported PDFs byte for byte.** `/CreationDate`, `/ModDate` and the derived `/ID`
  have one-second resolution, so a byte comparison passes or fails depending on timing. Compare
  page count, extracted text and rendered pages instead.
- **Resolve symlinks on both sides when comparing file URLs**, with `resolvingSymlinksInPath()` —
  applied to both sides, not just one — because the signed test host and an unsigned run report
  the temporary directory differently.

## Issues and pull requests

A good issue says what you expected, what happened, and how to reproduce it — a Markdown snippet
that triggers the bug is worth more than a description of one.

Keep pull requests small and focused on one change. Describe what changed and why, not just what.
CI (`swift build`, `swift test`, `swift test -c release`, and the CLI export smoke test) has to be
green; a PR that doesn't build or test cleanly won't be reviewed.

Version bumps and tagging are covered in [RELEASING.md](RELEASING.md) — you don't need to touch
`Sources/marsdawn/Version.swift` unless you're cutting a release.

## Security

Please report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

By contributing, you agree that your contribution is licensed under this repository's Apache-2.0
license (see [LICENSE](LICENSE)), on the same inbound = outbound basis as the rest of the project.
Bundled third-party code (Mermaid, highlight.js, KaTeX) keeps its own license; see
[NOTICE](NOTICE) and don't add new bundled dependencies without updating it.
