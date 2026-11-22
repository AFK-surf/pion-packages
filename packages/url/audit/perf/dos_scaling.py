#!/usr/bin/env python3
"""Adversarial-input scaling (DoS) probe: Pion `url` vs Rust `url v2.5.9 --release`.

Each workload is one (or a few) hostile input(s) of size n and 4n, run through the
differential drivers with the `L` (lengths-only output) prefix. Reports the median
wall time of 3 runs per size, the Pion/Rust ratio at 4n and the empirical growth
exponent log(t(4n)/t(n))/log(4) (~1 linear, ~2 quadratic; process start-up makes
small inputs read below 1). A workload is flagged SUPERLINEAR when Pion's exponent
is >= 1.6 and its 4n time is >= 10x Rust's, SLOW(>=10x) when only the latter holds.

Usage: dos_scaling.py <pion_bin> <rust_bin> <out.md>
Exit status 0 always (findings are data, not a harness failure).
"""
import math
import statistics
import subprocess
import sys
import time


def h(x):
    return "~" if x is None else x.encode().hex()


def case(*f):
    return "\t".join(h(x) for x in f)


def cjk(n):
    return "".join(chr(0x4E00 + (i * 7919) % 20000) for i in range(n))


def puny(s):
    return s.encode("punycode").decode()


# (name, n, builder(n) -> list of case lines, note)
WORKLOADS = [
    ("userinfo: n x '@' in authority", 20000,
     lambda n: [case("LP", "https://" + "@" * n + "example.com/")], ""),
    ("password: n x '@' after ':'", 20000,
     lambda n: [case("LP", "https://u:" + "@" * n + "h/")], ""),
    ("IDNA encode: one n-char CJK label", 10000,
     lambda n: [case("LP", "https://" + cjk(n) + ".com/")],
     "rust-url/idna rejects labels > 1000 chars (PUNYCODE_ENCODE_MAX_INPUT_LENGTH)"),
    ("IDNA decode: xn-- label of n CJK chars", 5000,
     lambda n: [case("LP", "https://xn--" + puny(cjk(n)) + ".com/")],
     "rust-url/idna rejects A-labels > 2000 bytes (PUNYCODE_DECODE_MAX_INPUT_LENGTH)"),
    ("setters: 1000 x set_hash on an n-segment URL", 12500,
     lambda n: [case("LS", "https://h/" + "a/" * n, *(["hash", "x"] * 1000))],
     "rust-url setters are O(len(component)); Pion re-parses the whole URL record"),
    ("setters: 1000 x set_query on an n-segment URL", 12500,
     lambda n: [case("LS", "https://h/" + "a/" * n, *(["set_query", "x=1"] * 1000))], ""),
    ("control: n x '../' path", 20000,
     lambda n: [case("LP", "https://example.com/" + "../" * n + "x")], ""),
    ("control: n x '%2e%2e/' path", 20000,
     lambda n: [case("LP", "https://example.com/" + "%2e%2e/" * n + "x")], ""),
    ("control: n x 'a/../' path", 20000,
     lambda n: [case("LP", "https://example.com/" + "a/../" * n + "x")], ""),
    ("control: n x 'é' labels", 20000,
     lambda n: [case("LP", "https://" + "é." * n + "com/")], ""),
    ("control: n x '%41' host", 20000,
     lambda n: [case("LP", "https://" + "%41" * n + ".com/")], ""),
    ("control: 3n-byte path needing encoding", 25000,
     lambda n: [case("LP", "https://h/" + "é<>" * n)], ""),
    ("control: QueryParams n reversed keys + sort()", 25000,
     lambda n: [case("LM", "&".join("k%06d=v" % (n - i) for i in range(n)), "sort")],
     "merge sort above 24 pairs: O(n log n), not O(n^2)"),
    ("control: QueryParams n/10 deletes on n pairs", 2500,
     lambda n: [case("LM", "&".join("k%05d=v" % i for i in range(n)),
                     *sum([["d", "k%05d" % i] for i in range(0, n, 10)], []))],
     "O(n*k) in both (rust Vec::retain); shown for completeness"),
]


def run(binary, data):
    t0 = time.perf_counter()
    p = subprocess.run([binary], input=data, capture_output=True, timeout=600)
    dt = time.perf_counter() - t0
    return dt, p.stdout, p.returncode


def med(binary, data, reps=3):
    ts, out, rc = [], None, None
    for _ in range(reps):
        dt, out, rc = run(binary, data)
        ts.append(dt)
    return statistics.median(ts), out, rc


def main():
    pion, rust, out_md = sys.argv[1:4]
    rows = []
    for name, n, build, note in WORKLOADS:
        res = {}
        for size in (n, 4 * n):
            data = ("\n".join(build(size)) + "\n").encode()
            tp, op, rcp = med(pion, data)
            tr, orr, rcr = med(rust, data)
            res[size] = (tp, tr, op == orr, len(data), rcp, rcr)
        (tp1, tr1, s1, b1, _, _), (tp4, tr4, s4, b4, rcp, rcr) = res[n], res[4 * n]
        ep = math.log(max(tp4, 1e-6) / max(tp1, 1e-6), 4)
        er = math.log(max(tr4, 1e-6) / max(tr1, 1e-6), 4)
        flag = ("SUPERLINEAR" if ep >= 1.6 and tp4 >= 10 * tr4 else
                "SLOW(>=10x)" if tp4 >= 10 * tr4 else "")
        rows.append((name, n, b4, tp1, tp4, tr1, tr4, tp4 / tr4, ep, er, s4, flag, note, rcp, rcr))
        print("%-46s n=%-6d pion %8.1f -> %8.1f ms (x^%.2f)  rust %6.1f -> %6.1f ms (x^%.2f)  "
              "ratio@4n %7.1fx  same_output=%s %s" % (name, n, tp1 * 1e3, tp4 * 1e3, ep, tr1 * 1e3,
                                                       tr4 * 1e3, er, tp4 / tr4, s4, flag))
        sys.stdout.flush()
    with open(out_md, "w") as f:
        f.write("| workload | n | input @4n | pion n / 4n (ms) | rust n / 4n (ms) | pion/rust @4n | "
                "growth pion / rust | same output | verdict | note |\n")
        f.write("| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- |\n")
        for (name, n, b4, tp1, tp4, tr1, tr4, ratio, ep, er, same, flag, note, rcp, rcr) in rows:
            f.write("| %s | %d | %.1f KB | %.1f / %.1f | %.1f / %.1f | **%.1fx** | n^%.2f / n^%.2f | %s | %s | %s |\n"
                    % (name, n, b4 / 2048.0, tp1 * 1e3, tp4 * 1e3, tr1 * 1e3, tr4 * 1e3, ratio,
                       ep, er, "yes" if same else "no", flag or "ok", note))


if __name__ == "__main__":
    main()
