#!/usr/bin/env python3
"""Run the Pion driver and the Go cel-go oracle on one case file and bucket the differences.

usage: run_diff.py <pion_cmd> <go_oracle> <cases> <out_prefix>
A case MATCHES when both sides give the same `OK <value>` or both give an error (any phase).
Phase-only differences (e.g. Pion CERR vs Go EERR) are counted separately as `phase`.
"""
import shlex
import subprocess
import sys


def transcript(cmd, cases):
    p = subprocess.run(shlex.split(cmd) + [cases], capture_output=True, timeout=1800)
    res = {}
    cur = None
    for line in p.stdout.decode("utf-8", "replace").split("\n"):
        if line.startswith("## "):
            cur = int(line[3:])
        elif cur is not None and line:
            res[cur] = line
            cur = None
    return res, p.returncode, p.stderr.decode("utf-8", "replace")[-2000:]


def kind(r):
    return "OK" if r.startswith("OK ") else ("ERR" if r else "MISSING")


def main():
    pion_cmd, go_cmd, cases, prefix = sys.argv[1:5]
    lines = open(cases).read().split("\n")
    pt, prc, perr = transcript(pion_cmd, cases)
    gt, grc, gerr = transcript(go_cmd, cases)
    total = match = phase = 0
    bad = []
    for i, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        total += 1
        p, g = pt.get(i, ""), gt.get(i, "")
        mode, hx = line.split("\t")[:2]
        tag = line.split("\t")[2] if line.count("\t") >= 2 else ""
        expr = bytes.fromhex(hx).decode("utf-8", "replace")
        if kind(p) == "OK" and kind(g) == "OK":
            if p == g:
                match += 1
                continue
        elif kind(p) == "ERR" and kind(g) == "ERR":
            match += 1
            if p.split("\t")[0] != g.split("\t")[0]:
                phase += 1
            continue
        bad.append((i, mode, tag, expr, p, g))
    with open(prefix + ".mismatch.txt", "w") as f:
        for i, mode, tag, expr, p, g in bad:
            f.write("#%d [%s/%s] %s\n  pion: %s\n  go:   %s\n" % (i, mode, tag, expr, p, g))
    print("cases=%d match=%d mismatch=%d (phase-only-diff among matches=%d) pion_rc=%d go_rc=%d" % (
        total, match, len(bad), phase, prc, grc))
    if prc != 0:
        print("  pion stderr tail:", perr.strip()[-400:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
