#!/usr/bin/env python3
"""Line-level delta-debugging shrinker for a Pion-vs-imara mismatch.

usage: shrink.py --oracle BIN --runner BIN --field HP [--require-equal HS] BEFORE AFTER
Prints the minimized (before, after) as Python literals and both outputs.
"""
import argparse, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fuzz import write_cases, run

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--oracle", required=True); ap.add_argument("--runner", required=True)
    ap.add_argument("--field", required=True); ap.add_argument("--require-equal", default="")
    ap.add_argument("before"); ap.add_argument("after")
    a = ap.parse_args()
    tmp = tempfile.mktemp(suffix=".bin")
    def bad(b, af):
        write_cases(tmp, [("".join(b), "".join(af))])
        x, y = run(a.oracle, tmp)[0], run(a.runner, tmp)[0]
        if x[a.field] == y[a.field]:
            return False
        return all(x[f] == y[f] for f in a.require_equal.split(",") if f)
    B = open(a.before, newline="").read().split("\n"); A = open(a.after, newline="").read().split("\n")
    B = [x + "\n" for x in B[:-1]] + ([B[-1]] if B[-1] else [])
    A = [x + "\n" for x in A[:-1]] + ([A[-1]] if A[-1] else [])
    assert bad(B, A), "seed does not reproduce"
    changed = True
    while changed:
        changed = False
        # remove a line present at the same "role" in both (shared context) or from one side
        for side in ("both", "b", "a"):
            i = 0
            while True:
                n = len(B) if side != "a" else len(A)
                if i >= n: break
                if side == "both":
                    if B[i] not in A: i += 1; continue
                    j = A.index(B[i])
                    nb, na = B[:i] + B[i+1:], A[:j] + A[j+1:]
                elif side == "b":
                    nb, na = B[:i] + B[i+1:], A
                else:
                    nb, na = B, A[:i] + A[i+1:]
                if bad(nb, na):
                    B, A, changed = nb, na, True
                else:
                    i += 1
    write_cases(tmp, [("".join(B), "".join(A))])
    x, y = run(a.oracle, tmp)[0], run(a.runner, tmp)[0]
    print("before =", repr("".join(B))); print("after  =", repr("".join(A)))
    for f in [a.field] + [f for f in a.require_equal.split(",") if f]:
        print(f"{f}: rust={x[f]!r}\n{f}: pion={y[f]!r}")

if __name__ == "__main__":
    main()
