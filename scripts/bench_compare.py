#!/usr/bin/env python3
"""Zero-dependency head-to-head benchmark runner with mandatory SHA-256 verification.

Usage example:
    python3 scripts/bench_compare.py \\
        --title "JSON Parse (canada.json)" \\
        --impl pion="./bench_pion data.json" \\
        --impl rust="./bench_rust data.json" \\
        --warmup 1 --rounds 5 --bytes 2251051 \\
        --md-out bench.md --json-out bench.json
"""

import argparse
import difflib
import hashlib
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple


MACOS_RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size\s*$", re.MULTILINE)
LINUX_RSS_RE = re.compile(
    r"^\s*Maximum resident set size \(kbytes\):\s*(\d+)\s*$", re.MULTILINE
)


def parse_impl(spec: str) -> Tuple[str, str]:
    if "=" not in spec:
        raise argparse.ArgumentTypeError(
            "expected --impl NAME=COMMAND (missing '=')"
        )
    name, cmd = spec.split("=", 1)
    name = name.strip()
    cmd = cmd.strip()
    if not name:
        raise argparse.ArgumentTypeError("--impl name must not be empty")
    if not cmd:
        raise argparse.ArgumentTypeError("--impl command must not be empty")
    return name, cmd


def parse_rss_bytes(stderr_text: str, system: str) -> Optional[int]:
    if system == "Darwin":
        m = MACOS_RSS_RE.search(stderr_text)
        if m:
            return int(m.group(1))
    else:
        m = LINUX_RSS_RE.search(stderr_text)
        if m:
            return int(m.group(1)) * 1024
    return None


def build_timed_argv(cmd: str, system: str) -> Tuple[List[str], bool]:
    time_bin = "/usr/bin/time"
    if os.path.isfile(time_bin) and os.access(time_bin, os.X_OK):
        if system == "Darwin":
            return [time_bin, "-l", "/bin/sh", "-c", cmd], True
        if system == "Linux":
            return [time_bin, "-v", "/bin/sh", "-c", cmd], True
    return ["/bin/sh", "-c", cmd], False


def run_once(cmd: str, system: str) -> Tuple[float, bytes, Optional[int], int, str]:
    argv, has_time = build_timed_argv(cmd, system)
    t0 = time.perf_counter()
    proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    elapsed_s = time.perf_counter() - t0
    stderr_text = proc.stderr.decode("utf-8", errors="replace")
    rss_bytes = parse_rss_bytes(stderr_text, system) if has_time else None
    return elapsed_s, proc.stdout, rss_bytes, proc.returncode, stderr_text


def summarize_diff(
    ref_name: str, ref_bytes: bytes, cur_name: str, cur_bytes: bytes
) -> str:
    lines: List[str] = []
    lines.append(
        "  len({}): {} bytes vs len({}): {} bytes".format(
            ref_name, len(ref_bytes), cur_name, len(cur_bytes)
        )
    )
    min_len = min(len(ref_bytes), len(cur_bytes))
    first_diff = None
    for i in range(min_len):
        if ref_bytes[i] != cur_bytes[i]:
            first_diff = i
            break
    if first_diff is None and len(ref_bytes) != len(cur_bytes):
        first_diff = min_len

    if first_diff is not None:
        start = max(0, first_diff - 16)
        end = first_diff + 32
        lines.append("  first differing byte offset: {}".format(first_diff))
        lines.append("  {}[{}..{}]: {!r}".format(ref_name, start, end, ref_bytes[start:end]))
        lines.append("  {}[{}..{}]: {!r}".format(cur_name, start, end, cur_bytes[start:end]))

    try:
        ref_text = ref_bytes.decode("utf-8")
        cur_text = cur_bytes.decode("utf-8")
        diff_lines = list(
            difflib.unified_diff(
                ref_text.splitlines(),
                cur_text.splitlines(),
                fromfile=ref_name,
                tofile=cur_name,
                n=2,
                lineterm="",
            )
        )
        if diff_lines:
            lines.append("  unified diff (first 20 lines):")
            for dl in diff_lines[:20]:
                lines.append("    " + dl)
            if len(diff_lines) > 20:
                lines.append("    ... ({} more lines)".format(len(diff_lines) - 20))
    except UnicodeDecodeError:
        pass
    return "\n".join(lines)


