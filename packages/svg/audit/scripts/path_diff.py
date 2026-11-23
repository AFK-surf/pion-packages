"""W3C SVG Path Data grammar + number parsing differential: Pion `parse_path` vs Rust svgtypes 0.15.3 PathParser.

Policy (documented in REPORT.md): Pion is all-or-nothing (returns Err on the first error) while svgtypes
yields the valid prefix; both rejecting = agreement. A path both accept must produce bit-identical
segments (svgtypes uses the correctly rounded `f64::from_str`)."""
import random, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from common import run, f64, ulps, Ledger

HAND = [
    # all 20 commands + implicit repeats
    "M10 20m1 2L30 40l3 4H50h5V60v6C1 2 3 4 5 6c1 2 3 4 5 6S7 8 9 10s1 2 3 4Q11 12 13 14q1 2 3 4T15 16t1 2A25 25-30 0 1 50-25a10 20 45 1 0 5 5Zz",
    "M0 0 1 1 2 2", "m0 0 1 1 2 2", "M1 2 3 4z m5 6 7 8", "M0 0L1 1 2 2 3 3", "M0 0H1 2 3V4 5 6",
    "M0 0C1 1 2 2 3 3 4 4 5 5 6 6", "M0 0Q1 1 2 2 3 3 4 4T5 5 6 6", "M0 0S1 1 2 2 3 3 4 4", "M0 0A1 1 0 0 1 2 2 1 1 0 0 1 3 3",
    "M0 0z", "M0 0zz", "M0 0z l1 1", "M0 0 z m1 1 z", "M0 0Z L5 5",
    # numbers
    "M1.2.3-4e-2", "M.5.5", "M1e+2-3", "M+1-2", "M1e2.5", "M-.5-.5", "M0.0.0", "M1E2 3E-1", "M 1e 2", "M1e- 2", "M1e+ 2",
    "M1em 2", "M1ex 2", "M.e1 2", "M. 2", "M- 1 2", "M+-1 2", "M1..2", "M00001.10000 2", "M1.e2 3", "M1.2e3.4e5",
    "M0.1 0.2", "M0.3 1.1", "M123456789012345678901234567890 1", "M1.234567890123456789012345 1",
    "M0.0000000000000000001 1", "M0.00000000000000000000123 1", "M1e-320 1", "M4.9e-324 1", "M2.2250738585072014e-308 1",
    "M1.7976931348623157e308 1", "M1.7976931348623158e308 1", "M1e308 1", "M1e309 1", "M1e400 1", "M-1e309 1",
    "M9007199254740993 1", "M0.30000000000000004 1", "M2.5e-5 1e-7", "M1e-7 1e-10",
    # separators
    "M10,10L20,20", "M10 , 10 L 20 , 20", "M10,,10", "M,10 10", "M10 10,L20 20", "M10 10L,20 20", "M10 10L20 20,",
    "M10,10,", "M\t10\n10\r\fL20 20", "M10 10", "M10 10 L20 20 ,", ",M10 10", " M10 10 ",
    # arc flags
    "M0 0a10 10 0 0110 10", "M0 0a10,10,0,1010,10", "M0 0a10 10 0 2 1 10 10", "M0 0a10 10 0 0 2 10 10",
    "M0 0a10 10 0 1 1 10 10", "M0 0a10 10 0 1,1 10,10", "M0 0a10 10 0 1 , 1 10 10", "M0 0a10 10 0 10 10", "M0 0a10 10 0 01.5.5",
    "M0 0a10 10 0 00-5-5", "M0 0a-10-10 0 1 1 5 5", "M0 0a10 10 0 01 10", "M0 0a10 10 0 1",
    # truncation / errors
    "M", "M10", "M10 10L", "M10 10L20", "M10 10C1 2 3 4 5", "L10 10", "m", "10 10", "Z", "z M0 0", "M0 0X1 1",
    "M0 0L1 1#", "M0 0 L1 1 ;", "", "   ", "M0 0L1 1 2",
]


def num(rng):
    k = rng.randrange(12)
    sign = rng.choice(["", "", "-", "+"])
    if k == 0:
        return sign + str(rng.randrange(1000))
    if k == 1:
        return sign + "." + str(rng.randrange(1000))
    if k == 2:
        return sign + f"{rng.uniform(0, 1000):.{rng.randrange(1, 12)}f}"
    if k == 3:
        return sign + f"{rng.randrange(1, 99)}e{rng.choice(['', '+', '-'])}{rng.randrange(0, 30)}"
    if k == 4:
        return sign + repr(rng.uniform(-1e6, 1e6)).lstrip("-")
    if k == 5:
        return sign + "".join(rng.choice("0123456789") for _ in range(rng.randrange(15, 30)))
    if k == 6:
        return sign + "0." + "0" * rng.randrange(0, 25) + str(rng.randrange(1, 10 ** 6))
    if k == 7:
        return sign + f"{rng.randrange(1, 10)}.{rng.randrange(10 ** 8)}e{rng.choice(['-', ''])}{rng.randrange(250, 330)}"
    if k == 8:
        return sign + repr(rng.random() * 10 ** rng.randrange(-30, 30))
    if k == 9:
        return sign + str(rng.randrange(1, 10)) + "." + str(rng.randrange(10 ** 17, 10 ** 19))
    if k == 10:
        return sign + "0"
    return sign + str(rng.randrange(10)) + "." + str(rng.randrange(10))


