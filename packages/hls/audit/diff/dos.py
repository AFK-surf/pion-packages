#!/usr/bin/env python3
"""DoS bombs for packages/hls under the default HlsLimits.

usage: dos.py <dir> <native_release_cmd> <wasm_release_cmd>
       dos.py <dir> --list-only          (only write the bomb files)

Every bomb is parsed once per runner (`<cmd> bomb <file>`) with a wall-clock timeout. A bomb passes when the
process exits normally (Ok or Err) within its time budget, with peak RSS <= RSS_BUDGET, and when the native and
wasm32 outputs are identical. A bomb tagged with a finding id that misses its budget is reported OPEN for that
id; a crash / trap / timeout / divergence (or any miss on an untagged bomb) is a P0 failure.
Prints `OPENIDS <ids>` and exits 1 on any P0 failure.
"""

import os
import subprocess
import sys
import time

RSS_BUDGET = 1 << 30
H = "#EXTM3U\n"
BIG = "x" * 65000


def defines(n):
    return "".join('#EXT-X-DEFINE:NAME="v%d",VALUE="x"\n' % i for i in range(n))


def bombs():
    """(name, text, native budget s, wasm budget s, finding id or None, description)."""
    b = []
    add = lambda *a: b.append(a)
    add("b00_expand_segments", H + "#EXT-X-TARGETDURATION:1\n#EXT-X-DEFINE:NAME=\"a\",VALUE=\"%s\"\n" % BIG +
        "#EXTINF:1,\n{$a}\n" * 70000, 3, 3, "P0-1", "1.2 MB: 70k segment URIs of {$a} (65 kB each) -> 4.5 GB")
    add("b01_expand_parts", H + "#EXT-X-TARGETDURATION:1\n#EXT-X-PART-INF:PART-TARGET=1\n#EXT-X-DEFINE:NAME=\"a\",VALUE=\"%s\"\n"
        % BIG + '#EXT-X-PART:DURATION=1,URI="{$a}"\n' * 70000, 3, 3, "P0-1", "2.4 MB: 70k EXT-X-PART URI={$a} -> 4.5 GB")
    laughs = H + '#EXT-X-DEFINE:NAME="l0",VALUE="xxxx"\n' + "".join(
        '#EXT-X-DEFINE:NAME="l%d",VALUE="{$l%d}{$l%d}"\n' % (i, i - 1, i - 1) for i in range(1, 31))
    add("b02_billion_laughs", laughs + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$l30}\n", 2, 3, None,
        "30-level doubling DEFINE chain (2^30 x 4 bytes if VALUEs were expanded)")
    add("b03_defines_quadratic", H + defines(80000) + "#EXT-X-STREAM-INF:BANDWIDTH=1\nu\n", 2, 3, "P1-3",
        "3 MB: 80k distinct EXT-X-DEFINE (duplicate check is a linear scan)")
    add("b04_refs_quadratic", H + defines(20000) + ("#EXT-X-STREAM-INF:BANDWIDTH=1\n" + "{$v19999}" * 7000 + "\n") * 30,
        2, 3, "P1-3", "2.6 MB: 210k references to the last of 20k variables (lookup is a linear scan)")
    add("b05_line_at_limit", H + "#EXT-X-STREAM-INF:BANDWIDTH=1\n" + "u" * 65536 + "\n", 2, 3, None, "64 KiB URI line")
    add("b06_line_over_limit", H + "#EXT-X-STREAM-INF:BANDWIDTH=1\n" + "u" * 65537 + "\n", 2, 3, None, "64 KiB + 1 line")
    add("b07_unclosed_quotes", H + ('#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="' + "a," * 30000 + "\nu\n") * 200, 2, 3, None,
        "200 x 60 kB unclosed quoted string")
    add("b08_max_segments", H + "#EXT-X-TARGETDURATION:1\n" + "#EXTINF:1,\ns.ts\n" * 99990, 2, 3, None,
        "99990 segments (max_lines allows < 100000), 1.6 MB")
    add("b09_max_segments_plus1", H + "#EXT-X-TARGETDURATION:1\n" + "#EXTINF:1,\ns.ts\n" * 100001, 2, 3, None,
        "100001 segments")
    add("b10_attr_lists", H + "#EXT-X-TARGETDURATION:1\n" + ('#EXT-X-DATERANGE:ID="i",START-DATE="2026-01-01T00:00:00Z",' +
        ",".join("X-A%d=1" % i for i in range(254)) + "\n") * 7500, 2, 3, None, "7500 x 256-attribute lists, 16 MB")
    add("b11_overflow_numbers", H + "#EXT-X-TARGETDURATION:1\n" + ("#EXTINF:99999999999999999999.5,\na\n#EXT-X-BYTERANGE:"
        "9223372036854775808@1\na\n") * 20000, 2, 3, None, "40k integer / decimal overflows")
    add("b12_custom_tags", H + "#EXT-X-TARGETDURATION:1\n" + "#EXT-X-FOO:%s\n" % ("v" * 1000) * 5000, 2, 3, None,
        "5000 unknown tags (max_custom_tags 4096)")
    add("b13_blank_lines", H + "\n" * 200001, 2, 3, None, "200001 blank lines (max_lines)")
    add("b14_input_limit", H + "#" * (16777216 - len(H) + 1), 2, 3, None, "16 MiB + 1 byte")
    add("b15_brace_scan", H + '#EXT-X-DEFINE:NAME="a",VALUE="x"\n' + ("#EXT-X-STREAM-INF:BANDWIDTH=1\n" + "{" * 60000 +
        "{$a}\n") * 200, 2, 3, None, "200 lines of 60k '{' before a reference")
    add("b16_media_tags", H + ('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="g",NAME="n",URI="%s"\n' % ("m" * 20)) * 190000 +
        "#EXT-X-STREAM-INF:BANDWIDTH=1\nv\n", 2, 3, None, "190k EXT-X-MEDIA (not bounded by max_variants), 13 MB")
    add("b17_dateranges", H + "#EXT-X-TARGETDURATION:1\n" + '#EXT-X-DATERANGE:ID="d",START-DATE="2026-01-01T00:00:00Z"\n'
        * 190000, 2, 3, None, "190k EXT-X-DATERANGE, 11 MB")
    return b


