"""DoS / complexity measurements for the RT-unicode-segment audit (stdlib only).

    python3 -I -B dos.py <native_rel_binary> "<wasm runner + wasm_rel>" [<rust 1.13.3 oracle>]

Every bomb is built in-process by the audit binary (`bomb <kind> <units> <api>`), timed inside the process
(clock_monotonic_us around the single API call, fastest of 3 fresh processes) and run in a fresh process whose peak RSS is read with wait4.
Linearity: each (kind, api) runs at N and 4N units; a ratio t(4N)/t(N) above 8 (quadratic gives ~16) or a
4N run over 5 s is a finding. The cursor walk (`cursor <kind> <units>`: next_ then prev_grapheme_boundary over
the whole input, the README's cursor-navigation use) is measured the same way. wasm32 --release runs every
bomb at N and must report exactly what native reports.

Prints result lines, then `OPENIDS <ids>` for findings that reproduce, `INFOIDS <ids>`; exit 1 on a crash,
a wasm32/native divergence or an over-budget bomb that no finding explains.
"""

import os
import shlex
import subprocess
import sys
import time

KINDS = [  # kind, N units
    ("sb_aterm_close_sp", 100000), ("sb_aterm_close_extend_sp", 100000), ("sb_sterm_close_sp", 100000),
    ("sb_aterm_numeric_tail", 100000), ("sb8_long_scan", 1000000), ("wb_aletter_midletter", 100000),
    ("wb_numeric_midnum", 100000), ("wb_midletter_extend_run", 100000), ("wb_hebrew_dq", 100000),
    ("wb_ri", 100000), ("gb_incb_linker", 100000), ("gb_ep_zwj", 100000), ("gb_ri", 100000),
    ("gb_extend", 100000), ("gb_hangul", 100000), ("crlf", 100000), ("invalid_utf8", 100000),
    ("ko_prose", 20000), ("hi_prose", 20000), ("en_prose", 20000), ("mixed", 15000),
]
APIS = ["graphemes", "grapheme_count", "words", "unicode_words", "sentences"]
CURSOR = [  # kind, N units (small: the walk is what is measured)
    ("en_prose", 300), ("hi_prose", 300), ("ko_prose", 200), ("gb_hangul", 2000), ("gb_incb_linker", 2000),
    ("gb_extend", 4000), ("gb_ep_zwj", 2000), ("mixed", 200), ("gb_ri", 2000),
]
RATIO_MAX = 8.0
BUDGET_US = 5_000_000


def run(cmd):
    t0 = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.read().decode("utf-8", "replace")
    _, status, ru = os.wait4(p.pid, 0)
    p.stdout.close()
    rss = ru.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    code = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else status >> 8
    return code, out.strip(), rss, time.time() - t0


def timed(cmd, reps=3):
    """Fastest of up to `reps` runs of the in-process microsecond timer (one run when it already takes > 1 s):
    the minimum is the least load-sensitive estimate on a shared machine and still shows a quadratic as ~16x;
    returns (exit code, output of the last run, parsed fastest result, peak RSS)."""
    rs, code, out, rss = [], 0, "", 0
    for i in range(reps):
        code, out, rss1, _ = run(cmd)
        rss = max(rss, rss1)
        r = parse(out)
        if code != 0 or r is None:
            return code, out, None, rss
        rs.append(r)
        if r[1] > 1_000_000:
            break
    rs.sort(key=lambda x: x[1])
    return code, out, rs[0], rss


def parse(out):
    try:
        b, us, cnt = out.split()[-3:]
        return int(b), int(us), int(cnt)
    except ValueError:
        return None


# the same text units as audit/src/main.pion bomb_unit, for the Rust GraphemeCursor comparison
RUST_UNITS = {
    "ko_prose": "\uc548\ub155\ud558\uc138\uc694 \uc138\uacc4 \ubc18\uac11\uc2b5\ub2c8\ub2e4 ",
    "en_prose": "The quick brown fox jumps over the lazy dog. ",
    "gb_hangul": "\uac00\uac01",
}


