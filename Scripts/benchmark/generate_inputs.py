#!/usr/bin/env python3
"""Generate deterministic Markdown fixtures for the B1 benchmark harness.

Standard library only. Every document is built from a fixed word bank and a
fixed per-size seed, so running this script twice - on this machine, on a
different machine, next year - produces byte-identical files. That is what
lets `run.py`'s results say "this was the input" and have it mean something.

Usage:
    python3 generate_inputs.py [--out-dir DIR]

Writes, under --out-dir (default: ./inputs next to this script):
    10kb.md, 100kb.md, 1mb.md, 10mb.md   - the benchmark's size ladder
    dense_boundary.md                     - a ~2.4 MB fixture for the failure
                                             row (see README.md's "Failure row")
    manifest.json                         - byte size + sha256 of every file,
                                             plus the generation parameters
"""

import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

SCHEMA_VERSION = 1

# A fixed, boring word bank. Deterministic content, not meant to read as prose.
WORDS = [
    "system", "document", "render", "layout", "export", "preview", "theme",
    "signature", "workflow", "template", "engine", "pipeline", "cloud",
    "signpost", "benchmark", "release", "binary", "process", "memory",
    "table", "diagram", "heading", "paragraph", "list", "code", "block",
    "server", "client", "agent", "session", "commit", "branch", "package",
    "target", "module", "cache", "thread", "queue", "buffer", "stream",
    "vector", "matrix", "index", "cursor", "handle", "token", "parser",
    "visitor", "schema", "manifest", "fixture", "input", "output", "result",
    "median", "sample", "cell", "state", "cold", "warm", "peak", "floor",
    "ceiling", "margin", "paper", "page", "font", "glyph", "style", "color",
    "border", "spacing", "region", "anchor", "route", "path", "config",
]

# Fixed generation seeds. Never derived from the clock or from randomness:
# changing these would change the fixtures, so they are pinned here, once.
SEEDS = {
    "10kb": 110_001,
    "100kb": 110_002,
    "1mb": 110_003,
    "10mb": 110_004,
    "dense_boundary": 110_099,
}

# Target byte sizes for the size ladder. "roughly" - the generator stops once
# it has reached the target and finished placing every scheduled diagram, so
# actual sizes land a little over these numbers (recorded exactly in the
# manifest; nothing about the harness assumes they land exactly on target).
TARGET_BYTES = {
    "10kb": 10 * 1024,
    "100kb": 100 * 1024,
    "1mb": 1 * 1024 * 1024,
    "10mb": 10 * 1024 * 1024,
    # K1 (not yet merged into kit main) introduces a 500k-node fallback at
    # roughly 2.4 MB of dense Markdown. This fixture sits right at that
    # boundary so run.py's failure-row check has something to probe.
    "dense_boundary": int(2.4 * 1024 * 1024),
}

# How many Mermaid diagrams each document gets. A fixed count per size, not
# scaled by byte count - Mermaid blocks are heavy relative to plain text, and
# the point is a realistic document, not a proportional one.
MERMAID_COUNTS = {
    "10kb": 1,
    "100kb": 2,
    "1mb": 4,
    "10mb": 8,
    "dense_boundary": 2,
}

# The fixed mix, repeated as a cycle until the target size is reached. Every
# size ladder document uses the same cycle - "fixed mix per size" means the
# ratio of block kinds is constant; only the number of cycles differs.
CYCLE = ["heading", "paragraph", "paragraph", "list", "paragraph", "table", "code", "paragraph"]

# A sentinel heading only Scripts/benchmark/fallback_probe looks for. Fixed
# text, not randomized, so its presence or absence in rendered output is a
# stable signal across runs.
FALLBACK_SENTINEL = "MARSDAWN_BENCH_FALLBACK_SENTINEL"


def phrase(rng, count):
    return " ".join(rng.choice(WORDS) for _ in range(count))


def sentence(rng):
    words = [rng.choice(WORDS) for _ in range(rng.randint(6, 14))]
    words[0] = words[0].capitalize()
    return " ".join(words) + "."


def make_heading(rng, index):
    level = 1 + (index % 3)  # cycle through H1-H3
    return "#" * level + " " + phrase(rng, rng.randint(2, 4)).title()


def make_paragraph(rng):
    return " ".join(sentence(rng) for _ in range(rng.randint(3, 6)))


