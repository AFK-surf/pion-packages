"""Delta-debug a Pion-vs-Rust `info` mismatch down to a minimal input (character granularity).
Usage: minimize.py <fuzz.json> [index...]   (fuzz.json from diff_fuzz.py --json)"""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run


def differs(recs):
    P, R = run("pion", "info", recs), run("rust", "info", recs)
    return [p != r for p, r in zip(P, R)]


def minimize(rec):
    d, s = rec[0], list(rec[1:])
    chunk = max(1, len(s) // 2)
    while chunk >= 1:
        changed = True
        while changed:
            changed = False
            cands = [s[:i] + s[i + chunk:] for i in range(0, len(s), chunk)]
            res = differs([d + "".join(c) for c in cands]) if cands else []
            for c, bad in zip(cands, res):
                if bad:
                    s, changed = c, True
                    break
        chunk //= 2
    return d + "".join(s)


if __name__ == "__main__":
    ex = json.load(open(sys.argv[1]))["examples"]
    idx = [int(x) for x in sys.argv[2:]] or range(len(ex))
    seen = set()
    for i in idx:
        m = minimize(ex[i][0])
        if m not in seen:
            seen.add(m)
            print(repr(m))
