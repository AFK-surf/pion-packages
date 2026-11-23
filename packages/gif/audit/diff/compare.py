#!/usr/bin/env python3
"""Differential driver: Pion `gif_audit digest` vs Go `gifdiff digest` (image/gif + browser compositor).

usage: compare.py <strict|fuzz> <dir> <go_bin> <pion_cmd...>

strict: every input must be accepted by Go and Pion must give the identical digest (frames, loop count,
        SHA-256 over delay/disposal/RGBA of every composited frame).
fuzz:   mutated inputs. FAIL on: Pion crash / panic / missing line, Go OK but Pion ERR, both OK but digests
        differ. "Go ERR, Pion OK" is a leniency, counted per Go error message (Pion follows browsers).
Exit status 1 on any FAIL.
"""
import collections
import glob
import os
import re
import subprocess
import sys

CHUNK = 400


def run_lines(cmd, files, timeout=600):
    r = subprocess.run(cmd + files, capture_output=True, text=True, timeout=timeout)
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2 and parts[0] in files:
            out[parts[0]] = parts[1]
    return out, r.returncode, r.stderr


def pion_digest(cmd, files):
    """Run Pion in chunks; re-run file by file to pin down a crashing input."""
    res = {}
    for i in range(0, len(files), CHUNK):
        chunk = files[i:i + CHUNK]
        out, rc, err = run_lines(cmd, chunk)
        if rc == 0 and len(out) == len(chunk):
            res.update(out)
            continue
        for f in chunk:
            try:
                o, rc1, err1 = run_lines(cmd, [f], timeout=60)
            except subprocess.TimeoutExpired:
                res[f] = "CRASH timeout"
                continue
            if rc1 != 0 or f not in o:
                msg = (err1.strip().splitlines() or ["rc=%d" % rc1])[-1]
                res[f] = "CRASH " + msg[:120]
            else:
                res[f] = o[f]
    return res


def over_default_limits(g):
    """Go line "OK <frames> <loop> <sha> <W>x<H>": True when packages/gif's DecodeLimits::default() applies."""
    p = g.split()
    frames = int(p[1])
    w, h = (int(x) for x in p[4].split("x"))
    return (w > 16384 or h > 16384 or w * h > 16777216 or frames > 4096
            or frames * w * h * 4 > 268435456)


def norm(v):
    # "OK <frames> <loop> <sha>" -> compare all fields; ERR -> class only
    p = v.split()
    return " ".join(p[:4]) if p and p[0] == "OK" else p[0]


def main():
    mode, d, go_bin = sys.argv[1], sys.argv[2], sys.argv[3]
    pion_cmd = sys.argv[4:]
    files = sorted(glob.glob(os.path.join(d, "*.gif")))
    go = {}
    for i in range(0, len(files), CHUNK):
        o, _, _ = run_lines([go_bin, "digest"], files[i:i + CHUNK])
        go.update(o)
    pi = pion_digest(pion_cmd, files)
    stats = collections.Counter()
    lenient = collections.Counter()
    fails = []
    for f in files:
        g, p = go.get(f, "MISSING"), pi.get(f, "MISSING")
        if p.startswith("CRASH") or p == "MISSING":
            fails.append((f, "pion crash: " + p, g))
            stats["pion_crash"] += 1
            continue
        if g.startswith("SKIP"):
            stats["skip_go_quirk"] += 1
            continue
        if mode == "strict" and not g.startswith("OK"):
            fails.append((f, "go rejected a corpus input", g))
            continue
        if g.startswith("OK") and p.startswith("OK"):
            if norm(g) == norm(p):
                stats["both_ok_identical"] += 1
            else:
                stats["both_ok_DIFFERENT"] += 1
                fails.append((f, "digest mismatch pion=" + p, g))
        elif g.startswith("OK"):
            if p == "ERR LimitExceeded" and over_default_limits(g):
                stats["limit_policy"] += 1
                continue
            stats["go_ok_pion_err"] += 1
            fails.append((f, "pion rejected what go accepts: " + p, g))
        elif p.startswith("OK"):
            stats["go_err_pion_ok"] += 1
            msg = g.split(" ", 1)[1] if " " in g else g
            lenient[re.sub(r"(_0x[0-9a-f]{2}|:_[0-9]+)$", "", msg)] += 1
        else:
            stats["both_err"] += 1
    print("  inputs: %d" % len(files))
    for k in sorted(stats):
        print("  %-22s %d" % (k, stats[k]))
    for k, v in lenient.most_common():
        print("    lenient (Go ERR, Pion OK) %-44s %d" % (k, v))
    for f, why, g in fails[:25]:
        print("  FAIL %s :: %s :: go=%s" % (os.path.basename(f), why, g))
    if len(fails) > 25:
        print("  ... %d more failures" % (len(fails) - 25))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
