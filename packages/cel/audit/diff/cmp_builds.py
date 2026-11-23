#!/usr/bin/env python3
"""Byte-compare the Pion transcript of one build mode against the native-debug reference.
usage: cmp_builds.py <cases> <reference_cmd> <other_cmd> <label>"""
import hashlib
import shlex
import subprocess
import sys

cases, ref_cmd, other_cmd, label = sys.argv[1:5]


def run(cmd):
    p = subprocess.run(shlex.split(cmd) + [cases], capture_output=True, timeout=3600)
    return p.stdout, p.returncode, p.stderr.decode("utf-8", "replace")


ref, rrc, _ = run(ref_cmd)
oth, orc, err = run(other_cmd)
traps = sum(1 for k in ("RangeError", "RuntimeError", "unreachable", "wasm trap", "panic") if k in err)
ra, oa = ref.split(b"\n"), oth.split(b"\n")
diffs = sum(1 for a, b in zip(ra, oa) if a != b) + abs(len(ra) - len(oa))
print("%-15s %s cases=%d sha256 ref=%s %s=%s byte_identical=%s diff_lines=%d rc=%d traps=%d" % (
    label, cases.rsplit("/", 1)[-1], ref.count(b"## "), hashlib.sha256(ref).hexdigest()[:16], label,
    hashlib.sha256(oth).hexdigest()[:16], ref == oth, diffs, orc, traps))
