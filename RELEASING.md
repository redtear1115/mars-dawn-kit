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

Pushing the tag runs CI against the tagged tree, including a job that builds the CLI and fails if
`marsdawn --version` doesn't print the tag's own name. Watch that run before you go on to step 3:
everything after this point -- the checksum, the formula, the bottle -- is built on the assumption
that the tag is right, and 0.4.0 reached users reporting `0.3.0` because step 1 was skipped and
nothing between here and `brew install` compared the two.

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

Change nothing else. Don't edit the `bottle do ... end` block by hand, and don't add one for the
new version: the publish run in step 6b writes it. The tap PR changes only `url` and `sha256`.

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
Before the PR is published it needs two things: all its checks green (step 6b, item 2), and a
verifier's confirmation of its head commit (step 6b, item 3). The verifier is someone other than
the author of the PR: a person, or a bot that did not write it. Publishing is the owner's call, as
is cutting the tag in step 2. Publishing is not the merge button: the PR is published as in step
6b, never merged with the button.

CI on the PR shows these checks: `install` (workflow `install-check.yml`), and `test-bot`,
`pour-check (macos-15)`, `pour-check (macos-26)` and `refuses-without-xcode-26` (workflow
`tests.yml`, named "brew test-bot").

## 6b. Publish the bottle

A tap PR is published, not merged. The bottle comes from the PR's CI run: publishing downloads it,
uploads it to a release on the tap, writes the `bottle do` block into the formula, and pushes all of
it to `main`. The merge button skips all of that and leaves the previous version's `bottle do` block
on `main`. Nothing stops the button: publishing does not need the PR merged first, and the tap's
rules for `main` (ruleset "protect main") only block deleting the branch and force-pushing to it,
not the merge button, so this document is the only guard.

In this step, `<version>` is the tag from step 2.

1. Check that the PR changes only `url` and `sha256` in `Formula/marsdawn.rb`. If it touches the
   `bottle do` block, take that change out first.
2. Wait until the PR's checks are all green: `test-bot`, `pour-check (macos-15)` and
   `pour-check (macos-26)`, plus `install` and `refuses-without-xcode-26`. `pour-check` is skipped
   when a PR changes no formula, so a skipped `pour-check` on a version bump is not a pass: find out
   why. If any check is red, fix it before going on; do not publish.
