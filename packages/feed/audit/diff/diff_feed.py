#!/usr/bin/env python3
"""Spec-graded differential run: Pion probe vs feed-rs =2.4.0 oracle over vectors.py.

usage: diff_feed.py <out_dir> <pion_probe> <rust_oracle>
Exit 1 if any graded check (P*/ctl) disagrees with the spec expectation; feed-rs agreement is informational.
"""
import collections
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runner import run_batch, write_requests  # noqa: E402
from vectors import V  # noqa: E402


def show(x):
    return x if not callable(x) else x.__name__


def main():
    out, probe, oracle = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    req = os.path.join(out, "diff_requests.tsv")
    write_requests(req, [(vid, "P", data) for vid, _, data, _ in V])
    _, pb, _, _ = run_batch([probe], req)
    _, ob, _, _ = run_batch([oracle], req)
    fails = collections.OrderedDict()
    graded = agree = disagree_rs = 0
    lines = []
    for vid, tag, _, checks in V:
        p, o = pb.get(vid, {}), ob.get(vid, {})
        for key, exp in checks:
            pv = p.get(key, "-" if key == "err" or "err" not in p else "<err %s>" % p.get("err"))
            ov = o.get(key, "-" if key == "err" or "err" not in o else "<err %s>" % o.get("err"))
            if exp is None:
                lines.append("  info  %-34s %-16s pion=%-40s feed-rs=%s" % (vid, key, pv, ov))
                continue
            graded += 1
            ok = exp(pv) if callable(exp) else pv == exp
            rs_ok = exp(ov) if callable(exp) else ov == exp
            agree += rs_ok
            disagree_rs += not rs_ok
            if not ok:
                fails.setdefault(tag, []).append((vid, key, show(exp), pv, ov))
    print("graded checks: %d, Pion failures: %d (in %d findings); feed-rs matches the spec expectation on %d/%d"
          % (graded, sum(len(v) for v in fails.values()), len(fails), agree, graded))
    for tag, rows in fails.items():
        print("\n[%s] %d failing check(s)" % (tag, len(rows)))
        for vid, key, exp, pv, ov in rows:
            print("  FAIL %-32s %-16s want=%-38s pion=%-38s feed-rs=%s" % (vid, key, exp, pv, ov))
    print("\ninformational rows (not graded):")
    print("\n".join(lines))
    with open(os.path.join(out, "diff_failures.tsv"), "w") as f:
        for tag, rows in fails.items():
            for r in rows:
                f.write("\t".join([tag] + [str(x) for x in r]) + "\n")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
