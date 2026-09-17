# B1 benchmark harness

Measures how fast `marsdawn export` renders Markdown to PDF, on this machine, so an
agent choosing between MarsDawn and a self-assembled pipeline has a real number instead
of a guess. Standard library Python only. No network access at any step.

This harness produces measurements, not marketing copy. A result file is not published
until someone reads it and decides it is worth publishing; running this script does not
by itself put a number anywhere public.

## What it measures

- `Scripts/benchmark/generate_inputs.py` writes five Markdown fixtures: a 10 KB, 100 KB,
  1 MB and 10 MB size ladder, plus a `dense_boundary.md` sized at roughly 2.4 MB for the
  failure row below. Every fixture comes from one generator, seeded and deterministic:
  running the script again, on any machine, reproduces every file **byte for byte**, and
  `inputs/manifest.json` records each file's exact size and sha256 so that claim is
  checkable, not just asserted.
- `Scripts/benchmark/run.py`:
  1. Builds `marsdawn` in release (`swift build -c release --product marsdawn`) and
     records the binary's path, size, build time and the kit commit it was built from.
  2. Runs `marsdawn export` once per size per requested run count (11 by default), each
     in a fresh process, with `--json` so a failed render can be told apart from a fast
     one — a non-zero exit code, or JSON without `"ok": true`, is a failure, never a time.
  3. Wraps every run in `/usr/bin/time -l` and records its "maximum resident set size"
     as peak RSS, plus "peak memory footprint" as a second, macOS-specific number.
  4. Records the machine (model identifier, chip, core counts, RAM, macOS build), AC
     power and a thermal-state proxy at the start and end of the run, and a load
     snapshot (load average plus a best-effort scan for heavy processes) so a number
     measured during a parallel build can be spotted instead of trusted.
  5. Reports median, min, p90, run count and spread per cell, and flags any cell whose
     spread is wide enough to look like noise.
  6. Aborts a cell on the first failed run rather than averaging a failure away.
  7. Checks the dense-Markdown fallback boundary (see below) and records it cleanly,
     including when the fallback isn't in this build at all.
  8. Writes `results/<iso-date>-<machine-id>.json` (the full, versioned record) and a
     `.md` summary next to it. **Nothing under `results/` is committed** — see
     "Results are not committed" below.
- `Scripts/benchmark/fallback_probe/` is a small standalone SwiftPM package (its own
  `Package.swift`, depending on the kit checkout by path) used only by `run.py`'s
  failure-row check. It is not part of the shipping package graph.

## Cold vs. warm, and their honest limits

- **Cold**: the first run of a freshly built binary against an input this `run.py`
  session has not yet read.
- **Warm**: every later run of that same input in the same session.

This is a real difference in what the OS and the process have already done, but it is
**not** a purged page cache. Purging the page cache needs `sudo` (`purge`, or dropping
caches at a lower level) and this harness does not do it, on this machine or any other,
because that requires privileges this harness should not ask for by default. So "cold"
here means "first read this session," not "as if the machine had just booted." Anyone
who needs the stricter number should run `sudo purge` themselves before invoking
`run.py`, and say so next to the result.

Similarly, the thermal-state field comes from `pmset -g therm`, which is the only
sudo-free thermal signal the command line exposes; it is a proxy for
`NSProcessInfo.thermalState`, not the same signal, and it only ever says "nothing has
been recorded" or names a recorded warning level — it does not give a live reading.

The load snapshot's "heavy processes" list is a best-effort instantaneous `ps` scan
(high %CPU, or a process name commonly seen doing build work on this machine). Its
absence is not proof the machine was quiet for an entire 11-run cell — only that nothing
was caught in that specific snapshot.

## Failure row: the dense-Markdown fallback boundary

K1 (not yet merged into kit `main` as of this harness) introduces a 500k-node fallback:
past that boundary, roughly 2.4 MB of dense Markdown, the renderer shows escaped source
text instead of rendering the document. An agent choosing MarsDawn for a large document
needs to know that boundary exists.

`run.py` detects this **behaviorally**, not by guessing from the exported PDF (whose
text is not reliably extractable without a PDF library, which this harness does not
depend on). `fallback_probe` calls `MarkdownRenderer.render(_:)` directly — the exact
function `MarsDawnExport` calls before laying a page out — on `dense_boundary.md`, which
carries a fixed sentinel heading (`# MARSDAWN_BENCH_FALLBACK_SENTINEL`). The check then
looks at the HTML that comes back:

- If the sentinel appears as a real `<h1>` element, the fallback did not trigger. If
  this kit commit has no fallback code at all (true as of this harness's introduction,
  since K1 hasn't merged), `run.py` reports this as **"not present in this build"** —
  a distinct, honest claim from "boundary not reached."
- If the sentinel appears as literal, un-rendered text (`# MARSDAWN_BENCH_FALLBACK_SENTINEL`),
  the fallback triggered on this input, and the harness reports **"triggered."**
- If neither form is found — an unexpected renderer change, a probe build failure, or a
  truncated read — the harness reports **"inconclusive"** rather than guessing.

## What this harness does not measure

- **The app and Quick Look are not yet measured.** They need `os_signpost` intervals
  from another workstream (B1-app): template load → first `didFinish` → first content
  push → first rendered paint in the app, and `preparePreviewOfFile` → rendered in the
  Quick Look extension. Until those signposts land, any app or Quick Look number here
  would be a guess. This harness never estimates them; it reports them as "not yet
  measured" and stops there.
- Anything about a competitor's tool. This harness measures MarsDawn's own numbers only.

## Rerunning

```sh
cd Scripts/benchmark
python3 generate_inputs.py                 # writes inputs/*.md + inputs/manifest.json
python3 run.py                              # full run: 11 runs x 4 sizes, writes results/
```

Useful flags on `run.py`:

- `--sizes 10kb,100kb` — restrict to a subset of the size ladder.
- `--runs N` — change the default run count per cell (11).
- `--size-runs 1mb=1` — override the run count for one size; repeatable.
- `--inputs-dir DIR` / `--out-dir DIR` — point at fixtures and results elsewhere, e.g. a
  scratch directory for a dry run that should not touch this repository.
- `--skip-fallback-check` — skip building/running `fallback_probe`.
- `--label TEXT` — a free-text note embedded in the result (e.g. `"dry run"`).

`run.py` verifies every input it is about to use against `manifest.json`'s sha256
before running anything, so a stale or hand-edited fixture is caught immediately instead
of silently producing a number for the wrong input.

## Results are not committed

This harness writes results wherever `--out-dir` points (default: `results/`, which is
git-ignored — see `.gitignore` in this directory). No results file from this repository
is committed as part of building the harness itself. When real measurements are taken on
a quiet machine, per the B1 plan, that is a separate, later step with its own commit —
this harness only makes that step possible.

## One machine, once

Every number this harness produces comes from one machine, at one moment, possibly
alongside other work on that same machine. It is not a guarantee about any other
machine, and it is not a guarantee that a rerun on the same machine will land on the
same number — that is exactly why `run.py` reports spread and flags noisy cells instead
of a single number per cell.