def rss_run(cmd, path, budget):
    """Run with /usr/bin/time to obtain the peak RSS (macOS -l: bytes, GNU -v: KiB)."""
    tf = path + ".time"
    flag = "-l" if sys.platform == "darwin" else "-v"
    t0 = time.monotonic()
    p = subprocess.Popen(["/usr/bin/time", flag, "-o", tf] + cmd + ["bomb", path], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    timed_out = False
    try:
        out, _ = p.communicate(timeout=max(budget * 10, 60))
    except subprocess.TimeoutExpired:
        p.kill()
        out, _ = p.communicate()
        timed_out = True
    secs = time.monotonic() - t0
    rss = 0
    try:
        for line in open(tf):
            if "maximum resident set size" in line:
                rss = int(line.split()[0])
            elif "Maximum resident set size" in line:
                rss = int(line.split()[-1]) * 1024
        os.unlink(tf)
    except OSError:
        pass
    text = out.decode("latin-1").strip().split("\n")
    last = text[-1] if text else ""
    crash = p.returncode != 0 or not (last.startswith("OK ") or last.startswith("ERR "))
    return last, crash, secs, timed_out, rss, text


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    bs = bombs()
    for name, text, *_ in bs:
        with open(os.path.join(d, name + ".m3u8"), "w") as f:
            f.write(text)
    if sys.argv[2] == "--list-only":
        return 0
    native = sys.argv[2].split()
    wasm = sys.argv[3].split()
    p0 = 0
    opened = []
    for name, text, nb, wb, fid, desc in bs:
        path = os.path.join(d, name + ".m3u8")
        res = []
        for label, cmd, budget in (("native", native, nb), ("wasm32", wasm, wb)):
            last, crash, secs, to, rss, raw = rss_run(cmd, path, budget)
            res.append((label, last, crash, secs, to, rss, budget, raw))
        problems = []
        hard = []
        for label, last, crash, secs, to, rss, budget, raw in res:
            if to:
                hard.append("%s TIMEOUT" % label)
            elif crash:
                msg = next((x for x in raw if "panic" in x or "Error" in x), raw[-1] if raw else "")
                hard.append("%s CRASH (%s)" % (label, msg[:90]))
            else:
                if secs > budget:
                    problems.append("%s %.1fs > %ds" % (label, secs, budget))
                if rss > RSS_BUDGET:
                    problems.append("%s RSS %d MiB > %d MiB" % (label, rss >> 20, RSS_BUDGET >> 20))
        if not hard and res[0][1] != res[1][1]:
            hard.append("native/wasm32 outputs differ")
        line = "  %-24s %-60s native %5.2fs %5d MiB | wasm32 %5.2fs %5d MiB | %s" % (
            name, desc[:60], res[0][3], res[0][5] >> 20, res[1][3], res[1][5] >> 20, res[0][1][:60] if not res[0][2] else "-")
        print(line)
        if hard or problems:
            what = "; ".join(hard + problems)
            if fid:
                print("    -> %s: %s" % (fid, what))
                opened.append(fid)
                if hard and fid.startswith("P0"):
                    p0 += 1
            else:
                print("    -> P0 (untagged bomb): %s" % what)
                p0 += 1
    print("OPENIDS " + " ".join(sorted(set(opened))))
    return 1 if p0 else 0


if __name__ == "__main__":
    sys.exit(main())
