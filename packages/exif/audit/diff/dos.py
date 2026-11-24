#!/usr/bin/env python3
"""DoS budgets for packages/exif/audit:  dos.py <dos.json> <runner...>

Each bomb is parsed with default limits (`exif_audit time <file> <iters>`) under /usr/bin/time to read the peak RSS.
  P0 budget (gates run_audit.sh): verdict as listed in dos.json, no crash, <= 250 ms per parse, peak RSS <= 256 MiB.
  P2 budget (advisory, finding P2-3): peak RSS <= 16 MiB (4 x max_payload_bytes) for inputs < 64 KiB
  (DOS_ADVISORY=0 disables it, e.g. under node where RSS includes the JS engine).
Exit 1 on a P0 breach, 3 when only the advisory budget is exceeded, else 0.
"""

import json
import os
import re
import subprocess
import sys

P0_MS, P0_RSS, P2_RSS = 250.0, 256 << 20, 16 << 20


def peak_rss(cmd):
    if sys.platform == "darwin":
        p = subprocess.run(["/usr/bin/time", "-l"] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        m = re.search(rb"(\d+)\s+maximum resident set size", p.stderr)
        rss = int(m.group(1)) if m else -1
    else:
        p = subprocess.run(["/usr/bin/time", "-v"] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        m = re.search(rb"Maximum resident set size \(kbytes\): (\d+)", p.stderr)
        rss = int(m.group(1)) * 1024 if m else -1
    return p.returncode, p.stdout.decode("latin-1").strip(), p.stderr.decode("latin-1"), rss


def main():
    bombs = json.load(open(sys.argv[1]))
    runner = sys.argv[2:]
    p0 = p2 = 0
    for b in bombs:
        iters = 20
        rc, out, err, rss = peak_rss(runner + ["time", b["file"], str(iters)])
        rc1, _, _, rss1 = peak_rss(runner + ["time", b["file"], "1"])
        m = re.match(r"(OK|ERR \w+) fields=(\d+) us=(\d+)", out)
        probs = []
        if rc != 0 or not m:
            probs.append("P0 crash rc=%d %s" % (rc, (err.strip().splitlines() or [""])[-1][:120]))
            verdict, ms = "CRASH", 0.0
        else:
            verdict, ms = m.group(1), int(m.group(3)) / 1000.0 / iters
            want = b["verdict"]
            if want != "ANY" and not verdict.startswith(want):
                probs.append("P0 verdict %s, want %s" % (verdict, want))
            if ms > P0_MS:
                probs.append("P0 %.1f ms/parse > %.0f" % (ms, P0_MS))
        if rss1 > P0_RSS:
            probs.append("P0 rss %.1f MiB" % (rss1 / 1048576.0))
        adv = ""
        if os.environ.get("DOS_ADVISORY", "1") == "1" and b["size"] < 65536 and rss1 > P2_RSS:
            adv = "  <- P2-3 rss %.1f MiB > %d MiB from a %d B input" % (rss1 / 1048576.0, P2_RSS >> 20, b["size"])
            p2 += 1
        if any(x.startswith("P0") for x in probs):
            p0 += 1
        print("  %s %-30s %8d B  %-18s %8.3f ms/parse  rss %6.1f MiB%s%s" % (
            "FAIL" if probs else "ok  ", b["name"], b["size"], verdict, ms, rss1 / 1048576.0,
            ("  <- " + "; ".join(probs)) if probs else "", adv))
    print("  dos: %d bombs, %d P0 breach(es), %d advisory (P2-3) breach(es)" % (len(bombs), p0, p2))
    return 1 if p0 else (3 if p2 else 0)


if __name__ == "__main__":
    sys.exit(main())
