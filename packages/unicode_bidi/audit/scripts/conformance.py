"""Unicode 16.0.0 conformance: BidiCharacterTest.txt (91k cases) + BidiTest.txt (all class
sequences x paragraph directions) run through BOTH the Pion probe and the Rust oracle (`pcl` mode:
paragraph level + per-char L1 levels; visual order derived with L2 over non-removed chars).
Usage: conformance.py [--json out.json] [--show N]
"""
import json, os, sys, collections
sys.path.insert(0, os.path.dirname(__file__))
from common import UCD, CLASSES, REP, run

DIRC = {"0": "0", "1": "1", "2": "-"}


def l2(levels):
    order = list(range(len(levels)))
    if not levels:
        return order
    hi, lo = max(levels), min(levels)
    lo |= 1
    while hi >= lo:
        i = 0
        while i < len(levels):
            if levels[i] >= hi:
                j = i
                while j < len(levels) and levels[j] >= hi:
                    j += 1
                order[i:j] = order[i:j][::-1]
                i = j
            else:
                i += 1
        hi -= 1
    return order


def check(cases, outs):
    """cases: list of (exp_para_level|None, exp_levels(list with None for x), exp_order|None)."""
    fails = []
    for k, ((pl, lv, order), out) in enumerate(zip(cases, outs)):
        s = out.decode()
        if s.startswith("PANIC"):
            fails.append((k, s)); continue
        a, b = s.split(";")
        got = [int(x) for x in b.split(",")] if b else []
        ok = len(got) == len(lv) and (pl is None or int(a) == pl)
        if ok:
            ok = all(e is None or e == g for e, g in zip(lv, got))
        if ok and order is not None:
            kept = [i for i, e in enumerate(lv) if e is not None]
            vis = [kept[i] for i in l2([got[i] for i in kept])]
            ok = vis == order
        if not ok:
            fails.append((k, s))
    return fails


def char_cases():
    recs, cases, src = [], [], []
    for ln in open(os.path.join(UCD, "BidiCharacterTest.txt"), encoding="utf-8"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        f = ln.split(";")
        text = "".join(chr(int(c, 16)) for c in f[0].split())
        lv = [None if x == "x" else int(x) for x in f[3].split()]
        order = [int(x) for x in f[4].split()]
        recs.append(DIRC[f[1]] + text)
        cases.append((int(f[2]), lv, order))
        src.append(ln)
    return recs, cases, src


def class_cases():
    recs, cases, src = [], [], []
    levels = order = None
    for ln in open(os.path.join(UCD, "BidiTest.txt"), encoding="utf-8"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        if ln.startswith("@Levels:"):
            levels = [None if x == "x" else int(x) for x in ln[8:].split()]; continue
        if ln.startswith("@Reorder:"):
            order = [int(x) for x in ln[9:].split()]; continue
        if ln.startswith("@"):
            continue
        seq, bits = ln.split(";")
        text = "".join(REP[c] for c in seq.split())
        bits = int(bits)
        for bit, d in ((1, "-"), (2, "0"), (4, "1")):
            if bits & bit:
                recs.append(d + text)
                cases.append((None, levels, order))
                src.append(f"{seq.strip()} dir={d} levels={levels} order={order}")
    return recs, cases, src


def main():
    show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 5
    report = {}
    for name, (recs, cases, src) in (("BidiCharacterTest", char_cases()), ("BidiTest", class_cases())):
        for impl in ("pion", "rust"):
            fails = check(cases, run(impl, "pcl", recs))
            report[f"{name}/{impl}"] = dict(total=len(cases), failed=len(fails),
                                            examples=[(src[k], o) for k, o in fails[:show]])
            print(f"  {name:18s} {impl:5s} total={len(cases):7d} failed={len(fails)}")
            for k, o in fails[:show]:
                print(f"      FAIL {src[k][:160]}\n           got {o[:160]}")
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