def percentile(sorted_vals: List[float], p: float) -> float:
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def fmt_rss(rss_bytes: Optional[int]) -> str:
    if rss_bytes is None:
        return "N/A"
    if rss_bytes >= 1024 * 1024:
        return "{:.2f} MiB".format(rss_bytes / (1024.0 * 1024.0))
    return "{:.1f} KiB".format(rss_bytes / 1024.0)


def render_markdown(report: Dict[str, Any]) -> str:
    title = report["title"]
    sha = report["sha256"]
    out_bytes = report["stdout_bytes"]
    warmup = report["warmup"]
    rounds = report["rounds"]
    baseline_name = report["baseline"]
    has_bytes = report.get("input_bytes") is not None
    has_ops = report.get("ops") is not None

    lines: List[str] = []
    lines.append("## {}".format(title))
    lines.append("")
    meta_parts = [
        "Platform: `{} {}`".format(report["platform"]["system"], report["platform"]["machine"]),
        "Warmup: `{}`".format(warmup),
        "Rounds: `{}` (strictly interleaved)".format(rounds),
        "Stdout: `{} B` (`sha256:{}...`)".format(out_bytes, sha[:16]),
    ]
    if has_bytes:
        meta_parts.append("Input: `{} B`".format(report["input_bytes"]))
    if has_ops:
        meta_parts.append("Ops: `{}`".format(report["ops"]))
    lines.append(" | ".join(meta_parts))
    lines.append("")

    headers = ["Implementation", "Median (ms)", "Min (ms)", "P95 (ms)"]
    aligns = ["---", "---:", "---:", "---:"]
    if has_bytes:
        headers.append("Throughput (MB/s)")
        aligns.append("---:")
    if has_ops:
        headers.append("ns/op")
        aligns.append("---:")
    headers.extend(["Peak RSS", "Speedup (vs {})".format(baseline_name)])
    aligns.extend(["---:", "---:"])

    lines.append("| " + " | ".join(headers) + " |")
    lines.append("| " + " | ".join(aligns) + " |")

    for item in report["results"]:
        row = [
            "`{}`".format(item["name"]),
            "{:.3f}".format(item["median_ms"]),
            "{:.3f}".format(item["min_ms"]),
            "{:.3f}".format(item["p95_ms"]),
        ]
        if has_bytes:
            mb_s = item.get("throughput_mb_s")
            row.append("{:.2f}".format(mb_s) if mb_s is not None else "N/A")
        if has_ops:
            ns_op = item.get("ns_per_op")
            row.append("{:.2f}".format(ns_op) if ns_op is not None else "N/A")
        row.append(fmt_rss(item.get("peak_rss_bytes")))
        if item["name"] == baseline_name:
            row.append("1.00x (baseline)")
        else:
            row.append("{:.2f}x".format(item["speedup_vs_baseline"]))
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")
    lines.append(
        "_SHA-256 verified identical across all implementations and rounds: `{}`._".format(sha)
    )
    return "\n".join(lines) + "\n"


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Head-to-head cross-language benchmark runner with mandatory SHA-256 verification."
    )
    parser.add_argument(
        "--impl",
        action="append",
        required=True,
        type=parse_impl,
        metavar="NAME=CMD",
        help="Implementation to benchmark (repeatable, e.g. --impl pion='./a' --impl rust='./b').",
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=1,
        help="Warmup iterations per implementation (default: 1).",
    )
    parser.add_argument(
        "--rounds",
        type=int,
        default=5,
        help="Measured interleaved rounds per implementation (default: 5).",
    )
    parser.add_argument(
        "--bytes",
        dest="input_bytes",
        type=int,
        default=None,
        help="Input size in bytes for MB/s throughput calculation.",
    )
    parser.add_argument(
        "--ops",
        type=int,
        default=None,
        help="Operation count per run for ns/op calculation.",
    )
    parser.add_argument(
        "--expect-sha256",
        type=str,
        default=None,
        help="Expected lowercase/uppercase hex SHA-256 of stdout.",
    )
    parser.add_argument(
        "--baseline",
        type=str,
        default=None,
        help="Implementation name used as 1.00x baseline (default: first --impl).",
    )
    parser.add_argument(
        "--title",
        type=str,
        default="Benchmark Comparison",
        help="Title for Markdown output.",
    )
    parser.add_argument(
        "--json-out",
        type=str,
        default=None,
        help="Optional output path for JSON results.",
    )
    parser.add_argument(
        "--md-out",
        type=str,
        default=None,
        help="Optional output path for Markdown table.",
    )

    args = parser.parse_args(argv)

    if args.warmup < 0:
        print("error: --warmup must be >= 0", file=sys.stderr)
        return 1
    if args.rounds < 1:
        print("error: --rounds must be >= 1", file=sys.stderr)
        return 1
    if args.input_bytes is not None and args.input_bytes <= 0:
        print("error: --bytes must be > 0", file=sys.stderr)
        return 1
    if args.ops is not None and args.ops <= 0:
        print("error: --ops must be > 0", file=sys.stderr)
        return 1

    impls: List[Tuple[str, str]] = args.impl
    names = [name for name, _ in impls]
    if len(set(names)) != len(names):
        print("error: duplicate --impl names are not allowed", file=sys.stderr)
        return 1

    baseline_name = args.baseline if args.baseline is not None else names[0]
    if baseline_name not in names:
        print(
            "error: --baseline {!r} not found in implementations: {}".format(
                baseline_name, ", ".join(names)
            ),
            file=sys.stderr,
        )
        return 1

    expected_sha: Optional[str] = None
    if args.expect_sha256 is not None:
        expected_sha = args.expect_sha256.strip().lower()
        if not re.fullmatch(r"[0-9a-f]{64}", expected_sha):
            print("error: --expect-sha256 must be a 64-char hex digest", file=sys.stderr)
            return 1

    system = platform.system()
    ref_name: Optional[str] = None
    ref_sha: Optional[str] = None
    ref_stdout: Optional[bytes] = None

    times_ms: Dict[str, List[float]] = {name: [] for name in names}
    rss_all: Dict[str, List[int]] = {name: [] for name in names}
    cmd_map: Dict[str, str] = dict(impls)

    def verify_and_record(
        phase: str, round_idx: int, name: str, cmd: str, record: bool
    ) -> Optional[int]:
        nonlocal ref_name, ref_sha, ref_stdout
        elapsed_s, stdout_bytes, rss_bytes, rc, stderr_text = run_once(cmd, system)
        if rc != 0:
            print(
                "FAIL: implementation {!r} exited with code {} during {} round {}".format(
                    name, rc, phase, round_idx + 1
                ),
                file=sys.stderr,
            )
            if stderr_text.strip():
                print("--- stderr ---\n{}".format(stderr_text.strip()), file=sys.stderr)
            return 1

        digest = hashlib.sha256(stdout_bytes).hexdigest()

        if expected_sha is not None and digest != expected_sha:
            print(
                "FAIL: SHA-256 mismatch for {!r} ({} round {}):".format(
                    name, phase, round_idx + 1
                ),
                file=sys.stderr,
            )
            print("  expected: {}".format(expected_sha), file=sys.stderr)
            print("  actual  : {}".format(digest), file=sys.stderr)
            return 2

        if ref_sha is None:
            ref_name = name
            ref_sha = digest
            ref_stdout = stdout_bytes
        elif digest != ref_sha:
            print(
                "FAIL: stdout SHA-256 mismatch between {!r} and {!r} ({} round {}):".format(
                    ref_name, name, phase, round_idx + 1
                ),
                file=sys.stderr,
            )
            print("  {}: {}".format(ref_name, ref_sha), file=sys.stderr)
            print("  {}: {}".format(name, digest), file=sys.stderr)
            if ref_stdout is not None and ref_name is not None:
                print(summarize_diff(ref_name, ref_stdout, name, stdout_bytes), file=sys.stderr)
            return 2

        if record:
            times_ms[name].append(elapsed_s * 1000.0)
            if rss_bytes is not None:
                rss_all[name].append(rss_bytes)
        return None

    # Warmup phase (interleaved as well)
    n = len(impls)
    for w in range(args.warmup):
        order = impls[w % n :] + impls[: w % n]
        for name, cmd in order:
            err = verify_and_record("warmup", w, name, cmd, record=False)
            if err is not None:
                return err

    # Measured phase (strictly interleaved rotation each round)
    for r in range(args.rounds):
        order = impls[r % n :] + impls[: r % n]
        for name, cmd in order:
            err = verify_and_record("measured", r, name, cmd, record=True)
            if err is not None:
                return err

    baseline_median_ms = statistics.median(times_ms[baseline_name])
    results: List[Dict[str, Any]] = []
    for name in names:
        samples = times_ms[name]
        sorted_samples = sorted(samples)
        med_ms = statistics.median(samples)
        min_ms = sorted_samples[0]
        max_ms = sorted_samples[-1]
        p95_ms = percentile(sorted_samples, 95.0)
        mean_ms = statistics.mean(samples)
        peak_rss = max(rss_all[name]) if rss_all[name] else None

        med_s = med_ms / 1000.0
        mb_s = (
            (args.input_bytes / (med_s * 1e6))
            if (args.input_bytes is not None and med_s > 0.0)
            else None
        )
        ns_op = (
            ((med_s * 1e9) / args.ops)
            if (args.ops is not None and args.ops > 0)
            else None
        )
        speedup = (baseline_median_ms / med_ms) if med_ms > 0.0 else 0.0

        results.append(
            {
                "name": name,
                "command": cmd_map[name],
                "samples_ms": [round(x, 4) for x in samples],
                "median_ms": round(med_ms, 4),
                "min_ms": round(min_ms, 4),
                "max_ms": round(max_ms, 4),
                "p95_ms": round(p95_ms, 4),
                "mean_ms": round(mean_ms, 4),
                "throughput_mb_s": round(mb_s, 4) if mb_s is not None else None,
                "ns_per_op": round(ns_op, 4) if ns_op is not None else None,
                "peak_rss_bytes": peak_rss,
                "rss_samples_bytes": rss_all[name],
                "speedup_vs_baseline": round(speedup, 4),
            }
        )

    report: Dict[str, Any] = {
        "title": args.title,
        "platform": {
            "system": system,
            "release": platform.release(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "warmup": args.warmup,
        "rounds": args.rounds,
        "input_bytes": args.input_bytes,
        "ops": args.ops,
        "baseline": baseline_name,
        "sha256": ref_sha,
        "stdout_bytes": len(ref_stdout) if ref_stdout is not None else 0,
        "results": results,
    }

    md = render_markdown(report)
    sys.stdout.write(md)

    if args.md_out:
        md_dir = os.path.dirname(os.path.abspath(args.md_out))
        if md_dir:
            os.makedirs(md_dir, exist_ok=True)
        with open(args.md_out, "w", encoding="utf-8") as f:
            f.write(md)

    if args.json_out:
        json_dir = os.path.dirname(os.path.abspath(args.json_out))
        if json_dir:
            os.makedirs(json_dir, exist_ok=True)
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, sort_keys=False)
            f.write("\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
