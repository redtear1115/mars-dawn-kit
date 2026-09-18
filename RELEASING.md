# Releasing MarsDawnKit and the `marsdawn` CLI

The app ships through the Mac App Store. This repository ships the Swift package and the free
`marsdawn` command-line tool, and the tool reaches people through the Homebrew tap
[`redtear1115/homebrew-tap`](https://github.com/redtear1115/homebrew-tap):

```sh
brew tap redtear1115/tap
brew install marsdawn
```

There is no cask. Homebrew Cask does not accept an app whose full version ships only through the
Mac App Store.

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

- `url` — the tag archive from step 3;
- `sha256` — the checksum from step 3;
- `version` — the same number, which is what `test do` compares `marsdawn --version` against.

## 5. Build, test and audit it locally

```sh
brew install --build-from-source redtear1115/tap/marsdawn
brew test marsdawn
brew audit --strict --online redtear1115/tap/marsdawn
```

`brew test` has to pass on a machine with **no MarsDawn.app installed**: `marsdawn export` renders
on its own, and only `marsdawn open` needs the app. If the app is installed on your machine, force
the same situation before trusting a green run:

```sh
MARSDAWN_APP_PATH=/nonexistent marsdawn export doc.md -o out.pdf --json   # exit 0, writes a PDF
MARSDAWN_APP_PATH=/nonexistent marsdawn open doc.md                       # exit 3
```

Shell completions come from ArgumentParser, so the formula can install them without any extra
work in the tool:

```ruby
generate_completions_from_executable(bin/"marsdawn", "--generate-completion-script")
```

ArgumentParser takes the shell name as the argument after the flag
(`marsdawn --generate-completion-script zsh`), which is the form that helper uses by default.
Check the three generated files once, the first time the formula installs them.

## 6. Open the tap pull request

Push the branch and open the PR against the tap. Merging it is the owner's call, as is cutting
the tag in step 2.

## 7. Afterwards

- Update the website's `/cli/` install section and `llms.txt`, in en and zh-Hant, once the tap
  works.
- The tap README explains the split in one paragraph: the app ships through the Mac App Store,
  and Homebrew carries the CLI only.
