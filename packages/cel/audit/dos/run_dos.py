#!/usr/bin/env python3
"""Run the DoS / limit probes against Pion (native + wasm32) and Go cel-go, print one table.

usage: run_dos.py <pion_dos_native> <go_dos> <pion_dos_pkg_dir> [--quick]
Each probe runs in its own process under /usr/bin/time -l (macOS) so crashes, wall time and
peak RSS are attributed to exactly one probe. Exit status 139 = SIGSEGV (native stack overflow).
"""
import re
import subprocess
import sys

pion, go, pkg = sys.argv[1:4]
quick = "--quick" in sys.argv


def timed(cmd, timeout=900):
    try:
        p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", 0.0, 0
    err = p.stderr.decode("utf-8", "replace")
    out = p.stdout.decode("utf-8", "replace").strip().split("\n")[-1:] or [""]
    real = re.search(r"([\d.]+) real", err)
    rss = re.search(r"(\d+)\s+maximum resident set size", err)
    status = out[0][:90]
    if p.returncode not in (0, 1):
        status = "CRASH rc=%d %s" % (p.returncode, "(SIGSEGV)" if p.returncode in (139, -11) else "")
    if "RangeError" in err or "Maximum call stack" in err:
        status = "CRASH wasm32 RangeError: Maximum call stack size exceeded"
    return status, float(real.group(1)) if real else 0.0, int(rss.group(1)) if rss else 0


def row(impl, probe, n, extra=()):
    if impl == "pion":
        cmd = [pion, probe, str(n)]
    elif impl.startswith("wasm32"):
        cmd = ["pionc", "run"] + (["--release"] if impl.endswith("rel") else []) + ["--target", "wasm32", pkg, "--", probe, str(n)]
    else:
        cmd = [go, probe, str(n)] + list(extra)
    st, t, rss = timed(cmd)
    print("| %-14s | %-13s | %7s | %8.2f | %8.1f | %s |" % (impl + (" cost=" + extra[0] if extra else ""), probe, n, t, rss / 1048576.0, st))


print("| impl | probe | n | wall s | RSS MiB | result |")
print("|---|---|---:|---:|---:|---|")
# P0-1 unbounded checker recursion: native and wasm32 crash points (see REPORT.md for the bisection)
for n in (300, 2000, 19000, 20000, 100000):
    row("pion", "check_chain", n)
for n in (300, 340, 2000):
    row("wasm32-dbg", "check_chain", n)
    row("wasm32-rel", "check_chain", n)
for n in (20000, 100000):
    row("pion", "check_member", n)
    row("pion", "check_index", n)
row("wasm32-rel", "check_member", 340)
row("wasm32-rel", "check_index", 340)
for n in (300, 20000):
    row("go", "check_chain", n)
row("go", "check_member", 20000)
# P1-10 false reject of flat chains
for n in (63, 70, 1000):
    row("pion", "or_chain", n)
    row("go", "or_chain", n)
# P0-2 output-bytes bypass (each value <= 1 MiB, result 2^n MiB)
for n in ((6, 8) if quick else (6, 8, 10)):
    row("pion", "mem_amp", n)
    row("go", "mem_amp", n)
    row("go", "mem_amp", n, ("1000000",))
# P0-3 cost bypass: linear scans charged as O(1)
for n in ((12, 14) if quick else (12, 14, 15, 16)):
    row("pion", "cpu_in", n)
    if n <= 15:
        row("go", "cpu_in", n)
    row("go", "cpu_in", n, ("1000000",))
for n in ((10,) if quick else (10, 12)):
    row("pion", "cpu_size", n)
    row("go", "cpu_size", n)
    row("go", "cpu_size", n, ("1000000",))
# linear-complexity cliffs (map lookup, Activation)
for n in ((12, 14) if quick else (12, 14, 16)):
    row("pion", "map_lookup", n)
    row("go", "map_lookup", n)
for n in (16, 512, 2048):
    row("pion", "act_lookup", n)
    row("go", "act_lookup", n)