3. Read the PR's head SHA, and get the verifier to confirm that commit. Do not press merge. Only
   the commit the verifier confirmed may be published. Set `PR` to the tap PR's number, digits
   only (the number at the end of the PR's URL):

   ```sh
   PR=<the tap PR number>
   HEAD_SHA=$(gh pr view "$PR" -R redtear1115/homebrew-tap --json headRefOid -q .headRefOid)
   echo "$HEAD_SHA"   # must be 40 characters; if it is empty or shorter, stop
   ```

   Give the verifier this SHA. If the PR gets a new commit after the verifier looked, the verifier
   must confirm the new head, and you read `HEAD_SHA` again.
4. Start the publish run with the SHA from item 3. Only someone with write access to the tap can
   start it:

   ```sh
   gh workflow run publish.yml -R redtear1115/homebrew-tap -f pull_request="$PR" -f head_sha="$HEAD_SHA"
   ```

   Always pass `head_sha`. The workflow treats it as optional: when `head_sha` is empty,
   `publish.yml` (the check `if [[ -n "$HEAD_SHA" ]]`) skips the commit check and runs
   `brew pr-pull` without `--head-sha`, so a commit pushed to the PR after verification could be
   published without anyone having looked at it. With it, the run is told which commit to expect
   (`brew pr-pull --head-sha`), which is what `publish.yml`'s header comment says it is for.

   Then watch the run. The workflow is named "brew pr-pull" and its single job is `pr-pull`.
   `gh run list` can still show the previous run for a few seconds after `gh workflow run`, so use
   the run whose start time is just now. `<run id>` is that run's ID:

   ```sh
   gh run list -R redtear1115/homebrew-tap --workflow publish.yml --limit 1
   gh run watch <run id> -R redtear1115/homebrew-tap --exit-status
   ```

   Expected: the run finishes green and `gh run watch` exits 0.
5. Check what the run did. Use the same terminal as item 3, so `PR` is still set:

   ```sh
   VERSION=<the tag from step 2>
   gh release view "marsdawn-$VERSION" -R redtear1115/homebrew-tap
   gh pr view "$PR" -R redtear1115/homebrew-tap --json state,mergedAt
   gh api repos/redtear1115/homebrew-tap/contents/Formula/marsdawn.rb -H 'Accept: application/vnd.github.raw'
   ```

   Expected: the release `marsdawn-<version>` exists and lists the file
   `marsdawn-<version>.arm64_sequoia.bottle.tar.gz`; the PR is `CLOSED` with `mergedAt` null
   (`pr-pull` closes it; it is not merged); and the formula on `main` has a `bottle do` block whose
   `root_url` ends in `/releases/download/marsdawn-<version>` and whose `arm64_sequoia` sha256 is
   new, not the previous version's. A normal release has no `rebuild` line:

   ```ruby
   bottle do
     root_url "https://github.com/redtear1115/homebrew-tap/releases/download/marsdawn-<version>"
     sha256 cellar: :any_skip_relocation, arm64_sequoia: "<64 hex characters>"
   end
   ```

   A `rebuild 1` line, and the file name `marsdawn-<version>.arm64_sequoia.bottle.1.tar.gz`, appear
   when `main` already has this version's `url` at the moment the bottle is built. In a normal
   release `main` still has the previous version, so they are not expected: if you see them, tell
   the owner. After a merge by mistake (the recovery below) `main` does have the new `url`, so
   there they are expected.

6. Check that a user gets the bottle. Run the tap's release pour check, which installs from the
   published tap on macos-15 and macos-26 and asserts that it poured. As in item 4, `gh run list`
   can still show the previous run for a few seconds: use the run whose start time is just now.

   ```sh
   gh workflow run release-pour-check.yml -R redtear1115/homebrew-tap
   gh run list -R redtear1115/homebrew-tap --workflow release-pour-check.yml --limit 1
   gh run watch <run id> -R redtear1115/homebrew-tap --exit-status
   ```

   Expected: both jobs (macos-15 and macos-26) finish green. A red job means the published bottle
   does not pour: stop, and tell the owner with the run link.

   Then, on a Mac with Apple silicon:

   ```sh
   brew update && brew reinstall redtear1115/tap/marsdawn
   marsdawn --version
   ```

   Expected: the output should contain a line starting
   `==> Pouring marsdawn-<version>.arm64_sequoia.bottle.tar.gz` (after the recovery below, the file
   name is `…bottle.1.tar.gz`), and `marsdawn --version` prints `<version>`. If you don't see
   "Pouring" (for example it runs `swift build`, or says 404), something is wrong: don't tell
   anyone the release is out, and tell the owner what `brew` printed.
   If `main` still has the previous version's `bottle do` block, use the recovery below. The bottle
   is `arm64_sequoia` only, so an Intel Mac gets no bottle (the formula requires macOS Sequoia or
   newer, and Xcode 26 to build).

**If the PR was already merged by mistake.** `main` has the new `url` and `sha256`, but its
`bottle do` block still points at the previous version's release, so `brew install` fails with a
404 for the new version's bottle file, and there is no `marsdawn-<version>` release. This happened
once: the tap PR for one release was merged with the button, publishing was skipped, and that
version's bottle 404ed until
[homebrew-tap#37](https://github.com/redtear1115/homebrew-tap/pull/37) removed the stale block and
was published. To recover:

1. Open a new PR against the tap that removes the whole stale `bottle do ... end` block from
   `Formula/marsdawn.rb` and changes nothing else. Don't write a bottle block for the new version by
   hand: its sha256 must come from the bottle CI builds.
2. Wait for all five checks of item 2 above to be green: `test-bot`, `pour-check (macos-15)`,
   `pour-check (macos-26)`, `install` and `refuses-without-xcode-26`. This run builds the new
   version's bottle.
3. Do items 3 and 4 above again for the new PR, with `PR` set to the new PR's number. Read
   `HEAD_SHA` again: it may still hold the old PR's commit (same terminal) or be empty (a new
   terminal, or item 3 was never run before the merge), and an empty value makes `publish.yml` skip
   the commit check. Check it with `echo`, get the new head confirmed by the verifier, start the
   run, and watch it until it exits 0.
4. Do items 5 and 6 above. Here `main` already has the new `url`, so the expected result is
   `rebuild 1`, the release file `marsdawn-<version>.arm64_sequoia.bottle.1.tar.gz`, and a
   `==> Pouring marsdawn-<version>.arm64_sequoia.bottle.1.tar.gz` line. That is not a reason to
   stop.

## 7. Check the weekly install run

`install-check.yml` also runs weekly, so a runner-image change can't break installs unnoticed. But
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

## Bumping swift-cmark

The node-budget pre-scan (`CMarkDepthScan` in `Sources/MarsDawnKit/MarkdownParsing.swift`) reads
one cmark-gfm internal, `cmark_parser.root`, and stops a document early on a lower bound whose
proof was made by reading swift-cmark 0.8.0's `blocks.c` and `extensions/table.c` (kit #150) and
re-verified for 0.9.0 (kit #179; `0.8.0...0.9.0` changes only `src/html.c` +2/-2 and leaves
`src/blocks.c` and `extensions/table.c` byte-identical). A
different swift-cmark is a different proof: `CMarkVersionPinTests` fails when `Package.resolved`
moves off 0.9.0, and at run time `CMarkInternals.isAudited` turns the early stop off for a
cmark-gfm whose version string, `cmark_parser` layout or probe counts differ. Bumping the pin
(Dependabot opens such PRs) means redoing that audit against the new sources, then updating the
pin test and `CMarkInternals.Fingerprint.audited` in the same change.

## Checking js-yaml advisories before each release

The JSON and YAML tree page (`data.html`, kit #128) runs a vendored js-yaml
(`Sources/MarsDawnKit/Resources/Preview/vendor/js-yaml.umd.min.js`; the version, tarball
integrity and digests are recorded in `LICENSE-js-yaml.txt`). Before every kit release, look the
vendored version up again in both advisory sources, and record the date and result in the
release PR:

```sh
VERSION=5.5.0   # the version in LICENSE-js-yaml.txt
curl -fsS -X POST -H 'Content-Type: application/json' \
  https://registry.npmjs.org/-/npm/v1/security/advisories/bulk -d "{\"js-yaml\":[\"$VERSION\"]}"
curl -fsS "https://api.github.com/advisories?ecosystem=npm&affects=js-yaml@$VERSION&per_page=100"
```

Both must come back empty (`{}` and `[]`). An advisory for the vendored version stops the release
until the owner decides. A newer js-yaml is a new vendoring: download the tarball, check it against
the registry's `dist.integrity`, redo the record, and re-run the direct probes
(`DataDocumentJSYAMLProbeTests`) and `VendoredJSYAMLTests`.
