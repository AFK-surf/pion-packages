"""DoS / complexity probes for packages/unicode_linebreak (stdlib only).

Each bomb is a repeated unit built *inside* the audit binary (`unicode_linebreak_audit bomb <hex> <reps> <rounds>
<op>`), which times only the library call with clock_monotonic_us and reports the median of `rounds` runs, so
process start-up, file I/O and single-run jitter of a shared, loaded machine do not enter the ratio. Every bomb
runs at n and 4n bytes; the 4n/n median ratio must stay < 8 (linear: 4, quadratic: 16; 8 is their geometric midpoint); a pair over the
limit is re-measured up to twice and the lowest ratio kept (load on a shared machine only inflates ratios). The big size also gets
an absolute budget and must not crash (no recursion: 1,000,000-unit runs).

  dos.py <bin> [<wasm runner prefix>]   -> table; `OPENIDS <ids>` for overruns explained by open findings;
                                           exit 1 on a crash, a result that differs between n-scaled runs and
                                           the expected opportunity count, or an unexplained overrun
"""
import subprocess
import sys

ROUNDS = 7
RATIO_MAX = 8.0  # geometric midpoint of linear (4x) and quadratic (16x) growth for a 4x input

# (id, description, unit, reps at n, expected opportunities at reps r (lambda), op, budget us at 4n, finding)
B = [
    ("d01", "SP x 250k", " ", 250000, lambda r: 1, "breaks", 2000000, None),
    ("d02", "a + CM x 250k", "́", 250000, None, "breaks", 2000000, None),
    ("d03", "ZWJ x 250k", "‍", 250000, lambda r: 1, "breaks", 2000000, None),
    ("d04", "QU (\") x 250k", '"', 250000, lambda r: 1, "breaks", 2000000, None),
    ("d05", "QU_Pf x 250k (LB15b lookahead)", "»", 125000, None, "breaks", 2000000, None),
    ("d06", "OP SP* (\"( \" x 125k)", "( ", 125000, None, "breaks", 2000000, None),
    ("d07", "CL CP SP* (\")) \" x 80k)", ")) ", 80000, None, "breaks", 2000000, None),
    ("d08", "NU IS NU chain (\"1.\" x 125k)", "1.", 125000, lambda r: 1, "breaks", 2000000, None),
    ("d09", "NU SY NU chain (\"1/\" x 125k)", "1/", 125000, lambda r: 1, "breaks", 2000000, None),
    ("d10", "PR OP NU (\"$(1\" x 80k)", "$(1", 80000, None, "breaks", 2000000, None),
    ("d11", "PR OP IS CM* NU (LB25 double lookahead)", "$(." + "́" * 30 + "1", 4000, None, "breaks", 2000000, None),
    ("d12", "RI x 125k", "\U0001F1E6", 62500, None, "breaks", 2000000, None),
    ("d13", "AK VI AK (Balinese)", "ᬅ᭄", 62500, None, "breaks", 2000000, None),
    ("d14", "HY AL (\" -a\" x 80k)", " -a", 80000, None, "breaks", 2000000, None),
    ("d15", "QU_Pi SP* (\"« \" x 80k)", "« ", 80000, None, "breaks", 2000000, None),
    ("d16", "Pf + CM run per unit (LB15b lookahead over CM)", "»" + "́" * 50, 2500, None, "breaks", 2000000, None),
    ("d17", "CJK QU CJK (LB19a lookahead)", "一“", 62500, None, "breaks", 2000000, None),
    ("d18", "AK AK + CM run (LB28a VF lookahead)", "ᬅ" + "᬴" * 40, 3000, None, "breaks", 2000000, None),
    ("d19", "SP IS + CM run (LB15c lookahead)", " ." + "́" * 40, 3000, None, "breaks", 2000000, None),
    ("d20", "ill-formed bytes 0xFF x 250k", b"\xff", 250000, None, "breaks", 2000000, None),
    ("d21", "truncated 4-byte lead x 250k", b"\xf0\x9f\x98", 80000, None, "breaks", 2000000, None),
    ("d22", "mixed news text", "Hello, world! 中文排版「引号」 $(1,234.56) 🇺🇸 👩‍💻 א-ב á\r\n", 4000, None,
     "breaks", 2000000, None),
    ("d23", "line_breaks_with_limits default, \"a \" x 125k", "a ", 125000, lambda r: r, "limits",
     2000000, None),
    ("d24", "next_break_opportunity(s, len-1), \"a \" x 125k", "a ", 125000, lambda r: 1, "nbo_last", 2000000, None),
    ("d25", "iterate next_break_opportunity, \"a \" x 2k", "a ", 2000, lambda r: r, "nbo_iter", 200000, "P1-1"),
]


def enc(u):
    return u if isinstance(u, bytes) else u.encode("utf-8")


def run(cmd, unit, reps, op):
    args = cmd + ["bomb", enc(unit).hex(), str(reps), str(ROUNDS), op]
    try:
        r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"
    if r.returncode != 0:
        return None, "exit %d %s" % (r.returncode, r.stderr.decode(errors="replace")[:160])
    p = r.stdout.decode().split()
    if len(p) != 5:
        return None, "bad output %r" % r.stdout[:120]
    return [int(x) for x in p[:4]] + [p[4]], None


def main(argv):
    runners = [("native", argv[0].split())]
    if len(argv) > 1:
        runners.append(("wasm32", argv[1].split()))
    rc = 0
    opened = set()
    print("  %-4s %-48s %-7s %10s %10s %7s %12s" % ("id", "bomb", "runner", "n us", "4n us", "ratio", "4n bytes"))
    for bid, desc, unit, reps, expect, op, budget, finding in B:
        for rname, cmd in runners:
            if rname == "wasm32" and op == "nbo_iter":
                reps_n = reps // 2
            else:
                reps_n = reps
            best = None
            for attempt in range(3):  # noise on a shared machine only ever inflates a ratio: keep the best
                a, err = run(cmd, unit, reps_n, op)
                b, err2 = run(cmd, unit, reps_n * 4, op) if a else (None, None)
                if not a or not b:
                    break
                # tiny timings are dominated by clock granularity: compare with a 200 us floor
                ratio_f = max(b[0], 200) / max(a[0], 200)
                if best is None or ratio_f < best[0]:
                    best = (ratio_f, a, b)
                if ratio_f < RATIO_MAX and not (rname == "native" and b[0] > budget):
                    break
            if not a or not b:
                print("  %-4s %-48s %-7s CRASH %s" % (bid, desc[:48], rname, err or err2))
                rc = 1
                continue
            ratio_f, a, b = best
            ratio = b[0] / max(a[0], 1)
            over = ratio_f >= RATIO_MAX or (rname == "native" and b[0] > budget)
            if expect is not None and (a[3] != expect(reps_n) or b[3] != expect(reps_n * 4)):
                print("  %s: opportunity count %d / %d, want %d / %d" % (bid, a[3], b[3], expect(reps_n), expect(reps_n * 4)))
                rc = 1
            tag = ""
            if over:
                if finding:
                    opened.add(finding)
                    tag = "  OVER (%s)" % finding
                else:
                    tag = "  OVER (unexplained)"
                    rc = 1
            elif finding:
                tag = "  (%s no longer reproduces)" % finding
            print("  %-4s %-48s %-7s %10d %10d %7.2f %12d%s" % (bid, desc[:48], rname, a[0], b[0], ratio, b[2], tag))
    if opened:
        print("OPENIDS " + " ".join(sorted(opened)))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