def make_list(rng, index):
    items = rng.randint(3, 7)
    ordered = index % 2 == 1
    lines = []
    for i in range(items):
        marker = f"{i + 1}." if ordered else "-"
        lines.append(f"{marker} {phrase(rng, rng.randint(3, 8))}")
    return "\n".join(lines)


def make_table(rng):
    cols = 3
    rows = rng.randint(3, 5)
    header = "| " + " | ".join(f"Column {c + 1}" for c in range(cols)) + " |"
    sep = "|" + "|".join(["---"] * cols) + "|"
    body = []
    for _ in range(rows):
        body.append("| " + " | ".join(phrase(rng, 2) for _ in range(cols)) + " |")
    return "\n".join([header, sep] + body)


CODE_LANGS = ["swift", "python"]


def make_code(rng, index):
    lang = CODE_LANGS[index % len(CODE_LANGS)]
    lines = []
    for i in range(rng.randint(5, 10)):
        lines.append(f"let {rng.choice(WORDS)}_{i} = \"{phrase(rng, 2)}\"")
    return "```" + lang + "\n" + "\n".join(lines) + "\n```"


def make_mermaid(rng, index):
    nodes = [f"{chr(65 + i)}[{phrase(rng, 2)}]" for i in range(rng.randint(4, 6))]
    edges = []
    for i in range(len(nodes) - 1):
        edges.append(f"  {chr(65 + i)} --> {chr(65 + i + 1)}")
    return "```mermaid\nflowchart TD\n" + "\n".join(edges) + "\n```"


def make_block(kind, rng, index):
    if kind == "heading":
        return make_heading(rng, index)
    if kind == "paragraph":
        return make_paragraph(rng)
    if kind == "list":
        return make_list(rng, index)
    if kind == "table":
        return make_table(rng)
    if kind == "code":
        return make_code(rng, index)
    raise ValueError(f"unknown block kind: {kind}")


def generate_document(seed, target_bytes, mermaid_count, sentinel_heading=None):
    """Deterministically build one document of roughly `target_bytes` bytes.

    Same seed + same target + same mermaid_count always yields the same
    bytes: every source of variation (word choice, list length, ...) comes
    from `rng`, seeded once here, and nothing else feeds the output.
    """
    rng = random.Random(seed)
    parts = []
    if sentinel_heading:
        parts.append("# " + sentinel_heading)

    diagram_targets = [target_bytes * (i + 1) / (mermaid_count + 1) for i in range(mermaid_count)]
    next_diagram = 0
    size = sum(len(p) for p in parts)
    index = 0
    max_cycles = 2_000_000  # safety valve; never reached in practice

    while (size < target_bytes or next_diagram < mermaid_count) and index < max_cycles:
        kind = CYCLE[index % len(CYCLE)]
        block = make_block(kind, rng, index)
        parts.append(block)
        size += len(block)
        index += 1

        while next_diagram < mermaid_count and size >= diagram_targets[next_diagram]:
            diagram = make_mermaid(rng, next_diagram)
            parts.append(diagram)
            size += len(diagram)
            next_diagram += 1

    if index >= max_cycles:
        raise RuntimeError("generator did not converge; check target_bytes/mermaid_count")

    return "\n\n".join(parts) + "\n"


def sha256_of(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_document(out_dir, name, text):
    path = out_dir / f"{name}.md"
    data = text.encode("utf-8")
    path.write_bytes(data)
    return path, len(data), hashlib.sha256(data).hexdigest()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "inputs",
        help="Directory to write fixtures and manifest.json into (default: ./inputs next to this script).",
    )
    args = parser.parse_args(argv)

    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "generator": "generate_inputs.py",
        "note": "Deterministic: rerunning this script with the same code reproduces every file byte for byte.",
        "files": {},
    }

    for name, target in TARGET_BYTES.items():
        sentinel = FALLBACK_SENTINEL if name == "dense_boundary" else None
        text = generate_document(SEEDS[name], target, MERMAID_COUNTS[name], sentinel_heading=sentinel)
        path, byte_size, digest = write_document(out_dir, name, text)
        manifest["files"][path.name] = {
            "target_bytes": target,
            "bytes": byte_size,
            "sha256": digest,
            "seed": SEEDS[name],
            "mermaid_count": MERMAID_COUNTS[name],
            "sentinel_heading": sentinel,
        }
        print(f"{path.name}: {byte_size} bytes (target {target}), sha256 {digest[:12]}...")

    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
