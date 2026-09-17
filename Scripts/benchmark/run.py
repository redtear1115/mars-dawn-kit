#!/usr/bin/env python3
"""B1 benchmark harness: how fast `marsdawn export` is, on this machine.

Standard library only, no network access. See README.md for what every field
means, the cold/warm definitions and their limits, and how to rerun this.

Typical use:
    python3 generate_inputs.py
    python3 run.py --out-dir results

Reduced (dry) run, used to prove the harness works without tying up the
machine:
    python3 run.py --sizes 10kb,100kb --runs 3 --size-runs 1mb=1 \
        --inputs-dir /path/to/scratch/inputs --out-dir /path/to/scratch/results
"""

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1
REPO_ROOT = Path(__file__).resolve().parents[2]
BENCHMARK_DIR = Path(__file__).resolve().parent
FALLBACK_PROBE_DIR = BENCHMARK_DIR / "fallback_probe"
DEFAULT_INPUTS_DIR = BENCHMARK_DIR / "inputs"
DEFAULT_RESULTS_DIR = BENCHMARK_DIR / "results"
SIZE_ORDER = ["10kb", "100kb", "1mb", "10mb"]

# A cell's spread is flagged as possible noise when (max - min) exceeds this
# fraction of the median. 11 runs on a quiet machine typically land well
# under this; the machine here runs several Claude sessions at once, so a
# build or another session's work can blow a cell way past it.
NOISE_SPREAD_FRACTION = 0.35


# ---------------------------------------------------------------------------
# Machine info


