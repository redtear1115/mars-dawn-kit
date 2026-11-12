# HTML golden corpus

A language-neutral set of Markdown inputs and the exact HTML fragment the MarsDawn renderer
produces for each one (kit #261). It exists so that a renderer written in another language (for
example, for an Android port) can be checked against the same expectations as the Swift one.

Everything here is plain files. Nothing in this directory depends on Swift, Xcode or macOS.

## Files

A fixture is a **name** and two or three files with that name:

| File | Required | Content |
|---|---|---|
| `<name>.md` | yes | The Markdown input. |
| `<name>.html` | yes | The expected output: the HTML fragment, exactly as rendered. |
| `<name>.options.json` | no | Renderer options this fixture needs (see [Options](#options)). Without it, every option has its default. |

- A **name** is lowercase ASCII letters, digits and `-`, and starts with a letter
  (`headings-toc`, `cjk-hard-breaks`).
- The part of the name before its first `-` is the fixture's **category** (`headings`, `lists`,
  `safety`, ...). The Swift suite lists the categories that must each have at least one fixture.
- `README.md` (this file) and `.gitattributes` are not fixtures. Any other file in the directory
  must belong to a fixture: an `.html` or `.options.json` without its `.md`, or an `.md` without
  its `.html`, is an error.
- The directory must not be empty.

## Encoding and line endings

- Every file is **UTF-8**, without a byte order mark.
- The inputs use **LF** (`\n`) line endings. A fixture may use CR LF or CR on purpose to test
  them; it is then the input, byte for byte. The `.gitattributes` here turns off Git's line-ending
  conversion so that no checkout changes a byte.
- The `.md` file is passed to the renderer **unchanged**: no trimming, no newline added or removed,
  no Unicode normalisation. Trailing spaces in an input are significant (two trailing spaces make
  a hard line break) and so are tabs and U+3000 IDEOGRAPHIC SPACE.
- The `.html` file is the renderer's output **unchanged**: nothing is added after it, not even a
  final newline. (Most outputs happen to end with `\n` because the last block element does.)

## What "byte for byte" means

Render the `.md` with the options below, encode the result as UTF-8, and compare that byte
sequence to the bytes of the `.html` file. They must be identical: same tags, same attribute
order, same quoting (`"`), same entity spellings (`&amp;`, `&lt;`, `&gt;`, `&quot;`), same
whitespace and newlines, same non-ASCII characters (written as UTF-8, not as entities). There is
no HTML normalisation, no DOM comparison and no whitespace folding.

A renderer must also give the same bytes every time: the Swift suite renders each fixture twice in
one process and requires the two results to be identical. Nothing in the output may depend on the
time, a random value, the order of a hash map, or the machine's language or locale (see
[Stability](#stability)).

## Options

`<name>.options.json` is a JSON object. Each key is optional; a missing key has its default. A key
not listed here is an error, and so is a value of the wrong JSON type.

| Key | JSON type | Default | Meaning |
|---|---|---|---|
| `softBreaksAsLineBreaks` | boolean | `false` | When `true`, every soft line break inside a paragraph is written as `<br>` followed by a newline (HackMD / GitHub-comment style). When `false`, a soft break is written as a newline (CommonMark), except between two CJK characters, where it is written as nothing at all (see the `cjk-` fixtures). |
| `frontMatterLabel` | string | `"Document info"` | The text of the `<summary>` of the front-matter block. Written HTML-escaped. |
| `footnoteBackLabel` | string | `"Back to reference"` | The start of each footnote back link's `aria-label`; the footnote number is appended after one space. Written attribute-escaped. |

Other inputs every fixture is rendered with, which no options file can change:

- Image sources are written as the document gives them (no URL rewriting), after the URL safety
  rules.
- The input-size limit is 16 MiB (16,777,216 bytes) and the node limit is 500,000; no fixture
  comes near either.

## Stability

The goldens must not change with the test machine. In particular:

- **Language and locale.** The renderer's output contains no localised text. Default callout
  titles are left empty (`<p class="callout-title"></p>`) and supplied by the page's style sheet;
  the two labels above are fixed English strings unless an options file sets them. The Swift suite
  re-renders every fixture with the process's preferred language set to Japanese, Traditional
  Chinese and German and requires the same bytes.
- **Heading ids** come from the heading's text alone, counted per document, never from earlier
  renders. The text is lowercased with Unicode's default (locale-independent) case mapping, so
  there is no Turkish dotless-i rule; then each character (grapheme cluster) that is a letter, a
  number, `-` or `_` is kept, a space becomes `-`, and everything else is dropped. A heading whose
  id is empty gets `section`. A repeated id gets `-1`, `-2`, ..., skipping any id another heading
  in the document already has (see `headings-basic`: `same`, `same-2`, `same-1`).
- **Placeholders.** Math and footnotes are internally swapped for placeholders carrying a random
  value while rendering; that value never reaches the output. A golden that contains U+E000 to
  U+E003 or a 16-digit hex run you did not write would be a bug.

## Notable behaviour a re-implementation must match

The goldens are the specification; these notes only point at things that are easy to miss.

- Every block element carries `data-line="N"`, the 1-based line in the `.md` file where it starts
  (front matter counts).
- Smart punctuation is on: `"` and `'` in prose become curly quotes, `--` and `---` dashes, `...`
  an ellipsis. Code, URLs and raw HTML are untouched.
- A Japanese document (by front matter `lang:` or by kana share) starts with the marker element
  `<md-content-lang data-lang="…"></md-content-lang>`.
- Raw HTML is passed through, except that the tags `link`, `iframe`, `frame`, `object`, `embed`,
  `portal` and `fencedframe` are renamed with an `x-md-` prefix. Scripts, event-handler attributes
  and `<style>` in raw HTML are **not** removed by the renderer: the page that shows the fragment
  removes them and blocks them with its content security policy. A host on another platform must
  do the same.
- Link `href`s keep only `http`, `https`, `mailto` and relative URLs; anything else becomes `#`.
  Image `src`s also allow `data:image/…` except SVG.

## Updating the goldens

The goldens are produced by the current Swift renderer. After an intended renderer change:

```sh
MARSDAWN_UPDATE_HTML_GOLDENS=1 swift test --no-parallel --filter HTMLGolden
```

That run rewrites every `<name>.html` from the renderer (and creates missing ones), and then
**fails** every fixture with "updated, not compared", so an update can never pass as a check. Run
again without the variable to compare, and read the diff of the `.html` files before committing:
each changed line should be explained by the change you made. A run without the variable never
writes anything.

To add a fixture, create `<name>.md` (and `<name>.options.json` if needed), run the update command,
and review the new `<name>.html` against what the Markdown should produce.
