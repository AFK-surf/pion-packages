#!/usr/bin/env python3
"""DoS / limits run over the gen_dos.py corpus in every build mode.

usage: dos.py <dos_dir> <bin_dir> <wasm_rt> <out_tsv>
Default limits (audit/probe `stat`) in native_rel / native_dbg / wasm_rel / wasm_dbg: graded on the expected
regex, exit status 0, wall time (native <= 20 s, wasm <= 120 s) and identical summary lines across modes.
Lifted limits (audit/limits_probe, every field 2^31-1) on the deep / wide inputs: graded on clean exit only;
SKIPPED when limits_probe did not build (FeedLimits API changed).
Exit 1 on any graded failure.
"""
import os
import re
import subprocess
import sys
import time


def run(cmd, timeout):
    t = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace").strip(), p.stderr.decode("utf-8", "replace").strip()[-300:], time.time() - t
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "", "", time.time() - t


def main():
    dos_dir, b, rt, out_tsv = sys.argv[1:5]
    modes = [("native_rel", [b + "/probe"], 20), ("native_dbg", [b + "/probe_dbg"], 20),
             ("wasm_rel", ["node", rt, b + "/probe.wasm"], 120), ("wasm_dbg", ["node", rt, b + "/probe_dbg.wasm"], 120)]
    exp = [l.rstrip("\n").split("\t") for l in open(os.path.join(dos_dir, "expect.tsv"))]
    fails, rows = [], []
    for name, rx in exp:
        path = os.path.realpath(os.path.join(dos_dir, name + ".in"))
        seen = {}
        for mode, cmd, lim in modes:
            rc, outl, err, dt = run(cmd + ["stat", path], lim)
            seen[mode] = outl
            ok = rc == 0 and re.search(rx, outl) is not None
            rows.append((name, mode, "%.2fs" % dt, str(rc), outl or err))
            if not ok:
                fails.append("%s [%s] rc=%s %.2fs: %s (want /%s/) %s" % (name, mode, rc, dt, outl, rx, err))
        if len(set(seen.values())) != 1:
            fails.append("%s: summaries differ across modes: %r" % (name, seen))
    lifted = os.path.exists(b + "/limits_probe")
    lmodes = [("native_rel", [b + "/limits_probe"], 60), ("wasm_rel", ["node", rt, b + "/limits_probe.wasm"], 180)]
    if lifted:
        for name in ["xhtml_deep_100k", "xml_deep_1m", "json_deep_1m", "atom_entries_10001", "text_4mib_plus1",
                     "feed_links_100k", "categories_100k", "dot_segments_200k"]:
            path = os.path.realpath(os.path.join(dos_dir, name + ".in"))
            for mode, cmd, lim in lmodes:
                rc, outl, err, dt = run(cmd + ["lifted", path], lim)
                rows.append((name + "@lifted", mode, "%.2fs" % dt, str(rc), outl or err))
                if rc != 0 or not outl.startswith(("ok", "err")):
                    fails.append("%s@lifted [%s] rc=%s %.2fs: %s %s" % (name, mode, rc, dt, outl, err))
        small = os.path.realpath(os.path.join(dos_dir, "links_64.in"))
        for which in ("zero", "negative"):
            for mode, cmd, lim in lmodes:
                rc, outl, err, dt = run(cmd + [which, small], lim)
                rows.append(("links_64@" + which, mode, "%.2fs" % dt, str(rc), outl or err))
                if rc != 0 or not outl.startswith("err"):
                    fails.append("links_64@%s [%s] rc=%s: %s (want fail-closed err) %s" % (which, mode, rc, outl, err))
    with open(out_tsv, "w") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    w = max(len(r[0]) for r in rows)
    for r in rows:
        print("  %-*s %-10s %7s rc=%-3s %s" % (w, r[0], r[1], r[2], r[3], r[4][:110]))
    if not lifted:
        print("  lifted-limit runs SKIPPED: audit/limits_probe did not build (FeedLimits API changed?)")
    print("DoS graded failures: %d" % len(fails))
    for f_ in fails:
        print("  FAIL " + f_)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
