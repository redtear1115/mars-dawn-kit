# Releasing MarsDawnKit and the `marsdawn` CLI

The app ships through the Mac App Store. This repository ships the Swift package and the free
`marsdawn` command-line tool, and the tool reaches people through the Homebrew tap
[`redtear1115/homebrew-tap`](https://github.com/redtear1115/homebrew-tap):

```sh
brew tap redtear1115/tap
brew install marsdawn
```

There is no cask. The app ships only through the Mac App Store and has no direct download, so there
is nothing a cask could install.

## 1. Bump the version in the source

`marsdawn --version` prints `MarsDawnCLI.version` from
[`Sources/marsdawn/Version.swift`](Sources/marsdawn/Version.swift), and the formula's `test do`
block asserts it equals the formula's own `version`. They have to match, so the bump is part of
the release, not an afterthought.

SwiftPM gives a target no way to read the package's tag, and Homebrew builds from a source
tarball that carries no git metadata, so the number cannot be derived at build time. It is a
constant, and a release bumps it by hand.

```sh
# edit Sources/marsdawn/Version.swift so version == the tag you are about to cut
swift test
swift test -c release
```

## 2. Tag

The tag is the bare version, with no `v`, because the formula's `url` interpolates it and Homebrew
compares it against `version`.

```sh
git tag 0.3.0
git push origin 0.3.0
```

Tags are immutable. A mistake gets a new patch tag, never a moved one.

## 3. Take the archive's checksum

Download exactly the archive the formula will download — GitHub generates it from the tag, and
re-downloading it later must give the same bytes.

```sh
VERSION=0.3.0
curl -fL -o "marsdawn-$VERSION.tar.gz" \
  "https://github.com/redtear1115/mars-dawn-kit/archive/refs/tags/$VERSION.tar.gz"
shasum -a 256 "marsdawn-$VERSION.tar.gz"
```

## 4. Update the formula

In a branch of the tap, edit `Formula/marsdawn.rb`:

- `url`: the tag archive from step 3. Homebrew takes the formula's version from this URL, which is
  what `test do` compares `marsdawn --version` against.
- `sha256`: the checksum from step 3.

Leave the install layout alone unless you mean to change it. The binary and its resource bundles
(`*.bundle`: preview page, KaTeX, Mermaid) go into `libexec`, and `bin` gets a `write_exec_script`
wrapper, not a symlink. SwiftPM looks for the bundles beside the path the binary was started from,
and some Swift versions (6.3.3, on the GitHub runner) don't follow a symlink to the real binary,
so a symlinked install crashes on start. Completions are generated from `libexec/"marsdawn"`,
because the wrapper only becomes executable once the install finishes:

```ruby
libexec.install ".build/release/marsdawn", *Dir[".build/release/*.bundle"]
bin.write_exec_script libexec/"marsdawn"
generate_completions_from_executable(libexec/"marsdawn", "--generate-completion-script")
```

## 5. Build, test, audit, and export for real

```sh
brew install --build-from-source redtear1115/tap/marsdawn
brew test marsdawn
brew audit --strict --online redtear1115/tap/marsdawn
```

**`brew test` does not export a PDF.** Its sandbox denies the Mach lookups WebKit needs to start
its helper processes, so the formula's test covers only `--version` and the JSON error contract
(exits 2, 3 and 4). See [homebrew-tap#2](https://github.com/redtear1115/homebrew-tap/issues/2).
Export has to be checked outside the sandbox, with the app out of the picture:

```sh
MARSDAWN_APP_PATH=/nonexistent marsdawn export doc.md -o out.pdf --json   # exit 0, "ok": true
MARSDAWN_APP_PATH=/nonexistent marsdawn open doc.md                       # exit 3
```

Use a document with math, a Mermaid diagram, code and a web image, and look at the PDF. The tap's
CI does the same on a macOS runner for every pull request (step 6).

## 6. Open the tap pull request

Push the branch and open the PR against the tap. Its CI (`install-check.yml`) installs the
formula from source on a macOS runner, runs `brew test` and `brew audit`, and exports a real PDF.
The PR needs that run green and an independent verification before it merges. Merging it is the
owner's call, as is cutting the tag in step 2.

## 7. Check the weekly install run

The same workflow also runs weekly, so a runner-image change can't break installs unnoticed. But
GitHub turns off scheduled workflows in a public repository after 60 days without activity, and a
tap that only changes at release time can easily go that long. A release is when someone is
looking, so check it now:

```sh
gh workflow list --all --repo redtear1115/homebrew-tap               # "disabled_inactivity" means it stopped
gh workflow enable install-check.yml --repo redtear1115/homebrew-tap  # turns it back on
gh workflow run install-check.yml --repo redtear1115/homebrew-tap     # runs it now against main
```

## 8. Afterwards

- Update the website's `/cli/` install section and `llms.txt`, in en and zh-Hant, if anything
  about installing changed.
- If the release changes what the tool does, update the tap README's description of the commands.