def main():
    native = shlex.split(sys.argv[1])
    wasm = shlex.split(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
    rust = shlex.split(sys.argv[3]) if len(sys.argv) > 3 else None
    bad = []
    open_ids, info_ids = set(), set()
    worst = (0, "")
    max_rss = 0
    n_runs = 0
    print("  %-26s %-15s %9s %9s %9s %6s %8s" % ("bomb", "api", "bytes(4N)", "us(N)", "us(4N)", "ratio", "RSS(4N)"))
    for kind, n in KINDS:
        for api in APIS:
            res = []
            for units in (n, 4 * n):
                code, out, r, rss = timed(native + ["bomb", kind, str(units), api])
                n_runs += 1
                if code != 0 or r is None:
                    bad.append("%s %s %d: exit %d %s" % (kind, api, units, code, out[-200:]))
                    break
                res.append((r, rss))
            if len(res) < 2:
                continue
            (b1, t1, c1), _ = res[0]
            (b4, t4, c4), rss4 = res[1]
            max_rss = max(max_rss, rss4)
            ratio = t4 / max(t1, 1)
            flag = ""
            if t4 > BUDGET_US or (t1 >= 5000 and ratio > RATIO_MAX):
                flag = "  <-- NON-LINEAR"
                bad.append("%s %s: ratio %.1f, %d us" % (kind, api, ratio, t4))
            if t4 > worst[0]:
                worst = (t4, "%s/%s %d B" % (kind, api, b4))
            print("  %-26s %-15s %9d %9d %9d %6.2f %7.1fM%s" % (kind, api, b4, t1, t4, ratio, rss4 / 2**20, flag))
            if wasm:
                code, out, _, _ = run(wasm + ["bomb", kind, str(n), api])
                n_runs += 1
                r = parse(out)
                if code != 0 or r is None or (r[0], r[2]) != (b1, c1):
                    bad.append("%s %s: wasm32 %s != native %s" % (kind, api, out[-120:], (b1, c1)))
    print("  -> %d bomb runs, worst native 4N run %.3f s (%s), peak RSS %.1f MiB, wasm32 --release agrees: %s"
          % (n_runs, worst[0] / 1e6, worst[1], max_rss / 2**20, "yes" if wasm and not any("wasm32" in b for b in bad) else "n/a" if not wasm else "NO"))
    print("  cursor walk (next_grapheme_boundary to the end, then prev_grapheme_boundary back to 0):")
    print("  %-18s %9s %10s %10s %6s" % ("text", "bytes(4N)", "us(N)", "us(4N)", "ratio"))
    for kind, n in CURSOR:
        res = []
        for units in (n, 4 * n):
            code, out, r, _ = timed(native + ["cursor", kind, str(units)])
            if code != 0 or r is None:
                bad.append("cursor %s %d: exit %d %s" % (kind, units, code, out[-200:]))
                break
            res.append(r)
        if len(res) < 2:
            continue
        ratio = res[1][1] / max(res[0][1], 1)
        quad = res[0][1] >= 5000 and ratio > RATIO_MAX
        note = ""
        if quad and kind == "gb_ri":
            note = "  quadratic: RI parity needs the whole run (Rust GraphemeCursor too) -> INFO-4"
            info_ids.add("INFO-4")
        elif quad:
            note = "  <-- QUADRATIC (P1-1)"
            open_ids.add("P1-1")
        per_kb = res[1][1] / (res[1][0] / 1024.0) / 1000.0
        rs = ""
        if rust and kind in RUST_UNITS:
            code, out, r, _ = timed(rust + ["cursor", RUST_UNITS[kind].encode().hex(), str(4 * n)])
            if code == 0 and r and r[0] == res[1][0] and r[2] == res[1][2]:
                rs = "  [Rust GraphemeCursor, same walk: %d us]" % r[1]
            else:
                rs = "  [Rust walk differs: %s]" % out[-80:]
        print("  %-18s %9d %10d %10d %6.2f  (%.2f ms per KB walked)%s%s" % (kind, res[1][0], res[0][1], res[1][1], ratio, per_kb, note, rs))
    for b in bad:
        print("  FAIL " + b)
    print("OPENIDS " + " ".join(sorted(open_ids)))
    print("INFOIDS " + " ".join(sorted(info_ids)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
