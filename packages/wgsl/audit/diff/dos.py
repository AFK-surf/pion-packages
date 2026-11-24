#!/usr/bin/env python3
"""DoS probes: every generated hostile input, in its own process per build mode, must return a verdict
(`OK ...` or `ERR ...`) within the wall-clock budget. A crash (SIGSEGV / wasm RangeError), a hang or a
budget overrun is a FAIL.

usage: dos.py <dos_dir> <budget_s> <mode>=<runner...> ...
Each input runs with default ParseLimits; inputs named in LIMIT_PROBES also run with the given limits."""
import os
import shlex
import subprocess
import sys
import time

d, budget = sys.argv[1], float(sys.argv[2])
modes = [(a.split("=", 1)[0], shlex.split(a.split("=", 1)[1])) for a in sys.argv[3:]]
# ParseLimits values that look like "tighter" or "off": 0 and negatives silently mean "unlimited" for
# bytes/tokens, so the token cap no longer stops the 100k nesting probes.
LIMIT_PROBES = {"index_nest_10k": ["0", "0", "0"], "tokens_250k_plus": ["-1", "-1", "-1"],
                "paren_nest_100k": ["-1", "-1", "-1"], "binary_chain_2k": ["1", "1", "1"]}
bad = 0
for f in sorted(os.listdir(d)):
    if not f.endswith(".wgsl"):
        continue
    name = f[:-5]
    runs = [("default", [])] + ([("limits " + ",".join(LIMIT_PROBES[name]), LIMIT_PROBES[name])] if name in LIMIT_PROBES else [])
    for label, extra in runs:
        cells = []
        for mode, runner in modes:
            t0 = time.time()
            try:
                r = subprocess.run(runner + ["time", os.path.join(d, f)] + extra, capture_output=True, text=True,
                                   timeout=budget * 5)
                dt = time.time() - t0
                out = r.stdout.strip()
                if r.returncode != 0 or not (out.startswith("OK") or out.startswith("ERR")):
                    err = (r.stderr.strip().splitlines() or ["signal %d" % -r.returncode])[0]
                    v = "CRASH(rc=%d %s)" % (r.returncode, err[:48])
                elif dt > budget:
                    v = "SLOW %.2fs" % dt
                else:
                    v = out.split(" ", 2)[0] + " " + out.split(" ")[1].split("@")[0]
            except subprocess.TimeoutExpired:
                dt, v = budget * 5, "HANG"
            if v.startswith(("CRASH", "SLOW", "HANG")):
                bad += 1
            cells.append("%s %-34s %5.2fs" % (mode, v[:34], dt))
        size = os.path.getsize(os.path.join(d, f))
        print("  %-26s %-15s %8d B | %s" % (name, label, size, " | ".join(cells)))
sys.exit(1 if bad else 0)
