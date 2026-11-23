#!/usr/bin/env python3
"""Compare Pion driver transcripts across build modes (native debug/release, wasm32 debug/release).

usage: cmp_builds.py <cases> <reference_cmd> <other_cmd> [label]

Both commands are shell-split prefixes; `<cases> <resume_line>` is appended. Crashes are
skipped and resumed (like run_diff.py). Prints one JSON line: blocks compared, identical,
differing (with the first examples) and crash count of the *other* build.
"""
import json
import shlex
import subprocess
import sys

from run_diff import blocks


def run_all(cmd, cases, n):
    out, crashes, resume = {}, [], 1
    while True:
        p = subprocess.run(shlex.split(cmd) + [cases, str(resume)], capture_output=True, timeout=900)
        bl = blocks(p.stdout.decode("utf-8", "replace"))
        out.update(bl)
        if p.returncode == 0:
            return out, crashes
        done = max(bl.keys(), default=resume - 1)
        crashes.append(done + 1)
        resume = done + 2
        if resume > n:
            return out, crashes


def main():
    cases, ref_cmd, other_cmd = sys.argv[1:4]
    label = sys.argv[4] if len(sys.argv) > 4 else other_cmd
    n = len(open(cases, encoding="utf-8").read().split("\n"))
    ref, ref_crash = run_all(ref_cmd, cases, n)
    oth, oth_crash = run_all(other_cmd, cases, n)
    diff = [k for k in oth if ref.get(k) != oth[k]]
    print(json.dumps({
        "label": label, "cases": cases.rsplit("/", 1)[-1], "reference_crashes": len(ref_crash),
        "other_blocks": len(oth), "identical": len(oth) - len(diff), "differing": len(diff),
        "other_crashes": len(oth_crash), "first_crash_lines": oth_crash[:5],
        "first_diff_lines": diff[:5],
    }))


if __name__ == "__main__":
    main()
