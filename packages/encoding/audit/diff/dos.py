#!/usr/bin/env python3
"""DoS budget gate for packages/encoding (native release; also usable under node for wasm32).

  dos.py <pion runner...> -- <oracle bin>

Decoder bombs: 1 MiB and 4 MiB of a repeated malformed/stateful pattern, whole buffer and 1-byte chunks.
  P0: crash, > 2000 ms per MiB, peak RSS > 256 MiB, or superlinear growth (4 MiB > 8x the 1 MiB time).
Encoder worst cases: encode_html of 1 MiB of one code point that takes the slowest table search.
  P0: crash or > 30 s per MiB.  P1 (finding P1-1): > 1000 ms per MiB.
Exit status: 0 within budget, 1 P0, 3 only the P1 encoder budget exceeded.
"""
import resource
import subprocess
import sys
import time

DECODE_BOMBS = [
    ("gb18030", "81308130"), ("gb18030", "81308120"), ("gb18030", "8130"), ("gb18030", "81"), ("gb18030", "ff"),
    ("GBK", "8130817f"), ("ISO-2022-JP", "1b2842"), ("ISO-2022-JP", "1b24"), ("ISO-2022-JP", "1b"),
    ("ISO-2022-JP", "1b24422121"), ("ISO-2022-JP", "0e"), ("UTF-8", "ff"), ("UTF-8", "f090"), ("UTF-8", "efbb"),
    ("UTF-8", "e0"), ("UTF-16LE", "00d8"), ("UTF-16BE", "41"), ("Big5", "8840"), ("Big5", "87"), ("EUC-JP", "8f"),
    ("EUC-JP", "8fa1"), ("Shift_JIS", "81"), ("Shift_JIS", "8120"), ("EUC-KR", "c720"), ("x-user-defined", "ff"),
    ("windows-1252", "81"), ("replacement", "ff"),
]
# (encoding, utf-8 hex of one code point) chosen to hit the longest linear table scans
ENCODE_WORST = [
    ("Big5", "c3a9"), ("Big5", "e9be98"), ("Big5", "eab080"), ("Big5", "f0a08080"), ("gb18030", "e9be98"),
    ("gb18030", "e4b8ad"), ("GBK", "e9be98"), ("Shift_JIS", "e9be98"), ("Shift_JIS", "e4b8ad"), ("EUC-JP", "e9be98"),
    ("ISO-2022-JP", "e9be98"), ("EUC-KR", "e4b8ad"), ("EUC-KR", "e9be98"), ("windows-1252", "e9be98"),
    ("GBK", "e38182"), ("EUC-KR", "eab080"),
]
MiB = 1 << 20


def run(cmd):
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    wall = (time.time() - t0) * 1000
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    rss_mib = (rss if sys.platform == "darwin" else rss * 1024) / MiB
    if p.returncode != 0 or not p.stdout.strip():
        return None, wall, rss_mib, (p.stdout + p.stderr).strip()[-200:]
    return p.stdout.strip(), wall, rss_mib, ""


def main():
    sep = sys.argv.index("--")
    pion = sys.argv[1:sep]
    oracle = sys.argv[sep + 1] if len(sys.argv) > sep + 1 else None
    p0, p1 = [], []
    print("  decoder bombs (ms = in-process decode time; 4M = 4 MiB input):")
    for enc, pat in DECODE_BOMBS:
        row = []
        for chunk in (0, 1):
            out1, _, rss1, err1 = run(pion + ["time", enc, pat, str(MiB), str(chunk)])
            out4, _, rss4, err4 = run(pion + ["time", enc, pat, str(4 * MiB), str(chunk)])
            if out1 is None or out4 is None:
                p0.append("%s %s chunk=%d crashed: %s" % (enc, pat, chunk, err1 or err4))
                row.append("CRASH")
                continue
            ms1, ms4 = int(out1.split()[0]), int(out4.split()[0])
            if ms1 > 2000 or ms4 > 4 * 2000:
                p0.append("%s %s chunk=%d: %d ms/MiB" % (enc, pat, chunk, ms1))
            if ms1 >= 20 and ms4 > 8 * ms1:
                p0.append("%s %s chunk=%d superlinear: 1 MiB %d ms, 4 MiB %d ms" % (enc, pat, chunk, ms1, ms4))
            if max(rss1, rss4) > 256:
                p0.append("%s %s chunk=%d: peak RSS %.0f MiB" % (enc, pat, chunk, max(rss1, rss4)))
            row.append("%s %4d/%5d ms rss<=%3.0f MiB" % ("whole" if chunk == 0 else "1-byte", ms1, ms4, max(rss1, rss4)))
        print("    %-14s %-10s %s" % (enc, pat, " | ".join(row)))
    print("  encoder worst cases (encode_html of 1 MiB of one code point; ms, pion vs encoding_rs 0.8.44 default features):")
    for enc, cp in ENCODE_WORST:
        out, _, rss, err = run(pion + ["enctime", enc, cp, str(MiB)])
        if out is None:
            p0.append("encode %s %s crashed: %s" % (enc, cp, err))
            continue
        ms = int(out.split()[0])
        ref = "-"
        if oracle:
            o, _, _, _ = run([oracle, "enctime", enc, cp, str(MiB)])
            if o:
                ref = o.split()[0]
        ratio = (" %5.1fx slower" % (ms / max(1, int(ref)))) if ref != "-" else ""
        print("    %-12s U+%-6s pion %5d ms  encoding_rs %5s ms%s" % (enc, "%04X" % ord(bytes.fromhex(cp).decode()), ms, ref, ratio))
        if ms > 30000:
            p0.append("encode %s %s: %d ms/MiB" % (enc, cp, ms))
        elif ms > 1000:
            p1.append("encode %s U+%04X: %d ms/MiB" % (enc, ord(bytes.fromhex(cp).decode()), ms))
    for x in p0:
        print("  P0: " + x)
    for x in p1:
        print("  P1-1 budget (1000 ms/MiB) exceeded: " + x)
    if p0:
        return 1
    return 3 if p1 else 0


if __name__ == "__main__":
    sys.exit(main())
