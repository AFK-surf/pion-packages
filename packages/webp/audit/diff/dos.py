#!/usr/bin/env python3
"""DoS / bomb budget check for `webp_audit time` (verdict + microseconds) and peak RSS.

usage: dos.py <native|wasm> <dir> <pion_cmd...>
native: every probe must give the expected verdict within its wall-clock and peak-RSS budget (FAIL otherwise).
wasm:   same probes under wasm32 release, information only: tag = verdict + time; RSS includes node itself.
"""
import os
import re
import subprocess
import sys

# file -> (expected verdict prefix, decode budget ms, peak RSS budget MiB (native), why)
PROBES = [
    ("vp8l_16383sq_header.webp", "ERR LimitExceeded", 5, 16, "14-bit VP8L maximum, rejected before allocation"),
    ("vp8l_16384sq_header.webp", "ERR LimitExceeded", 5, 16, "VP8L 16384^2"),
    ("vp8x_16777216sq.webp", "ERR LimitExceeded", 5, 16, "VP8X 24-bit canvas maximum"),
    ("vp8x_16384sq_alph.webp", "ERR LimitExceeded", 5, 16, "VP8X 16384^2 + ALPH"),
    ("vp8_16383sq.webp", "ERR LimitExceeded", 5, 16, "VP8 14-bit maximum"),
    ("vp8l_4096sq_solid_bomb.webp", "OK 4096x4096", 1500, 160, "34-byte file -> 64 MiB RGBA (largest default-limit image)"),
    ("vp8_4096sq_truncated.webp", "ERR UnexpectedEof", 500, 96, "46-byte VP8 4096^2, all partitions empty"),
    ("alph_vp8l_4096sq_bomb_truncated_vp8.webp", "ERR", 1500, 160, "16M-px VP8L ALPH plane + truncated VP8"),
    ("chunk_count_bomb_1M.webp", "OK 3x2", 500, 64, "1,048,576 empty unknown chunks (8 MiB)"),
    ("vp8l_meta_huffman_group_index_2600.webp", "ERR LimitExceeded", 50, 32, "meta prefix group index 2600 (cap)"),
    ("vp8l_meta_huffman_2600_groups_complete.webp", "OK 208x200", 1500, 128,
     "862 KB file, 2600 groups x complete maximal codes (libwebp: 42 MiB RSS)"),
    ("vp8l_meta_huffman_2600_groups_incomplete.webp", "ERR", 1500, 128,
     "125 KB file, 2600 groups x incomplete 15-bit codes (libwebp and x/image/webp reject)"),
]


def measure(cmd, path):
    if sys.platform == "darwin":
        full = ["/usr/bin/time", "-l"] + cmd + ["time", path]
    else:
        full = ["/usr/bin/time", "-v"] + cmd + ["time", path]
    try:
        r = subprocess.run(full, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", 120000.0, -1
    line = (r.stdout.strip().splitlines() or ["CRASH " + ((r.stderr.strip().splitlines() or ["?"])[0])])[-1]
    m = re.search(r"us=(\d+)", line)
    ms = int(m.group(1)) / 1000.0 if m else -1
    verdict = re.sub(r"\s*us=\d+", "", line)
    rss = -1
    m = re.search(r"(\d+)\s+maximum resident set size", r.stderr)
    if m:
        rss = int(m.group(1)) / 1048576.0
    m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", r.stderr)
    if m:
        rss = int(m.group(1)) / 1024.0
    if "panic" in r.stderr or r.returncode not in (0,):
        verdict = "CRASH rc=%d %s" % (r.returncode, (r.stderr.strip().splitlines() or [""])[-1][:80])
    return verdict, ms, rss


def main():
    mode, d = sys.argv[1], sys.argv[2]
    cmd = sys.argv[3:]
    bad = 0
    for name, want, budget, rss_budget, why in PROBES:
        path = os.path.join(d, name)
        verdict, ms, rss = measure(cmd, path)
        ok = verdict.startswith(want) and 0 <= ms <= budget
        if mode == "native":
            ok = ok and 0 <= rss <= rss_budget
        tag = "ok  " if ok else ("FAIL" if mode == "native" else "info")
        rb = ("%4d" % rss_budget) if mode == "native" else " n/a"
        print("  %s %-48s %-24s %9.2f ms (budget %5d)  rss %7.1f MiB (budget %s)  %s"
              % (tag, name, verdict[:24], ms, budget, rss, rb, why))
        if mode == "native" and not ok:
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