def run_text(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return out.stdout.strip()
    except Exception as exc:  # pragma: no cover - best effort diagnostics
        return f"<error: {exc}>"


def sysctl(name):
    value = run_text(["sysctl", "-n", name])
    return value if not value.startswith("<error") else None


def macos_version():
    return {
        "product_name": run_text(["sw_vers", "-productName"]),
        "product_version": run_text(["sw_vers", "-productVersion"]),
        "build_version": run_text(["sw_vers", "-buildVersion"]),
    }


def ac_power_state():
    # First line of `pmset -g ps` is e.g. "Now drawing from 'AC Power'".
    line = run_text(["pmset", "-g", "ps"]).splitlines()[0] if run_text(["pmset", "-g", "ps"]) else ""
    if "AC Power" in line:
        return "AC"
    if "Battery Power" in line:
        return "battery"
    return "unknown"


def thermal_state():
    # macOS has no public, sudo-free CLI for ProcessInfo.thermalState. `pmset -g therm`
    # is the closest system-provided proxy without elevated privileges: when nothing
    # has been recorded, the machine has not hit a throttling threshold recently. This
    # is a proxy, not the same signal as NSProcessInfo.thermalState - see README.md.
    return run_text(["pmset", "-g", "therm"])


def load_snapshot():
    try:
        load1, load5, load15 = __import__("os").getloadavg()
    except OSError:
        load1 = load5 = load15 = None

    # Heuristic "is something heavy running" check: high instantaneous %CPU,
    # or a process name commonly seen doing heavy work on this machine
    # (other Claude sessions, Xcode/SwiftPM builds). Best-effort, not proof -
    # see README.md's honesty note on this field.
    heavy_names = ("swift-frontend", "swiftc", "swift-build", "xcodebuild", "Xcode", "clang", "ld", "cc1")
    heavy = []
    ps_out = run_text(["ps", "-Ax", "-o", "pid,pcpu,comm"])
    for line in ps_out.splitlines()[1:]:
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        pid, pcpu, comm = parts
        try:
            pcpu_f = float(pcpu)
        except ValueError:
            continue
        base = comm.rsplit("/", 1)[-1]
        if pcpu_f >= 50.0 or any(base.startswith(n) for n in heavy_names):
            heavy.append({"pid": pid, "pcpu": pcpu_f, "comm": comm})

    return {
        "load_average_1_5_15": [load1, load5, load15],
        "heavy_processes": heavy,
        "note": "Best-effort snapshot: high %CPU or a known build-tool name at the moment this ran. "
        "Absence of a hit here is not proof the machine was quiet throughout a cell's 11 runs.",
    }


def machine_static_info():
    perf_cores = sysctl("hw.perflevel0.physicalcpu")
    eff_cores = sysctl("hw.perflevel1.physicalcpu")
    return {
        "model_identifier": sysctl("hw.model"),
        "chip": sysctl("machdep.cpu.brand_string"),
        "performance_cores": int(perf_cores) if perf_cores else None,
        "efficiency_cores": int(eff_cores) if eff_cores else None,
        "total_cores": int(sysctl("hw.ncpu")) if sysctl("hw.ncpu") else None,
        "ram_bytes": int(sysctl("hw.memsize")) if sysctl("hw.memsize") else None,
        "macos": macos_version(),
    }


def machine_id(static_info):
    model = static_info.get("model_identifier") or "unknown-model"
    return re.sub(r"[^A-Za-z0-9.]+", "-", model)


def snapshot_dynamic_state():
    return {
        "ac_power": ac_power_state(),
        "thermal_state_pmset": thermal_state(),
        "load_snapshot": load_snapshot(),
    }


# ---------------------------------------------------------------------------
# Building


def swift_show_bin_path(package_dir, configuration="release"):
    out = subprocess.run(
        ["swift", "build", "--show-bin-path", "-c", configuration],
        cwd=package_dir,
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise RuntimeError(f"swift build --show-bin-path failed in {package_dir}: {out.stderr}")
    return Path(out.stdout.strip().splitlines()[-1])


def swift_build(package_dir, product, configuration="release"):
    start = time.perf_counter()
    proc = subprocess.run(
        ["swift", "build", "-c", configuration, "--product", product],
        cwd=package_dir,
        capture_output=True,
        text=True,
    )
    elapsed = time.perf_counter() - start
    if proc.returncode != 0:
        raise RuntimeError(f"swift build --product {product} failed:\n{proc.stdout}\n{proc.stderr}")
    bin_dir = swift_show_bin_path(package_dir, configuration)
    binary = bin_dir / product
    if not binary.exists():
        raise RuntimeError(f"build reported success but {binary} is missing")
    return {
        "product": product,
        "path": str(binary),
        "bytes": binary.stat().st_size,
        "build_seconds": round(elapsed, 3),
    }


def git_commit(repo_dir):
    return run_text(["git", "-C", str(repo_dir), "rev-parse", "HEAD"])


# ---------------------------------------------------------------------------
# Benchmark cells

MAX_RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size", re.MULTILINE)
FOOTPRINT_RE = re.compile(r"^\s*(\d+)\s+peak memory footprint", re.MULTILINE)


# Generous ceiling for one export. The 10 MB cell has been observed to take several
# minutes; this exists only to stop a genuinely hung process, not to bound normal runs.
EXPORT_TIMEOUT_SECONDS = 1800


def run_one_export(binary_path, input_path, output_pdf):
    cmd = [
        "/usr/bin/time", "-l",
        str(binary_path), "export", str(input_path),
        "-o", str(output_pdf),
        "--theme", "dawn", "--paper", "a4",
        "--force", "--json",
    ]
    start = time.perf_counter()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=EXPORT_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as exc:
        elapsed = time.perf_counter() - start
        return {
            "ok": False,
            "elapsed_seconds": elapsed,
            "returncode": None,
            "peak_rss_bytes": None,
            "peak_memory_footprint_bytes": None,
            "pages": None,
            "diagram_errors": None,
            "json": None,
            "parse_error": None,
            "stderr_tail": f"timed out after {EXPORT_TIMEOUT_SECONDS}s: {exc}",
        }
    elapsed = time.perf_counter() - start

    rss_match = MAX_RSS_RE.search(proc.stderr)
    footprint_match = FOOTPRINT_RE.search(proc.stderr)
    peak_rss = int(rss_match.group(1)) if rss_match else None
    peak_footprint = int(footprint_match.group(1)) if footprint_match else None

    # /usr/bin/time exits with the wrapped command's status, and its own
    # reporting goes to stderr, so stdout is exactly the CLI's --json line.
    parsed = None
    parse_error = None
    stdout_line = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
    try:
        parsed = json.loads(stdout_line) if stdout_line else None
    except json.JSONDecodeError as exc:
        parse_error = str(exc)

    ok = proc.returncode == 0 and isinstance(parsed, dict) and parsed.get("ok") is True
    return {
        "ok": ok,
        "elapsed_seconds": elapsed,
        "returncode": proc.returncode,
        "peak_rss_bytes": peak_rss,
        "peak_memory_footprint_bytes": peak_footprint,
        "pages": parsed.get("pages") if isinstance(parsed, dict) else None,
        "diagram_errors": parsed.get("diagramErrors") if isinstance(parsed, dict) else None,
        "json": parsed,
        "parse_error": parse_error,
        "stderr_tail": "\n".join(proc.stderr.strip().splitlines()[-10:]),
    }


def percentile_90(values):
    # Nearest-rank method: with n values, take the value at rank ceil(0.9*n),
    # 1-indexed. Documented here because "p90" means nothing without a
    # definition, and small-n percentiles are easy to compute two ways.
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, -(-9 * len(ordered) // 10))  # ceil(0.9 * n)
    return ordered[rank - 1]


def cell_stats(elapsed_values):
    if not elapsed_values:
        return None
    lo, hi = min(elapsed_values), max(elapsed_values)
    med = statistics.median(elapsed_values)
    spread = hi - lo
    noisy = med > 0 and (spread / med) > NOISE_SPREAD_FRACTION
    return {
        "n": len(elapsed_values),
        "median_seconds": med,
        "min_seconds": lo,
        "p90_seconds": percentile_90(elapsed_values),
        "max_seconds": hi,
        "spread_seconds": spread,
        "noisy": noisy,
    }


def run_cell(binary_path, input_path, size_name, run_count, work_dir, seen_inputs):
    runs = []
    is_first_read_this_session = input_path not in seen_inputs
    seen_inputs.add(input_path)

    for i in range(run_count):
        state = "cold" if i == 0 and is_first_read_this_session else "warm"
        output_pdf = work_dir / f"{size_name}-run{i}.pdf"
        result = run_one_export(binary_path, input_path, output_pdf)
        result["run_index"] = i
        result["state"] = state
        runs.append(result)
        if not result["ok"]:
            # Abort the cell rather than average a failure away.
            break

    failed = [r for r in runs if not r["ok"]]
    cold_runs = [r for r in runs if r["state"] == "cold"]
    warm_runs = [r for r in runs if r["state"] == "warm"]

    entry = {
        "size": size_name,
        "input_path": str(input_path),
        "input_bytes": input_path.stat().st_size if input_path.exists() else None,
        "requested_runs": run_count,
        "completed_runs": len(runs),
        "runs": runs,
        "aborted": bool(failed),
    }
    if failed:
        entry["failure"] = {
            "run_index": failed[0]["run_index"],
            "returncode": failed[0]["returncode"],
            "parse_error": failed[0]["parse_error"],
            "stderr_tail": failed[0]["stderr_tail"],
        }
        return entry

    entry["cold"] = {
        "elapsed_seconds": cold_runs[0]["elapsed_seconds"] if cold_runs else None,
        "peak_rss_bytes": cold_runs[0]["peak_rss_bytes"] if cold_runs else None,
    }
    entry["warm"] = cell_stats([r["elapsed_seconds"] for r in warm_runs])
    if entry["warm"] is not None:
        entry["warm"]["peak_rss_bytes_median"] = (
            statistics.median([r["peak_rss_bytes"] for r in warm_runs if r["peak_rss_bytes"] is not None])
            if any(r["peak_rss_bytes"] is not None for r in warm_runs)
            else None
        )
    entry["pages"] = runs[0]["pages"]
    return entry


# ---------------------------------------------------------------------------
# Failure row: the dense-Markdown fallback boundary


def build_fallback_probe():
    try:
        return swift_build(FALLBACK_PROBE_DIR, "fallback-probe"), None
    except Exception as exc:
        return None, str(exc)


def check_fallback_boundary(probe_binary, dense_input, sentinel):
    proc = subprocess.run(
        [str(probe_binary), str(dense_input)],
        capture_output=True, text=True, timeout=600,
    )
    if proc.returncode != 0:
        return {"status": "inconclusive", "detail": f"probe exited {proc.returncode}: {proc.stderr.strip()[:500]}"}

    html = proc.stdout
    escaped_marker = f"# {sentinel}"
    rendered_marker = f">{sentinel}<"

    if escaped_marker in html:
        return {
            "status": "triggered",
            "detail": "The renderer showed the sentinel heading as literal escaped source "
            "instead of an <h1> element: this build's fallback triggered on this input.",
        }
    if rendered_marker in html:
        return {
            "status": "not_present_in_build",
            "detail": "The sentinel heading rendered normally as an <h1> element. As of this kit "
            "commit, K1's dense-Markdown fallback is not merged into main, so this is expected: "
            "'not present in this build', not 'boundary not reached'.",
        }
    return {
        "status": "inconclusive",
        "detail": "Neither the rendered nor the escaped form of the sentinel heading was found "
        "in the probe's output; treat this cell as unmeasured rather than guessing.",
    }


def failure_row(inputs_dir, sentinel, manifest):
    dense_input = inputs_dir / "dense_boundary.md"
    if not dense_input.exists():
        return {"status": "skipped", "detail": f"{dense_input} not found; run generate_inputs.py first."}

    probe_build, build_error = build_fallback_probe()
    if build_error:
        return {"status": "skipped", "detail": f"fallback-probe failed to build: {build_error}"}

    boundary = check_fallback_boundary(Path(probe_build["path"]), dense_input, sentinel)
    boundary["probe_build"] = probe_build
    boundary["input_path"] = str(dense_input)
    boundary["input_bytes"] = dense_input.stat().st_size
    return boundary


# ---------------------------------------------------------------------------
# Orchestration


def load_manifest(inputs_dir):
    manifest_path = inputs_dir / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"{manifest_path} not found; run generate_inputs.py first.")
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def verify_inputs(inputs_dir, manifest, size_names):
    import hashlib

    for size in size_names:
        filename = f"{size}.md"
        info = manifest["files"].get(filename)
        if info is None:
            raise ValueError(f"manifest.json has no entry for {filename}")
        path = inputs_dir / filename
        if not path.exists():
            raise FileNotFoundError(f"{path} not found; run generate_inputs.py first.")
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != info["sha256"]:
            raise ValueError(
                f"{path} does not match manifest.json (sha256 {digest} != {info['sha256']}); "
                "regenerate inputs before trusting these numbers."
            )


def parse_size_runs(pairs):
    overrides = {}
    for pair in pairs or []:
        if "=" not in pair:
            raise argparse.ArgumentTypeError(f"expected SIZE=COUNT, got {pair!r}")
        size, count = pair.split("=", 1)
        overrides[size.strip()] = int(count)
    return overrides


def write_markdown_summary(results):
    m = results["machine"]
    lines = [
        f"# B1 benchmark result{' (DRY RUN)' if results['config']['dry_run'] else ''}",
        "",
        f"Generated: {results['generated_at']}",
        f"Kit commit: `{results['kit_commit']}`",
        f"Machine: {m['model_identifier']} / {m['chip']} "
        f"({m['performance_cores']}P+{m['efficiency_cores']}E) / "
        f"{round((m['ram_bytes'] or 0) / (1024**3))} GB RAM / "
        f"macOS {m['macos']['product_version']} ({m['macos']['build_version']})",
        f"AC power at start: {results['dynamic_state']['start']['ac_power']}, "
        f"at end: {results['dynamic_state']['end']['ac_power']}",
        "",
        "This is one machine, once. See README.md before treating these numbers as a guarantee.",
        "",
        "## Export cells",
        "",
        "| size | state | n | median (s) | min (s) | p90 (s) | spread (s) | noisy? |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for cell in results["cells"]:
        size = cell["size"]
        if cell.get("aborted"):
            lines.append(f"| {size} | - | - | - | - | - | - | **FAILED**: {cell['failure']['stderr_tail'][:80]} |")
            continue
        cold = cell["cold"]
        lines.append(
            f"| {size} | cold | 1 | {cold['elapsed_seconds']:.3f} | - | - | - | - |"
        )
        warm = cell["warm"]
        if warm:
            lines.append(
                f"| {size} | warm | {warm['n']} | {warm['median_seconds']:.3f} | "
                f"{warm['min_seconds']:.3f} | {warm['p90_seconds']:.3f} | "
                f"{warm['spread_seconds']:.3f} | {'YES - rerun' if warm['noisy'] else 'no'} |"
            )
    lines += [
        "",
        "## Failure row: dense-Markdown fallback boundary",
        "",
        f"Status: **{results['failure_row']['status']}**",
        "",
        results["failure_row"]["detail"],
        "",
        "## App and Quick Look",
        "",
        "Not yet measured. These need os_signpost intervals from B1-app "
        "(template load -> first didFinish -> first content push -> first rendered paint, "
        "and preparePreviewOfFile -> rendered in the Quick Look extension). "
        "Never estimated here.",
        "",
        "## Binary",
        "",
        f"`{results['binary']['product']}`: {results['binary']['bytes']} bytes, "
        f"built in {results['binary']['build_seconds']}s.",
    ]
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--inputs-dir", type=Path, default=DEFAULT_INPUTS_DIR)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_RESULTS_DIR)
    parser.add_argument(
        "--sizes", type=lambda s: s.split(","), default=SIZE_ORDER,
        help="Comma-separated subset of 10kb,100kb,1mb,10mb (default: all four).",
    )
    parser.add_argument("--runs", type=int, default=11, help="Runs per cell (default: 11).")
    parser.add_argument(
        "--size-runs", action="append", default=[],
        help="Override the run count for one size, e.g. --size-runs 1mb=1. Repeatable.",
    )
    parser.add_argument(
        "--skip-fallback-check", action="store_true",
        help="Skip building/running the fallback-probe helper.",
    )
    parser.add_argument("--label", default=None, help="Note to embed in the result (e.g. 'dry run').")
    args = parser.parse_args(argv)

    size_runs = parse_size_runs(args.size_runs)
    for size in args.sizes:
        if size not in SIZE_ORDER:
            parser.error(f"unknown size {size!r}; choose from {SIZE_ORDER}")

    inputs_dir = args.inputs_dir.resolve()
    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest = load_manifest(inputs_dir)
    verify_inputs(inputs_dir, manifest, args.sizes)

    static_info = machine_static_info()
    m_id = machine_id(static_info)
    dynamic_start = snapshot_dynamic_state()

    print("Building marsdawn (release)...")
    binary = swift_build(REPO_ROOT, "marsdawn")
    print(f"  {binary['path']} ({binary['bytes']} bytes, {binary['build_seconds']}s)")

    work_dir = out_dir / "_scratch_pdfs"
    work_dir.mkdir(parents=True, exist_ok=True)

    seen_inputs = set()
    cells = []
    for size in args.sizes:
        run_count = size_runs.get(size, args.runs)
        input_path = inputs_dir / f"{size}.md"
        print(f"Benchmarking {size} ({run_count} runs)...")
        cell = run_cell(binary["path"], input_path, size, run_count, work_dir, seen_inputs)
        cells.append(cell)
        if cell.get("aborted"):
            print(f"  ABORTED: {cell['failure']}")
        elif cell["warm"]:
            print(f"  cold {cell['cold']['elapsed_seconds']:.3f}s, warm median {cell['warm']['median_seconds']:.3f}s")
        else:
            print(f"  cold {cell['cold']['elapsed_seconds']:.3f}s, no warm runs requested")

    if args.skip_fallback_check:
        f_row = {"status": "skipped", "detail": "--skip-fallback-check was passed."}
    else:
        print("Checking dense-Markdown fallback boundary...")
        f_row = failure_row(inputs_dir, "MARSDAWN_BENCH_FALLBACK_SENTINEL", manifest)
        print(f"  {f_row['status']}: {f_row['detail']}")

    dynamic_end = snapshot_dynamic_state()

    results = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "label": args.label,
        "kit_commit": git_commit(REPO_ROOT),
        "machine": static_info,
        "machine_id": m_id,
        "dynamic_state": {"start": dynamic_start, "end": dynamic_end},
        "binary": binary,
        "config": {
            "sizes": args.sizes,
            "runs_default": args.runs,
            "size_runs_override": size_runs,
            "dry_run": bool(args.label and "dry" in args.label.lower()),
            "noise_spread_fraction": NOISE_SPREAD_FRACTION,
        },
        "cells": cells,
        "failure_row": f_row,
        "manifest": manifest,
        "notes": [
            "Cold = the first run of this session's freshly built binary against an input not yet "
            "read this session. Warm = every later run. This is NOT a purged page cache; purging "
            "needs sudo and is not done here. See README.md.",
            "App and Quick Look numbers are not measured by this harness. Never estimated.",
        ],
    }

    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    json_path = out_dir / f"{date_str}-{m_id}.json"
    md_path = out_dir / f"{date_str}-{m_id}.md"
    json_path.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    md_path.write_text(write_markdown_summary(results), encoding="utf-8")

    print(f"\nWrote {json_path}")
    print(f"Wrote {md_path}")
    return 1 if any(c.get("aborted") for c in cells) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