def gen(rng):
    out = ["M" if rng.random() < .5 else "m", num(rng), " ", num(rng)]
    arity = {"L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "M": 2}
    for _ in range(rng.randrange(1, 8)):
        c = rng.choice("LHVCSQTAZMlhvcsqtazm")
        out.append(c)
        if c in "Zz":
            continue
        reps = rng.choice([1, 1, 1, 2, 3])
        for _r in range(reps):
            if c in "Aa":
                vals = [num(rng), num(rng), num(rng)]
                sep = rng.choice([" ", ",", ""])
                out.append(" ".join(vals) + " " + rng.choice("01") + sep + rng.choice("01") + sep + num(rng) + " " + num(rng))
            else:
                out.append(rng.choice([" ", ","]).join(num(rng) for _ in range(arity[c.upper()])))
            out.append(rng.choice([" ", ",", "", "  "]))
    s = "".join(out)
    if rng.random() < 0.05:  # random corruption
        i = rng.randrange(len(s))
        s = s[:i] + rng.choice(",.-+eE#ZzA1 ") + s[i:]
    return s


def parse_dump(s):
    lines = s.split("\n")
    head = lines[0]
    segs = [l.split(" ") for l in lines[1:]]
    return head, segs


def main():
    fuzz = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    rng = random.Random(20261123)
    corpus = HAND + [gen(rng) for _ in range(fuzz)]
    P = run("pion", "path", corpus)
    # Two documented svgtypes deviations from the W3C grammar are neutralised before asking the oracle:
    #  * wsp includes U+000C FORM FEED (SVG 2 §9.3.9 / SVG 1.1 BNF) - svgtypes does not skip it;
    #  * `flag comma_wsp? flag`: comma_wsp may start with whitespace ("1 , 1") - svgtypes only takes "1,".
    import re
    R = run("rust", "path", [re.sub(r"(?<=[01]) +,", ",", d.replace("\f", " ")) for d in corpus])
    L = Ledger("path")
    accept_mismatch, num_mismatch, struct_mismatch = [], [], []
    for d, p, r in zip(corpus, P, R):
        ph, ps = parse_dump(p)
        rh, rs = parse_dump(r)
        if ph.startswith("ERR") and rh.startswith("ERR"):
            continue
        if ph.startswith("ERR") != rh.startswith("ERR"):
            accept_mismatch.append((d, ph, rh))
            continue
        if len(ps) != len(rs) or any(a[0] != b[0] or len(a) != len(b) for a, b in zip(ps, rs)):
            struct_mismatch.append((d, p, r))
            continue
        worst, wrel = 0, 0.0
        for a, b in zip(ps, rs):
            for x, y in zip(a[1:], b[1:]):
                if x != y:
                    worst = max(worst, ulps(f64(x), f64(y)))
                    fy = f64(y)
                    wrel = max(wrel, abs(f64(x) - fy) / abs(fy) if fy else float("inf"))
        if worst:
            num_mismatch.append((worst, d, wrel))
    print(f"  corpus={len(corpus)} accept/reject mismatches={len(accept_mismatch)} structure={len(struct_mismatch)} "
          f"number-bit mismatches={len(num_mismatch)}")
    for d, ph, rh in accept_mismatch[:12]:
        print(f"    ACCEPT? pion={ph:4s} svgtypes={rh:8s} d={d[:110]!r}")
    for d, p, r in struct_mismatch[:5]:
        print(f"    STRUCT d={d[:110]!r}\n      pion={p[:200]!r}\n      rust={r[:200]!r}")
    num_mismatch.sort(reverse=True)
    cls = {"1 ulp": 0, "2-16 ulp": 0, "17 ulp .. 1e-9 rel": 0, "GROSS > 1e-9 rel": 0}
    for w, d, rel in num_mismatch:
        k = "1 ulp" if w <= 1 else "2-16 ulp" if w <= 16 else "17 ulp .. 1e-9 rel" if rel <= 1e-9 else "GROSS > 1e-9 rel"
        cls[k] += 1
    print("  number mismatch classes (worst coordinate per path): " + ", ".join(f"{k}: {v}" for k, v in cls.items()))
    for w, d, rel in num_mismatch[:8]:
        print(f"    NUM ulps={w:.3g} rel={rel:.3g} d={d[:100]!r}")
    L.check("grammar: accept/reject agrees with svgtypes on every input", not accept_mismatch, "P2",
            f"{len(accept_mismatch)} inputs, e.g. {accept_mismatch[0][0]!r}" if accept_mismatch else "")
    L.check("grammar: identical segment structure for accepted paths", not struct_mismatch, "P2")
    L.check("numbers: every parsed coordinate is the correctly rounded f64 (0 ulp vs f64::from_str)",
            not num_mismatch, "P2",
            f"{len(num_mismatch)}/{len(corpus)} paths; worst {num_mismatch[0][0]:.3g} ulp on {num_mismatch[0][1][:80]!r}" if num_mismatch else "")
    sys.exit(L.save())


if __name__ == "__main__":
    main()
